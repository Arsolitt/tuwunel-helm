# Troubleshooting

> Symptom catalogue for the tuwunel chart: the exact error text it produces, what each one means, and the page that owns the fix.

## Table of Contents

- [Start here](#start-here)
- [Rejected before render (schema)](#rejected-before-render-schema)
- [Rejected at render time (template guards)](#rejected-at-render-time-template-guards)
- [The server exits at startup](#the-server-exits-at-startup)
- [The pod never becomes Ready](#the-pod-never-becomes-ready)
- [Exposure and federation](#exposure-and-federation)
- [RTC media](#rtc-media)
- [Storage and backups](#storage-and-backups)
- [Upgrades](#upgrades)
- [Collecting diagnostics](#collecting-diagnostics)

---

## Start here

Three commands classify almost every failure. The release name below is `my-release`; the StatefulSet is `<fullname>`, so its pod is `<fullname>-0`.

```console
$ helm template my-release charts/tuwunel -f values.yaml
$ kubectl get pod my-release-tuwunel-0
$ kubectl logs my-release-tuwunel-0 -c tuwunel
```

**A render-time refusal is not a runtime failure.** `helm template` never contacts a cluster: if it fails, nothing exists to inspect, and pod state, events and logs cannot explain it - fix the values and render again. The reverse is also true: a clean render proves nothing about the server, because `config` is a deliberate pass-through. Wrong TOML types, wrongly shaped tables, an unbindable address and empty secret placeholders all pass validation and only surface when the container starts.

| What you see | Produced by | Read |
| --- | --- | --- |
| `Error: values don't meet the specifications of the schema(s) in the following chart(s):` | `values.schema.json`; every Helm verb, `lint` included | [Rejected before render](#rejected-before-render-schema) |
| `Error: execution error at (tuwunel/templates/…:line:col): …` | a template `fail` guard; render, install and upgrade only | [Rejected at render time](#rejected-at-render-time-template-guards) |
| `Error: chart requires kubeVersion: >=1.31.0-0 which is incompatible with Kubernetes v1.30.0` | `Chart.yaml`, before any template renders | [Installing the chart](./installation.md) |
| `Pending`, `ImagePullBackOff`, `CrashLoopBackOff`, `0/1 Running` | the cluster and the container | [The pod never becomes Ready](#the-pod-never-becomes-ready), [The server exits at startup](#the-server-exits-at-startup) |
| a 403/404/500 from a route while the pod is `Ready` | the server's own routing or configuration | [Exposure and federation](#exposure-and-federation) |

Two facts that remove whole classes of wrong answers:

- **Health is process-local.** All three probes exec `tuwunel --health-check` inside the container, so no HTTP status can make the pod NotReady. Checking `/_tuwunel/server_version` by hand proves the listener answers; a green readiness probe proves the server accepted its configuration.
- **`helm lint` is not a substitute for `helm template`.** It reports a guard failure as `level=INFO msg="funcMap fail" message="…"` and still exits 0 (`1 chart(s) linted, 0 chart(s) failed`); schema violations do fail lint. See [Development and releases](./development.md) for the gates CI uses.

## Rejected before render (schema)

Every schema rejection has the same shape, with a JSON pointer to the offending value (the angle-bracketed parts are placeholders):

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '<json-pointer>': <reason>
```

Unknown top-level keys are the main failure this catches - Helm silently ignores a key it does not know, so a misspelled block would otherwise never render. The fixture classes are: unknown key, wrong type, bad enum/format, missing required property, and additional properties inside a known block.

| Offending value | Exact error line | Fix | Owner |
| --- | --- | --- | --- |
| `ingres: {enabled: true}` (typo) | `- at '': additional properties 'ingres' not allowed` | Rename to `ingress`, or delete the block | [Configuring the server](./configuration.md) |
| `service.externalTrafficPolicy: Local` | `- at '/service': additional properties 'externalTrafficPolicy' not allowed` | The knob lives under `rtc.livekit.service.externalTrafficPolicy`; for the homeserver Service use `service.annotations`/an Ingress | [Exposing the homeserver with Ingress](./ingress.md) |
| `service.type: ExternalName` | `- at '/service/type': value must be one of 'ClusterIP', 'NodePort', 'LoadBalancer'` | The chart manages no `externalName`, so a Service of that type would be refused by the API server anyway; use the three supported types | [Exposing the homeserver with Ingress](./ingress.md) |
| `config.global.allow_federation: "false"` (quoted) | `- at '/config/global/allow_federation': got string, want boolean` | Unquote it - TOML booleans are bare | [Configuring the server](./configuration.md) |
| `config.global.ip_source: xforwarded_for` | `- at '/config/global/ip_source': value must be one of 'connect_info', 'rightmost_x_forwarded_for', 'rightmost_forwarded', 'x_real_ip', 'cf_connecting_ip', 'true_client_ip', 'fly_client_ip', 'cloudfront_viewer_address'` | Use one of the eight accepted values | [Configuring the server](./configuration.md) |
| `image.pullPolicy: Sometimes` | `- at '/image/pullPolicy': value must be one of 'Always', 'IfNotPresent', 'Never'` | Use a real pull policy | [Configuring the server](./configuration.md) |
| `persistence.data.accessMode: ReadWriteManyy` | `- at '/persistence/data/accessMode': value must be one of 'ReadWriteOnce', 'ReadOnlyMany', 'ReadWriteMany', 'ReadWriteOncePod'` | Use a Kubernetes access mode verbatim | [Storage and media](./storage-and-media.md) |
| `envFromSecret: {LIVEKIT_KEY: livekit-secrets}` (no key) | `- at '/envFromSecret/LIVEKIT_KEY': 'livekit-secrets' does not match pattern '^[^/]+/[^/]+$'` | Write `<secret-name>/<key>`; without the key part the template would fail with an opaque index error | [Secrets and hardening](./security.md) |
| `extraEnv: [{name: LIVEKIT_KEY}]` | `- at '/extraEnv/0': missing property 'value'` | `extraEnv` entries need both `name` and `value` - they cannot reference a Secret | [Configuring the server](./configuration.md) |
| `resources.limits: null` | `- at '/resources': missing property 'limits'` | Restore `limits.cpu` and `limits.memory`; the StatefulSet template dereferences them | [Configuring the server](./configuration.md) |
| `backup.keep: 0` | `- at '/backup/keep': minimum: got 0, want 1` | Keep at least one - `0` prunes every backup after the next one is taken | [Backups and restore](./backups.md) |
| `backup.schedule: "0 3 * *"` (four fields) | `- at '/backup/schedule': '0 3 * *' does not match pattern '^\\s*\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s*$'` | Write a five-field cron expression | [Backups and restore](./backups.md) |
| `rtc.enabled: true` without `rtc.domain` | `- at '/rtc/domain': minLength: got 0, want 1` | Set the RTC domain - the message names neither RTC nor the reason | [Matrix RTC with LiveKit](./rtc.md) |
| `rtc.livekit.networkMode: bridge` | `- at '/rtc/livekit/networkMode': value must be one of 'hostNetwork', 'pod'` | `bridge` was accepted-and-ignored before 2.0.0; pick `hostNetwork` or `pod` | [Matrix RTC with LiveKit](./rtc.md) |
| `rtc.ingress.path: /rtc` | `- at '/rtc/ingress': additional properties 'path' not allowed` | Removed in 2.0.0 - the RTC host always serves the JWT paths plus `/` | [Matrix RTC with LiveKit](./rtc.md) |

> **Note:** Unknown `config` keys are *not* rejected - `config` is a pass-through. A key 2.0.0 removed only warns: `Config parameter "blurhashing" is unknown to tuwunel, ignoring.` (the same line for `antispam`), and the server starts. See [Upgrading](./upgrade.md).

> **Note:** A missing or misnamed *value* inside a well-formed reference is not caught here. `envFromSecret: {TOKEN: secret/missing-key}` renders; the placeholder it feeds becomes an empty string at pod start.

## Rejected at render time (template guards)

These are cross-value rules the schema cannot express, so they are enforced by `fail` inside a template. Helm prints them as (angle-bracketed parts are placeholders):

```text
Error: execution error at (<template>:<line>:<column>): <message>

Use --debug flag to render out invalid YAML
```

They appear only in render/install/upgrade paths - `helm lint` downgrades them to `level=INFO` and exits 0. Every message below is emitted with the values you set, so the numbers and names in it are your own. The schema checks values one at a time; a guard is needed when the problem is a *combination* - including combinations with defaults the chart injects itself, such as the `50100`/`50200` range that makes `networkMode: pod` require `udp_port` even when you never wrote a `config.rtc` block.

| Trigger | Message (verbatim) | Template | Fix | Owner |
| --- | --- | --- | --- | --- |
| `config.global.port` differs from `service.port` | `config.global.port (8008) must equal service.port (8080): the chart sets TUWUNEL_PORT from service.port` | `tuwunnel/statefulset.yaml:24:4` | Delete the duplicate in `config`; move the port by changing `service.port` only | [Configuring the server](./configuration.md) |
| `config.global.server_name` differs from `server_name` | `config.global.server_name (other.example) must equal server_name (matrix.ci.example): the chart sets TUWUNEL_SERVER_NAME from server_name` | `tuwunnel/statefulset.yaml:28:4` | Keep the identity in `server_name` alone | [Federation and delegation](./federation.md) |
| `ingress.enabled: true` with the default `ingress.class: ""` | `If ingress.enabled is set to true, ingress.class is required` | `tuwunnel/ingress.yaml:31:23` | Name the class serving your cluster | [Exposing the homeserver with Ingress](./ingress.md) |
| `gateway.enabled: true` without `gateway.parentRefs` | `gateway.enabled needs gateway.parentRefs: the chart renders HTTPRoutes that attach to a Gateway you run, it does not create one` | `gateway/httproute.yaml:5:4` | Point the route at an existing Gateway | [Exposing the homeserver with Gateway API](./gateway-api.md) |
| `rtc.gateway.enabled: true` with no parentRefs anywhere | `rtc.gateway.enabled needs parentRefs: set rtc.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` | `rtc/httproute.yaml:5:4` | Set `rtc.gateway.parentRefs` (or the shared `gateway.parentRefs`) | [Matrix RTC with LiveKit](./rtc.md) |
| `rtc.livekit.gateway.udpRoute: true` without parentRefs | `rtc.livekit.gateway.udpRoute needs parentRefs: set rtc.livekit.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` | `rtc/udproute.yaml:12:4` | The media routes never inherit `rtc.gateway.parentRefs` - set their own or the homeserver's | [Exposing the homeserver with Gateway API](./gateway-api.md) |
| `rtc.livekit.gateway.tcpRoute: true` without parentRefs | `rtc.livekit.gateway.tcpRoute needs parentRefs: set rtc.livekit.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` | `rtc/tcproute.yaml:12:4` | Same as above | [Exposing the homeserver with Gateway API](./gateway-api.md) |
| A media route while `rtc.livekit.networkMode` is `hostNetwork` | `rtc.livekit.gateway.udpRoute needs rtc.livekit.networkMode=pod (it is "hostNetwork"): with hostNetwork the media ports are node ports, and the Service exposes rtc-udp only in pod mode` | `rtc/udproute.yaml:4:4` | Media routes only work in `pod` mode | [Matrix RTC with LiveKit](./rtc.md) |
| A media route whose port is unset | `rtc.livekit.gateway.udpRoute needs rtc.livekit.config.rtc.udp_port: the Service exposes no rtc-udp port without it` (the TCP route says `tcp_port` / `rtc-tcp`) | `rtc/udproute.yaml:8:4`, `rtc/tcproute.yaml:8:4` | The target port has to exist on the Service | [Matrix RTC with LiveKit](./rtc.md) |
| `rtc.livekit.networkMode: pod` without `config.rtc.udp_port` (even when you never touched `config.rtc`) | `rtc.livekit.networkMode=pod needs rtc.livekit.config.rtc.udp_port: a Kubernetes Service cannot forward rtc.livekit.config.rtc.port_range_start/end, so media would have no path to the pod (use a single udp_port, or networkMode=hostNetwork)` | `rtc/livekit-service.yaml:15:8` | Set a single `udp_port`; the default range `50100`/`50200` is present and triggers the guard | [Matrix RTC with LiveKit](./rtc.md) |
| `config.rtc.udp_port: "7882-7892"` (a range) | `rtc.livekit.config.rtc.udp_port: a Kubernetes Service cannot expose a UDP port range; set a single port (e.g. 7882) or use rtc.livekit.networkMode=hostNetwork` | `rtc/livekit-service.yaml:12:8` | One port per Service entry | [Matrix RTC with LiveKit](./rtc.md) |
| A cluster below 1.31, any chart install | `chart requires kubeVersion: >=1.31.0-0 which is incompatible with Kubernetes v1.30.0` | `Chart.yaml` | The gate fires before rendering; use a supported cluster | [Installing the chart](./installation.md) |
| `backup.scheduled: true` with `backup.enabled: false` | `backup.scheduled needs backup.enabled: the sidecar mounts the crontab ConfigMap, which only the backups-enabled render creates` | `tuwunnel/statefulset.yaml:37:4` | Enable the pair together; the SIGUSR2 job would run nothing without the backups render | [Backups and restore](./backups.md) |

The 13 schema fixtures live in `../charts/tuwunel/ci/invalid/` and the 5 guard fixtures in `../charts/tuwunel/ci/invalid-render/`. Only the guard fixtures carry an `# expect-error:` comment naming the message their render must report - the `schema` job extracts that substring and fails the fixture if the output does not contain it. The schema fixtures carry no such comment: the job only requires the render to be refused with `schema` in the message.

## The server exits at startup

A values change rolls the pod through the `checksum/config` annotation, so a bad configuration appears as a freshly created pod whose container exits non-zero and loops in CrashLoopBackOff. The server's message is on that container's own log:

```console
$ kubectl logs <fullname>-0 -c tuwunel --previous
```

| Log line (verbatim where quoted) | Cause | Check | Fix | Owner |
| --- | --- | --- | --- | --- |
| `invalid type: found string "false", expected a boolean for key "global.allow_federation"` | A TOML string where a boolean belongs. The schema pins only `allow_federation` and `allow_registration`, so every other boolean is the server's to reject | Render the ConfigMap and read the key | Unquote the value | [Configuring the server](./configuration.md) |
| `invalid type: found string "Authentik", expected struct IdentityProvider for key "global.identity_provider.brand"` | An array of tables (`[[global.<key>]]`) written as a YAML mapping, which renders as one table | Same class of message appears as `invalid type: found string, expected struct …` | Make it a YAML list | [Configuring the server](./configuration.md) |
| `Registration token was specified but is empty ("")` followed by `There was a problem with the 'registration_token' directive in your configuration` | The `${VAR}` placeholder expanded to empty because the Secret or key does not exist | The ConfigMap read (`kubectl get configmap <fullname>-configmap -o jsonpath='{.data.config\.toml}'`) shows the unresolved `${REGISTRATION_TOKEN}`; compare it with the `envFromSecret` key that must define it - the server is down, so `!admin server show-config` is not available | Create the secret/key, or drop the key | [Configuring the server](./configuration.md) |
| `Failed to bind 192.0.2.1:8080: Cannot assign requested address (os error 99)` followed by `There was a problem with the 'address' directive in your configuration` | `config.global.address` names an address the pod cannot bind | Compare with the rendered `TUWUNEL_ADDRESS` | Keep `::` on dual-stack pod networks, `0.0.0.0` on IPv4-only ones | [Configuring the server](./configuration.md) |
| `unknown variant …, expected one of …` | `ip_source` passed through `config` with a value the schema did not see | `config.global.ip_source` in the ConfigMap | Use one of the eight accepted sources | [Configuring the server](./configuration.md) |
| Startup fails with `EAGAIN` | Upstream's `db_pool_max_workers` default of 2048 exceeds the pod's task limit on a many-core node | `nproc` on the node vs the container's CPU limit | Set `config.global.db_pool_max_workers` to roughly the CPU limit (for example 64) | [Configuring the server](./configuration.md) |
| The server refuses to start *inside* a storage provider | S3 credentials are envsubst placeholders; a missing variable expands to empty and the render still succeeds, so with the provider's `startup_check` on the failure lands at startup | The ConfigMap read for the provider block's unresolved `${VAR}` placeholders, and the `envFromSecret` entry behind each one | Point `envFromSecret` at the real key | [Storage and media](./storage-and-media.md) |
| No create-permission error, database never appears | `config.global.database_path` moved outside `/data`. Nothing validates that key against the mount, and with `readOnlyRootFilesystem: true` only `/data`, `/tmp` and the config volume are writable | The rendered `TUWUNEL_DATABASE_PATH` vs the volumes | Keep the database under `/data`, or mount what you point it at | [Storage and media](./storage-and-media.md) |

## The pod never becomes Ready

| Symptom | Cause | Check | Fix | Owner |
| --- | --- | --- | --- | --- |
| Startup probe fails forever, `TUWUNEL_*` seems ignored | An image older than tuwunel v1.9.0: it does not read the `TUWUNEL_` prefix and does not implement `tuwunel --health-check`, so nothing the chart sets applies and the probe kills the container | The rendered image tag vs `image.tag` | Move to v1.9.0 or newer | [Installing the chart](./installation.md) |
| Pod killed during the first start after an upgrade | The one-time database migration exceeded the startup budget: 10s × 180 = 30 minutes (`probes.startup`). A breach restarts the container; the migration resumes from the last recorded step, not from the beginning | `kubectl describe pod` shows the startup probe failure; logs show the migration | Raise `probes.startup.failureThreshold`, and keep `terminationGracePeriodSeconds` at 1800 | [Day-2 operations](./operations.md) |
| Readiness flaps during a long migration | `probes.startup.enabled: false` lets the readiness probe be the one that reports a migration - the startup probe is the only budget that covers it | The rendered `startupProbe` | Re-enable the startup probe | [Day-2 operations](./operations.md) |
| Pod `Pending`, PVC `Pending` | `persistence.data.storageClass: "-"` renders `storageClassName: ""` (bind a pre-created PV only) and leaves the claim unbound on a cluster with a default provisioner; a non-existent `existingClaim` mounts a claim the chart never creates | `kubectl get pvc -l app.kubernetes.io/instance=my-release` | Use `""` for the cluster default, or provide the PV/claim | [Storage and media](./storage-and-media.md) |
| Pod `Pending` with no storage error | Nothing is pinned by default (`nodeSelector {}`, `tolerations []`, `affinity {}`, no `priorityClassName`), so the constraint is the cluster's, not the chart's; requests are 50m/128Mi | `kubectl describe pod` events | Set scheduling values or free capacity | [Day-2 operations](./operations.md) |
| Init container `Init:0/1` on an arm64 cluster; no application-level message | `initContainer.image` is `dibi/envsubst:1`, published for linux/amd64 only, while the tuwunel image itself is multi-arch. The same image is the RTC pods' init container | `kubectl describe pod` shows the platform mismatch / pull failure | Point `initContainer.image` at a multi-arch or mirrored equivalent, or pin the pod to an amd64 node | [Installing the chart](./installation.md) |
| `ImagePullBackOff` on the RTC JWT/LiveKit Deployments or the helm-test pod, while the homeserver pulls fine | `imagePullSecrets` is rendered only on the homeserver StatefulSet, despite the values comment saying "every pod the chart creates" | `kubectl get deployment -o yaml` for the missing `imagePullSecrets` | Use node-level credentials or a mirrored public image | [Secrets and hardening](./security.md) |
| Pod `Ready` but every federation request is refused, and hand-written health checks fail the same way | `allow_federation` defaults to `false`, so `/_matrix/federation/*` and `/_matrix/key/*` answer 403 - this is the historical cause of the chart's own false NotReady (readiness probed `/_matrix/federation/v1/version` before 1.2.0) | `curl` the federation version path | Enable federation, or use a path that is not federation-gated | [Federation and delegation](./federation.md) |
| Pod `Ready`, `helm test` fails | The hook pod fetches `http://<fullname>.<namespace>.svc:<service.port>/_tuwunel/server_version`; a non-2xx answer or a DNS failure makes it exit non-zero | `helm test my-release --logs`, or `kubectl logs my-release-tuwunel-test-connection` - the pod is left behind on purpose (`before-hook-creation` delete policy) | Fix the Service/port path | [Day-2 operations](./operations.md) |

> **Tip:** `probes.readiness.enabled`/`probes.liveness.enabled: false` is the documented escape hatch for an image or tag that does not implement `tuwunel --health-check` - not a fix for a slow migration.

## Exposure and federation

### Delegation narrowed the server-name host

Setting `config.global.well_known.server` switches the Ingress into its delegated layout: on the `server_name` host only `/.well-known/matrix*` and `/_matrix*` are routed, and every other path (`/_tuwunel/server_version`, the RTC control paths `/get_token`, `/sfu/get`, `/healthz`, `/delegate_delayed_leave`, `/sfu_webhook`, admin paths) matches no rule. Setting only `well_known.client` changes nothing in the rendered Ingress or HTTPRoute. A delegated domain equal to `server_name` additionally renders a duplicated TLS host entry and two rules for the same host, the first one being the narrowed delegated rule. The Gateway route describes the same host differently - one catch-all with all hostnames - so comparing the two manifests during a cutover shows paths that are in fact covered. See [Federation and delegation](./federation.md).

### Federation disabled

`allow_federation: false` is the chart default, and the whole `/_matrix/federation/*` and `/_matrix/key/*` surface answers 403 - including `/_matrix/federation/v1/version`, which is the path a hand-written health check usually probes. The well-known endpoints are registered regardless, so a federation-disabled server still advertises `m.server` and peers may cache that answer (the specification recommends ~24h) before you enable federation. The sibling default is `allow_registration: false`, and a registration attempt against a fresh install is answered `403 M_FORBIDDEN: Registration has been disabled.` - the closed registration surface, not a broken client; [Creating the first account](./installation.md#creating-the-first-account) is the path that opens it. Nothing in the chart opens an 8448 listener: `service.port` is the only port on the pod, and every reachability question is DNS/TLS/ingress work. See [Federation and delegation](./federation.md).

### Empty well-known answers

| Symptom | Cause | Fix | Owner |
| --- | --- | --- | --- |
| `/.well-known/matrix/client` and `/.well-known/matrix/server` both 404 | Both documents 404 unless their keys are set, and even the empty `[global.well_known]` table the chart renders counts as unset | Set `config.global.well_known.client` / `.server` (they have opposite shapes: a portless HTTPS URL, and a bare `host:port`) | [Federation and delegation](./federation.md) |
| `/…/rtc/transports` returns an empty `rtc_transports` list on an RTC-enabled install | `rtc.enabled` injects `well_known.livekit_url` only, never `well_known.client` | Also set `well_known.client`; if `livekit_url` itself is missing see [RTC media](#rtc-media) | [Matrix RTC with LiveKit](./rtc.md) |
| A `well_known.server` written as a URL becomes a crash-loop instead of a Helm error | The chart validates neither `well_known` key, and `server` has to be a bare `host:port` - a URL fails the server's config deserialization at startup | Fix the value; the deserialization message is in `kubectl logs … -c tuwunel` | [Federation and delegation](./federation.md) |
| A `well_known.client` with a port: the install starts, the published document is non-conformant | The same absent validation, without the failure - `client` accepts the value and the server serves it verbatim as `m.homeserver.base_url` | Write a portless HTTPS URL; nothing in the chart or the server refuses the port | [Federation and delegation](./federation.md) |

### Wrong Host

The chart adds no host validation of its own: routing is per-host (Ingress rules and HTTPRoute hostnames built from `server_name`, the delegated domain and `extraHosts`/`gateway.hostnames`). A request whose host matches no rule is not routed to the homeserver at all. For Gateway API, `gateway.hostnames` entries only take effect if the Gateway listener also serves those hostnames - hostname and TLS binding belong to the listener, which the chart does not create. See [Exposing the homeserver with Gateway API](./gateway-api.md).

### Client IP and ip_source

With a header-based `config.global.ip_source` and a request that lacks that header, requests needing the client IP fail - verified on v1.9.2 as `500 M_UNKNOWN` / `Can't extract client IP from configured ip_source` (checked with `POST /_matrix/client/v3/register` and `/_matrix/client/v3/login`), while paths that do not need it (`/_tuwunel/server_version`, `/_matrix/client/versions`) still answer 200. That asymmetry is what makes it look unrelated. Startup logs the warning:

```text
ip_source is set to RightmostXForwardedFor, a header-based source. Ensure a trusted reverse proxy populates this header for every request; otherwise clients can spoof their IP address.
```

Unset `ip_source` means `connect_info`: behind an ingress every client looks like the proxy, and rate limiting, invites and moderation all act on that one address. `ip_source_trusted_subnets` (put the in-cluster pod CIDR there) bypasses `ip_source` entirely for probes and in-cluster calls, and changing it needs a restart. See [Configuring the server](./configuration.md) and [Secrets and hardening](./security.md).

## RTC media

Start from the checklist on [Matrix RTC with LiveKit](./rtc.md), then use this table; the components are selected with `app.kubernetes.io/component=rtc-jwt`, `rtc-livekit` and `rtc-ingress`, and a wrong selector returns an empty list that reads like "the resources were never created".

| Symptom | Cause | Check | Fix | Owner |
| --- | --- | --- | --- | --- |
| Clients can signal but no audio/video in `pod` mode | `rtc.livekit.service.type: ClusterIP` (the default) plus an RTC Ingress only: HTTP works, media has no path from outside | The rendered LiveKit Service type and the presence of a media route | `NodePort`/`LoadBalancer` with `externalTrafficPolicy: Local`, or the Gateway UDP/TCP media routes | [Matrix RTC with LiveKit](./rtc.md) |
| `rtc_transports` is empty while the `/.well-known/matrix/client` document looks right | `config.global.well_known.livekit_url` is missing from the rendered `config.toml` - not a LiveKit outage. The chart injects it only when `rtc.enabled` and `rtc.domain` are set and neither `livekit_url` nor `rtc_transports` is present | `curl https://<server_name>/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` | Set `rtc.domain` (or `livekit_url`), and remember the derived values are defaults - an explicit wrong value always wins | [Matrix RTC with LiveKit](./rtc.md) |
| Media works in `hostNetwork` but the Service looks wrong | In `hostNetwork` the LiveKit Service is still rendered (ClusterIP, http 7880/tcp and rtc-tcp 7881/tcp) but carries no `rtc-udp` port - media goes straight to the node IP on `50100-50200/udp`. A UDP range is a node-port concept, which is why pod mode refuses it | `kubectl get svc -l app.kubernetes.io/component=rtc-livekit` | Open the node ports, or switch to `pod` mode with a single `udp_port` | [Matrix RTC with LiveKit](./rtc.md) |
| "Media does not flow in pod mode" although the ports look right | The rendered `livekit.yaml` still contains `port_range_start`/`port_range_end` next to `udp_port`; only the Deployment and Service ports collapse to the single port | `kubectl get configmap <fullname>-livekit -o yaml` | Align or remove the range and rely on the candidate addressing | [Matrix RTC with LiveKit](./rtc.md) |
| No media at all, `rtc.domain` resolves | In `hostNetwork` the domain has to resolve to the node IP that runs LiveKit; in `pod` mode to the Service address. The chart publishes no DNS | `dig` plus the mode in use | Fix the record for the mode you run | [Matrix RTC with LiveKit](./rtc.md) |
| Clients cannot reach media despite correct routes | `UDPRoute`/`TCPRoute` only exist at `gateway.networking.k8s.io/v1` from Gateway API v1.6 (earlier bundles serve them at `v1alpha2`), so on an older bundle the API server refuses the media routes — `no matches for kind "UDPRoute" in version "gateway.networking.k8s.io/v1"` — and the whole release fails, not just the media path | `kubectl get crd udproutes.gateway.networking.k8s.io` (and its served versions) | Upgrade the Gateway API bundle, or disable `rtc.livekit.gateway.udpRoute`/`tcpRoute` | [Exposing the homeserver with Gateway API](./gateway-api.md) |
| A `LIVEKIT_*` variable added to `rtc.livekit.env` has no effect, silently | That block is rendered on the `config-processor` init container only; the variables reach LiveKit solely through `${VAR}` substitution inside `livekit.yaml`, and an undefined placeholder becomes an empty string | The substituted `livekit.yaml` in the LiveKit pod | Reference the variable from the LiveKit config, or use `rtc.livekit.envFromSecret` as the chart expects | [Matrix RTC with LiveKit](./rtc.md) |
| `rtc.jwt.env.LIVEKIT_JWT_BIND` changed, but every backend still targets 8080 | The bind is overridable while the container port, the Service port, the probe, the Ingress/HTTPRoute backend and the derived webhook URL are all hardcoded to 8080 (five places) - the service would listen where nothing routes | `kubectl get svc <fullname>-jwt -o yaml` | Leave the bind at `:8080`, or change the template together with it | [Matrix RTC with LiveKit](./rtc.md) |
| TLS on the RTC host never becomes valid | `rtc.ingress.tls: true` with an empty `tlsSecretName` points at `<fullname>-rtc-tls`, a secret the chart never creates | `kubectl get secret` | Let cert-manager issue it, or pre-create it | [Secrets and hardening](./security.md) |

Route preconditions (`parentRefs`, pod-mode media, a single `udp_port`) are refused at render time - see [Rejected at render time](#rejected-at-render-time-template-guards) for the exact messages.

## Storage and backups

| Symptom | Cause | Check | Fix | Owner |
| --- | --- | --- | --- | --- |
| Writes start failing with the volume apparently fine | The chart has no storage telemetry: no metrics endpoint, ServiceMonitor/PodMonitor or PVC-usage surface. Retention (`database_backups_to_keep`) bounds the number of backups, not their size, and `backup.size` is a one-time request | Cluster-level PVC/kubelet metrics | Grow the claim or prune; plan capacity outside the chart | [Storage and media](./storage-and-media.md) |
| No backup appears although the schedule is armed | The crontab's job is `pkill -USR2 -x tuwunel`, an exact `argv[0]` match on the bare name - a wrapper image whose `argv[0]` is a path matches nothing, and crond reports no error. The signal reaches the server only because the chart sets `shareProcessNamespace`, and `admin_signal_execute` is injected only for the `backup.enabled` + `backup.scheduled` pair; a mismatch between those two is refused at render time, not at runtime | `<backup.path>/meta/<id>` and the server's `Created database backup…` line; the sidecar's own log stays empty by design | Keep the process name `tuwunel`, or take the backup from the admin room / `kubectl exec <fullname>-0 -c backup -- pkill -USR2 -x tuwunel` | [Backups and restore](./backups.md) |
| `kubectl logs <pod> -c backup` is empty | Busybox crond logs through syslog, which no daemon in the pod serves - and the chart passes a level (`-l 8`), not a sink - so the sidecar's log is empty whether or not the job ran | The server container's `Created database backup…` line and the repository directory | Trust the repository, not the sidecar log | [Backups and restore](./backups.md) |
| The server writes to a path with no volume behind it | `config.global.database_backup_path` set by hand disables the chart's injection of that key, so `backup.path` (the mount) and the server's write path can drift apart with no render error | The ConfigMap read: a `database_backup_path` line there means your own value displaced the chart's injection; `!admin server show-config` confirms the path the server actually writes to | Leave the key to the chart, or align it with `backup.path` | [Storage and media](./storage-and-media.md) |
| A volume mount you added has no effect | `extraVolumeMounts` are appended after the chart's own mounts and cannot replace them: reusing a chart volume name (`data`, `config-template`, `config`, `tmp`, `backup`) adds a second mount instead of moving the original | The rendered container mounts | Mount your volume at a different path, or mount the chart's volume where you need it | [Storage and media](./storage-and-media.md) |
| "The data is here" but the server reads elsewhere | The data volume is mounted at `/data` with `subPath: data`, so the database lives at `<pvc-root>/data/db` (default). A claim supplied through `persistence.data.existingClaim` renders no PVC object at all, so `pvcAnnotations` cannot apply to it | `ls` the claim root, not the server's view | Look one level deeper | [Storage and media](./storage-and-media.md) |
| An S3-backed server will not start, or the first upload fails | Credentials are `${VAR}` placeholders: a missing or misnamed secret key expands to empty while the render still succeeds. With the provider's `startup_check` on, startup fails; with it off, the failure moves to the first upload | The ConfigMap read for the unresolved `${VAR}` placeholders; `!admin server show-config` for what they expanded to when the server does run | Fix the `envFromSecret` reference | [Storage and media](./storage-and-media.md) |
| A restore appears to hang or repeats on its own | The restore is driven by the release's `args`: the container runs `--restore-backup … --execute`, exits, and the kubelet then restarts it because no `restartPolicy` is set, so the restore loops until the args are removed. `kubectl scale` is not durable either - the StatefulSet template hardcodes `replicas: 1` and the next upgrade re-asserts it | `kubectl get statefulset <fullname> -o jsonpath='{.spec.template.spec.containers[0].args}'`; logs show `Restoring database backup backup_id=…` then `Restored database backup` | Scale to 0, run the restore with the args, then drop the args again | [Backups and restore](./backups.md) |
| A backup volume outlives what it backs up | `persistence.data.enabled: false` degrades the data volume to an emptyDir while the mount stays at `/data`, so database and local media vanish on pod recreation - a supported, CI-exercised mode with no warning | The rendered volume type | Keep persistence on | [Storage and media](./storage-and-media.md) |

## Upgrades

| Symptom | Cause | Check | Fix | Owner |
| --- | --- | --- | --- | --- |
| The database is half-migrated after a rollout | The one-time migration runs before the server listens, and a SIGKILL in the middle damages the database rather than merely delaying it - that is what the 1800s `terminationGracePeriodSeconds` and the 30-minute startup probe protect against. Forcing a pod delete, draining the node or shortening the grace period is what breaks it | Pod logs and `terminationGracePeriodSeconds` in the rendered manifest | Let the pod terminate within the grace period | [Upgrading](./upgrade.md) |
| An upgrade looks stuck for many minutes | The pod is replaced, not rolled with surge (one replica, no `updateStrategy` override), and a replacement pod can take up to the 1800s grace period to be deleted when the process does not exit promptly | `kubectl get pod -w`, `kubectl describe pod` for the termination reason | Wait, or shorten the grace period deliberately | [Upgrading](./upgrade.md) |
| A pre-v1.9.0 image renders fine and then never becomes Ready | The chart's contract is `TUWUNEL_*` plus `tuwunel --health-check`; an older image ignores both, so nothing you set applies | `kubectl logs`, `kubectl describe pod` probe failures | Upgrade the image tag first | [Upgrading](./upgrade.md) |
| The server ignores the port you set through a legacy variable | Upstream precedence is `CONDUIT_` < `CONDUWUIT_` < `TUWUNEL_`, and the chart always renders `TUWUNEL_PORT` from `service.port`; with both set, v1.9.2 logs `Listening on ["tcp:[::]:8080"]` | The rendered env and the startup log | Use `service.port` | [Upgrading](./upgrade.md) |
| A values file from 1.x fails the upgrade instead of being ignored | Values that used to be accepted and ignored are refused now: quoted booleans, `rtc.livekit.networkMode: bridge`, `rtc.ingress.path`/`extraHosts`, `config.global.port`/`server_name` duplicating the top-level keys | The error shape tells you which layer refused it - schema, guard or server | Fix the values; the 2.0.0 list doubles as the symptom catalogue | [chart README § Upgrading to 2.0.0](../charts/tuwunel/README.md#upgrading-to-200) |
| The cluster cannot take the chart at all | `Chart.yaml` requires `>=1.31.0-0` and Helm enforces it at install/template time | `helm template` fails before producing a manifest | Use a supported cluster | [Installing the chart](./installation.md) |
| A rotation or a values change does not take effect | Editing `config`/`env`/`envRaw`/`envFromSecret` rolls the pod through the `checksum/config` annotation, but rotating a Secret's *contents* does not - the annotation hashes the references, not the data | `helm get values`, and the pod's start time | Restart the pod after rotating a secret | [Day-2 operations](./operations.md) |

Rollback expectations: `helm rollback` restores the previous ConfigMap and checksum annotation, so the pod comes back with the previous values. The database migration is performed by the server at start, not by a Helm hook, so a rollback does not undo anything it already applied - treat a chart rollback as a configuration rollback only, and check upstream's release notes before rolling an image back. What `checksum/config` does and does not cover is described in [How the chart renders a running server](./internals.md).

## Collecting diagnostics

Attach this bundle to an issue; the repository's template asks for exactly these fields.

```console
$ helm version --short
$ helm list -n <namespace>
$ kubectl version
$ helm get values my-release -n <namespace>          # strip secrets before pasting
$ helm template my-release charts/tuwunel -f values.yaml > rendered.yaml
$ kubectl describe pod my-release-tuwunel-0 -n <namespace>
$ kubectl logs my-release-tuwunel-0 -n <namespace> -c tuwunel --previous
$ kubectl logs my-release-tuwunel-0 -n <namespace> -c config-processor
$ kubectl get pvc -l app.kubernetes.io/instance=my-release -n <namespace>
$ kubectl get events -n <namespace> --sort-by=.lastTimestamp
$ kubectl get configmap my-release-tuwunel-configmap -n <namespace> -o jsonpath='{.data.config\.toml}'
```

Notes that make the difference between a usable and an unusable report:

- The ConfigMap read above answers "what did the chart render": it holds the pre-substitution template, with `${VAR}` placeholders intact. The file the server reads is `/tmp/config/config.toml` (`TUWUNEL_CONFIG`), produced from that template by the `config-processor` init container with envsubst - and nothing in the image can print it back, because the server container holds `/usr/bin/tuwunel` and no shell or coreutils, so `kubectl exec … -c tuwunel -- cat …` fails. The effective configuration - placeholders and `TUWUNEL_*` variables resolved - is the admin room's answer instead: `!admin server show-config`. That needs a running server, so when the container exits at startup the ConfigMap read plus the secret it points at is what you have. `-c config-processor` logs are only interesting when the init container itself fails: its command redirects envsubst's output into the file, so a successful run prints nothing.
- With RTC enabled add `kubectl logs -l app.kubernetes.io/component=rtc-jwt`, the same for `rtc-livekit`, and the LiveKit ConfigMap.
- If `helm test` failed, `helm test my-release --logs` prints the wget failure, and the `<fullname>-test-connection` pod is left behind for `kubectl logs`.
- The template's scope is chart behaviour - rendering, values, probes, ingress and the optional RTC components; problems inside the homeserver itself belong upstream, and [the bug report template](../.github/ISSUE_TEMPLATE/bug_report.yml) says so. Locally, `hack/runtime-check.sh` runs the same scenarios against the real image and reproduces the class of failure no schema can see (see [Development and releases](./development.md)).
