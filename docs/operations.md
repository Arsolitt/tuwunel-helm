# Day-2 operations

> What a running tuwunel release looks like from the outside: probe behaviour, the migration budget, what a values edit restarts, thread derivation, storage growth and the routine checks.

## Table of Contents

- [Health and probes](#health-and-probes)
- [The migration budget](#the-migration-budget)
- [Applying configuration changes](#applying-configuration-changes)
- [Resources and thread derivation](#resources-and-thread-derivation)
- [Storage and growth](#storage-and-growth)
- [Inspecting a running release](#inspecting-a-running-release)
- [Single-replica constraint](#single-replica-constraint)
- [Routine maintenance table](#routine-maintenance-table)

---

## Health and probes

All three probes are exec probes that ask the server process about itself, not HTTP probes against a path:

```yaml
readinessProbe:
  exec:
    command: ["tuwunel", "--health-check"]
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
  initialDelaySeconds: 0
```

The server's own `--help` describes the flag as *"Probe a running server for liveness and exit; the running server must share this configuration"*. Run against a v1.9.2 server it exits `0` with no output while the server is serving, and exits `1` with `Error: I/O error: Connection refused (os error 111)` when the configuration loads but nothing is listening.

| Probe | Period | Timeout per attempt | `failureThreshold` | Worst case before something happens |
| --- | --- | --- | --- | --- |
| `probes.startup` | 10 s | 5 s | 180 | 30 min (10 s × 180) to finish the one-time migration |
| `probes.readiness` | 10 s | 5 s | 3 | 30 s of consecutive failures, then the pod leaves the Service endpoints |
| `probes.liveness` | 10 s | 5 s | 3 | ~30 s of failures, then the container is restarted (grace period applies before SIGKILL) |

Every field is settable (`enabled`, `periodSeconds`, `timeoutSeconds`, `failureThreshold`, `initialDelaySeconds`); the defaults live in [`values.yaml`](../charts/tuwunel/values.yaml) under `probes`. The complete table is in the [chart README § Probes and database migrations](../charts/tuwunel/README.md#probes-and-database-migrations).

The exec probes replaced a path-based one. Until 2.0.0 the chart configured a single readiness probe: in 1.1.0 it was an HTTP GET of `/_matrix/federation/v1/version`, which answers `403` as soon as federation is disabled — the chart default — so the pod sat `NotReady` while the server itself ran fine. 1.2.0 moved that probe to `/_tuwunel/server_version`, and 2.0.0 made all three probes (`startup`, `readiness`, `liveness`) exec probes running `tuwunel --health-check`. `/_tuwunel/server_version` still answers 200; `helm test` is now the only thing that requests it.

Read probe state from the pod, not from the chart:

```console
$ kubectl get pod <fullname>-0                    # READY 0/1 while a probe is failing, RESTARTS for kills
$ kubectl describe pod <fullname>-0               # probe configuration, and probe failures as events
$ kubectl get events --field-selector involvedObject.name=<fullname>-0 --sort-by=.lastTimestamp
```

> **Warning:** the exec probe requires tuwunel v1.9.0 or newer. An older image still renders and starts, but it does not answer `tuwunel --health-check`, so the pod never becomes Ready. The requirement and the prerequisites are covered in [Installing the chart](./installation.md) and [Upgrading to 2.0.0](../charts/tuwunel/README.md#upgrading-to-200).

## The migration budget

The first start after a homeserver upgrade runs a one-time blocking database migration *before* the server listens. Two chart values exist purely to let it finish:

| Setting | Default | What it protects |
| --- | --- | --- |
| `probes.startup` | `10s` × `180` = 30 min | the migration window itself; the readiness probe stays out of the way meanwhile |
| `terminationGracePeriodSeconds` | `1800` | the same window against SIGKILL — Kubernetes' own default of 30 s would cut a migration off mid-write |

The startup probe, not readiness, is the one that carries the budget: while the migration runs the listener does not exist yet, so a readiness probe would fail — and be *counted* — for the whole migration, leaving the pod out of the Service endpoints for its duration. That is all a failing readiness probe does; it never restarts the container. Restarts come from the startup probe (when it exhausts its budget) and from the liveness probe — which Kubernetes holds back until the startup probe has succeeded, so nothing restarts the container while the migration is still running.

To tell a slow migration from a hung pod, read the log and the restart count:

```console
$ kubectl logs <fullname>-0 -c tuwunel --tail=50
$ kubectl get pod <fullname>-0 -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
```

Migration progress is logged under `tuwunel_service::migrations`, and the last line of a completed start is the router announcing its listener. Reproduced against v1.9.2 opening a database written by v1.5.1 (timestamps trimmed):

```text
INFO  main:start:open: tuwunel_database::engine::open: Opened database. columns=138 sequence=285 time=121.767143ms
INFO  main:start: tuwunel_service::migrations: Stamped server_name marker on upgraded database server_name=ci.example
WARN  main:start: tuwunel_service::migrations::injectivity: Discarding cached auth chains; entries from earlier releases may be truncated.
INFO  main:start: tuwunel_service::migrations::injectivity::scan: Scanning ShortID columns for duplicate values...
INFO  main:start: tuwunel_service::migrations: Loaded RocksDB database with schema version 17
INFO  tuwunel_router::serve: Listening on ["tcp:[::1]:8008", "tcp:127.0.0.1:8008"]
```

A migrating pod produces new `migrations` lines — the schema version, the injectivity scan — and keeps `restartCount` at 0; a start that got through the migration ends with the router's `Listening on [...]` line. A pod whose `restartCount` climbs has exhausted the startup probe and been restarted, and the migration resumes from the last recorded step rather than from the beginning — raise `probes.startup.failureThreshold` rather than watching it loop.

The server treats a graceful stop and a kill differently; upstream's deployment notes describe it as *"A stop request is honored between steps and every step that finished is recorded, so the migration resumes where it left off; killing the process instead can leave the database mid-write."* That is what `terminationGracePeriodSeconds: 1800` buys, and why an interrupted rollout is a [troubleshooting](./troubleshooting.md) case rather than a routine one.

> **Danger:** setting `probes.startup.enabled: false` removes the 30-minute budget. The readiness probe then counts the migration against itself (the pod drops out of the Service), and with no startup probe in front of it the liveness probe restarts the container after ~30 s of the same failures — so a large database upgrade crash-loops instead of waiting.

## Applying configuration changes

Both the rendered `config.toml` and the environment reach the server only at pod start. The StatefulSet pod template carries a `checksum/config` annotation built from two hashes — one over the rendered ConfigMap, one over `env`, `envRaw` and `envFromSecret` — so a values edit usually changes the pod template and rolls the pod.

What each kind of edit does (directly rendered and compared):

| Change | `checksum/config` | Pod template | Pod rolls? |
| --- | --- | --- | --- |
| `config.*` | first half changes | unchanged input, new hash | yes |
| `env`, `envRaw`, `envFromSecret` (the reference map) | second half changes | env list differs | yes |
| `extraEnv` | unchanged | env list differs | yes — the StatefulSet revision changes even though the annotation does not |
| Contents of a Secret referenced by `envFromSecret` | unchanged | unchanged | **no** — the old value stays live until something recreates the pod |
| `resources`, `args`, `image.tag`, `service.port`, `probes.*`, `podLabels`, `podAnnotations`, `nodeSelector`, `tolerations`, `affinity`, `priorityClassName`, `imagePullSecrets`, `extraVolumes`, `extraVolumeMounts`, `persistence.data.enabled`, `persistence.data.existingClaim`, `backup.existingClaim`, and the pod-facing `backup.*` keys (`enabled`, `path`, `keep`, `scheduled`, `command`, `sidecar.resources`) | unchanged (unless the key also lands in `config.toml`, which the backup keys do) | differs | yes |
| `ingress.*`, `gateway.*`, `rtc.ingress.*`, `service.annotations` / `type` / `loadBalancer*`, `pvcAnnotations`, and the claim-only keys `persistence.data.size`, `backup.size`, `backup.storageClass`, `backup.accessMode` | unchanged | unchanged | no — those objects are updated in place |
| `backup.schedule` | unchanged | unchanged | no — the value is read only when the `<fullname>-backup-crontabs` ConfigMap is rendered, so that object changes and nothing in the pod template does |

Because a secret rotation is invisible to the annotation, roll the pod yourself after rotating credentials:

```console
$ kubectl rollout restart statefulset/<fullname>
```

The rollout behaviour per workload is rendered, not implied:

| Workload | Rendered strategy | Effect with the pinned replica count |
| --- | --- | --- |
| StatefulSet `<fullname>` | none → Kubernetes default `RollingUpdate` | with `replicas: 1` that is delete-then-create: the only pod is terminated, then recreated — no surge pod, so every values edit is a short outage |
| Deployment `<fullname>-livekit` (RTC) | `Recreate` (explicit) | the old pod goes away before the new one starts, which frees the `hostNetwork` ports it owns |
| Deployment `<fullname>-jwt` (RTC) | none → Deployment default `RollingUpdate` | a replacement pod can be created before the old one is removed |

The correct upgrade flow, with the checks after each step:

```console
$ helm upgrade my-release tuwunel/tuwunel -f values.yaml --dry-run=client
$ helm upgrade my-release tuwunel/tuwunel -f values.yaml
$ kubectl rollout status statefulset/<fullname>
$ kubectl logs -f statefulset/<fullname> -c tuwunel
$ helm test my-release
$ kubectl get pod <fullname>-0
```

- `--dry-run=client` renders manifests and NOTES without touching the cluster; `--dry-run=server` additionally asks the API server (and needs cluster connectivity), which is what catches rejections a client render cannot see. Add `--hide-secret` when the output would otherwise contain secrets.
- `kubectl rollout status` waits for the new pod to become Ready. On a homeserver version bump that includes the migration, so the wait is minutes — see [The migration budget](#the-migration-budget).
- A pod that does not exit on SIGTERM keeps the rollout waiting for up to `terminationGracePeriodSeconds` (1800 s) before SIGKILL. A "stuck" upgrade with the old pod in `Terminating` is usually this deliberate grace period, not a deadlock.
- `helm test` is the post-upgrade smoke check: an in-cluster fetch of `/_tuwunel/server_version` through the Service, described in [Verifying the deployment](../charts/tuwunel/README.md#verifying-the-deployment).
- One quirk: `service.port` must match `config.global.port` when you set that key, otherwise the render fails with `config.global.port (8008) must equal service.port (8080): the chart sets TUWUNEL_PORT from service.port`.

The upgrade procedure itself, including chart-version migrations, is in [Upgrading](./upgrade.md).

## Resources and thread derivation

`resources.limits.cpu` is not only a limit — it derives the two thread-count environment variables the chart sets, `TOKIO_WORKER_THREADS` and `TUWUNEL_ROCKSDB_PARALLELISM_THREADS` (both always get the same value).

The rule, from the template: a string limit is read as a CPU quantity in millicores — a trailing `m` is stripped, and a value containing `.` is `ceil`ed and multiplied by 1000 — and that millicore count is then divided by 1000, rounding up to whole threads unless it divides evenly. A non-string (plain YAML number) limit is used as the thread count literally.

Measured by rendering the chart (v2.0.1) with each form:

| `resources.limits.cpu` | Rendered threads | Note |
| --- | --- | --- |
| `"1"` (chart default) | 1 | |
| `250m` | 1 | rounds up from 0.25 |
| `500m` | 1 | |
| `1500m` | 2 | rounds up from 1.5 |
| `2000m` | 2 | |
| `"2"` (quoted) | 1 | misread as millicores — the trailing-`m` rule cannot tell `"2"` from `"2000m"` |
| `2` (unquoted integer) | 2 | the numeric form means "this many threads" |
| `0.5` (unquoted float) | `"0.5"` | fractional thread count reaches the server |
| no `cpu` key in `limits` | 1 | |

So use a plain integer (`2`) or an `m`-suffixed string (`"2000m"`). The numeric form cannot express cores above 1000 either: `cpu: 4000` renders 4000 threads.

`resources.requests` (default `50m`/`128Mi`) and `resources.limits` (default `"1"`/`512Mi`) are both required — the schema refuses a values file without `limits` (`at '/resources': missing property 'limits'`). Dropping only the `cpu` key is allowed and falls back to one thread. See [chart README § Resource Configuration](../charts/tuwunel/README.md#resource-configuration) and [Configuring the server](./configuration.md).

On a node with many cores, also set `config.global.db_pool_max_workers`. Upstream's default of 2048 can exceed the pod's task limit and fail startup with `EAGAIN`; a value around the CPU limit (for example `64`) is plenty.

## Storage and growth

| Item | Value | Where |
| --- | --- | --- |
| Data claim | `<fullname>-data`, `ReadWriteOnce`, `persistence.data.size` default `4Gi` | mounted at `/data` (with `subPath: data`) |
| Database directory | `/data/db` (`TUWUNEL_DATABASE_PATH`) | inside the claim: `data/db` |
| Media | `media/` under the database path, i.e. `/data/db/media` by default | same volume as the database |
| Backup claim | `<fullname>-backup`, default `5Gi`, only when `backup.enabled` | mounted at `backup.path` (`/backups`) |

The chart ships no usage metric, no `ServiceMonitor` and no resizing helper: `size` is only the PVC request. Watch the claim with cluster-level tooling:

```console
$ kubectl get pvc -l app.kubernetes.io/instance=my-release
$ kubectl describe pvc <fullname>-data
```

`kubectl get pvc` reports the requested capacity and the claim's state, not how full the volume is. For actual usage use whatever your cluster already exports — the kubelet publishes per-volume `kubelet_volume_stats_used_bytes` and `kubelet_volume_stats_capacity_bytes`. The tuwunel container cannot help here: the image contains only `/usr/bin/tuwunel` and a CA bundle, so there is no shell, `df` or `du` in it. If you want a file-level look, run a throwaway pod against the claim on the same node (a `ReadWriteOnce` claim can only be attached by pods on one node):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: tuwunel-data-peek
spec:
  restartPolicy: Never
  nodeName: <node-running-the-tuwunel-pod>
  containers:
    - name: peek
      image: busybox:1.37
      command: ["du", "-sh", "/mnt/data"]
      volumeMounts:
        - name: data
          mountPath: /mnt
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: <fullname>-data
```

When the claim fills up, grow it in place — this depends on your StorageClass allowing volume expansion, which the chart neither sets nor documents:

```console
$ kubectl patch pvc <fullname>-data --type=merge -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
$ kubectl get pvc <fullname>-data
```

Then set `persistence.data.size` to the same value in your values file, so a claim recreated from the chart does not come back at the old size. Media shares the volume with the database by default, so uploads and database growth compete for the same space; moving uploads to an S3-compatible provider separates the two — see [Storage and media](./storage-and-media.md) and [Persistence Configuration](../charts/tuwunel/README.md#persistence-configuration).

## Inspecting a running release

The container you want is `tuwunel`; `backup` is the cron sidecar (only with `backup.scheduled`) and `config-processor` is the init container that renders the configuration.

```console
# pods of the release (the RTC pods and the test hook share the name label)
$ kubectl get pods -l app.kubernetes.io/name=tuwunel
$ kubectl get pods -l app.kubernetes.io/name=tuwunel,app.kubernetes.io/component=tuwunel

# logs — server, the envsubst init container, the cron sidecar
$ kubectl logs -f statefulset/<fullname> -c tuwunel
$ kubectl logs <fullname>-0 -c config-processor
$ kubectl logs <fullname>-0 -c backup

# the chart's own reachability check, from inside the cluster
$ helm test my-release

# images: what the release asks for vs what the pod runs
$ kubectl get statefulset <fullname> -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
$ kubectl get pod <fullname>-0 -o jsonpath='{.spec.containers[*].image}{"\n"}'

# effective configuration: the input template, and the env that envsubst substitutes into it
$ kubectl get configmap <fullname>-configmap -o jsonpath='{.data.config\.toml}'
$ kubectl get pod <fullname>-0 -o jsonpath='{.spec.containers[0].env}'

# why it restarted / did not schedule
$ kubectl get events --field-selector involvedObject.name=<fullname>-0 --sort-by=.lastTimestamp
```

The running file is `/tmp/config/config.toml` (`TUWUNEL_CONFIG`), written at pod start by `config-processor` from the ConfigMap — and the chart's environment variables outrank it. Since the image has no shell you read those two inputs rather than the file. For the server's own view of its live configuration, use the admin room: `!admin server show-config` prints configuration values, with `!admin server uptime` and `!admin server memory-usage` alongside it (commands in the console's `server` group, the same group as the backup commands in [Backups and restore](./backups.md)).

Two things that look like problems and are not: `helm test` leaves its `Completed` pod `<fullname>-test-connection` behind (it is deleted before the next hook creation), and the sidecar's logs are empty whether or not its job ran — busybox `crond` logs through a syslog the pod does not run, so check the repository with `!admin server list-backups` instead.

RTC deployments expose their own component labels when `rtc.enabled` is set:

```console
$ kubectl logs -l app.kubernetes.io/component=rtc-livekit
$ kubectl logs -l app.kubernetes.io/component=rtc-jwt
```

Details are in [Matrix RTC with LiveKit](./rtc.md).

## Single-replica constraint

`replicas` is hardcoded to `1` in the StatefulSet and there is no values key for it. The chart's release notes put it plainly: *"WARNING:  Scaling the StatefulSet will probably cause failures and quiet data corruption."* The reason is the storage model — as the README states, *"The StatefulSet runs a single replica with a RocksDB store on a `ReadWriteOnce` volume; scaling it up is not supported."* RocksDB is a single-writer store; a second replica means two writers on one database directory.

Scale-up attempts also do not stick: `kubectl scale` is not a control surface the chart honours, because the next `helm upgrade` writes `replicas: 1` back from the render. The one sanctioned scale is to zero for a maintenance window, and the [restore recipe](./backups.md) uses exactly that (`--replicas=0`, do the work, then `--replicas=1`).

Both RTC Deployments are pinned to one replica as well. LiveKit cannot be scaled behind the chart: with the default `hostNetwork` mode its ports are node ports on the node it lands on, which is also why its strategy is `Recreate` rather than a rolling update.

## Routine maintenance table

| Task | Cadence | Command |
| --- | --- | --- |
| Verify backups exist and are readable | weekly, and after any schedule change | `!admin server list-backups`, `!admin server verify-backup` in the admin room — see [Backups and restore](./backups.md) |
| Confirm the scheduled backup is armed | after editing `backup.*` | `kubectl exec <fullname>-0 -c backup -- cat /etc/crontabs/root` (expect `<schedule> pkill -USR2 -x tuwunel`, the crontab `crond` fires); the job itself is described in that guide |
| Storage headroom (data and backup claims) | weekly | `kubectl get pvc -l app.kubernetes.io/instance=my-release` plus the kubelet's `kubelet_volume_stats_used_bytes` / `kubelet_volume_stats_capacity_bytes` |
| Image / CVE bump of the server | per upstream release | `helm upgrade my-release tuwunel/tuwunel -f values.yaml --set image.tag=v<X.Y.Z>` then `helm test my-release` (never below v1.9.0) |
| Log review | weekly | `kubectl logs <fullname>-0 -c tuwunel --since=24h \| grep -E 'ERROR\|WARN'` |
| Probe and restart state | after every rollout | `kubectl get pod <fullname>-0` (READY, RESTARTS) and `kubectl describe pod <fullname>-0` |
| Post-upgrade smoke test | after every upgrade | `helm test my-release` |

For failures — a pod stuck in `Terminating`, a probe that never succeeds, a rollout that restarts in a loop — see [Troubleshooting](./troubleshooting.md).
