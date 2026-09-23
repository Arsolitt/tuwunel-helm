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
# permanently NotReady.
#
# So every fixture is rendered, then driven by what that render *says* - this
# script hardcodes no env name, no path and no probe:
#
#   1. `helm template` the fixture and parse the manifests (python3 + PyYAML);
#   2. read the `tuwunel` container (image, command, args, env, ports, probes),
#      the init container that feeds the rendered config.toml through
#      `envsubst`, and the `helm.sh/hook: test` pod - its URL is the readiness
#      surface `helm test` talks to;
#   3. run that init container as rendered (same image, command, args and env,
#      every secretKeyRef faked with a placeholder) so the config the server
#      really reads is produced by the chart's own mechanism, not by a copy of
#      its assumptions held in this file;
#   4. start the image with the rendered env, that substituted config mounted
#      where the manifest reads it, and a tmpfs at the rendered database path;
#   5. assert, in this order: the container is still running, the *rendered*
#      probe command exits 0, and the rendered readiness URL answers 200;
#   6. when the substituted config asks for online backups
#      (database_backup_path + admin_signal_execute), run the crontab command
#      the chart renders for the backup sidecar with a shared PID namespace and
#      wait for the backup repository to appear - the SIGUSR2 path that
#      `backup.scheduled` depends on.
#
# A container that exits on its own is a failure of that fixture, never a slow
# start.
#
# usage: hack/runtime-check.sh [chart-dir]     (default: charts/tuwunel)
#        RUNTIME_CHECK_TIMEOUT=<seconds>       (ready budget per fixture, default 180)
#
# Scenarios are <chart-dir>/ci/*-values.yaml. Needs docker with a running
# daemon, helm and python3 with pyyaml. Exits non-zero on
# the first failing scenario; every container this starts is removed again, on
# success, on failure and on interrupt.
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

# A failing fixture aborts the run: it prints the fixture, the image, the
# assertion that failed and the server's own stderr, which is where a config
# value of the wrong type or a failed bind shows up.
fail() {
  echo "::error file=$values::$values: $1"
  echo "FAIL $values $image -> $1"
  if [ -n "$container" ] && docker inspect "$container" >/dev/null 2>&1; then
    echo "--- $container (exit code $(docker inspect -f '{{.State.ExitCode}}' "$container")) ---"
    docker logs "$container" 2>&1 | tail -30 || true
  fi
  exit 1
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

for tool in docker helm python3; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "::error::$tool is not on PATH, but this gate drives the rendered manifests with it"; exit 2; }
done
docker info >/dev/null 2>&1 \
  || { echo "::error::the docker daemon is not reachable"; exit 2; }
python3 -c 'import yaml' >/dev/null 2>&1 \
  || { echo "::error::python3 needs pyyaml to read the rendered manifests"; exit 2; }
[ -d "$chart_dir" ] || { echo "::error::$chart_dir is not a directory"; exit 2; }

# The init image the chart pins (dibi/envsubst) is published for linux/amd64
# only, so a non-amd64 daemon has to be told which variant to run; a native
# amd64 runner must not be forced through emulation. The tuwunel image itself is
# multi-arch and is left to the daemon, which is what a real node does too.
platform_args=()
daemon_arch=$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m)
case "$daemon_arch" in
  x86_64 | amd64) ;;
  *) platform_args=(--platform linux/amd64) ;;
