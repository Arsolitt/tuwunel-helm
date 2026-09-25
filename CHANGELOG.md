# Changelog

All notable changes to the tuwunel Helm chart. The section for a released
version is published as that GitHub release's body by the `release` job in
`.github/workflows/ci.yaml`.

Versions come from the git tag, not from a hand-edited `Chart.yaml`: the tag is
`tuwunel-<version>`, where `<version>` is either a stable release (`2.1.0`) or a
release candidate (`2.1.0-rc.1`). The section published is `## [<version>]` - a
candidate publishes the section of the version it is a candidate of, so
`2.1.0-rc.1` publishes `## [2.1.0]`. Write the section before cutting the first tag
of the version; its heading date is the day the section was opened.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.2] - 2026-09-25

### Fixed

- **A chart upgrade no longer fails on an immutable selector.** `spec.selector.matchLabels` of the
  StatefulSet and of the two RTC Deployments was rendered from the whole label set, which carries
  `helm.sh/chart: tuwunel-<chart version>`. That value moves with every chart release and a workload's
  selector is immutable, so the first upgrade of any release created by 2.0.1 or older was refused by
  the API server with `spec.selector: Invalid value: …: field is immutable` - naming the three objects
  and no cause. Every selector, Services included, now renders from a subset that cannot move:
  `app.kubernetes.io/name`, `app.kubernetes.io/instance` and the resource's component.
- **The render refuses that upgrade itself, with the commands that fix it.** The statefulset template
  reads the live StatefulSet and the two RTC Deployments through `lookup`; when one of them still
  carries `helm.sh/chart` in its selector, the render fails before anything is applied and prints the
  ready `kubectl delete` commands for the release at hand (`--cascade=orphan` for the StatefulSet, a
  plain delete for the RTC Deployments). Measured on Kubernetes 1.35: the homeserver pod is not
  restarted - the recreated StatefulSet adopts it, same pod UID, `restartCount` unchanged, the
  database on its PersistentVolumeClaim untouched - and the two RTC Deployments recreate their pods.
  `lookup` has nothing to ask without a cluster, so `helm template` and `helm lint` (`lint`, CI) never
  see the check, and it goes silent for good once the commands have run.
- **A Service no longer drops its endpoints during a chart upgrade.** The three Services selected on
  the same moving label set, `helm.sh/chart` included, and the new selector is applied before any new
  pod exists - so from the first apply until the first new pod was Ready the Service matched no pod.
  The stable subset matches the pods that are still running, so the endpoints never empty.

### Changed

- **`lint` asserts both selector properties on every render** - the defaults and each
  `ci/*-values.yaml` fixture: no selector carries a label that moves with the chart version
  (`helm.sh/chart`, `app.kubernetes.io/version`, `app.kubernetes.io/managed-by`), and every
  workload's own pod template carries everything its selector asks for. Chart 2.0.1 fails the first
  assertion, so a single render can no longer ship a defect only the next chart release discovers.
- Docs: [Upgrading](./docs/upgrade.md) gains the one-time migration with the measured effect of each
  command, [Troubleshooting](./docs/troubleshooting.md) gains the raw API error and the new guard,
  [How the chart renders a running server](./docs/internals.md) explains why the selectors are a fixed
  subset, [Installing the chart](./docs/installation.md) documents the label split, and
  [Configuring the server](./docs/configuration.md) records that upstream documents
  `[global.blurhashing]` without implementing it - no released image registers the section (nor the
  shorter `blurhash`), so neither spelling can turn blurhashes on.

## [2.0.1] - 2026-09-24

### Fixed

- An Ingress with `ingress.tls: true` and no delegated domain renders an applyable `spec.tls` list.
  The delegated domain is added only when `config.global.well_known.server` is set; the empty host
  the list used to carry made the API server refuse the whole Ingress with
  `spec.tls[0].hosts[1]: Invalid value: ""`.
