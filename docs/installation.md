# Installing the chart

> Install the tuwunel Helm chart into a Kubernetes cluster, watch the pod come up, and verify that the homeserver actually answers.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Add the chart repository](#add-the-chart-repository)
- [What the chart creates](#what-the-chart-creates)
- [A minimal install](#a-minimal-install)
- [Watching the first start](#watching-the-first-start)
- [Verifying the deployment](#verifying-the-deployment)
- [Creating the first account](#creating-the-first-account)
- [Uninstalling](#uninstalling)
- [Next steps](#next-steps)

---

## Prerequisites

| You need | Details |
|---|---|
| Kubernetes | Chart version 2.0.0 declares `kubeVersion: '>=1.31.0-0'` in `Chart.yaml`; Helm refuses anything older. Rendered manifests are CI-checked against Kubernetes 1.31.0 and 1.37.0. |
| Helm | The repository documents no minimum Helm version — its CI pins Helm 4.3.0. The chart needs plain `helm install`/`test`/`uninstall` and no plugins or post-renderers. |
| A `server_name` | The Matrix domain clients and user IDs use. It is a required value: the schema requires the key and a non-empty string, and the StatefulSet template carries a second `required()` guard. |
| A PersistentVolume provisioner | The default install creates a 4Gi `ReadWriteOnce` claim for `/data`. A cluster with a default StorageClass needs nothing; otherwise set `persistence.data.storageClass` yourself, or pre-create a PV and use the `"-"` sentinel. |
| tuwunel v1.9.0 or newer | The chart configures the server through the `TUWUNEL_*` environment contract and probes it with `tuwunel --health-check`, both introduced in v1.9.0. The chart pins `ghcr.io/matrix-construct/tuwunel:v1.9.2`. |
| An exposure layer (optional) | Nothing is reachable outside the cluster after a bare install. If you want clients to connect, you also need an ingress controller or a Gateway you run — the chart never creates TLS material, an IngressClass, a Gateway or a GatewayClass. |

Below the version floor Helm fails before rendering anything:

```text
Error: chart requires kubeVersion: >=1.31.0-0 which is incompatible with Kubernetes v1.30.0
```

Failing to set a usable `server_name` is refused just as early. Setting it to an empty string, or dropping the key through a values file:

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/server_name': minLength: got 0, want 1
```

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '': missing property 'server_name'
```

> **Warning:** The default `server_name` is the placeholder `yourdomain.com` (`charts/tuwunel/values.yaml`). An install that keeps it renders, starts and serves — under the wrong homeserver identity. The value is recorded in the database behind every user ID, so changing it later is a migration, not a config edit; delegation can move the DNS name but not the identity. See [Federation and delegation](./federation.md).

> **Warning:** On an arm64 cluster the home server pod never starts: the init container image `dibi/envsubst:1` is published for `linux/amd64` only, even though the tuwunel image is multi-arch. Point `initContainer.image` at a multi-arch or mirrored equivalent, or pin the pod with `nodeSelector`. The busybox image the chart uses for the test pod and the backup sidecar is multi-arch and is not affected.

> **Note:** `imagePullSecrets` is applied to the tuwunel StatefulSet only — not to the test pod or the optional RTC pods, despite the values comment saying otherwise. A private registry mirror needs those pods handled separately, or the registry left reachable for them.

The complete value reference lives in the chart README: [chart README § Core Configuration](../charts/tuwunel/README.md#core-configuration).

## Add the chart repository

```console
$ helm repo add tuwunel https://arsolitt.github.io/tuwunel-helm
$ helm repo update
```

`helm repo update` is what makes a newly published chart version visible to `helm install`, so run it again after a release. Confirm the chart is reachable before installing:

```console
$ helm search repo tuwunel/tuwunel
```

If you would rather install exactly the chart you reviewed, point Helm at the chart directory of a checkout and skip the repository steps:

```console
$ helm install my-release charts/tuwunel -f values.yaml
```

## What the chart creates

A default install of release `my-release` in namespace `default` renders exactly these objects (verified with `helm template my-release charts/tuwunel`):

| Kind | Name | Present when |
|---|---|---|
| ConfigMap | `my-release-tuwunel-configmap` | always — holds the `config.toml` template |
| PersistentVolumeClaim | `my-release-tuwunel-data` | `persistence.data.enabled: true` and `persistence.data.existingClaim` unset |
| Service (ClusterIP, `clusterIP: None` — headless) | `my-release-tuwunel` | always |
| StatefulSet | `my-release-tuwunel` | always |
| Pod (hook) | `my-release-tuwunel-test-connection` | always rendered, but only created when you run `helm test` |

Objects that only appear when the matching block is enabled:

| Kind | Name | Enabled by |
|---|---|---|
| Ingress | `<fullname>` | `ingress.enabled: true` and a non-empty `ingress.class` (the render fails without one) |
| HTTPRoute | `<fullname>` | `gateway.enabled: true` |
| PersistentVolumeClaim | `<fullname>-backup` | `backup.enabled: true` |
| ConfigMap | `<fullname>-backup-crontabs` | `backup.scheduled: true` |
| Service + Deployment | `<fullname>-jwt` | `rtc.enabled: true` (see [Matrix RTC with LiveKit](./rtc.md)) |
| Service + Deployment + ConfigMap | `<fullname>-livekit` | `rtc.enabled: true` |
| HTTPRoute | `<fullname>-rtc` | `rtc.enabled` and `rtc.gateway.enabled` |
| Ingress | `<fullname>-rtc` | `rtc.enabled` and `rtc.ingress.enabled` |
| UDPRoute / TCPRoute | `<fullname>-livekit-udp` / `<fullname>-livekit-tcp` | `rtc.livekit.networkMode: pod` with `rtc.livekit.gateway.udpRoute` / `rtc.livekit.gateway.tcpRoute` |

There is deliberately no other controller surface: no CronJob (scheduled backups are a sidecar container in the same pod driven by the crontab ConfigMap), no operator, no CRDs, and no Gateway/GatewayClass. The StatefulSet always runs exactly one replica — `spec.replicas: 1` is hardcoded and there is no `replicaCount` value.

`<fullname>` is `<release>-tuwunel` unless the release name already contains `tuwunel` or you set `nameOverride`/`fullnameOverride`. Almost every object carries `app.kubernetes.io/name=tuwunel`, `app.kubernetes.io/instance=<release>`, `app.kubernetes.io/managed-by=Helm` and `helm.sh/chart=tuwunel-2.0.0`, plus an `app.kubernetes.io/component`: `tuwunel` on the StatefulSet and the pod template, `tuwunel-backup` on the backup claim and the crontab ConfigMap, `tuwunel-test` on the hook pod. The `<fullname>-configmap` ConfigMap is the exception — it carries no labels at all — and `extraLabels` adds your own wherever the chart's label helper is used.

How those objects and the configuration flow together is described in [How the chart renders a running server](./internals.md).

## A minimal install

The only value you have to set is `server_name`. Create `values.yaml`:

```yaml
server_name: matrix.example.org
```

`server_name` becomes the `TUWUNEL_SERVER_NAME` environment variable and the identity in every user ID (`@steve:matrix.example.org`). Everything else falls back to the chart defaults.

In practice you normally also name your storage class, because the default `persistence.data.storageClass: ""` leaves the claim to the cluster's default provisioner:

```yaml
server_name: matrix.example.org

persistence:
  data:
    storageClass: local-path
```

Install it:

```console
$ helm install my-release -f values.yaml tuwunel/tuwunel
```

To put the release in its own namespace, add the usual Helm flags:

```console
$ helm install my-release -f values.yaml tuwunel/tuwunel --namespace matrix --create-namespace
```

The root README's one-liner form works too, but the release name is generated for you, which you then need in every later `helm test`/`helm uninstall`:

```console
$ helm install --set server_name=matrix.example.org tuwunel/tuwunel
```

Values that matter for a first install, with their defaults:

| Value | Default | What it changes |
|---|---|---|
| `server_name` | `yourdomain.com` (placeholder) | Matrix domain; rendered into `TUWUNEL_SERVER_NAME`; must not stay at the placeholder |
| `persistence.data.size` | `4Gi` | Size of the `<fullname>-data` claim |
| `persistence.data.accessMode` | `ReadWriteOnce` | Access mode of that claim |
| `persistence.data.storageClass` | `""` | `""`/unset → no `storageClassName` (cluster default); `"-"` → `storageClassName: ""` to bind a pre-created PV by hand; anything else → that class. `"-"` is a sentinel, not a class name — mistyping a class leaves the claim unbound. |
| `service.port` | `8080` | The chart's single port knob: Service port, container port and `TUWUNEL_PORT` |
| `image.tag` | `v1.9.2` | Server image tag; must be v1.9.0 or newer |
| `config.global.address` | `"::"` | Address the server binds; use `0.0.0.0` only in a pod network without a usable IPv6 stack |
| `config.global.allow_registration` | `false` | Registration stays closed until you turn it on (see [Creating the first account](#creating-the-first-account)) |
| `config.global.allow_federation` | `false` | Federation stays closed until you enable it (see [Federation and delegation](./federation.md)) |

Beyond those, the chart derives the server's environment contract itself — you do not set any of these:

| Variable | Derived from |
|---|---|
| `TUWUNEL_CONFIG` | fixed at `/tmp/config/config.toml` |
| `TUWUNEL_SERVER_NAME` | `server_name` |
| `TUWUNEL_DATABASE_PATH` | `/data/db` |
| `TUWUNEL_PORT` | `service.port` |
| `TUWUNEL_ADDRESS` | `config.global.address` |
| `TOKIO_WORKER_THREADS`, `TUWUNEL_ROCKSDB_PARALLELISM_THREADS` | the CPU limit (default `1`) |

> **Note:** `persistence.data.enabled: false` replaces the claim with an `emptyDir` and prints no warning. The install looks healthy, but the database and local media disappear when the pod is recreated. Use it only for throwaway clusters.

## Watching the first start

The pod runs an init container before the server. Follow the whole sequence:

```console
$ kubectl get pods -l app.kubernetes.io/name=tuwunel -w
```

The pod moves `Init:0/1` → `Running` (not ready) → `Running` with `READY 1/1` once the probes pass. The init container is where the configuration is finished:

```console
$ kubectl logs -f my-release-tuwunel-0 -c config-processor
```

`config-processor` runs `envsubst < /tmp/config-template/config.toml > /tmp/config/config.toml`, so a successful run writes the file and prints nothing — an empty log is the healthy case, and a failure (a malformed template, a missing mount) is what shows up here.

The server itself:

```console
$ kubectl logs -f my-release-tuwunel-0 -c tuwunel
```

A healthy first boot ends with the listening line; the chart README quotes v1.9.2 printing:

```text
Listening on ["tcp:[::]:8080"]
```

Then the pod is ready and stays that way.

Three exec probes guard that path, all of them running `tuwunel --health-check` inside the container so they ask the running server rather than dialing a path that might answer for an unrelated reason:

| Probe | Default | Purpose |
|---|---|---|
| `probes.startup` | `enabled: true`, 10s × 180 = 30 minutes | Absorbs the one-time blocking database migration the first start after a homeserver upgrade runs before the server listens. Readiness stays out of the way until the startup probe succeeds. |
| `probes.readiness` | `enabled: true`, 10s, threshold 3 | Marks the pod ready once the server actually serves the rendered configuration |
| `probes.liveness` | `enabled: true`, 10s, threshold 3 | Restarts a server that stops answering |

`terminationGracePeriodSeconds` defaults to `1800` rather than Kubernetes' 30, for the same reason: a SIGKILL in the middle of the migration leaves the database half-migrated.

> **Warning:** A pre-v1.9.0 image renders fine and starts, but it ignores the `TUWUNEL_*` variables and never answers `tuwunel --health-check`, so the startup probe fails until the container is killed and the pod loops. If the pod never leaves `Running`, check the tag before anything else.

## Verifying the deployment

```console
$ kubectl get pods -l app.kubernetes.io/name=tuwunel
```

```console
$ kubectl get statefulset,service,pvc,configmap
```

The first command is the chart README's own first troubleshooting step. For a release in a non-default namespace add `-n <namespace>`. Expect one `my-release-tuwunel-0` pod `Running` and `1/1`, the headless Service, the `<fullname>-data` claim `Bound`, and the `<fullname>-configmap` ConfigMap.

Readiness is an exec probe, not an HTTP one: `command: ["tuwunel", "--health-check"]`. The `/_tuwunel/server_version` path still answers, but nothing probes it any more — `helm test` fetches it instead:

```console
$ helm test my-release
```

The test is a busybox pod that runs `wget -q --spider http://<fullname>.<namespace>.svc:<service.port>/_tuwunel/server_version` from inside the cluster — the one check a rendered manifest cannot make. It runs as uid/gid 65534 with a read-only root filesystem, and its delete policy is `before-hook-creation`: a successful run leaves `my-release-tuwunel-test-connection` behind in `Completed` state until the next hook creation. A failure there can be DNS or exposure rather than the server; the URL intentionally omits the cluster domain.

After a successful install Helm prints the chart's `NOTES.txt` verbatim:

```text
Tuwunel helm chart has been installed. You can access the server from within the k8s cluster using:

  my-release-tuwunel.default.svc.cluster.local:8080

WARNING:  Scaling the StatefulSet will probably cause failures and quiet data corruption.
```

The warning is not decorative: tuwunel stores its database in RocksDB, a single-writer store, so a second replica would mean two writers on one `ReadWriteOnce` volume. Scaling is also not a durable control surface — `kubectl scale` is reverted by the next `helm upgrade`.

> **Note:** A bare install is reachable only from inside the cluster. To expose it, see [Exposing the homeserver with Ingress](./ingress.md) or [Exposing the homeserver with Gateway API](./gateway-api.md); to tune the server beyond the defaults, see [Configuring the server](./configuration.md).

## Creating the first account

Registration is closed by default (`config.global.allow_registration: false`), so your first client registration attempt is answered:

```text
403 M_FORBIDDEN: Registration has been disabled.
```

To create the first user you enable registration **and** give the server a token, then turn registration back off. The chart's recipe keeps the token in a Secret and lets `envsubst` expand it:

```yaml
envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN

config:
  global:
    allow_registration: true
    registration_token: "${REGISTRATION_TOKEN}"
```

The client flow is the standard Matrix UIAA one: `POST /_matrix/client/v3/register` without a token answers `401` with `{"flows":[{"stages":["m.login.registration_token"]}], "session": "..."}`, and the same request with `"auth": {"type": "m.login.registration_token", "token": "..."}` creates the account and returns an access token. Two things this depends on:

- `envFromSecret` values are `<secret>/<key>` pairs; a value without the `/` is rejected by the schema.
- A missing or typo'd variable expands to `registration_token = ""`, and v1.9.2 then refuses to start with `Registration token was specified but is empty ("")`. A broken secret is loud, not an open server.

> **Danger:** Leaving `config.global.allow_registration: true` with a token (or worse, with the extra opt-in that opens tokenless registration) turns your homeserver into an open registration endpoint. Disable it again once the accounts you need exist, and read [Secrets and hardening](./security.md) for the rest of the credential story — including `registration_shared_secret`, which is equivalent to an admin access token.

## Uninstalling

```console
$ helm uninstall my-release
```

The command removes every Kubernetes component the chart created and deletes the release — including the `my-release-tuwunel-data` PersistentVolumeClaim, because the chart sets no `helm.sh/resource-policy: keep` anywhere.

> **Danger:** `helm uninstall` destroys the homeserver database. Whether the underlying PersistentVolume outlives its claim depends on the volume's reclaim policy, not on the chart — on a `Delete`-policy storage class the data is gone with it. Take a backup first (see [Backups and restore](./backups.md)).

Because all resource names derive from the release name, re-installing under a different name creates a second, separate deployment rather than renaming the first: the new StatefulSet starts from a fresh PVC while the old volumes linger.

## Next steps

- [Configuring the server](./configuration.md) — `config.toml` pass-through, env vars and secrets
- [Exposing the homeserver with Ingress](./ingress.md) — the usual next step after a bare install
- [Exposing the homeserver with Gateway API](./gateway-api.md) — the HTTPRoute alternative
- [Federation and delegation](./federation.md) — open federation and serve `/.well-known/matrix/*`
- [Matrix RTC with LiveKit](./rtc.md) — Element Call support
- [Backups and restore](./backups.md) — online backups and the documented restore procedure
- [Day-2 operations](./operations.md) — probe behavior, rollouts, volume growth and recovery
