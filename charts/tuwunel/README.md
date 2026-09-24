# Tuwunel Helm Chart

Helm chart for deploying [Tuwunel](https://github.com/matrix-construct/tuwunel) - a Matrix homeserver based on Conduit.

Values are validated against [`values.schema.json`](values.schema.json): unknown top-level keys
and impossible values are rejected by `helm lint`, `helm template` and `helm install` instead of
being silently ignored.

The chart requires tuwunel **v1.9.0 or newer**. It configures the server through the canonical
`TUWUNEL_*` environment variables and probes it with `tuwunel --health-check`, both introduced in
v1.9.0. An older image still renders, but it ignores the chart-managed environment variables and
does not answer the exec probe.

## Upgrading to 2.0.0

Breaking changes:

- **tuwunel v1.9.0 or newer is required.** The chart now sets `TUWUNEL_CONFIG`,
  `TUWUNEL_SERVER_NAME`, `TUWUNEL_DATABASE_PATH`, `TUWUNEL_PORT`, `TUWUNEL_ADDRESS` and
  `TUWUNEL_ROCKSDB_PARALLELISM_THREADS` (the prefix introduced in v1.9.0) and probes the
  container with `tuwunel --health-check`.
- **Registration is disabled by default** (`config.global.allow_registration: false`) and the
  published default token (`registration_token: supa-dupa-secret-token`) is gone. Token
  registration for the first user is described in
  [Registration and the first user](#registration-and-the-first-user).
- **A legacy `CONDUWUIT_PORT` no longer wins over the chart's port.** Upstream precedence is
  `CONDUIT_` < `CONDUWUIT_` < `TUWUNEL_`; the chart owns the port and renders `TUWUNEL_PORT` from
  `service.port`. Verified against v1.9.2 with both variables set: the server logs
  `Listening on ["tcp:[::]:8080"]` (the chart's port), not the legacy one.
- **`config.global.blurhashing` and `config.global.antispam` are gone from the defaults.** Current
  tuwunel has neither; v1.9.2 starts but warns
  `Config parameter "blurhashing" is unknown to tuwunel, ignoring.` Remove them from your values.
- **The readiness probe is an exec probe**, `command: ["tuwunel", "--health-check"]`, not
  `httpGet /_tuwunel/server_version`. The server-version path still answers, but nothing probes it
  any more; `helm test` uses it instead.
- **`rtc.ingress.path` and `rtc.ingress.extraHosts` are rejected by the schema** instead of being
  accepted and ignored:
  `at '/rtc/ingress': additional properties 'path' not allowed`. The RTC ingress always routes the
  JWT paths listed in [RTC ingress](#rtc-ingress) and `/` to LiveKit.
- **`config.global.port` must equal `service.port`, and `config.global.server_name` must equal
  `server_name`**, or the render fails with
  `config.global.port (8008) must equal service.port (8080): the chart sets TUWUNEL_PORT from
  service.port`. An environment variable beats the configuration file, so a differing value would
  otherwise be silently ignored.
- **Editing `config` or the env vars now rolls the pod** (a `checksum/config` annotation covers the
  rendered ConfigMap plus `env`/`envRaw`/`envFromSecret`), and `terminationGracePeriodSeconds`
  defaults to 1800 rather than the Kubernetes default of 30.
- **RTC images moved to the current releases**: lk-jwt-service `0.7.0` (new `/get_token` contract,
  mandatory `LIVEKIT_FULL_ACCESS_HOMESERVERS`) and LiveKit `v1.13.7`.

Also new in this release: [online backups](#backups-and-recovery), [media storage providers
(local and S3)](#media-storage-local-and-s3), [`ip_source`](#client-ip-behind-a-proxy),
[Gateway API exposure](#gateway-api), the `pod` network mode for LiveKit, and a `helm test` hook.

## Configuration

The following tables list the configurable parameters of the tuwunel chart and their default values.

### Core Configuration

| Parameter                          | Description                                                                                 | Default                            |
| ---------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------- |
| `server_name`                      | Server name (your Matrix domain)                                                            | `yourdomain.com`                   |
| `image.repository`                 | Image repository                                                                            | `ghcr.io/matrix-construct/tuwunel` |
| `image.tag`                        | Image tag; needs v1.9.0 or newer for the chart's env and probe contract                      | `v1.9.2`                           |
| `image.pullPolicy`                 | Image pull policy                                                                           | `IfNotPresent`                     |
| `initContainer.image.repository`   | Init container image for envsubst                                                           | `dibi/envsubst`                    |
| `initContainer.image.tag`          | Init container image tag                                                                    | `1`                                |
| `initContainer.image.pullPolicy`   | Init container pull policy                                                                  | `IfNotPresent`                     |
| `busybox.image.repository`         | Image for the backup cron sidecar and the `helm test` pod                                   | `busybox`                          |
| `busybox.image.tag`                | busybox tag (has to stay multi-arch)                                                        | `1.37`                             |
| `busybox.image.pullPolicy`         | busybox pull policy                                                                         | `IfNotPresent`                     |
| `imagePullSecrets`                 | Pull secrets for every pod the chart creates                                                | `[]`                               |

`dibi/envsubst:1` is published for `linux/amd64` only. On an arm64 node either point
`initContainer.image` at a multi-arch (or mirrored) equivalent or pin the pod to an amd64 node;
the tuwunel image itself is multi-arch.

### Environment Variables

| Parameter              | Description                                          | Default |
| ---------------------- | ---------------------------------------------------- | ------- |
| `env`                  | Plain text environment variables for config          | `{}`    |
| `envRaw`               | Raw environment variable sections (complex configs)  | `[]`    |
| `envFromSecret`        | Environment variables from Kubernetes secrets        | `{}`    |
| `extraEnv`             | Additional environment variables for the container   | `[]`    |

Format for `envFromSecret`: `ENV_VAR: secretName/secretKey`

Example:
```yaml
envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN
```

`env`, `envRaw` and `envFromSecret` are set on **both** the init container and the tuwunel
container, so a `${VAR}` placeholder in `config` and a direct reference to the same variable
always agree. `extraEnv` is applied to the tuwunel container last, on top of everything else.

### Tuwunel Configuration

The `config` section is converted directly into the tuwunel configuration file. See the [tuwunel documentation](https://github.com/matrix-construct/tuwunel) for all available options.

| Parameter                                   | Description                                                                                 | Default                  |
| ------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------ |
| `config.global.address`                     | Address tuwunel listens on; `::` is a dual-stack socket, `0.0.0.0` is IPv4 only             | `::`                     |
| `config.global.allow_registration`          | Whether to allow users to register new accounts                                             | `false`                  |
| `config.global.allow_federation`            | Whether to allow federating with other Matrix servers                                       | `false`                  |
| `config.global.trusted_servers`             | Servers to trust when federating                                                            | `[]`                     |
| `config.global.tls`                         | TLS configuration                                                                           | `{}`                     |
| `config.global.log`                         | Log level: `trace`, `debug`, `info`, `warn`, `error`                                        | `info`                   |
| `config.global.ip_source`                   | Where the client IP is read from (`connect_info` plus 7 header sources); see below          | unset (`connect_info`)   |
| `config.global.ip_source_trusted_subnets`   | CIDRs that keep their connection address instead of `ip_source`                             | unset (`[]`)             |
| `config.global.db_pool_max_workers`         | RocksDB thread pool size; upstream default 2048 can exceed the pod task limit                | unset (upstream `2048`)  |
| `config.global.well_known.client`           | Client delegation URL (for delegated domains)                                               |                          |
| `config.global.well_known.server`           | Server delegation (for delegated domains)                                                   |                          |
| `config.global.well_known.livekit_url`      | MatrixRTC focus URL; set by the chart when `rtc.enabled` is true                            |                          |
| `config.global.well_known.rtc_transports`   | RTC transports for Element Call; escape hatch for a non-LiveKit focus                       |                          |
| `config.global.ldap`                        | LDAP configuration                                                                          | `{}`                     |

Everything else under `config` is written to `config.toml` as-is, so any upstream key works as
long as it is valid TOML.

Booleans have to be TOML booleans, not strings: `allow_federation: "false"` renders
`allow_federation = "false"` into `config.toml` and tuwunel exits 1 at startup with
`invalid type: found string "false", expected a boolean for key "global.allow_federation"`.
`values.schema.json` pins `config.global.allow_federation` and `config.global.allow_registration`
to type `boolean`, so the quoted form is rejected at render time - existing values files that still
carry quoted booleans have to be fixed before upgrading the chart.

Keys that upstream defines as an **array of tables** (TOML `[[global.<key>]]`) have to be written as
a YAML list. A nested mapping renders as a single table instead, which is not the shape tuwunel
deserializes and stops the server at startup - `config` is a passthrough, so the chart cannot catch
this for you:

```yaml
config:
  global:
    # WRONG: renders [global.identity_provider] with brand = "..." in it, and
    # v1.9.2 exits with `invalid type: found string "Authentik", expected struct
    # IdentityProvider for key "global.identity_provider.brand"`
    # identity_provider:
    #   brand: Authentik
    #   client_id: ...
    #
    # RIGHT: `-` makes it a list, which renders [[global.identity_provider]]
    identity_provider:
      - brand: Authentik
        client_id: ...
        client_secret: ...
        issuer_url: "https://sso.example.com/application/o/tuwunel/"
        callback_url: "https://matrix.example.com/_matrix/client/unstable/login/sso/callback/<client_id>"
```

`identity_provider` (OIDC/LDAP providers) and `well_known.rtc_transports` are the two keys this
chart's own examples use; the rule holds for every upstream key documented with `[[...]]`.

#### Bind address

kubelet probes exec inside the container, but the Service, the `helm test` pod and the RTC webhook
still reach the server over the pod network, so it has to listen on the family the cluster assigns:

- the cluster assigns IPv6 pod addresses: keep the default `config.global.address: "::"` - one
  dual-stack socket that serves IPv6 and IPv4-mapped clients;
- the pod network has no usable IPv6 stack: set `config.global.address: "0.0.0.0"` - IPv4 only.

`config.global.address` also accepts a list. Prefer a single address: an address that cannot be
bound is not a degraded listener but a dead server - v1.9.2 exits 1 with
`Failed to bind 192.0.2.1:8080: Cannot assign requested address (os error 99)` and
`There was a problem with the 'address' directive in your configuration`. The chart passes the same
value as `TUWUNEL_ADDRESS`.

### Service Configuration

| Parameter                          | Description                                                                                 | Default                            |
| ---------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------- |
| `service.annotations`              | Annotations for Service resource                                                            | `{}`                               |
| `service.type`                     | Type of service to deploy                                                                   | `ClusterIP`                        |
| `service.clusterIP`                | ClusterIP of service; `None` is the headless service the StatefulSet needs                   | `None`                             |
| `service.port`                     | Port to expose service; the chart's single port knob                                         | `8080`                             |
| `service.externalIPs`              | External IPs for service                                                                    | `[]`                               |
| `service.loadBalancerIP`           | Load balancer IP                                                                            | `""`                               |
| `service.loadBalancerSourceRanges` | List of IP CIDRs allowed to access the load balancer                                        | `[]`                               |

`service.port` is rendered into the Service, the Ingress backends, the container port and
`TUWUNEL_PORT`. Setting `config.global.port` to a different number fails the render instead of
being ignored (see [Upgrading to 2.0.0](#upgrading-to-200)).

### Ingress Configuration

| Parameter                    | Description                                           | Default       |
| ---------------------------- | ----------------------------------------------------- | ------------- |
| `ingress.enabled`            | Whether to deploy the Ingress resource                | `false`       |
| `ingress.class`              | Ingress class                                         | `""`          |
| `ingress.annotations`        | Ingress annotations                                   | `{}`          |
| `ingress.path`               | Ingress path                                          | `/`           |
| `ingress.extraHosts`         | Additional hostnames                                  | `[]`          |
| `ingress.tls`                | Whether to configure TLS for the ingress              | `false`       |
| `ingress.tlsSecretName`      | TLS secret name (defaults to `<release-name>-tls`)    | `""`          |

### Gateway API

The chart can expose the homeserver through `gateway.networking.k8s.io` routes instead of an
Ingress, or next to one. It renders `HTTPRoute` objects that attach to a `Gateway` you already run:
the listeners, the TLS certificates and the addresses of that Gateway stay yours. As with
`ingress.class` and an IngressClass, the chart never creates a `Gateway` or a `GatewayClass` -
`parentRefs` name the Gateway your controller serves. Ingress and Gateway API may be enabled at the
same time; they are served by different controllers, so running both is the supported state during
a cutover.

The homeserver route is named `<fullname>` and carries every hostname the server has to answer for:
`server_name`, the delegated domain from `config.global.well_known.server` with its port stripped
(the rule the Ingress already follows) and `gateway.hostnames`. A single catch-all `PathPrefix /`
rule points at `<fullname>:service.port`; with both hostnames listed, one rule covers what the
Ingress splits into separate path sets.

| Parameter             | Description                                             | Default         |
| --------------------- | ------------------------------------------------------- | --------------- |
| `gateway.enabled`     | Render the homeserver `HTTPRoute`                       | `false`         |
| `gateway.parentRefs`  | Gateways the route attaches to                          | `[]`            |
| `gateway.hostnames`   | Additional hostnames for the route                      | `[]`            |
| `gateway.annotations` | Annotations for the `HTTPRoute`                         | `{}`            |

A `parentRefs` entry needs at least a `name`; `namespace` defaults to the release namespace when
omitted and `sectionName` picks one listener of a multi-listener Gateway (TLS and hostname binding
belong to that listener). `gateway.annotations` are written onto the `HTTPRoute`, for the
controller-specific opt-ins a route may need.

Enabling `gateway.enabled` without any `parentRefs` fails the render with
`gateway.enabled needs gateway.parentRefs`: a route with an empty `parentRefs` list is valid for
the CRD and would simply never be attached, so the chart refuses it instead.

```yaml
gateway:
  enabled: true
  parentRefs:
    - name: eg
      namespace: gateway-system
    - name: eg
      sectionName: https
  hostnames:
    - alias.example.com
  annotations:
    example.com/note: rendered
```

#### RTC on the Gateway API

With `rtc.enabled` and `rtc.gateway.enabled` the chart renders a second `HTTPRoute`, named
`<fullname>-rtc`, for `rtc.domain`: the JWT paths listed in [RTC ingress](#rtc-ingress) go to
`<fullname>-jwt:8080` and everything else to `<fullname>-livekit:<rtc.livekit.config.port>` - the
same routing table the RTC ingress uses. The route is rendered only when `rtc.enabled` is true,
exactly like `rtc.ingress`; `gateway.enabled` is not required for it, but it needs
`rtc.gateway.parentRefs` or the shared `gateway.parentRefs`, and a render with neither fails with a
message naming `rtc.gateway.parentRefs`.

| Parameter                 | Description                                             | Default |
| ------------------------- | ------------------------------------------------------- | ------- |
| `rtc.gateway.enabled`     | Render the RTC `HTTPRoute`                              | `false` |
| `rtc.gateway.parentRefs`  | Gateways the RTC route attaches to                      | `[]`    |
| `rtc.gateway.annotations` | Annotations for the RTC `HTTPRoute`                     | `{}`    |

LiveKit's media is UDP and raw TCP, which an `HTTPRoute` cannot carry, so the chart renders a
`UDPRoute` named `<fullname>-livekit-udp` and a `TCPRoute` named `<fullname>-livekit-tcp` - in
`pod` mode only, because in the default `hostNetwork` mode the media ports are node ports on the
node `rtc.domain` resolves to and no Service fronts them. A media route in `hostNetwork` mode fails
the render with a message naming `rtc.livekit.networkMode`; with `networkMode: pod` the ports live
on the Service in `rtc.livekit.service`, and the routes target `config.rtc.udp_port` and
`config.rtc.tcp_port`. A route whose port is unset fails the render with a message naming that port
value.

| Parameter                         | Description                                             | Default |
| --------------------------------- | ------------------------------------------------------- | ------- |
| `rtc.livekit.gateway.udpRoute`    | Render a `UDPRoute` for `config.rtc.udp_port`           | `false` |
| `rtc.livekit.gateway.tcpRoute`    | Render a `TCPRoute` for `config.rtc.tcp_port`           | `false` |
| `rtc.livekit.gateway.parentRefs`  | Gateways the media routes attach to                     | `[]`    |
| `rtc.livekit.gateway.annotations` | Annotations for the media routes                        | `{}`    |

The media routes also need `rtc.enabled`, and `rtc.livekit.gateway.parentRefs` falls back to
`gateway.parentRefs` - not to `rtc.gateway.parentRefs`, so a media-only configuration needs its own
list or the shared one.

Whether a `UDPRoute`/`TCPRoute` actually carries media depends on the Gateway implementation's data
plane: HTTPRoute proxying is universally implemented, UDP/TCP proxying is not, so check your
controller's conformance before relying on the media routes. The Service path needs no Gateway
support at all and keeps working on any controller (or none).

Gateway API versions: `HTTPRoute` and `Gateway` have been `v1` since Gateway API v1.0, but
`UDPRoute` and `TCPRoute` only reach `v1` in **Gateway API v1.6** and are still absent from some
vendor bundles. A cluster running an older bundle cannot serve the media routes, while the
homeserver and RTC `HTTPRoute`s are unaffected.

### Persistence Configuration

| Parameter                          | Description                                           | Default          |
| ---------------------------------- | ----------------------------------------------------- | ---------------- |
| `persistence.data.enabled`         | Use persistent volume to store data                   | `true`           |
| `persistence.data.size`            | Size of persistent volume claim                       | `4Gi`            |
| `persistence.data.existingClaim`   | Use an existing PVC to persist data                   | `""`             |
| `persistence.data.storageClass`    | Storage class for the data claim                      | `""`             |
| `persistence.data.accessMode`      | PVC access mode                                       | `ReadWriteOnce`  |
| `pvcAnnotations`                   | Annotations added to every PVC the chart creates       | `{}`             |

`storageClass` (here and in `backup`, below) is a three-way switch:

- unset or `""` - no `storageClassName` in the claim, the cluster's default provisioner decides;
- `"-"` - renders `storageClassName: ""`, i.e. bind a pre-created PersistentVolume by hand
  (the sentinel Kubernetes itself uses for an explicitly empty class name);
- anything else - that class, quoted, e.g. `storageClass: "fast-ssd"`.

The StatefulSet runs a single replica with a RocksDB store on a `ReadWriteOnce` volume; scaling it
up is not supported.

### Backups and Recovery

tuwunel has built-in online backups - no external tooling, and the server keeps running while a
backup is written. The chart's `backup` block gives the backup repository its own volume and
points the server at it:

```yaml
backup:
  enabled: true
  size: 20Gi
  scheduled: true
  schedule: "0 3 * * *"
  keep: 14
```

What `backup.enabled: true` renders:

- a PVC `<fullname>-backup` (or `backup.existingClaim`) mounted at `backup.path`;
- `database_backup_path` and `database_backups_to_keep` in `config.toml` - only when you did not
  set those keys yourself;
- with `backup.scheduled: true` additionally: `admin_signal_execute: ["server backup-database"]`, a
  `backup` sidecar (`busybox`, running `crond -f -l 8 -c /etc/crontabs`), a
  `<fullname>-backup-crontabs` ConfigMap whose only entry is
  `<schedule> pkill -USR2 -x tuwunel`, and `shareProcessNamespace: true` so that signal reaches the
  server process. SIGUSR2 makes the server run the configured admin command, i.e. the same online
  backup as `!admin server backup-database`.

| Parameter                    | Description                                                          | Default                |
| ---------------------------- | -------------------------------------------------------------------- | ---------------------- |
| `backup.enabled`             | Create the backup volume and render the backup configuration keys     | `false`                |
| `backup.existingClaim`       | Use an existing claim instead of creating `<fullname>-backup`         | `""`                   |
| `backup.storageClass`        | Storage class for the backup claim (same three-way rule as above)     | `""`                   |
| `backup.accessMode`          | Backup PVC access mode                                               | `ReadWriteOnce`        |
| `backup.size`                | Backup PVC size                                                      | `5Gi`                  |
| `backup.path`                | Mount path and `database_backup_path`; keep it off the data volume    | `/backups`             |
| `backup.keep`                | `database_backups_to_keep`; older backups are pruned after a new one  | `7`                    |
| `backup.scheduled`           | Add the SIGUSR2 cron sidecar and its crontab ConfigMap               | `false`                |
| `backup.schedule`            | Five-field cron expression for the sidecar                           | `0 3 * * *`            |
| `backup.command`             | The admin command a SIGUSR2 runs (`admin_signal_execute`)            | `server backup-database` |
| `backup.sidecar.resources`   | Resources for the cron sidecar                                       | 10m/32Mi requests, 100m/64Mi limits |

Keep `backup.path` outside the data volume - a backup that shares a volume with the database does
not survive losing it.

The managed backup covers the database only: it does not include `media/` or any configured storage
provider, so back those up separately (a second volume, `restic`, or the provider's own bucket
replication) - otherwise a restore brings the database back without the files it references.

In the admin room (`!admin` commands; the backup commands live under the `server` group):

- `!admin server backup-database` - take a backup now;
- `!admin server list-backups` - what the backup repository holds;
- `!admin server verify-backup [id]` - check one backup (newest when the id is omitted);
- `!admin server delete-backups <keep>` - prune everything but the newest `<keep>`; the argument is
  a count, not a backup id, and `0` deletes every managed backup.

Restore a backup (verified end to end: the server restores `backup_id=1` into a fresh database path
and exits 0):

```console
# 1. stop the server
kubectl scale statefulset/<fullname> --replicas=0

# 2. start it once in restore mode: --restore-backup [<id>] picks the newest by default,
#    --maintenance keeps client traffic out, --execute runs one admin command and exits
helm upgrade my-release tuwunel/tuwunel -f values.yaml \
  --set 'args={--restore-backup,--maintenance,--execute,server shutdown}'

# 3. watch it
kubectl logs -f statefulset/<fullname>
#    ... "Restoring database backup backup_id=..." then "Restored database backup"

# 4. back to normal: drop args again (the upgrade restores replicas: 1) and confirm the pod is up
helm upgrade my-release tuwunel/tuwunel -f values.yaml
kubectl scale statefulset/<fullname> --replicas=1
```

`args` is appended to the container command, and `tuwunel --help` lists the other flags that go
with it: `--read-only`, `--maintenance`, `--health-check`, `--restore-backup [<id>]`,
`--execute <command>`, `--generate-config`, `--regenerate-config`.

### Media Storage (local and S3)

Without configuration, media lives in a `media/` subdirectory of the database path on the data
volume (the chart renders `TUWUNEL_DATABASE_PATH`, `/data/db` by default; the volume is mounted at
`/data`). Nothing to configure for a single-node install with the data volume as the only store.

An S3-compatible provider is a passthrough config block plus the credentials through envsubst:

```yaml
envFromSecret:
  S3_ACCESS_KEY: tuwunel-secrets/S3_ACCESS_KEY
  S3_SECRET_KEY: tuwunel-secrets/S3_SECRET_KEY

config:
  global:
    ## Name the provider here or it is never used
    media_storage_providers: ["media", "media_on_s3"]
    ## Where new media is written while old media is still read from "media"
    store_media_on_providers: ["media_on_s3"]
    storage_provider:
      media_on_s3:
        s3:
          url: "s3://tuwunel-media/matrix"          # or bucket/region/base_path separately
          endpoint: "https://s3.example.com"        # self-hosted / non-AWS endpoints
          region: "us-east-1"
          key: "${S3_ACCESS_KEY}"
          secret: "${S3_SECRET_KEY}"
          # startup_check: false
```

- `media_storage_providers` is what makes the provider exist; `store_media_on_providers` decides
  which of the listed providers new media goes to. Listing `media` as a fallback keeps existing
  uploads reachable.
- Credentials are placeholders - `${S3_ACCESS_KEY}` is substituted by the init container's envsubst
  from `env`/`envRaw`/`envFromSecret` (see
  [Using Secrets for Configuration](#using-secrets-for-configuration)), so the bucket keys never
  have to be written into a values file.
- The provider-level `startup_check` (upstream default `true`) pings the bucket while the server
  starts and aborts the start when it is unreachable. Turn it off only when the store is expected
  to be down while the homeserver boots.
- Other provider keys from `tuwunel --generate-config` work as-is: `base_path`, `use_vhost_request`,
  `token`, `kms`, `use_bucket_key`.
- To migrate an existing install without downtime, list both providers, point
  `store_media_on_providers` at the new one, then run `!admin query storage sync <src> <dst>` to
  copy the old media across.

### Client IP behind a proxy

`config.global.ip_source` decides where tuwunel reads the client IP from. Rate limiting, invites and
moderation all read it. Unset means `connect_info`: the address of whoever opened the TCP
connection, which behind an ingress is the proxy - every client then looks like the same IP.

```yaml
config:
  global:
    ip_source: rightmost_x_forwarded_for
    ip_source_trusted_subnets:
      - 10.42.0.0/16
```

The accepted values are `connect_info`, `rightmost_x_forwarded_for`, `rightmost_forwarded`,
`x_real_ip`, `cf_connecting_ip`, `true_client_ip`, `fly_client_ip` and
`cloudfront_viewer_address`; anything else makes tuwunel exit at startup (`unknown variant ...,
expected one of ...`).

Header-based sources are only correct when the proxy sets the header on **every** request. Verified
on v1.9.2 with `ip_source: rightmost_x_forwarded_for`:

- a request that needs the client IP and arrives without the header is answered
  `500 M_UNKNOWN` / `Can't extract client IP from configured ip_source` (checked with
  `POST /_matrix/client/v3/register` and `/_matrix/client/v3/login`);
- paths that do not need it, such as `/_tuwunel/server_version` and `/_matrix/client/versions`,
  still answer 200;
- startup logs a warning:
  `ip_source is set to RightmostXForwardedFor, a header-based source. Ensure a trusted reverse
  proxy populates this header for every request; otherwise clients can spoof their IP address.`

`ip_source_trusted_subnets` is the escape hatch for peers whose connection address is already
trustworthy: they bypass `ip_source` entirely. Put the in-cluster pod CIDR there so probes and
in-cluster calls do not depend on a header. Any peer inside those subnets can forge the client IP
through headers, so only list networks you control end to end. Changing the list requires a restart.

### Registration and the first user

Registration is closed by default (`config.global.allow_registration: false`) and the chart no
longer ships a default token. A registration attempt against a closed server is answered
`403 M_FORBIDDEN: Registration has been disabled.`

To create the first user with a token, keep the token in a Secret and let envsubst expand it:

```yaml
envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN

config:
  global:
    allow_registration: true
    registration_token: "${REGISTRATION_TOKEN}"
```

or point `registration_token_file` at a file on the pod (mounted through `extraVolumes` /
`extraVolumeMounts`); multiple whitespace-separated tokens are accepted there.

A placeholder never fails silently in a way that opens the server: a missing or typo'd environment
variable expands to `registration_token = ""`, and v1.9.2 then refuses to start with
`Registration token was specified but is empty ("")` and
`There was a problem with the 'registration_token' directive in your configuration`. A broken secret
is loud, not an open server.

The client flow is the standard Matrix UIAA one: `POST /_matrix/client/v3/register` without a token
answers `401` with `{"flows":[{"stages":["m.login.registration_token"]}], "session": "..."}`, and
the same request with `"auth": {"type": "m.login.registration_token", "token": "..."}` creates the
account and returns an access token. Turn `allow_registration` back off once the accounts you need
exist.

Two related keys, both from `tuwunel --generate-config`:

- `registration_shared_secret` (or `registration_shared_secret_file`) enables out-of-band account
  creation through the Synapse-style `/_synapse/admin/v1/register` endpoint, authenticated by
  HMAC-SHA1 with that secret. Treat it as equivalent to an admin access token.
- Open registration without any token requires **both** `allow_registration: true` and
  `yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse: true`; with only the
  first, startup fails demanding the second. This is not the recommended path.

### Probes and database migrations

All three probes are exec probes running `tuwunel --health-check` inside the container, which asks
the running server whether it is healthy instead of dialing a path that may answer for an
unrelated reason.

| Parameter                        | Description                                                            | Default                                 |
| -------------------------------- | ---------------------------------------------------------------------- | --------------------------------------- |
| `probes.startup`                 | First-start probe; covers the one-time database migration               | `enabled: true`, 10s x 180 = 30 minutes |
| `probes.readiness`               | Readiness probe                                                         | `enabled: true`, 10s, threshold 3       |
| `probes.liveness`                | Liveness probe                                                          | `enabled: true`, 10s, threshold 3       |

Each block takes `enabled`, `periodSeconds`, `timeoutSeconds`, `failureThreshold` and
`initialDelaySeconds`; the defaults are `true/10/5/180/0` for the startup probe and
`true/10/5/3/0` for readiness and liveness.

The first start after a homeserver upgrade runs a **one-time blocking database migration** before
the server listens. Two settings exist so it can finish:

- the startup probe allows 30 minutes (10 s x 180), the budget upstream's own deployment guidance
  asks for, and the readiness probe stays out of the way until then;
- `terminationGracePeriodSeconds` defaults to 1800. A SIGKILL in the middle of the migration
  leaves the database half-migrated, not merely slow to start, and Kubernetes' default grace period
  of 30 s would do exactly that.

On a node with many cores, watch the pool size: upstream's `db_pool_max_workers` default of 2048
can exceed the pod's task limit and fail startup with `EAGAIN`. Setting
`config.global.db_pool_max_workers` to roughly the CPU limit (for example `64`) is plenty and
removes the failure mode on large machines.

### Pod Configuration

| Parameter                          | Description                                                     | Default  |
| ---------------------------------- | --------------------------------------------------------------- | -------- |
| `terminationGracePeriodSeconds`    | Grace period; has to cover the one-time migration                | `1800`   |
| `args`                             | Extra arguments for the tuwunel container (restore recipe)        | `[]`     |
| `podLabels`                        | Labels added to the pod template                                  | `{}`     |
| `podAnnotations`                   | Annotations added to the pod template                             | `{}`     |
| `priorityClassName`                | Pod `priorityClassName`, applied when set                         | `""`     |
| `nodeSelector`                     | Node labels for pod assignment                                    | `{}`     |
| `tolerations`                      | Toleration labels for pod assignment                              | `[]`     |
| `affinity`                         | Affinity settings for pod assignment                              | `{}`     |
| `extraVolumes`                     | Extra volumes for the tuwunel container                           | `[]`     |
| `extraVolumeMounts`                | Extra mounts; each entry needs `name` and a `mountPath`           | `[]`     |
| `extraLabels`                      | Additional labels for all resources                               | `{}`     |
| `statefulsetAnnotations`           | Annotations for the StatefulSet                                   | `{}`     |

`extraVolumeMounts` entries are appended after the chart's own mounts; a `name` has to match one of
`extraVolumes` or one of the chart's volumes (`data`, `config-template`, `config`, `tmp`, `backup`).
The pod template always carries a `checksum/config` annotation over the rendered configuration and
the environment, so a values edit rolls the pod.

### Resource Configuration

| Parameter              | Description                   | Default         |
| ---------------------- | ----------------------------- | --------------- |
| `resources.requests`   | CPU/Memory resource requests  | 50m/128Mi       |
| `resources.limits`     | CPU/Memory resource limits    | 1/512Mi         |

The CPU limit also derives the thread counts the chart passes to the server
(`TOKIO_WORKER_THREADS` and `TUWUNEL_ROCKSDB_PARALLELISM_THREADS`).

### Verifying the deployment

The chart ships a `helm test` hook: a busybox pod that fetches
`http://<fullname>.<namespace>.svc:<service.port>/_tuwunel/server_version` from inside the cluster,
which is the one check a rendered manifest cannot make.

```console
helm test my-release
```

Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example,

```console
helm install my-release \
	--set ingress.enabled=true \
	tuwunel/tuwunel
```

Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart. For example,

```console
helm install my-release -f values.yaml tuwunel/tuwunel
```

Read through the [values.yaml](values.yaml) file for all available options.

## Matrix RTC (Element Call) Support

This chart supports Matrix RTC via LiveKit for Element Call functionality. This enables audio/video calling features in Element Web and other Matrix clients.

### Prerequisites

1. **Create Kubernetes secret with LiveKit credentials:**

```bash
LIVEKIT_KEY=$(openssl rand -hex 10)
LIVEKIT_SECRET=$(openssl rand -hex 32)

kubectl create secret generic livekit-secrets \
  --from-literal=LIVEKIT_KEY=$LIVEKIT_KEY \
  --from-literal=LIVEKIT_SECRET=$LIVEKIT_SECRET
```

2. **Configure DNS for the RTC domain.** Where it has to point depends on the network mode:
   `rtc.domain` resolves to the node IP in `hostNetwork` mode and to the Service address in `pod`
   mode (see [Network modes](#network-modes)).

3. **Nothing else.** `LIVEKIT_URL`, `LIVEKIT_FULL_ACCESS_HOMESERVERS`, the LiveKit webhook URL,
   the LiveKit `keys` entry and `config.global.well_known.livekit_url` all follow from `rtc.domain`
   and `server_name`.

### Basic Configuration

Add the following to your `values.yaml`:

```yaml
server_name: "yourdomain.com"

rtc:
  enabled: true
  domain: "matrix-rtc.yourdomain.com"

  jwt:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET

  livekit:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET

  ingress:
    enabled: true
    class: nginx
    tls: true
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
```

### What the chart derives

Every value below is used only when you did not set it yourself, so an existing configuration keeps
working:

- JWT service (`rtc.jwt.env`): `LIVEKIT_URL` = `wss://<rtc.domain>`,
  `LIVEKIT_FULL_ACCESS_HOMESERVERS` = `server_name` (mandatory in lk-jwt-service 0.7.0, which used
  to default it to `*`), `LIVEKIT_JWT_BIND` = `:8080`.
- LiveKit config (`rtc.livekit.config`): `keys` = `{"${LIVEKIT_KEY}": "${LIVEKIT_SECRET}"}`,
  `room.auto_create: false` and `webhook.api_key: "${LIVEKIT_KEY}"`,
  `webhook.urls: ["http://<fullname>-jwt:8080/sfu_webhook"]`. That is the pairing lk-jwt-service
  expects: rooms are not created by a token request, and LiveKit reports room events back to the
  service over the webhook.
- Homeserver config: `config.global.well_known.livekit_url = https://<rtc.domain>` when
  `rtc.enabled` is true and neither `livekit_url` nor `rtc_transports` is set.

`livekit_url` is what the client API endpoint
`/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` answers from. With it unset that
endpoint returns an empty transport list and clients report that no MatrixRTC transport is
configured ("no transport"), even when a `.well-known/matrix/client` document served by your
ingress looks correct. Set `config.global.well_known.rtc_transports` (the escape hatch for a
non-LiveKit focus) or `livekit_url` yourself to override the injected value; only one of the two
belongs in a config file.

### RTC ingress

With `rtc.ingress.enabled: true`, the host `rtc.domain` routes to the JWT service for
`/get_token`, `/sfu/get`, `/healthz`, `/delegate_delayed_leave` and `/sfu_webhook`, and everything
else to LiveKit. `/get_token` is the lk-jwt-service 0.7.0 entry point; `/sfu/get` is the older
one and is kept for clients that still call it. The annotations set on the ingress are the
websocket/read-timeout ones plus `nginx.ingress.kubernetes.io/proxy-buffering: "off"`; your own
`rtc.ingress.annotations` are applied last and win.

The same host can be served by an `HTTPRoute` instead: `rtc.gateway.enabled` with
`rtc.gateway.parentRefs`, and `rtc.livekit.gateway.udpRoute`/`tcpRoute` for the media ports in `pod`
mode. The routing table and the JWT paths are identical in both cases - see
[RTC on the Gateway API](#rtc-on-the-gateway-api).

### Network Modes

`rtc.livekit.networkMode` chooses how media reaches the server:

**`hostNetwork` (default)** - the pod shares the node's network namespace, so clients connect to
the node IP that `rtc.domain` resolves to, and every port below is a node port that needs a
firewall rule:

- `7880/tcp` - HTTP API
- `7881/tcp` - RTC TCP (`config.rtc.tcp_port`)
- `50100-50200/udp` - RTC UDP media range (`config.rtc.port_range_start`/`port_range_end`)

The chart sets `dnsPolicy: ClusterFirstWithHostNet` in this mode, otherwise a hostNetwork pod keeps
the node's resolver and cannot resolve the `<fullname>-jwt` Service it posts webhooks to. ICE
candidates come from `config.rtc.use_external_ip: true` (default, asks an external service for the
address) or from `config.rtc.node_ip` with `use_external_ip: false`; `external_ip_only: true` drops
the host's private/bridge interfaces from the candidates when clients are offered unreachable
`docker0` addresses.

**`pod`** - media goes through the Service in `rtc.livekit.service` (`ClusterIP`, `NodePort` or
`LoadBalancer`). A Kubernetes Service forwards one port per entry, never a range, so the media port
has to collapse into a single multiplexed UDP port:

- set `config.rtc.udp_port` to a single port (for example `7882`); the render fails if it holds a
  range, and it also fails when a range is configured without any `udp_port`, because media would
  have no path to the pod;
- use `externalTrafficPolicy: Local` on a `NodePort`/`LoadBalancer` so clients reach the node that
  actually hosts the pod;
- candidates come from `config.rtc.node_ip` (or `use_external_ip: true`), and `rtc.domain` has to
  resolve to the Service address rather than a node.

In both modes the LiveKit pod and the JWT service take `nodeSelector`, `tolerations`, `affinity`
and `podAnnotations` (`rtc.livekit.*`, `rtc.jwt.*`). `hostNetwork` pins the RTC endpoint to one
node, so this is where you pin LiveKit to the node whose address `rtc.domain` names.

TURN: pass an external TURN server through to clients with `rtc.livekit.config.rtc.turn_servers`
(`host`, `port`, `protocol`, `secret`), or run LiveKit's own TURN server with
`rtc.livekit.config.turn.*` - the latter needs its own UDP ports reachable from the internet
(`udp_port`, `relay_range_start`/`relay_range_end`).

### RTC Configuration Parameters

| Parameter                              | Description                                           | Default                    |
| -------------------------------------- | ----------------------------------------------------- | -------------------------- |
| `rtc.enabled`                          | Enable Matrix RTC support                             | `false`                    |
| `rtc.domain`                           | RTC domain for LiveKit services                       | `""`                       |
| `rtc.jwt.image.repository`             | JWT service image                                     | `ghcr.io/element-hq/lk-jwt-service` |
| `rtc.jwt.image.tag`                    | JWT service image tag                                 | `0.7.0`                    |
| `rtc.jwt.resources`                    | JWT service resources                                 | 50m-200m/128Mi-256Mi       |
| `rtc.jwt.env`                          | JWT service environment variables (defaults derived)  | `{}`                       |
| `rtc.jwt.envRaw`                       | Raw environment variable sections                     | `[]`                       |
| `rtc.jwt.envFromSecret`                | JWT service env from secrets                          | `{}`                       |
| `rtc.jwt.podAnnotations`               | Annotations for the JWT pod                           | `{}`                       |
| `rtc.jwt.nodeSelector`                 | Node labels for the JWT pod                           | `{}`                       |
| `rtc.jwt.tolerations`                  | Tolerations for the JWT pod                           | `[]`                       |
| `rtc.jwt.affinity`                     | Affinity for the JWT pod                              | `{}`                       |
| `rtc.livekit.image.repository`         | LiveKit server image                                  | `livekit/livekit-server`   |
| `rtc.livekit.image.tag`                | LiveKit server image tag                              | `v1.13.7`                  |
| `rtc.livekit.resources`                | LiveKit server resources                              | 50m-1/128Mi-1Gi            |
| `rtc.livekit.networkMode`              | `hostNetwork` or `pod`                                | `hostNetwork`              |
| `rtc.livekit.gateway.udpRoute`         | `UDPRoute` for `config.rtc.udp_port`                  | `false`                    |
| `rtc.livekit.gateway.tcpRoute`         | `TCPRoute` for `config.rtc.tcp_port`                  | `false`                    |
| `rtc.livekit.gateway.parentRefs`       | Gateways the media routes attach to                   | `[]`                       |
| `rtc.livekit.gateway.annotations`      | Annotations for the media routes                      | `{}`                       |
| `rtc.livekit.env`                      | LiveKit environment variables                         | `{}`                       |
| `rtc.livekit.envRaw`                   | Raw environment variable sections                     | `[]`                       |
| `rtc.livekit.envFromSecret`            | LiveKit env from secrets (needs `LIVEKIT_KEY`/`LIVEKIT_SECRET`) | `{}`              |
| `rtc.livekit.podAnnotations`           | Annotations for the LiveKit pod                       | `{}`                       |
| `rtc.livekit.nodeSelector`             | Node labels for the LiveKit pod                       | `{}`                       |
| `rtc.livekit.tolerations`              | Tolerations for the LiveKit pod                       | `[]`                       |
| `rtc.livekit.affinity`                 | Affinity for the LiveKit pod                          | `{}`                       |
| `rtc.livekit.service.type`             | LiveKit Service type (used in `pod` mode)             | `ClusterIP`                |
| `rtc.livekit.service.annotations`      | LiveKit Service annotations                           | `{}`                       |
| `rtc.livekit.service.externalTrafficPolicy` | `Cluster` or `Local`; `Local` is what a LoadBalancer should use | `Cluster`    |
| `rtc.livekit.service.loadBalancerIP`   | Load balancer IP for the LiveKit Service              | `""`                       |
| `rtc.livekit.service.loadBalancerSourceRanges` | Allowed CIDRs for the LiveKit Service         | `[]`                       |
| `rtc.livekit.config.port`              | HTTP API port                                         | `7880`                     |
| `rtc.livekit.config.rtc.tcp_port`      | RTC TCP port                                          | `7881`                     |
| `rtc.livekit.config.rtc.port_range_start` | UDP port range start (hostNetwork)                 | `50100`                    |
| `rtc.livekit.config.rtc.port_range_end` | UDP port range end (hostNetwork)                     | `50200`                    |
| `rtc.livekit.config.rtc.udp_port`      | Single multiplexed UDP port (required in `pod` mode)  | unset                      |
| `rtc.livekit.config.rtc.use_external_ip` | Ask an external service for the advertised IP       | `true`                     |
| `rtc.livekit.config.rtc.node_ip`       | Address advertised to clients when `use_external_ip` is false | unset              |
| `rtc.ingress.enabled`                  | Enable RTC ingress                                    | `false`                    |
| `rtc.ingress.class`                    | Ingress class; falls back to `ingress.class`          | `""`                       |
| `rtc.ingress.annotations`              | Extra ingress annotations (applied last)              | `{}`                       |
| `rtc.ingress.tls`                      | Enable TLS                                            | `false`                    |
| `rtc.ingress.tlsSecretName`            | TLS secret name (defaults to `<release-name>-rtc-tls`) | `""`                      |
| `rtc.gateway.enabled`                  | Enable the RTC HTTPRoute                              | `false`                    |
| `rtc.gateway.parentRefs`               | Gateways the RTC route attaches to                    | `[]`                       |
| `rtc.gateway.annotations`              | Annotations for the RTC HTTPRoute                     | `{}`                       |

### Deployment

```bash
helm install matrix tuwunel/tuwunel \
  -f values.yaml
```

### Troubleshooting

1. **Check pods are running:**
   ```bash
   kubectl get pods -l app.kubernetes.io/name=tuwunel
   ```

2. **Check the LiveKit Service:**
   ```bash
   kubectl get svc -l app.kubernetes.io/component=rtc-livekit
   ```

3. **Check that the homeserver advertises a transport:**
   ```bash
   curl https://yourdomain.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports
   ```
   An empty `rtc_transports` list means `livekit_url` is missing from the rendered `config.toml`,
   not that LiveKit is down.

4. **Check logs:**
   ```bash
   kubectl logs -l app.kubernetes.io/component=rtc-jwt
   kubectl logs -l app.kubernetes.io/component=rtc-livekit
   ```

## Using with Other Conduit Forks

This chart is primarily designed for tuwunel but can work with other Conduit forks like Continuwuity. To override the image:

```yaml
image:
  repository: ghcr.io/continuwuity/continuwuity
  tag: latest
```

Note that the chart's env, probe and configuration contract targets tuwunel v1.9.0 or newer
(`TUWUNEL_*`, `tuwunel --health-check`, `config.toml`): a fork without those will need `env`,
`extraEnv` and `probes.*.enabled` adjustments.

## Using Secrets for Configuration

Sensitive configuration reaches `config.toml` as a `${VAR}` placeholder that the init container
substitutes with `envsubst` before the server starts:

```yaml
envFromSecret:
  EMERGENCY_PASSWORD: my-secret/emergency-password

config:
  global:
    emergency_password: "${EMERGENCY_PASSWORD}"
```

The variables come from `env`, `envRaw` and `envFromSecret`, and the same set is exported on the
tuwunel container as well, so a `${VAR}` placeholder and a direct environment reference always
carry the same value. There is no `{__env: X}` key - a placeholder the environment does not define
expands to the empty string, which makes the rendered value empty rather than falling back to
anything (and for `registration_token`, an empty token stops startup; see
[Registration and the first user](#registration-and-the-first-user)).

## Examples

### Basic Installation with Ingress

```yaml
server_name: "matrix.example.org"

ingress:
  enabled: true
  class: nginx
  tls: true
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"

envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN

config:
  global:
    allow_registration: true
    registration_token: "${REGISTRATION_TOKEN}"
```

### With Federation Enabled

```yaml
server_name: "matrix.example.org"

config:
  global:
    allow_federation: true
    trusted_servers:
      - "matrix.org"

ingress:
  enabled: true
  class: nginx
  tls: true
```

### Production Deployment

```yaml
server_name: "matrix.example.org"

image:
  tag: "v1.9.2"

persistence:
  data:
    size: 50Gi
    storageClass: "fast-ssd"

resources:
  requests:
    cpu: "200m"
    memory: "512Mi"
  limits:
    cpu: "2"
    memory: "2Gi"

ingress:
  enabled: true
  class: nginx
  tls: true
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"

backup:
  enabled: true
  size: 20Gi
  scheduled: true
  keep: 14

config:
  global:
    allow_registration: false
    allow_federation: true
    log: "info"
```

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](../../LICENSE) file for details.

## Credits

Based on [modern-conduwuit-helm](https://github.com/magikid/modern-conduwuit-helm) by [magikid](https://github.com/magikid).

## Additional Resources

- [Tuwunel GitHub](https://github.com/matrix-construct/tuwunel)
- [Matrix Protocol](https://matrix.org/)
- [Element Call Documentation](https://call.element.io/)
- [LiveKit Documentation](https://docs.livekit.io/)
- [lk-jwt-service](https://github.com/element-hq/lk-jwt-service)