- `service.type: LoadBalancer` and `service.type: NodePort` install without a workaround. The
  headless default (`clusterIP: "None"`) is rendered for a `ClusterIP` Service, which is where the
  StatefulSet needs it; the other two types let the cluster allocate the VIP instead of shipping a
  `None` the API server rejects, and an explicitly named address still pins it. `loadBalancerIP`
  and `loadBalancerSourceRanges` are rendered for a `LoadBalancer` only, the one type they are
  legal on.
- `backup.scheduled: true` now actually runs its job. The sidecar was started as the pod's
  unprivileged user, while busybox `crond` runs a crontab file as the user that file is named after
  - and the chart names it `root` - so `crond` could not switch identity, skipped the job, and
  reported nothing because its log goes to syslog. No scheduled backup was ever produced; a working
  schedule shows up as the server's `Created database backup` line and the `<backup.path>/meta/`
  entries.
- Host fields are normalised through one helper: a trailing `:port` is stripped from `server_name`,
  each `ingress.extraHosts` entry, each `gateway.hostnames` entry and
  `config.global.well_known.server`, because those values become Ingress rule/TLS hosts and
  HTTPRoute hostnames, where a port is invalid - a `server_name` like `host:8448` used to render
  hosts the API server refuses. A value carrying a scheme has nothing to strip to a hostname, so the
  render fails naming the field and the value instead of emitting an unusable host. `server_name`
  keeps its port in `TUWUNEL_SERVER_NAME` and in `config.toml`; only the host fields are stripped.
- `rtc.domain` is pinned to a bare lowercase DNS name: the schema refuses a scheme, a port,
  uppercase and underscores when `rtc.enabled` is true. The chart prefixes the value itself
  (`https://<rtc.domain>` for the well-known document, `wss://<rtc.domain>` for `LIVEKIT_URL`), so a
  scheme in the value used to render `https://https://...`.
- `rtc.livekit.config.port` has to be a port number. The LiveKit container port, the LiveKit
  Service, the RTC Ingress and the RTC HTTPRoute are all built from it, so an empty value now fails
  the render with a message naming those four consumers, and one that is not digits only is refused
  with the same explanation.
- Environment-variable names are validated against Kubernetes' rule
  (`[-._a-zA-Z][-._a-zA-Z0-9]*`) by the schema, for `env`, `envFromSecret`, `extraEnv` and the
  `name` of `envRaw` entries: a name like `2FA_TOKEN` is refused at `helm lint`/`helm template` time
  instead of by the API server at apply time.
