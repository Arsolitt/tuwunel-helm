# How the chart renders a running server

> What happens between your values and a running tuwunel process: the ConfigMap template, the envsubst init container, the chart-owned environment, every value the chart derives and every guard that stops a bad render.

## Table of Contents

- [From values to a running server](#from-values-to-a-running-server)
- [The config processor init container](#the-config-processor-init-container)
- [Chart-managed environment](#chart-managed-environment)
- [Derivations and precedence](#derivations-and-precedence)
- [Render-time guards](#render-time-guards)
- [Reconciliation and rollouts](#reconciliation-and-rollouts)
- [What the chart does not do](#what-the-chart-does-not-do)
- [How CI proves a render](#how-ci-proves-a-render)

---

## From values to a running server

Every install walks the same six steps. Only two templates decide the behaviour of the running server: `templates/tuwunnel/configmap.yaml` produces the configuration template, and `templates/tuwunnel/statefulset.yaml` produces the init container that substitutes it plus the environment the server reads.

1. **Schema validation.** Helm validates your values against [`charts/tuwunel/values.schema.json`](../charts/tuwunel/values.schema.json) before any template runs. A shape the schema can express — a boolean written as a string, an unknown top-level key, a four-field cron expression — fails here and never reaches a template.
2. **The config template.** `templates/tuwunnel/configmap.yaml` takes a `deepCopy` of `.Values.config`, injects the chart-derived keys (see [Derivations and precedence](#derivations-and-precedence)), and renders the whole tree with Helm's `toToml` into the ConfigMap `<fullname>-configmap` under the single key `config.toml`. Keys come out sorted and empty tables are still emitted.
3. **The ConfigMap holds a template, not a file.** Its `config.toml` value may contain `${VAR}` placeholders — that is how secrets and S3 credentials stay out of the ConfigMap.
4. **The init container substitutes it.** `config-processor` mounts the ConfigMap read-only over `/tmp/config-template`, runs `envsubst`, and writes the result to an `emptyDir` at `/tmp/config`.
5. **The server reads the substituted file.** The `tuwunel` container mounts the same `emptyDir` at `/tmp/config` and finds its configuration through `TUWUNEL_CONFIG=/tmp/config/config.toml`.
6. **The environment carries the same facts.** The chart exports `TUWUNEL_SERVER_NAME`, `TUWUNEL_PORT`, `TUWUNEL_ADDRESS`, `TUWUNEL_DATABASE_PATH` and the two thread counts on the server container, so the values that decide reachability never depend on the file being read.

```text
values.yaml + your values
        │
        ▼
values.schema.json .......... shapes, enums, formats (aborts before any template)
        │
        ▼
templates/tuwunnel/configmap.yaml
  deepCopy .Values.config → inject derived keys → toToml
        │
        ▼
ConfigMap <fullname>-configmap
  data["config.toml"] = a template containing ${VAR} placeholders
        │  mounted read-only at /tmp/config-template
        ▼
initContainer config-processor   (initContainer.image, default dibi/envsubst:1)
  envsubst < /tmp/config-template/config.toml > /tmp/config/config.toml
  env: env / envRaw / envFromSecret only — nothing else
        │
        ▼
emptyDir "config" → /tmp/config/config.toml
        │  mounted into the server container at the same path
        ▼
container tuwunel → TUWUNEL_CONFIG=/tmp/config/config.toml
```

The moment that matters is step 4: the file the server opens exists only inside the pod, in an `emptyDir`. `kubectl get configmap ci-tuwunel-configmap -o jsonpath='{.data.config\.toml}'` shows the template, not the file; `.Values.config` alone therefore never reaches the server.

A minimal render shows the TOML passthrough shape (`helm template ci charts/tuwunel -f charts/tuwunel/ci/minimal-values.yaml`):

```toml
[global]
  address = "::"
  allow_federation = false
  allow_registration = false
  log = "info"
  trusted_servers = []
  [global.ldap]
  [global.tls]
  [global.well_known]
```

### Volumes and the read-only root filesystem

The server container runs with `readOnlyRootFilesystem: true`, so the only writable paths are mounted volumes. `extraVolumeMounts` and `extraVolumes` are your extension points.

| Volume | Kind | Mounted at | Purpose |
|---|---|---|---|
| `data` | PVC `<fullname>-data`, or `emptyDir` when `persistence.data.enabled` is false | `/data` with `subPath: data` | Database (`/data/db` by default) and media (`media/` under the database path) |
| `config-template` | ConfigMap `<fullname>-configmap` | `/tmp/config-template` (init container only) | The unsubstituted `config.toml` |
| `config` | `emptyDir` | `/tmp/config` in both containers | The substituted `config.toml` |
| `tmp` | `emptyDir` | `/tmp` | Scratch space for the container |
| `backup` | PVC `<fullname>-backup` (only when `backup.enabled`) | `backup.path` (default `/backups`) | Online database backups |
| `backup-crontabs` | ConfigMap `<fullname>-backup-crontabs` (only when `backup.scheduled`) | `/etc/crontabs` in the sidecar | The single crontab line |

> **Danger:** Because the root filesystem is read-only, `config.global.database_path` pointed anywhere outside `/data` moves the database off every writable volume. Keep it under `/data` — see [Storage and media](./storage-and-media.md).

## The config processor init container

`config-processor` is the only init container in the pod, and it never mounts the data volume. Everything it does is visible in the render:

| Field | Rendered value |
|---|---|
| `image` | `{{ .Values.initContainer.image.repository }}:{{ .Values.initContainer.image.tag }}` — default `dibi/envsubst:1` |
| `command` | `["/bin/sh", "-c"]` |
| `args` | `envsubst < /tmp/config-template/config.toml > /tmp/config/config.toml` |
| `volumeMounts` | `config-template` → `/tmp/config-template`, `config` → `/tmp/config`, `tmp` → `/tmp` |
| `env` | Your `env`, `envRaw` and `envFromSecret` entries — and nothing else. The block is emitted only when at least one of the three is non-empty; `envFromSecret` entries are resolved through `secretKeyRef` like everywhere else |

The substitution step has consequences you cannot see in the ConfigMap:

- `envsubst` runs **without a variable list**, so every `${VAR}` and `$VAR` reference in the configuration is replaced. A name the environment does not define expands to the empty string rather than failing.
- The chart's own `TUWUNEL_*` / `TOKIO_*` variables are **not** exported to the init container. A `${TUWUNEL_PORT}` or `${TUWUNEL_DATABASE_PATH}` placeholder written into `config` therefore renders as an empty value, silently.
- `extraEnv` is not exported either: it is appended to the server container only, so it is invisible to `envsubst` as well.
- The init container image is shared with the LiveKit pod's init container — see [Matrix RTC with LiveKit](./rtc.md).

> **Warning:** `dibi/envsubst:1` is published for `linux/amd64` only. On an arm64 cluster both the homeserver pod and the LiveKit pod stay in `Init:0/1` with no application-level error until you point `initContainer.image` at a multi-arch or mirrored equivalent ([Troubleshooting](./troubleshooting.md)).

## Chart-managed environment

The chart writes seven variables on the server container, in this order, before any user-supplied environment. The example column is the value from `helm template ci charts/tuwunel -f charts/tuwunel/ci/minimal-values.yaml` (`server_name: matrix.ci.example`, default `service.port` and default CPU limit):

| Variable | Source | Example value |
|---|---|---|
| `TUWUNEL_CONFIG` | Literal in `statefulset.yaml` | `/tmp/config/config.toml` |
| `TUWUNEL_SERVER_NAME` | `server_name`, through `required` | `matrix.ci.example` |
| `TUWUNEL_DATABASE_PATH` | `config.global.database_path`, default `/data/db` | `/data/db` |
| `TUWUNEL_PORT` | `service.port` | `8080` |
| `TUWUNEL_ADDRESS` | `config.global.address`, default `::`, passed through `toJson` and then quoted | `"::"` |
| `TOKIO_WORKER_THREADS` | Derived from `resources.limits.cpu` | `1` |
| `TUWUNEL_ROCKSDB_PARALLELISM_THREADS` | The same derived thread count | `1` |

After the chart-owned block the template appends, in order: `env`, then `envRaw` verbatim, then `envFromSecret` as `secretKeyRef`, then `extraEnv` last with both name and value quoted. A user entry that reuses a chart-managed name is not rejected — it appears twice in the container spec.

**Precedence.** An environment variable beats a value in the configuration file, and the canonical `TUWUNEL_` prefix outranks the legacy `CONDUIT_` / `CONDUWUIT_` aliases of older releases. A leftover `CONDUWUIT_PORT` in `env` no longer decides the port: with both set, tuwunel v1.9.2 listens on the `TUWUNEL_PORT` port. That is also why the chart fails the render when `config.global.port` or `config.global.server_name` disagrees with the chart-owned value instead of letting the environment win silently ([Render-time guards](#render-time-guards), and [Upgrading](./upgrade.md) for leftovers from 1.x values files).

> **Note:** `TUWUNEL_ADDRESS` is a JSON string literal — the quotes are part of the value. A string address renders as `"::"`, a list address as `["::","0.0.0.0"]`. The environment value is deliberately not textually identical to `address = "::"` in the configuration file.

## Derivations and precedence

Every value the chart fills in is additive-only. Each injection is guarded by `hasKey` / `not hasKey` (or `default`), so **the chart never overwrites a value it finds** — if you set the key, your value wins and nothing else is nested. The two deliberate exceptions are the port and server-name guards, which fail the render instead of losing silently.

| Left empty | What the chart supplies | Where |
|---|---|---|
| `config.global.address` | `"::"` in `config.toml` and as `TUWUNEL_ADDRESS` | `statefulset.yaml` |
| `config.global.database_path` | `/data/db` | `statefulset.yaml` |
| `resources.limits.cpu` | One thread (the schema normally requires both `requests` and `limits`, so this is visible only when schema validation is skipped) | `statefulset.yaml` |
| Data volume claim name | `<fullname>-data` (`persistence.data.existingClaim` wins) | `pvc-data.yaml`, `statefulset.yaml` |
| Backup volume claim name | `<fullname>-backup` (`backup.existingClaim` wins) | `pvc-backup.yaml`, `statefulset.yaml` |
| `ingress.tlsSecretName` | `<fullname>-tls` | `tuwunnel/ingress.yaml` |
| RTC ingress class / TLS secret | `ingress.class` / `<fullname>-rtc-tls` | `rtc/ingress.yaml` |
| RTC route `parentRefs` | `gateway.parentRefs` | `rtc/httproute.yaml`, `rtc/tcproute.yaml`, `rtc/udproute.yaml` |
| `config.global.well_known.livekit_url` | `https://<rtc.domain>`, only when `rtc.enabled` and `rtc.domain` are set and neither `livekit_url` nor `rtc_transports` exists | `tuwunnel/configmap.yaml` |
| `config.global.database_backup_path` | `backup.path` (`/backups`), only when `backup.enabled` | `tuwunnel/configmap.yaml` |
| `config.global.database_backups_to_keep` | `backup.keep` as an integer (`7`), only when `backup.enabled` | `tuwunnel/configmap.yaml` |
| `config.global.admin_signal_execute` | A one-element list `["server backup-database"]` from `backup.command`, only when `backup.enabled` and `backup.scheduled` | `tuwunnel/configmap.yaml` |
| `rtc.jwt.env` entries | `LIVEKIT_URL=wss://<rtc.domain>`, `LIVEKIT_FULL_ACCESS_HOMESERVERS=<server_name>`, `LIVEKIT_JWT_BIND=:8080` | `rtc/jwt-deployment.yaml` |
| `rtc.livekit.config` keys | `keys: {"${LIVEKIT_KEY}": "${LIVEKIT_SECRET}"}`, `room.auto_create: false`, `webhook.api_key: ${LIVEKIT_KEY}`, `webhook.urls: [http://<fullname>-jwt:8080/sfu_webhook]` | `rtc/livekit-configmap.yaml` |
| Probe timings | The `values.yaml` defaults, emitted verbatim — startup `10 / 5 / 180 / 0`, readiness and liveness `10 / 5 / 3 / 0` (period / timeout / failure threshold / initial delay). There is no defaulting in the template: a probe block is omitted entirely when its `enabled` is false | `values.yaml`, `statefulset.yaml` |

Two layouts are derived rather than defaulted, and both matter as soon as you delegate a domain:

- **Ingress hosts.** When `config.global.well_known.server` is set, the chart strips its `:port` suffix and uses the result as the delegated domain. The `server_name` host is then narrowed to `/.well-known/matrix` and `/_matrix`, while the delegated host serves `ingress.path`, and `ingress.extraHosts` are appended. The TLS host list is `server_name` + delegated domain + `ingress.extraHosts`. See [Ingress](./ingress.md) and [Federation and delegation](./federation.md).
- **Gateway hostnames.** The HTTPRoute hostnames are `server_name` + the delegated domain + `gateway.hostnames`, deduplicated with `uniq`, and the route has a single catch-all rule — no per-path host list. See [Gateway API](./gateway-api.md).

`service.port` is propagated as well: it is the Service port, the container port, `TUWUNEL_PORT`, every Ingress and HTTPRoute backend, and the URL the test hook calls. It is the only port knob in the chart.

### Thread count from the CPU limit

`TOKIO_WORKER_THREADS` and `TUWUNEL_ROCKSDB_PARALLELISM_THREADS` both come from `resources.limits.cpu`, with a type-sensitive rule that deserves a table of its own (all values measured with `helm template`):

| `resources.limits.cpu` | Derived threads |
|---|---|
| unset | `1` |
| `1` (number, the chart default) | `1` |
| `2` (number) | `2` |
| `0.25` (number) | `0.25` — passed through unchanged |
| `"1"` (string) | `1` |
| `"2"` (string) | `1` — a bare string is millicores: 2000m ÷ 1000 |
| `"100m"`, `"500m"`, `"1000m"` | `1` |
| `"1500m"`, `"2000m"` | `2` |
| `"0.5"` | `1` |
| `"1.5"` | `2` |

A string limit has a trailing `m` stripped, a value containing `.` is `ceil`ed and multiplied by 1000, and the result is rounded up to whole threads unless it divides evenly by 1000. Quoting the CPU limit (or setting it with `--set-string`) therefore reads as millicores and silently leaves the server with one worker.

**Never derived** (fixed in the templates or required from you): `server_name` (required, non-empty), `replicas` (hardcoded `1` on all three workloads), the pod and container security context, and the probe commands themselves.

## Render-time guards

Guards fail with `Error: execution error at (<template>:<line>:<column>): <message>` and abort the whole render — nothing is installed or upgraded. These are the template-level refusals; each message below is quoted as the chart emits it (values in parentheses are interpolated from your values).

| Guard | Fires when | Exact message |
|---|---|---|
| Required `server_name` | `server_name` is empty | `You must set a server name otherwise no one will be able to reach you` |
| Port agreement | `config.global.port` is set and differs from `service.port` | `config.global.port (8008) must equal service.port (8080): the chart sets TUWUNEL_PORT from service.port` |
| Server-name agreement | `config.global.server_name` is set and differs from `server_name` | `config.global.server_name (other.example) must equal server_name (matrix.ci.example): the chart sets TUWUNEL_SERVER_NAME from server_name` |
| Ingress class | `ingress.enabled` with an empty `ingress.class` | `If ingress.enabled is set to true, ingress.class is required` |
| Gateway parentRefs | `gateway.enabled` without `gateway.parentRefs` | `gateway.enabled needs gateway.parentRefs: the chart renders HTTPRoutes that attach to a Gateway you run, it does not create one` |
| RTC route parentRefs | `rtc.gateway.enabled` without `rtc.gateway.parentRefs` or `gateway.parentRefs` | `rtc.gateway.enabled needs parentRefs: set rtc.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` |
| UDP media route, mode | `rtc.livekit.gateway.udpRoute` while `rtc.livekit.networkMode` is not `pod` | `rtc.livekit.gateway.udpRoute needs rtc.livekit.networkMode=pod (it is "hostNetwork"): with hostNetwork the media ports are node ports, and the Service exposes rtc-udp only in pod mode` |
| UDP media route, port | `udpRoute` without `rtc.livekit.config.rtc.udp_port` | `rtc.livekit.gateway.udpRoute needs rtc.livekit.config.rtc.udp_port: the Service exposes no rtc-udp port without it` |
| UDP media route, parentRefs | `udpRoute` without `rtc.livekit.gateway.parentRefs` or `gateway.parentRefs` | `rtc.livekit.gateway.udpRoute needs parentRefs: set rtc.livekit.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` |
| TCP media route, mode | `rtc.livekit.gateway.tcpRoute` while `networkMode` is not `pod` | `rtc.livekit.gateway.tcpRoute needs rtc.livekit.networkMode=pod (it is "hostNetwork"): with hostNetwork the media ports are node ports, and the Service exposes rtc-tcp only in pod mode` |
| TCP media route, port | `tcpRoute` with no `rtc.livekit.config.rtc.tcp_port` | `rtc.livekit.gateway.tcpRoute needs rtc.livekit.config.rtc.tcp_port: the Service exposes no rtc-tcp port without it` |
| TCP media route, parentRefs | `tcpRoute` without `rtc.livekit.gateway.parentRefs` or `gateway.parentRefs` | `rtc.livekit.gateway.tcpRoute needs parentRefs: set rtc.livekit.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` |
| Pod-mode UDP range | `rtc.livekit.networkMode: pod` with a range in `config.rtc.udp_port` | `rtc.livekit.config.rtc.udp_port: a Kubernetes Service cannot expose a UDP port range; set a single port (e.g. 7882) or use rtc.livekit.networkMode=hostNetwork` |
| Pod-mode range-only config | `networkMode: pod` with `port_range_start`/`port_range_end` and no `udp_port` | `rtc.livekit.networkMode=pod needs rtc.livekit.config.rtc.udp_port: a Kubernetes Service cannot forward rtc.livekit.config.rtc.port_range_start/end, so media would have no path to the pod (use a single udp_port, or networkMode=hostNetwork)` |

Two notes on reachability: the TCP "port" branch only fires if you explicitly null `tcp_port`, because the chart's default `rtc.livekit.config` already carries `tcp_port: 7881` and the `50100`–`50200` range; and for the media routes the *mode* guard is the one you meet first — it fires in the default `hostNetwork` mode, which is what `ci/invalid-render/rtc-media-route-without-pod-mode.yaml` exists to prove — while the port and parentRefs branches of those two templates only become reachable once `networkMode: pod`.

Above the templates, `Chart.yaml` sets `kubeVersion: '>=1.31.0-0'`, so Helm refuses the release on an older cluster before producing any manifest: `Error: chart requires kubeVersion: >=1.31.0-0 which is incompatible with Kubernetes v1.30.0`.

### What the schema refuses first

`values.schema.json` runs before the templates, so its rejections never look like the guards above. Examples, quoted as Helm prints them:

| Fixture | Message fragment |
|---|---|
| Unknown top-level key | `at '': additional properties 'ingres' not allowed` |
| Quoted boolean | `at '/config/global/allow_federation': got string, want boolean` |
| Secret reference without a key | `at '/envFromSecret/LIVEKIT_KEY': 'livekit-secrets' does not match pattern '^[^/]+/[^/]+$'` |
| `extraEnv` entry without a value | `missing property 'value'` |
| `resources.limits` nulled | `at '/resources': missing property 'limits'` |
| `rtc.enabled` with an empty domain | `at '/rtc/domain': minLength: got 0, want 1` |

Enums (`image.pullPolicy`, `persistence.data.accessMode`, `rtc.livekit.networkMode`, `ip_source`), `backup.keep` below 1, and a cron schedule that is not five fields are rejected the same way — the schema's root also *requires* `server_name`, `image`, `config`, `service`, `ingress`, `persistence`, `resources` and `rtc` to be present, even when you only intend to disable them (`probes` is not in that list: nulling it passes the schema and then fails in the template instead). See [Configuring the server](./configuration.md) for the value-by-value view.

## Reconciliation and rollouts

The configuration and the environment reach the server only at container start, and neither changes the pod template on its own. The chart therefore puts a digest on the pod template:

```yaml
checksum/config: <64 hex chars><64 hex chars>
```

It is the **concatenation of two `sha256sum`s** — the first 64 characters hash the rendered `configmap.yaml` template, the last 64 hash `printf "%v%v%v" .Values.env .Values.envRaw .Values.envFromSecret` — so the value is 128 hex characters, not a hash of a hash. Changing `config` moves the first half (and the pod rolls); changing `env`, `envRaw` or `envFromSecret` moves the second half.

`extraEnv` is the one gap in the annotation, not in the rollout: an `extraEnv`-only change leaves the annotation byte-identical (confirmed by rendering with and without an entry), but `extraEnv` still renders into `containers[].env`, so the pod template changes and the StatefulSet — no `updateStrategy`, so the default `RollingUpdate` at `replicas: 1` — recreates the pod anyway. Only the chart's own roll trigger misses the edit.

| Workload | Strategy | Notes |
|---|---|---|
| StatefulSet `<fullname>` | No `spec.strategy` (Kubernetes default `RollingUpdate`), `replicas: 1`, `podManagementPolicy: Parallel` | Carries `checksum/config`; `terminationGracePeriodSeconds: 1800` by default, sized for the one-time database migration that a `SIGKILL` would leave half-applied |
| Deployment `<fullname>-livekit` (RTC) | `strategy.type: Recreate`, `replicas: 1` | Carries `checksum/livekit-config` because `livekit.yaml` only reaches the pod through its own init container; in `hostNetwork` mode its media ports are node ports, so there is no rolling path |
| Deployment `<fullname>-jwt` (RTC) | Default strategy, `replicas: 1` | No checksum annotation: its derived environment lives inline in the pod template, so an env change already changes the template |

> **Warning:** `podAnnotations` is rendered *after* `checksum/config`, so setting `podAnnotations["checksum/config"]` yourself produces a duplicate YAML key whose last occurrence wins — and the chart's roll trigger is silently replaced. Editing `config` then stops rolling the pod.

`backup.scheduled: true` additionally sets `shareProcessNamespace: true` on the pod, because the crond sidecar signals the server by name (`pkill -USR2 -x tuwunel`) from the ConfigMap-provided crontab — and the sidecar itself runs as root with `SETGID`/`SETUID`/`KILL` added, since crond starts a spool file as the user that file is named after ([Backups and restore](./backups.md#the-scheduled-sidecar)).

The test hook adds one Pod that plain `helm template` already shows: `<fullname>-test-connection`, a busybox container running `wget -q --spider http://<fullname>.<namespace>.svc:<service.port>/_tuwunel/server_version` as UID/GID `65534`, annotated `helm.sh/hook: test` with `helm.sh/hook-delete-policy: before-hook-creation`. It is created only by `helm test` and deleted before the next hook creation, so its absence from a live cluster is expected ([Day-2 operations](./operations.md)).

### Selectors are a fixed label subset

Every selector in the chart - `spec.selector.matchLabels` on the StatefulSet and the two RTC
Deployments, and the `selector` of each Service - is rendered from `tuwunel.selectorLabels`
(`app.kubernetes.io/name`, `app.kubernetes.io/instance`) plus the component of the resource. The
metadata labels and the pod template labels keep the full `tuwunel.labels` set instead, so the pod
template is always a superset of the selector that has to match it. Three labels are held out of the
selectors on purpose:

| Label | Why it stays out |
| --- | --- |
| `helm.sh/chart` | It carries the chart version, so it moves on every chart release. `spec.selector` is immutable on a StatefulSet and on a Deployment, which makes the next `helm upgrade` unapplyable - that is exactly what happened up to 2.0.1, and what [Upgrading from 2.0.1 or older](./upgrade.md#upgrading-from-201-or-older) cleans up |
| `app.kubernetes.io/managed-by` | Constant for a Helm-managed release, but it says nothing about which pod is which: a Service that selects on it stops matching pods the moment the release is adopted by another manager |
| `extraLabels` | Yours, so changing one would move a selector the same way `helm.sh/chart` does - the guarantee "my labels cannot break an upgrade" is worth more than selecting on a label the chart does not own |

The Service selectors are not immutable, but they are held to the same subset for a second reason:
the new selector is applied before the new pods exist, so a Service that selected on the chart version
would drop the old pods' endpoints for the whole rollout window. With the fixed subset the old pods
match the new selector too, and the endpoints never empty.

The `lint` job asserts both properties on every render - no moving label in any selector, and every
workload's own pod template carrying what its selector asks for - because a single render cannot show
an immutability defect: the API server only refuses the *next* chart version.

## What the chart does not do

Each row was checked against the rendered output of the CI scenarios and against the chart's file list:

| Not done | Evidence |
|---|---|
| No CRDs and no `crds/` directory | `charts/tuwunel/` contains only `Chart.yaml`, `.helmignore`, `README.md`, `values.yaml`, `values.schema.json`, `ci/` and `templates/` |
| No Gateway or GatewayClass | The Gateway API templates render only `HTTPRoute`, `TCPRoute` and `UDPRoute`; attaching to a Gateway you run is the contract ([Gateway API](./gateway-api.md)) |
| No database bootstrap Job, no wait-for-database init container | The pod has exactly one init container (`config-processor`) and it never mounts the data volume; the server migrates itself on first start, which is what the startup probe budget covers |
| No NetworkPolicy | No `NetworkPolicy` (and no PodDisruptionBudget, HPA, ServiceAccount/RBAC, ServiceMonitor or Job) appears in any of the twelve scenario renders |
| No high availability | `replicas` is hardcoded to `1` on the StatefulSet and both RTC Deployments; the release notes warn that scaling the StatefulSet risks quiet data corruption, and nothing in the chart stops two writers on one RocksDB directory |
| No validation of the configuration *contents* | `config` is a free-form object; a nested mapping where upstream wants an array of tables — `config.global.identity_provider` written as a YAML mapping — passes `helm lint` and renders `[global.identity_provider]`, and stops the server at startup instead ([Troubleshooting](./troubleshooting.md), [Configuring the server](./configuration.md)) |

## How CI proves a render

`hack/runtime-check.sh` is the layer that executes something: it renders a fixture and then drives the real image with what the render says. In the script's own words, it "hardcodes no env name, no path and no probe" — it takes the environment from the *rendered* init container (same image, command, args and env, with each `secretKeyRef` faked by a placeholder), the config path from the rendered `TUWUNEL_CONFIG` (falling back to the init container's output path), the database path from the rendered `TUWUNEL_DATABASE_PATH`, and finally runs the rendered probe command and readiness URL. `AGENTS.md` states the rule that keeps it honest: if the script has to know something the manifests do not say, that is a bug in the manifests.

The release pipeline, the fixture conventions and the exact commands are on [Development and releases](./development.md); the value-level reference is the [chart README § Environment Variables](../charts/tuwunel/README.md#environment-variables) and [chart README § What the chart derives](../charts/tuwunel/README.md#what-the-chart-derives).
