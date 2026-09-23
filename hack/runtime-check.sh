#!/usr/bin/env bash
#
# Run the chart's scenarios against the real image, exactly like the `runtime`
# job in .github/workflows/ci.yaml (that job just calls this script).
#
# The other gates only prove the manifests have the right *shape*: `helm lint`,
# `kubeconform` and values.schema.json never read the rendered config.toml, and
# no schema says anything about the readiness path - yet both decide whether
# tuwunel starts at all. The *types* in the rendered config.toml decide it: a
# value like `allow_federation = "false"` (a TOML string where tuwunel wants a
# boolean) makes the process exit 1 at startup instead of failing a render, and
# a readiness path that answers 403 while federation is disabled leaves the pod
# permanently NotReady. So every fixture is rendered, started as a container
# with its own env vars and config.toml, and the exact path the readiness probe
# uses must answer 200.
#
# usage: hack/runtime-check.sh [chart-dir]     (default: charts/tuwunel)
#
# Scenarios are <chart-dir>/ci/*-values.yaml. Needs docker with a running
# daemon, helm and python3 with pyyaml. Exits non-zero on the first failing
# scenario; every container this starts is removed again, on success, on
# failure and on interrupt.
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "usage: hack/runtime-check.sh [chart-dir]" >&2
  exit 2
fi
chart_dir="${1:-charts/tuwunel}"

# `::group::`/`::endgroup::` collapse the per-fixture output in the Actions log
# and are pure noise in a terminal; `::error::` stays, it is a single line.
group() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::group::$1"
  fi
}
endgroup() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::endgroup::"
  fi
}

# Without nullglob an unmatched fixture glob is passed to helm
# verbatim; with it the loop below is skipped and the fixture-count
# guard fails the job instead of checking nothing.
shopt -s nullglob

container=""
cleanup() {
  if [ -n "$container" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# A published port may still be in TIME_WAIT from the previous
# fixture; never fail a fixture over that.
free_port() {
  python3 - "$1" <<'PY'
import socket, sys
port = int(sys.argv[1])
while True:
    with socket.socket() as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            port += 1
            continue
        print(port)
        break
PY
}

# Per-run id for container names and scratch dirs: leftovers from a
# killed run (or a concurrent invocation on a shared host) must not
# collide with this one and fail the check for the wrong reason.
run_id="${GITHUB_RUN_ID:-$$}"

fixtures=0
index=0
for values in "$chart_dir"/ci/*-values.yaml; do
  fixtures=$((fixtures + 1))
  index=$((index + 1))
  container="tuwunel-ci-${run_id}-${index}"
  host_port=$(free_port $((18080 + index - 1)))
  work="${RUNNER_TEMP:-/tmp}/tuwunel-runtime-${run_id}-${index}"
  rm -rf "$work"
  mkdir -p "$work"

  group "runtime check: $values"

  # The image, the literal env pairs, the rendered config.toml and the
  # readiness probe all come from the render under test, through the
  # same values.schema.json the other jobs use.
  python3 - "$chart_dir" "$values" "$work" <<'PY'
import os, subprocess, sys, yaml

chart, values, work = sys.argv[1:4]
manifest = subprocess.run(["helm", "template", "ci", chart, "-f", values],
                          capture_output=True, text=True, check=True).stdout
docs = [doc for doc in yaml.safe_load_all(manifest) if doc]
sts = next(doc for doc in docs if doc["kind"] == "StatefulSet")
configmap = next(doc for doc in docs if doc["kind"] == "ConfigMap"
                 and doc["metadata"]["name"].endswith("-configmap"))
server = sts["spec"]["template"]["spec"]["containers"][0]
probe = server["readinessProbe"]["httpGet"]

# The probe port may be a name; resolve it through the ports list.
port = probe["port"]
if isinstance(port, str):
    port = next(p["containerPort"] for p in server["ports"] if p["name"] == port)

# Literal `value:` pairs only - envFromSecret/valueFrom need a cluster.
env = {e["name"]: str(e["value"]) for e in server.get("env", []) if "value" in e}
env["CONDUWUIT_CONFIG"] = "/tmp/config/config.toml"
env["CONDUWUIT_DATABASE_PATH"] = "/data/db"

with open(os.path.join(work, "config.toml"), "w") as fh:
    fh.write(configmap["data"]["config.toml"])
with open(os.path.join(work, "env.list"), "w") as fh:
    for key, value in env.items():
        fh.write(f"{key}={value}\n")
for name, value in (("image", server["image"]), ("port", port),
                    ("path", probe["path"])):
    with open(os.path.join(work, name), "w") as fh:
        fh.write(f"{value}\n")
PY

  image=$(cat "$work/image")
  port=$(cat "$work/port")
  path=$(cat "$work/path")

  # The database directory is a tmpfs, not a bind mount: the container writes
  # its RocksDB as its own uid, and on a Linux host (the CI runner) the runner
  # user then cannot delete those files again, so a bind-mounted scratch dir
  # leaves the cleanup failing with "Permission denied" - a failure that macOS
  # bind mounts hide. Nothing has to persist between fixtures anyway.
  docker run -d --name "$container" \
    -v "$work/config.toml:/tmp/config/config.toml:ro" \
    --tmpfs "/data:rw,mode=1777,size=512m" \
    --env-file "$work/env.list" \
    -p "127.0.0.1:${host_port}:${port}" "$image" >/dev/null

  # Poll the readiness path until it answers 200. A container that has
  # already exited (unparsable config, TOML type error) is a failure,
  # not a slow start - report its log instead of waiting out the poll.
  code=""
  for _ in $(seq 1 90); do
    if code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 \
      "http://127.0.0.1:${host_port}${path}" 2>/dev/null); then
      break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
      echo "FAIL $values $image $path -> container exited with code $(docker inspect -f '{{.State.ExitCode}}' "$container")"
      docker logs "$container" 2>&1 | tail -20
      exit 1
    fi
    sleep 1
  done

  if [ "$code" = "200" ]; then
    echo "OK   $values $image $path -> $code | $(docker logs "$container" 2>&1 | grep -o 'Listening on .*' | tail -1)"
  else
    echo "FAIL $values $image $path -> ${code:-no response}"
    docker logs "$container" 2>&1 | tail -20
    exit 1
  fi

  docker rm -f "$container" >/dev/null
  container=""
  rm -rf "$work"
  endgroup
done

if [ "$fixtures" -eq 0 ]; then
  echo "::error::no fixtures matched $chart_dir/ci/*-values.yaml - this job would pass without checking anything"
  exit 1
fi
echo "runtime check passed for $fixtures fixture(s)"