- Image `tag` is required to be non-empty (the schema's `minLength`; `repository` already had it)
  for `image`, `initContainer.image`, `busybox.image`, `rtc.jwt.image` and `rtc.livekit.image`: an
  empty tag rendered `ghcr.io/matrix-construct/tuwunel:` and failed in the kubelet as
  `InvalidImageName`.

### Changed

- The `backup` sidecar container runs as root with only `SETGID`, `SETUID` and `KILL` added to an
  otherwise dropped capability set, keeping its read-only root filesystem and no privilege
  escalation.
- `backup.scheduled: true` without `backup.enabled: true` is refused at render time with a message
  naming the pair: the sidecar mounts a crontab ConfigMap that only the enabled render creates.
- `service.type: ExternalName` is no longer accepted by the schema. The chart renders no
  `externalName`, so a Service of that type could never be valid.
- `config.global: null` no longer aborts an Ingress render.
- `config.global.well_known.server` written as a URL is refused at render time, with or without an
  Ingress or a Gateway API route: the key is a bare `host:port` and the server refuses anything
  else at startup, so the render says so first instead of leaving a crash-looping pod behind.

## [2.0.0] - 2026-09-24

### Added

- Gateway API exposure next to the Ingress: `gateway.*` renders a homeserver `HTTPRoute` for
  `server_name`, the delegated domain and `gateway.hostnames` with one catch-all path to
  `service.port`; `rtc.gateway.*` renders the RTC route with the JWT path set the RTC ingress
  already uses; `rtc.livekit.gateway.udpRoute` and `.tcpRoute` render the LiveKit media ports. The
  chart creates no `Gateway` or `GatewayClass` - `parentRefs` name the Gateway you run, and a
  render without them fails instead of emitting a route nothing would attach to.
- Online database backups: `backup.*` gives the backup repository its own volume, renders
  `database_backup_path` and `database_backups_to_keep`, and with `backup.scheduled: true` adds a
  cron sidecar that triggers `!admin server backup-database` through SIGUSR2
  (`shareProcessNamespace` plus a crontab ConfigMap). `args` carries the documented restore recipe
  (`--restore-backup`, `--maintenance`, `--execute`).
- `helm test` hook: a busybox pod that fetches `/_tuwunel/server_version` from inside the cluster,
  the one check a rendered manifest cannot make.
- A `pod` network mode for LiveKit next to the `hostNetwork` default: media goes through the
  Service in `rtc.livekit.service` (new block with `type`, `externalTrafficPolicy`,
  `loadBalancerIP`, `loadBalancerSourceRanges`) on a single multiplexed `config.rtc.udp_port`.
- More pod configuration: `probes.startup`/`readiness`/`liveness` (enable, timings, thresholds),
  `podLabels`, `podAnnotations`, `priorityClassName`, `extraVolumes`, `extraVolumeMounts`,
  `pvcAnnotations`, `imagePullSecrets`, `busybox.*` and per-workload `nodeSelector`, `tolerations`,
  `affinity` and `podAnnotations` for the LiveKit and JWT pods.
- The chart derives the RTC wiring when those values are left empty: `LIVEKIT_URL` =
  `wss://<rtc.domain>`, `LIVEKIT_FULL_ACCESS_HOMESERVERS` = `server_name` (mandatory in
  lk-jwt-service 0.7.0, which used to default it to `*`), `LIVEKIT_JWT_BIND`, the LiveKit `keys`
  entry, `room.auto_create: false` with the `sfu_webhook` URL, and
  `config.global.well_known.livekit_url` = `https://<rtc.domain>`.
- `config.global.log` defaults to `info`, and the README documents the v1.9 config surface the
  chart passes through: media storage providers (local and S3 - `media_storage_providers`,
  `store_media_on_providers`, `storage_provider`), `ip_source` with `ip_source_trusted_subnets`
  for client IPs behind a proxy, and `livekit_url`.

### Changed

- tuwunel v1.9.2 (was v1.5.1), lk-jwt-service 0.7.0 (was 0.4.1) and LiveKit v1.13.7 (was v1.9.12).
  The chart needs tuwunel v1.9.0 or newer.
- Chart-managed environment variables use the `TUWUNEL_` prefix: `TUWUNEL_CONFIG`,
  `TUWUNEL_SERVER_NAME`, `TUWUNEL_DATABASE_PATH`, `TUWUNEL_PORT`, `TUWUNEL_ADDRESS` and
  `TUWUNEL_ROCKSDB_PARALLELISM_THREADS`. A legacy `CONDUWUIT_PORT` no longer wins over the chart's
  port, and `config.global.port` now has to equal `service.port` while
  `config.global.server_name` has to equal `server_name`, or the render fails.
- Every probe is an exec probe running `tuwunel --health-check`. The startup probe allows 30
  minutes (10 s x 180) for the one-time database migration, and `terminationGracePeriodSeconds`
  defaults to 1800 s so a SIGKILL cannot interrupt it.
- Registration is disabled by default (`config.global.allow_registration: false`).
- Editing `config` or the environment rolls the pod: the StatefulSet template carries a
  `checksum/config` annotation over the rendered configuration and `env`/`envRaw`/`envFromSecret`.
- The CPU limit derives `TOKIO_WORKER_THREADS` and `TUWUNEL_ROCKSDB_PARALLELISM_THREADS`.
- `Chart.yaml` declares `kubeVersion: '>=1.31.0-0'`.
- The chart README gained an upgrade section for this release and a note on the array-of-tables
  shape (TOML `[[...]]`) for `config` keys upstream defines as tables, which a nested mapping
  renders as a single table and stops the server.

### Removed

- The published default `registration_token` (`supa-dupa-secret-token`) is gone; an install with
  registration enabled has to bring its own token or shared secret.
- `config.global.blurhashing` and `config.global.antispam` are gone from the defaults and from the
  documented config surface.
- `rtc.ingress.path` and `rtc.ingress.extraHosts` are rejected by the schema instead of being
  accepted and ignored: the RTC ingress always routes the JWT paths and `/`.

## [1.2.0] - 2026-09-23

### Changed

- `config.global.address` drives the address tuwunel listens on. It defaults to `::`, one
  dual-stack socket that also serves IPv4-mapped clients, where the chart previously hardcoded
  `0.0.0.0`; set it to `0.0.0.0` on a pod network without a usable IPv6 stack.
  `values.schema.json` pins the address shape and `config.global.allow_registration` /
  `config.global.allow_federation` to booleans, so a quoted `"false"` is rejected at render time
  instead of stopping tuwunel at startup.

### Fixed

- The readiness probe requests `/_tuwunel/server_version` instead of
  `/_matrix/federation/v1/version`, which answers 403 as soon as federation is disabled (the chart
  default) and left the pod NotReady while the server itself was running.

## [1.1.0] - 2026-09-23

### Added

- `values.schema.json`: values are validated on every `helm lint`, `helm template` and install, so
  a typo like `ingres:` or an impossible value is rejected instead of being silently ignored by
  Helm.

### Fixed

- `extraLabels` rendered invalid YAML: with extra labels set they were appended to the
  `helm.sh/chart` line and the manifest failed to parse. The block is emitted on its own line now.

### Changed

- Chart metadata: `home`, `maintainers` and `sources` point at the canonical `Arsolitt` repository
  casing, with the upstream homeserver repository listed as a source.

## [1.0.3] - 2026-03-15

### Changed

- The configuration reference and the RTC documentation moved from the repository README into the
  chart README, so they ship inside the packaged chart (`helm show readme`).

## [1.0.2] - 2026-03-11

### Added

- Security contexts on every pod the chart creates: `runAsNonRoot` with fixed user and group IDs,
  a read-only root filesystem with tmp volumes for the writable directories, all capabilities
  dropped, `allowPrivilegeEscalation: false` and the `RuntimeDefault` seccomp profile.
- `rtc.jwt.resources` and `rtc.livekit.resources`.

### Changed

- `service.port` defaults to 8080 instead of 80, so the homeserver container no longer binds a
  privileged port.
- tuwunel v1.5.1 (was v1.5.0) and LiveKit v1.9.12 (was v1.9.11).

## [1.0.1] - 2026-03-07

### Changed

- `env`, `envRaw` and `envFromSecret` moved from `config.global` to the top level of the values
  file, where they belong to the chart rather than to the tuwunel configuration. An existing values
  file has to move these keys.

## [1.0.0] - 2026-03-05

### Added

- Initial release: the tuwunel homeserver (v1.5.0) as a StatefulSet with `config` rendered into
  `config.toml` by an `envsubst` init container, a PersistentVolumeClaim for `/data`, a headless
  Service and an optional Ingress with TLS.
- `env`, `envRaw` and `envFromSecret` for environment variables, plus `extraEnv`, `extraLabels`,
  `statefulsetAnnotations`, `resources`, `nodeSelector`, `tolerations` and `affinity`.
- Optional Matrix RTC support under `rtc.*`: lk-jwt-service 0.4.1 and LiveKit v1.9.11 on the node's
  network namespace (`hostNetwork`), with their Deployments, Services, ConfigMaps and an Ingress
  that routes the JWT paths to the JWT service and everything else to LiveKit. Media ports are node
  ports: `7880/tcp`, `7881/tcp` and `50100-50200/udp`.
- `initContainer.*` for the envsubst image, and the `Recreate` strategy on the LiveKit Deployment
  so the `hostNetwork` pod can be replaced.