esac

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
scratch_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
scratch_root="${scratch_root%/}"
case "$scratch_root/" in
  /*) ;;
  *) echo "::error::refusing to use relative scratch root $scratch_root" >&2; exit 2 ;;
esac

fixtures=0
index=0
for values in "$chart_dir"/ci/*-values.yaml; do
  fixtures=$((fixtures + 1))
  index=$((index + 1))
  container="tuwunel-ci-${run_id}-${index}"
  host_port=$(free_port $((18080 + index - 1)))
  work="${scratch_root}/tuwunel-runtime-${run_id}-${index}"
  rm -rf "$work"
  mkdir -p "$work/config-template" "$work/substituted" "$work/backup"
  # The containers write into these mounts as the pod's uid (which is not the
  # runner's) and the cleanup below has to be able to delete what they leave,
  # so every scratch mount is world-writable - the same shape as the emptyDirs
  # and the fsGroup 2020 the pod gets in a cluster.
  chmod 777 "$work/config-template" "$work/substituted" "$work/backup"

  group "runtime check: $values"

  # Everything this fixture's pod is made of, read out of the render. The
  # output is a sourceable file of shell assignments plus the env files and the
  # config template the containers are started with.
  python3 - "$chart_dir" "$values" "$work" <<'PY'
import os, re, subprocess, sys
from shlex import quote
from urllib.parse import urlsplit
import yaml

chart, values, work = sys.argv[1:4]


def die(message):
    sys.exit(f"{values}: {message}")


try:
    manifest = subprocess.run(
        ["helm", "template", "ci", chart, "-f", values],
        capture_output=True, text=True, check=True).stdout
except subprocess.CalledProcessError as exc:
    die(f"helm template failed:\n{(exc.stderr or '').strip()}")

with open(os.path.join(work, "manifest.yaml"), "w") as handle:
    handle.write(manifest)

docs = [doc for doc in yaml.safe_load_all(manifest) if isinstance(doc, dict)]


def find(kind, pick, describe):
    for doc in docs:
        if doc.get("kind") == kind and pick(doc):
            return doc
    die(f"no {kind}{describe} was rendered")


sts = find("StatefulSet", lambda d: True, "")
pod = sts["spec"]["template"]["spec"]

main = next((c for c in pod.get("containers") or [] if c.get("name") == "tuwunel"), None)
if main is None:
    die("the rendered StatefulSet has no container named tuwunel")

volumes = {v["name"]: v for v in pod.get("volumes") or []}


def is_test_hook(doc):
    annotations = (doc.get("metadata") or {}).get("annotations") or {}
    return "test" in [h.strip() for h in str(annotations.get("helm.sh/hook", "")).split(",")]


# The ConfigMap mounted into an init container is the config template; the
# init container that mounts it is the one that has to run before the server.
init = None
config_map = None
config_key = template_dir = ""
for candidate in pod.get("initContainers") or []:
    for mount in candidate.get("volumeMounts") or []:
        volume = volumes.get(mount["name"]) or {}
        name = (volume.get("configMap") or {}).get("name")
        if not name:
            continue
        for doc in docs:
            if doc.get("kind") != "ConfigMap" or doc["metadata"]["name"] != name:
                continue
            keys = [k for k in (doc.get("data") or {}) if k.endswith(".toml")]
            if keys:
                init, config_map, config_key, template_dir = candidate, doc, keys[0], mount["mountPath"]
    if init:
        break

if config_map is None:
    config_map = find("ConfigMap",
                      lambda d: any(k.endswith(".toml") for k in (d.get("data") or {})),
                      " holding a .toml file")

# Where the init container reads its template from and writes the substituted
# config to - both are named by its own args, so a change there is picked up.
init_args = [str(a) for a in (init or {}).get("args") or []]
toml_paths = re.findall(r"/[^\s\"'<>|]*\.toml", " ".join(init_args))
init_input = init_output = ""
if len(toml_paths) >= 2:
    init_input, init_output = toml_paths[0], toml_paths[-1]
elif init is not None:
    die("cannot tell which config path the rendered init container writes "
        f"(args: {init_args})")


def env_pairs(container):
    """The rendered env; every valueFrom gets the value a cluster would supply."""
    pairs = []
    for entry in container.get("env") or []:
        value = entry["value"] if "value" in entry else "ci-secret-value"
        pairs.append((entry["name"], "" if value is None else str(value)))
    return pairs


main_env = env_pairs(main)


def env_value(suffix, prefix="/"):
    for name, value in main_env:
        if name.endswith(suffix) and value.startswith(prefix):
            return value
    return ""


# Where the server reads the config: the path the manifest itself names, or the
# path the init container writes to when the manifest does not name one.
config_path = env_value("_CONFIG") or init_output
if not config_path:
    die("the manifest names no config path (no *_CONFIG env var, no init container output)")
if init_output and os.path.basename(init_output) != os.path.basename(config_path):
    die(f"the init container writes {init_output} but the server reads {config_path}: "
        "the file names differ, so the rendered pod cannot start")

# The database directory the server opens; its own default if nothing names one.
db_path = env_value("_DATABASE_PATH") or "/data/db"

ports = main.get("ports") or []
port = ports[0].get("containerPort") if ports else None
if port is None:
    die("the tuwunel container declares no containerPort")

probe_kind, probe_cmd = "", []
for kind in ("readinessProbe", "startupProbe", "livenessProbe"):
    command = ((main.get(kind) or {}).get("exec") or {}).get("command")
    if command:
        probe_kind, probe_cmd = kind, [str(part) for part in command]
        break

# The readiness URL `helm test` uses - the chart's only declared HTTP surface.
test_pod = find("Pod", is_test_hook, " with a `helm.sh/hook: test` annotation")
url = ""
for box in test_pod["spec"]["containers"]:
    for arg in list(box.get("command") or []) + list(box.get("args") or []):
        if isinstance(arg, str) and arg.startswith(("http://", "https://")):
            url = arg
if not url:
    die("the helm test pod names no http URL to probe")
parts = urlsplit(url)

security = pod.get("securityContext") or {}
run_as = ""
if security.get("runAsUser") is not None:
    run_as = str(security["runAsUser"])
    if security.get("runAsGroup") is not None:
        run_as = f"{run_as}:{security['runAsGroup']}"


def sh_array(name, items):
    return f"{name}=({ ' '.join(quote(str(item)) for item in items) })\n"


with open(os.path.join(work, "spec.sh"), "w") as handle:
    handle.write(f"IMAGE={quote(str(main.get('image', '')))}\n")
    handle.write(f"RUN_AS={quote(run_as)}\n")
    handle.write(f"MAIN_PORT={quote(str(port))}\n")
    handle.write(f"DB_PATH={quote(db_path)}\n")
    handle.write(f"CONFIG_DIR={quote(os.path.dirname(config_path))}\n")
    handle.write(f"CONFIG_FILE={quote(os.path.basename(config_path))}\n")
    handle.write(f"READY_PATH={quote(parts.path or '/')}\n")
    handle.write(f"READY_URL={quote(url)}\n")
    handle.write(f"SERVICE_PORT={quote(str(parts.port or ''))}\n")
    handle.write(f"PROBE_KIND={quote(probe_kind)}\n")
    handle.write(sh_array("PROBE_CMD", probe_cmd))
    handle.write(sh_array("MAIN_CMD", [str(c) for c in main.get("command") or []]))
    handle.write(sh_array("MAIN_ARGS", [str(a) for a in main.get("args") or []]))
    handle.write(f"HAVE_INIT={'1' if init is not None else '0'}\n")
    handle.write(f"INIT_IMAGE={quote(str((init or {}).get('image', '')))}\n")
    handle.write(f"INIT_TEMPLATE_DIR={quote(template_dir)}\n")
    handle.write(f"INIT_INPUT={quote(init_input)}\n")
    handle.write(f"INIT_OUT_DIR={quote(os.path.dirname(init_output))}\n")
    handle.write(sh_array("INIT_CMD", [str(c) for c in (init or {}).get("command") or []]))
    handle.write(sh_array("INIT_ARGS", init_args))

with open(os.path.join(work, "env.list"), "w") as handle:
    for name, value in main_env:
        handle.write(f"{name}={value}\n")

init_env = env_pairs(init or {})
with open(os.path.join(work, "init.env"), "w") as handle:
    for name, value in init_env:
        handle.write(f"{name}={value}\n")

# The template the init container substitutes into, under the key name it has
# in the ConfigMap - that is the file name a mounted ConfigMap produces.
if init is not None:
    if os.path.dirname(init_input) != template_dir:
        die(f"cannot line up the config template: args say {init_input}, "
            f"the mounted ConfigMap says {template_dir}")
    if os.path.basename(init_input) != config_key:
        die(f"the init container reads {init_input}, the ConfigMap key is {config_key}")
    with open(os.path.join(work, "config-template", config_key), "w") as handle:
        handle.write(config_map["data"][config_key])

print(f"     image  {main.get('image')}  user={run_as or 'image default'} "
      f"port={port} db={db_path}")
print(f"     render config {config_path} (probe {probe_kind or 'none'}: "
      f"{' '.join(probe_cmd) or '-'}), ready {url}")
PY

  # shellcheck source=/dev/null
  . "$work/spec.sh"
  image="$IMAGE"

  # 1. The init container exactly as rendered: same image, same command, same
  #    args, same env. It is what turns the ConfigMap template into the config
  #    the server reads, so skipping it (as this gate used to) would test a
  #    file the pod never sees.
  if [ "$HAVE_INIT" = "1" ]; then
    echo "     init   $INIT_IMAGE ${INIT_CMD[*]:-} ${INIT_ARGS[*]:-}"

    init_entrypoint=()
    init_argv=()
    if [ "${#INIT_CMD[@]}" -gt 0 ]; then
      init_entrypoint=(--entrypoint "${INIT_CMD[0]}")
      i=1
      while [ "$i" -lt "${#INIT_CMD[@]}" ]; do
        init_argv+=("${INIT_CMD[$i]}")
        i=$((i + 1))
      done
    fi
    init_argv+=( ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} )
    init_user=()
    if [ -n "$RUN_AS" ]; then
      init_user=(--user "$RUN_AS")
    fi

    docker run --rm ${platform_args[@]+"${platform_args[@]}"} \
      ${init_user[@]+"${init_user[@]}"} ${init_entrypoint[@]+"${init_entrypoint[@]}"} \
      -v "$work/config-template:${INIT_TEMPLATE_DIR}:ro" \
      -v "$work/substituted:${INIT_OUT_DIR}" \
      --env-file "$work/init.env" \
      "$INIT_IMAGE" ${init_argv[@]+"${init_argv[@]}"} \
      || fail "the rendered init container ($INIT_IMAGE) failed to produce the config"

    [ -f "$work/substituted/$CONFIG_FILE" ] \
      || fail "the rendered init container produced no $CONFIG_FILE under $INIT_OUT_DIR"
  else
    # A chart that mounts its ConfigMap straight into the server has no
    # substitution step; the rendered config is then the config, placeholders
    # and all, and the server has to cope with it.
    cp "$work/config-template"/*.toml "$work/substituted/$CONFIG_FILE"
    echo "     init   none rendered - starting from the rendered config as-is"
  fi

  # 2. The backup check is planned from the *substituted* config, so a
  #    ${VAR} placeholder that changes the path is honoured.
  python3 - "$work" "$work/substituted/$CONFIG_FILE" <<'PY'
import os, re, sys
from shlex import quote
import yaml

work, config_file = sys.argv[1:3]

with open(config_file) as handle:
    text = handle.read()


def toml_values(source, key):
    """Every `key = value` line of the substituted config, at any table depth."""
    pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=\s*(.+?)\s*$")
    values = []
    for line in source.splitlines():
        match = pattern.match(line)
        if match:
            values.append(match.group(1))
    return values


def toml_value(raw):
    """A quoted string or an array of them - the shapes the chart renders."""
    if len(raw) >= 2 and raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1]
    if raw.startswith("[") and raw.endswith("]"):
        return [toml_value(part.strip()) for part in raw[1:-1].split(",") if part.strip()]
    return raw


def config_value(key, default=None):
    for raw in toml_values(text, key):
        return toml_value(raw)
    return default


backup_path = config_value("database_backup_path")
signal_execute = config_value("admin_signal_execute")

lines = []
skip = "the substituted config sets no database_backup_path/admin_signal_execute pair"

if isinstance(backup_path, str) and backup_path.startswith("/") and signal_execute:
    with open(os.path.join(work, "manifest.yaml")) as handle:
        docs = [doc for doc in yaml.safe_load_all(handle) if isinstance(doc, dict)]

    # The command the chart's own crontab runs: the signal, with the schedule
    # fields stripped off its line.
    signal = []
    for doc in docs:
        if doc.get("kind") != "ConfigMap":
            continue
        root = (doc.get("data") or {}).get("root")
        if not root:
            continue
        for raw in str(root).splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            signal = fields[1:] if fields[0].startswith("@") else fields[5:]
            break
        if signal:
            break

    image = "busybox:1.37"
    for doc in docs:
        if doc.get("kind") != "StatefulSet":
            continue
        for box in doc["spec"]["template"]["spec"].get("containers") or []:
            if (box.get("command") or [None])[0] == "crond":
                image = str(box.get("image"))

    if not signal:
        # The crontab the chart renders for the sidecar; only used when the
        # render carries none (backup.scheduled off) but the config asks for
        # backups anyway.
        signal = ["pkill", "-USR2", "-x", "tuwunel"]

    if isinstance(signal_execute, list):
        signal_execute = " ".join(str(part) for part in signal_execute)

    lines.append(f"BACKUP_PATH={quote(backup_path)}")
    lines.append("BACKUP_SKIP=")
    lines.append(f"SIGNAL_IMAGE={quote(image)}")
    lines.append(f"SIGNAL_EXECUTE={quote(str(signal_execute))}")
    lines.append("SIGNAL_CMD=(" + " ".join(quote(str(f)) for f in signal) + ")")
else:
    lines.append("BACKUP_PATH=")
    lines.append(f"BACKUP_SKIP={quote(skip)}")
    lines.append("SIGNAL_IMAGE='busybox:1.37'")
    lines.append("SIGNAL_EXECUTE=''")
    lines.append("SIGNAL_CMD=()")

with open(os.path.join(work, "backup.sh"), "w") as handle:
    handle.write("\n".join(lines) + "\n")
PY
  # shellcheck source=/dev/null
  . "$work/backup.sh"

  # 3. The server itself, with the rendered env, the substituted config on the
  #    path the manifest names, and the rendered database path on a tmpfs: the
  #    server writes RocksDB as its own uid, and a bind mount would leave files
  #    the runner cannot delete again (macOS bind mounts hide that; the Linux
  #    CI runner does not). Nothing has to survive the fixture anyway.
  main_entrypoint=()
  main_argv=()
  if [ "${#MAIN_CMD[@]}" -gt 0 ]; then
    main_entrypoint=(--entrypoint "${MAIN_CMD[0]}")
    i=1
    while [ "$i" -lt "${#MAIN_CMD[@]}" ]; do
      main_argv+=("${MAIN_CMD[$i]}")
      i=$((i + 1))
    done
  fi
  main_argv+=( ${MAIN_ARGS[@]+"${MAIN_ARGS[@]}"} )

  main_user=()
  if [ -n "$RUN_AS" ]; then
    main_user=(--user "$RUN_AS")
  fi

  backup_mount=()
  if [ -n "$BACKUP_PATH" ]; then
    backup_mount=(-v "$work/backup:${BACKUP_PATH}")
  fi

  # `--read-only` plus the tmpfs mirrors the pod's readOnlyRootFilesystem and
  # its emptyDir at /tmp; the only writable paths are the ones the chart gives
  # the container as well.
  #
  # The published port is picked before docker binds it, so a concurrent run on
  # a shared host can take it in between: retry on the next free port instead of
  # reporting that race as a chart failure, and report anything else as-is.
  started=""
  for _ in 1 2 3 4 5; do
    if run_err=$(docker run -d --name "$container" \
        ${main_entrypoint[@]+"${main_entrypoint[@]}"} \
        ${main_user[@]+"${main_user[@]}"} \
        --read-only --tmpfs /tmp:rw,mode=1777 \
        --tmpfs "${DB_PATH}:rw,mode=1777,size=512m" \
        --env-file "$work/env.list" \
        -v "$work/substituted:${CONFIG_DIR}:ro" \
        ${backup_mount[@]+"${backup_mount[@]}"} \
        -p "127.0.0.1:${host_port}:${MAIN_PORT}" \
        "$image" ${main_argv[@]+"${main_argv[@]}"} 2>&1 >/dev/null); then
      started=1
      break
    fi
    case "$run_err" in
      *"port is already allocated"* | *"address already in use"*)
        docker rm -f "$container" >/dev/null 2>&1 || true
        host_port=$(free_port $((host_port + 1)))
        ;;
      *) break ;;
    esac
  done
  if [ -z "$started" ]; then
    fail "the container could not be started: ${run_err:-docker run failed}"
  fi

  if [ -n "$SERVICE_PORT" ] && [ "$SERVICE_PORT" != "$MAIN_PORT" ]; then
    echo "     note   the helm test URL uses port $SERVICE_PORT while the container listens on $MAIN_PORT; probing $MAIN_PORT directly (no Service in docker)"
  fi

  # 4. Assert in order: still running, the rendered probe command, the rendered
  #    readiness URL. A container that has already exited is a failure, not a
  #    slow start.
  deadline=$((SECONDS + ${RUNTIME_CHECK_TIMEOUT:-180}))
  health=""
  code=""
  while :; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
      fail "the container exited on its own (exit code $(docker inspect -f '{{.State.ExitCode}}' "$container")) instead of serving"
    fi
    if [ -z "$health" ] && [ "${#PROBE_CMD[@]}" -gt 0 ]; then
      if docker exec "$container" ${PROBE_CMD[@]+"${PROBE_CMD[@]}"} >/dev/null 2>&1; then
        health=1
      fi
    fi
    if [ -z "$code" ]; then
      got=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 \
        "http://127.0.0.1:${host_port}${READY_PATH}" 2>/dev/null || true)
      if [ "$got" = "200" ]; then
        code="$got"
      fi
    fi
    if [ -n "$code" ] && { [ -n "$health" ] || [ "${#PROBE_CMD[@]}" -eq 0 ]; }; then
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      hint="the readiness path never answered 200"
      [ -n "$code" ] && hint="the rendered probe command never exited 0"
      fail "$hint within ${RUNTIME_CHECK_TIMEOUT:-180}s"
    fi
    sleep 1
  done

  # 5. The online-backup path, only for a config that turns it on.
  backup_evidence=""
  if [ -n "$BACKUP_PATH" ]; then
    echo "     backup $BACKUP_PATH via admin_signal_execute=$SIGNAL_EXECUTE; running ${SIGNAL_CMD[*]:-} from $SIGNAL_IMAGE"
    docker run --rm --pid="container:$container" "$SIGNAL_IMAGE" \
      ${SIGNAL_CMD[@]+"${SIGNAL_CMD[@]}"} \
      || fail "the rendered crontab command (${SIGNAL_CMD[*]:-}) failed in the server's PID namespace"

    backup_start=$SECONDS
    while :; do
      # The mount starts empty (the scratch dir is recreated per fixture), so
      # anything under meta/ is a repository this signal created - the backup
      # engine names its entries <path>/meta/<id>. The nested form is accepted
      # too, so a layout change does not turn into a timeout.
      meta=("$work/backup"/meta/* "$work/backup"/*/meta/*)
      if [ "${#meta[@]}" -gt 0 ]; then
        break
      fi
      if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
        fail "the server died while handling the backup signal"
      fi
      [ $((SECONDS - backup_start)) -lt 60 ] || fail "no backup repository (meta/) appeared under $BACKUP_PATH within 60s of the rendered crontab's signal"
      sleep 1
    done
    backup_evidence=$(docker logs "$container" 2>&1 | grep -o 'Created database backup.*' | tail -1 || true)
    echo "     backup ok after $((SECONDS - backup_start))s: ${backup_evidence:-a backup repository exists under $BACKUP_PATH}"
  elif [ -n "$BACKUP_SKIP" ]; then
    echo "     backup skipped: $BACKUP_SKIP"
  fi

  echo "OK   $values $image ${PROBE_KIND:-no-probe}${PROBE_KIND:+:}[${PROBE_CMD[*]:-}] $READY_PATH -> $code${backup_evidence:+ | $backup_evidence}"
  if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
    docker logs "$container" 2>&1 | grep -o 'Listening on .*' | tail -1 || true
  fi

  docker rm -f "$container" >/dev/null
  container=""
  # The backup repository is written by the pod's uid inside a bind mount, so on
  # a Linux runner some of it may survive as files the runner cannot unlink;
  # that is scratch space in the runner's temp dir, never a reason to fail.
  rm -rf "$work" 2>/dev/null || true
  endgroup
done

if [ "$fixtures" -eq 0 ]; then
  echo "::error::no fixtures matched $chart_dir/ci/*-values.yaml - this job would pass without checking anything"
  exit 1
fi
echo "runtime check passed for $fixtures fixture(s)"
