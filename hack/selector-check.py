#!/usr/bin/env python3
"""Assert the two selector properties a single render cannot show.

A selector that carries a label moving with the chart version renders exactly
like one that does not: `spec.selector` of a workload accepts `helm.sh/chart`,
and only the *next* chart release discovers that the API server refuses to
change it (`spec.selector: Invalid value: ...: field is immutable`). Chart 2.0.1
shipped that, so every upgrade of every release it created failed; the fix is a
fixed label subset, and this script is the gate that keeps it fixed.

It reads a rendered manifest and checks, for every workload and Service:

  * no selector key is `helm.sh/chart`, `app.kubernetes.io/version` or
    `app.kubernetes.io/managed-by` - values that are a function of the chart
    version or of the release, not of the workload's identity. On a workload the
    selector is immutable, so such a key makes the next chart release
    unapplyable; on a Service the selector is mutable but the new one is applied
    before the new pods exist, so the old pods' endpoints are dropped for the
    whole rollout window.
  * every workload's own pod template carries the pairs its selector asks for -
    a selector its own pods do not match is a workload that never becomes
    available.

usage: hack/selector-check.py <rendered-manifest.yaml> [<label>]

Exits 0 when the render is clean, 1 on the first render with a finding (every
finding in that render is printed), and 2 when the input holds no workload or no
Service - an empty check is not a passed check. The `lint` job in
.github/workflows/ci.yaml runs this over the chart defaults and every
ci/*-values.yaml fixture.
"""

import sys

import yaml

MOVING = (
    "helm.sh/chart",
    "app.kubernetes.io/version",
    "app.kubernetes.io/managed-by",
)
WORKLOAD_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job")


def name_of(doc):
    return (doc.get("metadata") or {}).get("name") or "?"


def check(path, label):
    docs = [doc for doc in yaml.safe_load_all(open(path)) if isinstance(doc, dict)]
    problems = []
    workloads = 0
    services = 0
    templates = []

    for doc in docs:
        kind, spec = doc.get("kind"), doc.get("spec") or {}
        if kind in WORKLOAD_KINDS:
            workloads += 1
            selector = (spec.get("selector") or {}).get("matchLabels") or {}
            labels = ((spec.get("template") or {}).get("metadata") or {}).get("labels") or {}
            templates.append(labels)
            if not selector:
                problems.append(f"{kind}/{name_of(doc)} has no spec.selector.matchLabels")
            for key, value in selector.items():
                if key in MOVING:
                    problems.append(
                        f"{kind}/{name_of(doc)} selects on {key}: it changes with every "
                        "chart release and spec.selector is immutable, so the next "
                        "upgrade cannot be applied")
                if labels.get(key) != value:
                    problems.append(
                        f"{kind}/{name_of(doc)} selects {key}={value}, which its own pod "
                        f"template does not carry ({labels.get(key)!r})")
        elif kind == "Service":
            if not spec.get("selector"):
                problems.append(f"Service/{name_of(doc)} renders no selector at all")
                continue
            services += 1
            for key in spec["selector"]:
                if key in MOVING:
                    problems.append(
                        f"Service/{name_of(doc)} selects on {key}: the endpoints of every "
                        "pod that does not carry the new value are dropped as soon as "
                        "the chart is applied")

    for doc in docs:
        if doc.get("kind") != "Service":
            continue
        selector = (doc.get("spec") or {}).get("selector") or {}
        if selector and not any(all(labels.get(k) == v for k, v in selector.items())
                                for labels in templates):
            problems.append(
                f"Service/{name_of(doc)} selects {selector}, which no pod template in "
                "this render matches")

    for entry in problems:
        print(f"::error::a selector breaks an upgrade - {label}: {entry}")
    if problems:
        return 1
    if workloads == 0 or services == 0:
        print(f"::error::{label}: the render has no workloads or no Services, so "
              "nothing was checked")
        return 2
    print(f"{label}: {workloads} workload selectors and {services} Service selectors "
          "are immutable and match their pods")
    return 0


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: hack/selector-check.py <rendered-manifest.yaml> [<label>]",
              file=sys.stderr)
        return 2
    path = argv[1]
    label = argv[2] if len(argv) == 3 else path
    return check(path, label)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
