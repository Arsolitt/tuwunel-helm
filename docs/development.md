# Development and releases

> Repository layout, the fixture contract, the local command set and the CI jobs behind this chart, and how a release tag becomes a published release.

## Table of Contents

- [Repository layout](#repository-layout)
- [Fixture categories](#fixture-categories)
- [Local validation](#local-validation)
- [The CI jobs](#the-ci-jobs)
- [The runtime check](#the-runtime-check)
- [Releasing](#releasing)
- [Adding or changing a value](#adding-or-changing-a-value)
- [Working in this repo](#working-in-this-repo)

---

## Repository layout

This is a single-chart repository: `charts/tuwunel` is the only chart, and `.github/workflows/ci.yaml` the only pipeline.

```text
tuwunel-helm/
├── .github/
│   ├── workflows/ci.yaml          # the only pipeline: jobs lint, schema, runtime, release-tag, release
│   ├── ISSUE_TEMPLATE/            # bug_report.yml, feature_request.yml, config.yml
│   ├── CODEOWNERS                 # `* @Arsolitt`
│   ├── dependabot.yml             # weekly, grouped GitHub Actions updates
│   └── PULL_REQUEST_TEMPLATE.md   # what changed / how it was verified / checklist
├── charts/tuwunel/                # the chart
│   ├── Chart.yaml                 # name tuwunel, version 2.0.2, appVersion v1.9.2, kubeVersion '>=1.31.0-0'
│   ├── values.yaml                # defaults (server_name: "yourdomain.com", image.tag: v1.9.2)
│   ├── values.schema.json         # applied by every helm command
│   ├── README.md                  # canonical value reference; ships inside the packaged chart
│   ├── .helmignore                # excludes ci/ - fixtures never ship
│   ├── ci/                        # 38 fixtures: 13 scenarios, 17 invalid, 8 invalid-render
│   └── templates/
│       ├── _helpers.tpl           # named templates (labels, fullname, ...)
│       ├── NOTES.txt              # post-install notes
│       ├── backup-crontabs.yaml   # crontab ConfigMap for the scheduled-backup sidecar
│       ├── pvc-data.yaml          # data volume claim
│       ├── pvc-backup.yaml        # backup repository claim
│       ├── gateway/httproute.yaml # homeserver HTTPRoute (Gateway API exposure)
│       ├── rtc/                   # livekit + jwt workloads, configmap, services, ingress, http/udp/tcp routes
│       ├── tests/test-connection.yaml  # the `helm test` hook: the only file named *test*
│       └── tuwunnel/              # configmap, statefulset, service, ingress
├── docs/                          # this documentation tree
├── hack/
│   ├── runtime-check.sh           # the runtime gate - the `runtime` job just calls it
│   ├── selector-check.py          # the selector gate - the `lint` job calls it per render
│   ├── release.sh                 # cuts a release tag; `--check` is what the `release-tag` job runs
│   └── release-notes.sh           # prints a CHANGELOG section as the GitHub release body
├── AGENTS.md                      # conventions: style, fixture rules, CI/release rules
├── CHANGELOG.md                   # Keep a Changelog; a released version's section is its release body
├── LICENSE                        # GPL-3.0
└── README.md                      # landing page, install instructions, the release flow
```

There is no test framework. `find . -name '*test*'` returns only `charts/tuwunel/templates/tests/test-connection.yaml` (the `helm test` hook), and `hack/` holds exactly four scripts. Local build artifacts are gitignored: `.tmp`, `output`, `*.tgz`, `.cr-release-packages/`, `.cr-index/`.

## Fixture categories

Three folders, one meaning each. The folder is the contract: a fixture in the wrong folder makes the job that owns it fail, not pass.

| Folder | What the fixture must do | Owning job | Count |
|---|---|---|---|
| `charts/tuwunel/ci/*-values.yaml` | render `helm template` **and** start its image | `lint`, `runtime` | 13 |
| `charts/tuwunel/ci/invalid/*.yaml` | be rejected by `values.schema.json` | `schema` | 17 |
| `charts/tuwunel/ci/invalid-render/*.yaml` | be rejected by a template `fail`, naming the value in its `# expect-error:` line | `schema` | 8 |

### Scenarios - `charts/tuwunel/ci/*-values.yaml`

| Fixture | What it exercises |
|---|---|
| `gateway-media-values.yaml` | RTC media routes on Gateway API with `gateway.enabled: false` (the UDP/TCP routes belong to `rtc.livekit`); LiveKit pod mode, single multiplexed `udp_port: 7882` next to the TCP port `7881` |
| `gateway-values.yaml` | Gateway API instead of Ingress: two `parentRefs` (one namespaced, one picking a listener by `sectionName`), an extra hostname, a delegated domain derived from `well_known.server` (port dropped), route annotations, and an RTC HTTPRoute that inherits `gateway.parentRefs` |
| `ingress-federation-values.yaml` | Ingress with a delegated domain, TLS, extra hosts, federation settings, the client-IP knobs behind a proxy, and the pod-level passthrough (annotations, extra volume/mount) |
| `ingress-tls-values.yaml` | Ingress TLS without a delegated domain, so the TLS host list has to hold `server_name` and the extra host and no empty entry; the previously broken combination |
| `ipv4-only-values.yaml` | `config.global.address: 0.0.0.0` for a netns without a usable IPv6 stack; no PVC |
| `minimal-values.yaml` | Smallest supported install: no Ingress, no RTC, `emptyDir` instead of a PVC |
| `overrides-values.yaml` | Values that worked before `values.schema.json` existed: numeric and string CPU quantities, a quoted service port, a numeric init-container tag, extra/untyped env values, scheduling knobs, labels and annotations |
| `rtc-pod-network-values.yaml` | LiveKit in pod network mode through a LoadBalancer: single `udp_port` and `externalTrafficPolicy: Local` |
| `rtc-values.yaml` | RTC enabled with everything the chart derives left unset: no `well_known` block, no `LIVEKIT_URL` / `LIVEKIT_FULL_ACCESS_HOMESERVERS` / `LIVEKIT_JWT_BIND`, no `livekit.config.keys`, no `networkMode` |
| `scheduled-backup-values.yaml` | Online backups with a per-minute schedule (`* * * * *`), so the runtime job starts the rendered sidecar and lets `crond` fire the job inside its wait window |
| `server-name-with-port-values.yaml` | A Matrix server name that carries a port (`matrix.ci.example:8448`) on both exposure paths at once: the Ingress rules and TLS hosts plus the HTTPRoute hostnames are rendered without the port (the extra host `alias.ci.example:8443` and the gateway hostname `alt.ci.example` go through the same helper), while `TUWUNEL_SERVER_NAME` and `config.toml` keep the configured value |
| `service-loadbalancer-values.yaml` | The homeserver Service published by a cloud load balancer: `service.type: LoadBalancer` plus `loadBalancerSourceRanges`, which must render without the headless `clusterIP` |
| `storage-and-backup-values.yaml` | S3-backed media storage plus online backups on the default `0 3 * * *` schedule; the runtime job falls back to the crontab's own signal for this one and expects a backup repository under `backup.path` |

Two rules shape a scenario. It must render, and the `runtime` job starts its tuwunel container - which is why `overrides-values.yaml` pins `image.tag: v1.9.2` and the init-container tag: the runtime job starts that exact image. The backup sidecar is the one sidecar the runtime job starts, and only for a scenario whose rendered schedule can fire inside its wait window; nothing in CI installs a Gateway controller or a Gateway: the media routes are rendered and schema-validated, not exercised.

### Schema-rejected fixtures - `charts/tuwunel/ci/invalid/`

| Fixture | Value it must be rejected for |
|---|---|
| `backup-keep-zero.yaml` | `backup.keep: 0` |
| `backup-schedule-bad.yaml` | four-field cron `0 3 * *` in `backup.schedule` |
| `config-quoted-boolean.yaml` | `config.global.allow_federation: "false"` |
| `env-from-secret-without-key.yaml` | `envFromSecret` entry without the `secretName/key` form |
| `env-name-invalid.yaml` | `env` key `2FA_TOKEN` - a container env name Kubernetes refuses (`^[-._a-zA-Z][-._a-zA-Z0-9]*$`), which would otherwise reach the API server |
| `extra-env-without-value.yaml` | `extraEnv` entry lacking `value` |
| `image-pull-policy.yaml` | `image.pullPolicy: Sometimes` |
| `image-repository-empty.yaml` | `image.repository: ""` - an empty repository renders `:v1.9.2`, which the kubelet refuses as `InvalidImageName` |
| `image-tag-empty.yaml` | `image.tag: ""` - the tag is rendered verbatim after the `:` separator, so an empty one renders `ghcr.io/matrix-construct/tuwunel:` |
| `ip-source-typo.yaml` | `config.global.ip_source: xforwarded_for` |
| `persistence-access-mode.yaml` | `persistence.data.accessMode: ReadWriteManyy` |
| `resources-limits-null.yaml` | `resources.limits: null` |
| `rtc-domain-with-scheme.yaml` | `rtc.domain: "https://rtc.ci.example"` - the value is prefixed into `https://`/`wss://` URLs and written into an Ingress/HTTPRoute host, so only a bare lowercase DNS name renders |
| `rtc-enabled-without-domain.yaml` | `rtc.enabled: true` without `rtc.domain` |
| `rtc-network-mode-invalid.yaml` | `rtc.livekit.networkMode: bridge` |
| `service-type-externalname.yaml` | `service.type: ExternalName` - the chart renders no `externalName`, so the type leaves the schema enum |
| `unknown-top-level-key.yaml` | `ingres` (a typo'd top-level key) |

### Template-rejected fixtures - `charts/tuwunel/ci/invalid-render/`

Not every impossible value is a schema question. Rules that span two values belong to a template, and every fixture in this folder declares, in its first comment lines, the substring the refusal has to contain.

| Fixture | `# expect-error:` | Refused by |
|---|---|---|
| `backup-scheduled-without-enabled.yaml` | `backup.enabled` | the statefulset template - the sidecar and its crontab volume are gated on `backup.scheduled`, but the ConfigMap they mount belongs to the backups-enabled render |
| `config-port-mismatch.yaml` | `config.global.port` | the statefulset template - it sets `TUWUNEL_PORT` from `service.port`, so an environment variable would win over the file and the server would listen on a port the values file does not name |
| `gateway-without-parentrefs.yaml` | `gateway.enabled needs gateway.parentRefs` | the gateway HTTPRoute template - the chart renders routes that attach to a Gateway you run, it never creates one |
| `host-with-scheme.yaml` | `must be a bare hostname` | the `tuwunel.host` helper - the host fields the chart renders (`server_name`, the delegated domain, `ingress.extraHosts`, `gateway.hostnames`) take a bare hostname, so a `://` in the value is refused rather than guessed away |
| `rtc-livekit-port-empty.yaml` | `rtc.livekit.config.port` | the livekit service template - one value is the LiveKit container port, the Service port and the backend port of the RTC Ingress and the RTC HTTPRoute, and an empty one renders `port:`/`number:` (null) in all four |
| `rtc-media-route-without-pod-mode.yaml` | `networkMode=pod` | the udproute template - in hostNetwork mode the media ports are node ports no Service fronts |
| `rtc-pod-udp-range.yaml` | `rtc.livekit.config.rtc.udp_port` | the livekit service template - a Kubernetes Service cannot expose a UDP port range |
| `well-known-server-with-scheme.yaml` | `config.global.well_known.server must be a bare host:port, not a URL` | the configmap template - the key is written into `config.toml` and served as `m.server`, so a URL is wrong however the release is exposed; the exposure templates refuse it only when they render it as a host field, and this fixture enables neither |

### Adding a fixture

```bash
# a scenario: any combination of values that must keep working
# -> charts/tuwunel/ci/<name>-values.yaml

# a shape that values.schema.json must keep rejecting
# -> charts/tuwunel/ci/invalid/<name>.yaml

# a rule that spans two values, enforced by a template fail
# -> charts/tuwunel/ci/invalid-render/<name>.yaml, with the convention:
#
#   # expect-error: <substring the render must report>
```

The `# expect-error:` line is read with `sed -n 's/^# expect-error: //p'`, so it must start at column 1, and the job matches it with `grep -qF` against the combined render output - renaming a value inside a template's `fail` message therefore breaks the fixture loudly instead of silently.

Every check fails closed:

| Situation | Job result |
|---|---|
| A fixture in `ci/invalid-render/` carries no `# expect-error:` line | `::error file=<fixture>::<fixture> has no '# expect-error: <substring>' line naming the value the render must report` |
| Such a fixture renders instead of failing | `::error file=<fixture>::<fixture> rendered, but a template has to refuse it (<expected>)` |
| Such a fixture is refused by the schema instead of by a template | `::error file=<fixture>::<fixture> was rejected by values.schema.json, not by the template that owns the rule (<expected>)` |
| Such a fixture is refused, but the message does not contain the declared substring | `::error file=<fixture>::<fixture> was refused without naming '<expected>'` |
| A fixture in `ci/invalid/` renders successfully | `::error file=<fixture>::<fixture> was accepted, but it must be rejected by charts/tuwunel/values.schema.json` |
| A fixture in `ci/invalid/` fails for a reason that does not mention the schema | `::error file=<fixture>::<fixture> failed for an unexpected reason (not schema validation)` |
| All fixtures are deleted, renamed or moved out of `ci/invalid/` or `ci/invalid-render/` | `::error::no fixtures under charts/tuwunel/ci/invalid/ - this check would pass without validating anything` |

## Local validation

Run these from the repository root. Every one of them is also what CI runs.

| Command | Proves |
|---|---|
| `helm lint --strict charts/tuwunel` | template shape and value validation against `values.schema.json` for the defaults |
| the scenario render loop | every supported scenario still renders |
| `helm template … \| kubeconform -strict -summary …` | rendered manifests are valid against a Kubernetes schema |
| the `ci/invalid/` loop | the schema still refuses these shapes |
| the `ci/invalid-render/` loop | the templates still refuse these combinations |
| the selector assertion (CI step `Selectors are immutable and select their own pods`) | no selector carries a label that moves with the chart version, and every workload's pod template carries what its selector asks for - on the defaults and on every scenario |
| `hack/runtime-check.sh charts/tuwunel` | the real image starts per scenario, the rendered probe exits 0, the readiness URL answers 200, and the backup path works where the scenario enables it - through the rendered sidecar when its schedule can fire, otherwise through the crontab's own command |

```console
$ helm lint --strict charts/tuwunel
$ for f in charts/tuwunel/ci/*-values.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null || exit 1; done
$ helm template ci charts/tuwunel --set server_name=matrix.example.org | kubeconform -strict -summary -kubernetes-version 1.31.0
$ for f in charts/tuwunel/ci/invalid/*.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null && echo "unexpectedly accepted: $f"; done
$ for f in charts/tuwunel/ci/invalid-render/*.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null && echo "unexpectedly accepted: $f"; done
$ helm template ci charts/tuwunel > /tmp/render.yaml && python3 hack/selector-check.py /tmp/render.yaml
$ hack/runtime-check.sh charts/tuwunel
```

Read the output of the two negative loops: they only `echo "unexpectedly accepted: <file>"`, they do not exit non-zero. CI turns the same conditions into a red job. Failures look like this:

| Command | What a failure looks like |
|---|---|
| `helm lint --strict` | non-zero exit with the offending template path or schema violation |
| scenario render loop | `helm template` fails and the loop exits 1 |
| kubeconform | non-zero exit with per-resource errors; CI runs it on both pinned versions (`1.31.0` and `1.37.0`) and additionally asserts the summary reports exactly as many resources as the render has `kind:` lines and that it ends with `Skipped: 0` |
| the selector assertion | `::error::a selector breaks an upgrade - <fixture>: <object> selects on helm.sh/chart: …`, and the step exits 1; `hack/selector-check.py` exits 1 on the first render with a finding, and 2 when the render has no workload or no Service |
| runtime check | `FAIL <values> <image> -> <assertion>` plus the container's last 30 log lines; the script exits 1 on the first failing scenario |

> **Warning:** `helm lint --strict` can exit 0 on values that `helm install`/`upgrade` refuse. The chart's cross-value guards surface as `level=INFO msg="funcMap fail"` during lint while the exit code stays 0, so verify those changes with `helm template` or `helm install --dry-run`, not with lint alone.

> **Note:** CI pins Helm to the version in the workflow `env:` block (`4.3.0`); a local Helm can be older, and lint output and template error text can differ between versions. The `env:` block is the reference for what the gate actually runs.

> **Warning:** kubeconform ships no schema for `gateway.networking.k8s.io`, and `-strict` turns a missing schema into a failure, so a Gateway scenario needs the same extra schemas the workflow fetches - `httproute_v1.json`, `udproute_v1.json`, `tcproute_v1.json` from the pinned CRDs-catalog commit, passed as a second `-schema-location` next to `default`. The one-liner above renders the defaults, which carry no Gateway resources.

Other useful commands from the same list:

```console
$ helm template release-name charts/tuwunel --include-crds > output.yaml
$ helm dep up charts/tuwunel
$ helm install test-release charts/tuwunel --set server_name=test.example.com --dry-run
$ helm package charts/tuwunel
```

`helm dep up` is a no-op today (`Chart.yaml` declares no dependencies), `output` and `*.tgz` are gitignored, and `helm package` is how you confirm the `ci/` exclusion: the resulting `tuwunel-<version>.tgz` contains `.helmignore`, `Chart.yaml`, `README.md`, `values.yaml`, `values.schema.json` and `templates/*` only.

## The CI jobs

`.github/workflows/ci.yaml` is the only pipeline. It runs on every `pull_request`, on `push` to `main` and on a push of a `tuwunel-*` tag; job ids double as status-check contexts, and the first three are meant to be required on pull requests.

| Job | Name | Runs | Protects against |
|---|---|---|---|
| `lint` | Lint and validate manifests | `helm lint --strict` for the defaults and every scenario; `helm template` + `kubeconform -strict` for the **default values** and every scenario, on each version in `KUBERNETES_VERSIONS`; three assertions on the renders themselves - `Service types render an applyable clusterIP` (the headless default is kept, a LoadBalancer renders no `clusterIP`) and `Rendered host lists carry no empty entries` (every `spec.tls[].hosts[]`, `spec.rules[].host` and route `spec.hostnames[]` has to be a host the API server accepts - an RFC 1123 subdomain, optionally `*.`-prefixed - so an empty entry, a port or a scheme in any rendered host fails the step; it runs over the default values and every scenario); and `Selectors are immutable and select their own pods` (no `spec.selector.matchLabels` and no Service `selector` may carry `helm.sh/chart`, `app.kubernetes.io/version` or `app.kubernetes.io/managed-by`, and every workload's own pod template has to carry the pairs its selector asks for - a selector that moves with the chart version renders fine and is only discovered by the *next* chart release, which is what happened up to 2.0.1) | a scenario that stops rendering, a manifest that violates the Kubernetes or Gateway API schemas, and the three combinations no schema can see: `clusterIP: "None"` is legal on a ClusterIP Service only, kubeconform's Ingress schema accepts an empty host that the API server refuses, and a selector that moves with the chart version only fails on the *next* chart release |
| `schema` | Value schema guardrails | every `ci/invalid/*.yaml` must be refused by the schema; every `ci/invalid-render/*.yaml` must be refused by a template and name its value; every scenario must still render | a weakened `values.schema.json` or a dropped template guard |
| `runtime` | Runtime smoke test against the real image | checkout, the pinned Helm, then `hack/runtime-check.sh "$CHART_DIR"` (`timeout-minutes: 25`) | a config value of the wrong TOML type and a readiness path that answers non-200 - neither is visible to the shape-only jobs; for a schedule that can fire inside the wait window it also starts the rendered backup sidecar, so a sidecar whose job `crond` cannot start fails here |
| `release-tag` | Resolve the release tag | a `tuwunel-*` tag push only; `hack/release.sh --check "$GITHUB_REF_NAME"` resolves `version`, `channel`, `section` and `tag` (the same script that cuts the tag, so the rules cannot drift), then the job refuses a tag that is not an ancestor of `origin/main` | a version that is neither `<major>.<minor>.<patch>` nor `<major>.<minor>.<patch>-rc.<n>`, a missing `## [<version>]` CHANGELOG section, and a tag not cut from `main` - each fails in seconds, before the ~25-minute `runtime` gate |
| `release` | Release chart | a `tuwunel-*` tag push only, `needs: [release-tag, lint, schema, runtime]`, `concurrency: chart-release`; packages the tagged tree with `helm package --version` (stamping the tag's version, then reading it back out of the `.tgz`), runs the pinned `cr` directly (`cr upload --skip-existing`, `cr index --push`, `--make-release-latest=false` on the candidate track; `chart-releaser-action@v1.7.0` is used with `install_only: true` for the binary alone - its own script dies on an unbound variable when packaging is skipped), sets the body with `hack/release-notes.sh <version> [<section-version>]` (`--prerelease` for a candidate), then commits the released `version` to `main` as `chore(release): record <tag> [skip ci]` | a package that does not carry the released version, a release body that stayed the chart description, and a release recorded nowhere on the branch |

Tool pins live in the workflow `env:` block - one pin per tool, no `@latest` anywhere; Dependabot only bumps the actions.

| Pin | Value |
|---|---|
| `HELM_VERSION` | `4.3.0` |
| `KUBECONFORM_VERSION` | `v0.8.0` |
| `KUBECONFORM_SHA256` | `9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883` |
| `CRDS_CATALOG_SHA` | `ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2` |
| `HTTPROUTE_SCHEMA_SHA256` | `e5692e62edd9b8a14bd2527d0a732e174a649131aa4d47159737dc6527c59ca5` |
| `UDPROUTE_SCHEMA_SHA256` | `d624dc44db2eb4dfedcd02a137b7dd1ceabd11d9670335a90727b340b667e5d9` |
| `TCPROUTE_SCHEMA_SHA256` | `91b0188d2b7b0552c462e1fc7dd531b735013e8762d725fdc1e42e49e4bf4418` |
| `CHART_RELEASER_VERSION` | `v1.8.1` |
| `KUBERNETES_VERSIONS` | `1.31.0 1.37.0` |
| `CHART_DIR` | `charts/tuwunel` |
| action pins | `actions/checkout@v7`, `azure/setup-helm@v5`, `helm/chart-releaser-action@v1.7.0` |

Bumping `KUBECONFORM_VERSION` or `CRDS_CATALOG_SHA` without updating the matching checksum fails the job at `sha256sum -c`; those pins travel together.

The `release` job is gated four ways: it runs only on a tag push (`if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')`), `needs: [release-tag, lint, schema, runtime]`, `permissions: contents: write` (the workflow default is `contents: read`), and `concurrency: chart-release`, which serialises releases across refs - two tags pushed close together would otherwise race on the same branch. The workflow keeps its own group (`${{ github.workflow }}-${{ github.ref }}`, cancelling in progress only for pull requests).

> **Note:** There is deliberately no `paths:` filter on `pull_request`. A job skipped by a path filter never reports a status, so requiring it would block every merge that does not touch those paths - which is also why a docs-only pull request still runs all three quality jobs.

## The runtime check

`hack/runtime-check.sh` is the only gate that starts the real image. Per scenario it:

1. renders the fixture with `helm template` and parses the manifests (`python3` + PyYAML);
2. reads the `tuwunel` container (image, command, args, env, ports, probes), the init container that feeds the rendered `config.toml` through `envsubst`, and the `helm.sh/hook: test` pod;
3. runs that init container as rendered - same image, command, args and env, every `secretKeyRef` faked with a placeholder - so the config the server reads is produced by the chart's own mechanism;
4. starts the image with the rendered env, the substituted config mounted where the manifest reads it, and a tmpfs at the rendered database path;
5. asserts, in order: the container is still running, the *rendered* probe command exits 0, the rendered readiness URL answers 200;
6. for a config that asks for online backups (`database_backup_path` together with `admin_signal_execute`), drives the backup path the render describes: when the rendered schedule can fire inside a 90-second window it starts the *rendered* sidecar — the manifest's own image, command, args, user and capabilities, with the crontab ConfigMap projected into its spool — and lets `crond` fire the job on its own; a schedule that cannot (say `0 3 * * *`) falls back to running the crontab's command once in the server's PID namespace, and prints why. Either path has to leave a `meta/` entry under `backup.path`.

The rule that matters when you change a manifest: it reads images, env names, paths, probes and the readiness URL out of the render, and hardcodes none of them. If the script needs to know something the manifests do not say, that is a bug in the manifests. When the render stops naming something, the script fails with an explicit message instead of guessing:

| Message | Cause |
|---|---|
| `the manifest names no config path (no *_CONFIG env var, no init container output)` | nothing in the render says where the server reads its config |
| `the helm test pod names no http URL to probe` | the `helm.sh/hook: test` pod no longer carries an http(s) URL |
| `cannot tell which config path the rendered init container writes (args: [...])` | the init container's args no longer name both TOML paths |

| Assertion | Failure message |
|---|---|
| container still running | `the container exited on its own (exit code <n>) instead of serving` |
| probe command and readiness URL | whichever deadline expires first: `the readiness path never answered 200 within 180s` while no 200 has been seen, otherwise `the rendered probe command never exited 0 within 180s` |
| backup sidecar start | the rendered sidecar could not be started from `<image>`, or its crontab could not be projected into the spool directory |
| backup signal (fallback path) | `the rendered crontab command (<cmd>) failed in the server's PID namespace` |
| backup repository | `no backup repository (meta/) appeared under <path> within 90s of` the path that was driven - the rendered sidecar's job, or the rendered crontab's signal |

```console
$ hack/runtime-check.sh charts/tuwunel
$ RUNTIME_CHECK_TIMEOUT=300 hack/runtime-check.sh charts/tuwunel
```

Usage is `hack/runtime-check.sh [chart-dir]`, defaulting to `charts/tuwunel`; `RUNTIME_CHECK_TIMEOUT` is the ready budget per fixture and defaults to 180 seconds. The script preflights `docker`, `helm` and `python3` on `PATH`, a reachable Docker daemon, a `python3` with `pyyaml`, and the chart directory - each exits 2. It fails on the first failing scenario (exit 1) and prints the scenario, the image, the failed assertion and the server's last 30 log lines - plus, when the run started the backup sidecar, its state and its last 20 log lines.

Every scenario gets a unique container name and scratch directory derived from `GITHUB_RUN_ID` or the shell PID, world-writable mounts (the pod's uid writes them), and a cleanup trap that removes the container on success, failure and interrupt. An empty scenario glob is a failure of the script itself:

```text
::error::no fixtures matched charts/tuwunel/ci/*-values.yaml - this job would pass without checking anything
```

> **Note:** The init image (`dibi/envsubst:1`, pinned by `initContainer.image`) is published for `linux/amd64` only, so on a non-amd64 daemon the script passes `--platform linux/amd64` to the init container and to nothing else; the tuwunel image is multi-arch and is left to the daemon. Overriding `initContainer.image` to a multi-arch or mirrored equivalent takes the same path.

## Releasing

A release is a tag push. Both tracks are cut from `main`, and nothing in the tree is bumped by hand:
the tag carries the version, the release job stamps it into the package, and the branch records it
afterwards.

| | stable track | release candidate track |
|---|---|---|
| version shape | `<major>.<minor>.<patch>` | `<major>.<minor>.<patch>-rc.<n>` |
| tag | `tuwunel-2.1.0` | `tuwunel-2.1.0-rc.1` |
| CHANGELOG section | `## [2.1.0]` | `## [2.1.0]` - the version it is a candidate of |
| GitHub release | normal, "Latest" | `--prerelease`, never "Latest" |

1. Write the section the release body comes from: `## [<version>]` in `CHANGELOG.md`, once per version and before the first tag of it. A candidate reuses the section of the version it is a candidate of, so `2.1.0-rc.1` publishes `## [2.1.0]`; the heading date is the day the section was opened.
2. Cut the tag with `hack/release.sh <version>` - the only thing that creates one. It refuses a version that is neither shape, a missing CHANGELOG section (it runs `hack/release-notes.sh` as the check), a dirty working tree, a `HEAD` that is not the tip of `origin/main`, and a tag that already exists locally or on `origin`. `hack/release.sh --check <version>` validates only, printing the `version`, `channel`, `section` and `tag` it resolved.
3. Pushing the tag starts the run. `release-tag` resolves it through the same script and refuses a tag that is not an ancestor of `origin/main`; `lint`, `schema` and `runtime` gate the release.
4. The `release` job packages the tagged tree with `helm package --version` - the tag carries the version, and the tree still records the *previous* release because the recording commit lands only afterwards - then reads the package back to prove its `Chart.yaml` carries that version, and runs the pinned `cr` itself: `cr upload --skip-existing` attaches the GitHub release to the tag that already exists and `cr index --push` rewrites `index.yaml` on the `gh-pages` branch (which holds `.nojekyll` and `index.yaml` only), with `--make-release-latest=false` on the candidate track. `chart-releaser-action@v1.7.0` is used with `install_only: true` for the binary alone - its own script dies on an unbound variable when packaging is skipped (fixed on its `main`, unreleased as of v1.7.0) - and `--skip-existing` makes a re-run after a failed step idempotent.
5. The body is set next, from the repository's own text: `hack/release-notes.sh "$VERSION" "$SECTION"` piped into `gh release edit "$TAG" --notes-file`, with `--prerelease` for a candidate. `concurrency: chart-release` serialises releases, and `main` never moves backwards - a release cut from an older commit publishes and leaves the branch alone.
6. The last step commits the released version to `main` as `chore(release): record <tag> [skip ci]`, writing `version` into `charts/tuwunel/Chart.yaml`. A push made with `GITHUB_TOKEN` starts no run by itself, and `[skip ci]` keeps the commit out of a pipeline if that ever changes.
7. Consumers pick the version up with `helm repo update`. A candidate is opt-in: an unqualified `helm install` keeps resolving the newest stable, and the candidate needs `helm search repo tuwunel/tuwunel --versions --devel` / `helm install … --version 2.1.0-rc.1`.

The release body is not the action's: `chart-releaser-action@v1.7.0` has no notes input, and `cr upload` reads a notes file only from inside the packaged chart, so the job runs `hack/release-notes.sh` and applies the result with `gh release edit`. The version is never read out of the checkout either - `release-tag` resolves it from the tag, and the packaging step stamps it into the package.

`hack/release-notes.sh <version> [<section-version>]` prints the `## [<section-version>]` section of `CHANGELOG.md` (the second argument defaults to the first), from the heading up to (excluding) the next `## ` heading, plus a best-effort `**Full Changelog**: https://github.com/<repo>/compare/<previous-tag>...<tag>` line when the repository, the `<chart>-<version>` tag and a previous `<chart>-*` tag are all resolvable. The previous tag is track-aware: a candidate compares against whatever preceded it, a stable release against the previous *stable* one, so a stable body is the whole section rather than what changed since the last candidate. `hack/release.sh` runs the same script as its section check, so the rule that gates the tag is the rule the release job applies.

| Invocation | Result |
|---|---|
| `hack/release-notes.sh 2.0.0` | exit 0, the section plus the compare link on stdout - one argument means the section version is the released version |
| `hack/release-notes.sh 2.1.0-rc.1 2.1.0` | exit 0, the `## [2.1.0]` section - the form a candidate is published with, once that section exists |
| `hack/release-notes.sh 9.9.9` | exit 1, nothing on stdout, `no '## [9.9.9]' section in <...>/CHANGELOG.md: add it before releasing 9.9.9, the GitHub release body is taken from it` |
| `hack/release-notes.sh 2.1.0-rc.1 9.9.9` | exit 1, nothing on stdout, the same message naming `## [9.9.9]` as the missing section and `2.1.0-rc.1` as the version being released |
| `hack/release-notes.sh` (no argument) | exit 2, `usage: hack/release-notes.sh <version> [<section-version>]   (e.g. 2.0.0, or 2.1.0-rc.1 2.1.0 for a candidate)` |
| `CHANGELOG_FILE=<path> hack/release-notes.sh <version>` | reads that file instead of the repository changelog (the documented test hook); a missing file exits 1 with `no changelog file <path>: it holds the release body for <version>` |

The heading match is a literal prefix and requires a space or the end of the line after the closing bracket, so looking for `1.2.0` cannot pick up a `## [1.2.0-rc1]` heading above it. A heading written as `## [2.0.0]-something` matches nothing, so `hack/release.sh` refuses to create the tag and `release-tag` refuses it again in CI - a version whose section is missing cannot be published at all.

| Failure mode | What happens |
|---|---|
| No `## [<version>]` section for the tagged version | `hack/release.sh` refuses to cut the tag, and `release-tag` refuses the tag again in CI: the run fails before the gates and before anything is published - not after the release exists |
| A version of any other shape (`9.9`, `9.9.9-rc`, `9.9.9-rc.1.2`, `foo-9.9.9`) | `hack/release.sh` exits 2 without creating a tag; pushed anyway, the same check fails the run in `release-tag` |
| A tag that is not an ancestor of `origin/main` | `release-tag` fails the run in seconds; nothing is published |
| A merge that only touches docs, CI or even the chart | nothing is published - a release needs a tag push, and there was none |
| A release candidate | supported: it publishes a GitHub pre-release (never "Latest") with the section of the version it is a candidate of, and consumers opt in with `--devel` / `--version` |
| A pin and its checksum updated separately | the job fails at `sha256sum -c` before validating anything |

> **Tip:** To see what is actually published, read `origin/gh-pages` (or the chart repository URL) rather than a local `gh-pages` branch - a checkout's local branch can lag the published `index.yaml`.

> **Note:** The recovery depends on whether anything was published. While the release was refused - a version of the wrong shape, a missing section, a tag that is not on `main` - nothing exists on the repository yet, so the tag can be deleted and re-pushed. Once `cr upload` has run the tag must not move: recover with `gh run rerun` (the published release is skipped and the notes and the version record are retried), or, when the workflow itself is the defect, re-run the notes and the version record by hand.

## Adding or changing a value

Adding a value means touching three places:

| Place | What changes |
|---|---|
| `charts/tuwunel/values.yaml` | the value itself, with a comment and its default |
| `charts/tuwunel/values.schema.json` | the shape rule that keeps impossible values out |
| [`charts/tuwunel/README.md`](../charts/tuwunel/README.md) | the value tables (this file ships inside the packaged chart, so it is the reader's reference) |

Then decide the fixture:

| If the change | Put it |
|---|---|
| is a combination of values worth permanent coverage | a scenario in `charts/tuwunel/ci/<name>-values.yaml` |
| has a shape that must be rejected | a fixture in `charts/tuwunel/ci/invalid/` |
| is a rule that spans two values and belongs to a template | a fixture in `charts/tuwunel/ci/invalid-render/` with the `# expect-error:` line |

The full procedure for a configuration key is: add it to `values.yaml` with a comment and default, reference it in a template, cover it in `values.schema.json`, update the chart README, then test with `helm template` (or add a scenario when the combination deserves permanent coverage).

Two packaging rules apply to everything under `ci/`:

- `charts/tuwunel/.helmignore` excludes `ci/`, so scenarios and negative fixtures never ship in the packaged chart. `helm package charts/tuwunel` is the check.
- That file's last pattern (`ci/`) has no trailing newline. Add a newline before appending a pattern, or the new pattern merges into `ci/` and excludes the wrong path.

If a new value renders a kind that no earlier render produced, the `lint` job fails until that kind's schema is in the pinned set - a rendered resource kubeconform cannot find a schema for is a failure (`kubeconform skipped resources, so a kind has no schema (add it to the pinned set)`), never a silent pass. The Gateway API kinds are handled that way already; see [Configuring the server](./configuration.md) for the value-level reference and [How the chart renders a running server](./internals.md) for what the templates derive.

## Working in this repo

[`AGENTS.md`](../AGENTS.md) carries the conventions a change must follow.

| Area | Rule |
|---|---|
| Whitespace control | `{{-` trims before, `-}}` trims after; wrap optional resources in `{{- if .Values.x.enabled -}}` |
| Indentation | `nindent` for nested blocks, 4 spaces for labels under `labels:` |
| Naming | Templates `chartname.resourcetype` (e.g. `tuwunel.fullname`); component suffixes `-livekit`, `-jwt`, `-configmap`; helper templates live in `_helpers.tpl` with a doc comment |
| Labels | Every resource carries `{{- include "tuwunel.labels" . \| nindent 4 }}` plus `app.kubernetes.io/component: <component>` |
| Security contexts | Pod-level on every workload: `runAsNonRoot: true`, `runAsUser`/`runAsGroup`, `seccompProfile: RuntimeDefault` (LiveKit is the exception - only the seccomp profile); every container adds `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false` and `capabilities.drop: [ALL]` |
| `values.yaml` style | `##` for section headers, `#` for inline comments, `enabled: false` for optional features |
| Env vars | three patterns: plain `{{- range $key, $val := .Values.env }}`, secret form `secretName/key` via `name: {{ (split "/" $val)._0 }}`, and raw sections via `{{- with .Values.envRaw }}{{- toYaml . \| nindent 12 }}{{- end }}` |
| Pins | Nothing uses `@latest`: the workflow `env:` block pins Helm, kubeconform (+ sha256), chart-releaser, the Kubernetes versions and the CRDs-catalog commit; Dependabot bumps the GitHub Actions only |
| Version and tags | the tag carries the version: `hack/release.sh <version>` creates it, and the release job records it in `charts/tuwunel/Chart.yaml` on `main` afterwards; `appVersion` is updated in a pull request when the application version changes |
| Documentation | the repository's prose is English - `values.yaml` comments, `charts/tuwunel/README.md`, `CHANGELOG.md`, `ci/` fixture header comments - and every fixture header explains why the fixture exists |

The pull request template asks for what changed, how it was verified, and a six-item checklist: lint passes, every scenario renders, `hack/runtime-check.sh` passes, new or changed values are covered by `values.schema.json` and the chart README tables, nothing under `ci/invalid/` became acceptable to the schema, and `CHANGELOG.md` carries the section for the version the change ships in. `.github/CODEOWNERS` assigns every path to one owner, and Dependabot opens weekly grouped action updates rather than touching the manual tool pins.

Related pages: [Upgrading](./upgrade.md) for what a published version change means to consumers, [Troubleshooting](./troubleshooting.md) for reading the render refusals and runtime failures, and [Installing the chart](./installation.md) for the consumer side of the published chart.
