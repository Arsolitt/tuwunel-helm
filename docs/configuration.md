# Configuring the server

> How your values become the server's `config.toml`: the `config` passthrough, the four environment
> sources, secret placeholders, TOML shape rules, and the two gates that reject a broken
> configuration before the pod starts.

## Table of Contents

- [How a values file becomes `config.toml`](#how-a-values-file-becomes-configtoml)
- [The `config` block](#the-config-block)
- [Environment variables](#environment-variables)
- [Secret placeholders](#secret-placeholders)
- [TOML shapes](#toml-shapes)
- [Validation](#validation)
- [Common configurations](#common-configurations)
- [Where to find every value](#where-to-find-every-value)

---

## How a values file becomes `config.toml`

The chart has two configuration layers, and they meet in one file inside the pod:

- **Data** — everything under `config` is passed through to the server as TOML. The chart deep-copies
  `Values.config`, amends four keys in it when it has something to derive, and serialises the result
  with `toToml` into the ConfigMap key `config.toml`.
- **Environment** — the chart-owned contract (`TUWUNEL_CONFIG`, `TUWUNEL_SERVER_NAME`,
  `TUWUNEL_PORT`, `TUWUNEL_ADDRESS`, `TUWUNEL_DATABASE_PATH`, the two thread counts) is set as
  environment variables. Where both layers could decide a value, the environment wins, which is why
  the render refuses a conflicting `config.global.port` instead of ignoring it (see
  [Validation](#validation)).

The ConfigMap holds the *template*, not the final file. Substitution is deliberately deferred to pod
start so that secrets referenced from the configuration never land in a ConfigMap:

```text
values.yaml  (config: ...)
   │  helm template / helm install
   ▼
ConfigMap <fullname>-configmap            data: config.toml  = toToml(config), ${VAR} kept verbatim
   │  volume "config-template" (ConfigMap volume), mounted at /tmp/config-template
   ▼
init container "config-processor"   (dibi/envsubst:1)
   │  envsubst < /tmp/config-template/config.toml > /tmp/config/config.toml
   ▼
emptyDir "config"  →  /tmp/config/config.toml  in the "tuwunel" container
   │  TUWUNEL_CONFIG=/tmp/config/config.toml
   ▼
tuwunel v1.9.2
```

Two consequences follow from that picture:

- the ConfigMap is **never mounted into the server container** — the server reads the substituted
  copy from the `emptyDir` at `/tmp/config/config.toml`;
- the substitution happens at pod start, so a `${VAR}` placeholder is visible **verbatim** in the
  rendered ConfigMap. Rendering the [registration example](#registration-with-a-secret-token) shows:

```toml
[global]
  address = "::"
  allow_federation = false
  allow_registration = true
  log = "info"
  registration_token = "${REGISTRATION_TOKEN}"
  trusted_servers = []
  [global.ldap]
  [global.tls]
  [global.well_known]
```

`envsubst` expands every `$NAME` and `${NAME}` occurrence in the file, not only the placeholders you
intended. There is no `{__env: X}` fallback syntax: a name the environment does not define expands to
the **empty string**. That also means a literal `$` in a value is at risk — reproduced with the
chart's init image, `$HOME` becomes `/root`, `${MISSING}` becomes empty and `pa$$word` becomes
`pa$`. Keep `$` out of passwords, regexes and bucket keys, or read them from a file instead.

To see what a values file actually produces before installing:

```console
$ helm template tuwunel charts/tuwunel -f values.yaml --show-only templates/tuwunnel/configmap.yaml
```

And to see what the server really reads — note that the running container cannot be asked: the
image holds only `/usr/bin/tuwunel`, so there is no shell and no `cat` to read
`/tmp/config/config.toml` with:

```console
# the template, with the ${VAR} placeholders still unresolved
$ kubectl get configmap tuwunel-configmap -o jsonpath='{.data.config\.toml}'

# the effective configuration the server loaded, values substituted (admin room console)
!admin server show-config
```

> **Note:** the init container needs `dibi/envsubst:1`, which is published for `linux/amd64` only.
> On an arm64 node, mirror the image or pin the pod to an amd64 node — the pod does not start
> otherwise. See [Installing the chart](./installation.md).

`<fullname>` in that diagram is the usual Helm derivation: `fullnameOverride` when set, otherwise
the release name if it contains `tuwunel`, otherwise `<release>-tuwunel`. With a release named
`tuwunel` the ConfigMap is `tuwunel-configmap` — the name used in the command above — and the
pod is `tuwunel-0`.

## The `config` block

`config` is a passthrough with `additionalProperties: true`: any upstream tuwunel/Conduit key is
accepted as long as it is valid TOML. The chart pins types for the keys below because they either
stop the server from starting when mistyped, or because the chart also derives them from a value of
its own.

| Key | Pinned type | Default | What happens when you set it |
| --- | --- | --- | --- |
| `config.global.address` | string, or list of strings | `"::"` | Written to `config.toml` **and** passed as `TUWUNEL_ADDRESS` (JSON-encoded). An address that cannot be bound kills the server: v1.9.2 exits 1 with `Failed to bind <addr>: Cannot assign requested address (os error 99)`. |
| `config.global.allow_registration` | boolean | `false` | Must be a TOML boolean. Opening registration needs a token (`registration_token` / `registration_token_file`), or the explicit `yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse` opt-in — with neither, startup fails. |
| `config.global.allow_federation` | boolean | `false` | Must be a TOML boolean. Federation is off unless you turn it on; see [Federation and delegation](./federation.md). |
| `config.global.trusted_servers` | string list (not shape-checked) | `[]` | Written as-is; matters only while federating. |
| `config.global.log` | non-empty string | `"info"` | The only log-level knob — there is no `RUST_LOG` in tuwunel. The documented levels are `trace`, `debug`, `info`, `warn`, `error`. |
| `config.global.ip_source` | enum of 8 values | unset (server default `connect_info`) | Read the client IP from a proxy header. A misspelled value is rejected at render time; an unset value makes every client look like the ingress. |
| `config.global.ip_source_trusted_subnets` | string list | unset | Peers in these CIDRs keep their connection address instead of the header value — the in-cluster pod CIDR belongs here. |
| `config.global.db_pool_max_workers` | integer ≥ 1 | unset (upstream `2048`) | RocksDB worker/pool size. Upstream's default can exceed the pod's task limit on a many-core node and fail startup with `EAGAIN`; roughly the CPU limit is plenty. |
| `config.global.server_name` | string or number | unset | Compatibility key. If set, it must equal the top-level `server_name` or the render fails. |
| `config.global.port` | string or integer | unset | Compatibility key. If set, it must equal `service.port` or the render fails. |
| `config.global.tls` | table | `{}` | Server-side TLS, raw pass-through — the chart neither manages nor validates it. Ingress TLS is a separate value; see [Secrets and hardening](./security.md). |
| `config.global.well_known` | table | `{}` | Client/server delegation and RTC discovery; the chart injects `livekit_url` here when RTC is enabled. |
| `config.global.ldap` | table | `{}` | LDAP configuration, pass-through. |

Everything else under `config` — including the whole top level of upstream's file — is written
as-is. Keys outside `global` are emitted **before** the `[global]` table, so they become root TOML
keys. A values file with `config.media_storage_providers: ["media_on_s3"]` renders:

```toml
media_storage_providers = ["media_on_s3"]

[global]
  address = "::"
  ...
```

### Keys the chart derives

Four keys are injected **only when you have not set them yourself**, so your value always wins:

| Key | Injected when | Value |
| --- | --- | --- |
| `global.well_known.livekit_url` | `rtc.enabled` and `rtc.domain` are set, and you set neither `livekit_url` nor `rtc_transports` | `https://<rtc.domain>` |
| `global.database_backup_path` | `backup.enabled` | `backup.path` |
| `global.database_backups_to_keep` | `backup.enabled` | `backup.keep` |
| `global.admin_signal_execute` | `backup.enabled` and `backup.scheduled` | `[<backup.command>]` (a TOML array) |

Nothing else in the file is written or rewritten by the chart: the injection surface is exactly
those four keys plus the two equality rules in [Validation](#validation). Backup keys and the
scheduled-backup signal are covered in [Backups and restore](./backups.md); the RTC injection in
[Matrix RTC with LiveKit](./rtc.md).

### The default file

With the chart defaults the rendered ConfigMap contains exactly this (three empty tables included,
because the chart's defaults declare them):

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

## Environment variables

Four values feed the containers' environments. All four end up as environment variables, but they do
**not** behave the same way — the difference is which container sees them, and whether a change rolls
the pod.

| Value | Shape | Reaches | Notes |
| --- | --- | --- | --- |
| `env` | `map<string, string\|number\|boolean>` | init container **and** server | Scalars are quoted into strings (`NUM: 42` → `"42"`, `BOOL: false` → `"false"`); entries are emitted in alphabetical key order. |
| `envRaw` | list of Kubernetes `EnvVar` objects | init container **and** server | `toYaml` pass-through, so `valueFrom` / `fieldRef` and the other `EnvVarSource` forms all work; only `name` is required. |
| `envFromSecret` | `map<NAME, "<secret>/<key>">` | init container **and** server | Rendered as a `secretKeyRef` **without a namespace**, so the Secret must live in the release namespace. |
| `extraEnv` | list of `{name, value}` | server only, appended last | No `valueFrom`; both `name` and `value` are required by the schema. |

`envFromSecret` is the one with a syntax of its own: the value is `secretName/KEY`, split on `/`
into the secret name and the key, and it must match `^[^/]+/[^/]+$` — exactly one slash.

```yaml
envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN
```

```console
$ kubectl create secret generic tuwunel-secrets \
    --from-literal=REGISTRATION_TOKEN=...
```

### Variables the chart owns

These are written on the server container by the chart. Do not set them yourself:

| Variable | Value |
| --- | --- |
| `TUWUNEL_CONFIG` | `/tmp/config/config.toml` |
| `TUWUNEL_SERVER_NAME` | the top-level `server_name`. Emptied (`server_name: ""`) it never reaches this guard: the schema rejects first with `- at '/server_name': minLength: got 0, want 1`. The template's own `required` message, `You must set a server name otherwise no one will be able to reach you`, is what fails under `--skip-schema-validation`. |
| `TUWUNEL_DATABASE_PATH` | `config.global.database_path` if set, otherwise `/data/db` |
| `TUWUNEL_PORT` | `service.port` |
| `TUWUNEL_ADDRESS` | `config.global.address`, JSON-encoded (the default renders as the literal `"::"`, quotes included) |
| `TOKIO_WORKER_THREADS` | derived from `resources.limits.cpu` |
| `TUWUNEL_ROCKSDB_PARALLELISM_THREADS` | derived from `resources.limits.cpu` |

The `TUWUNEL_` prefix outranks the legacy `CONDUIT_` / `CONDUWUIT_` names, so a leftover
`CONDUWUIT_PORT` in `env` no longer decides the port. See [Upgrading](./upgrade.md) for that
breaking change and [How the chart renders a running server](./internals.md) for the CPU-limit
derivation (a fractional numeric limit such as `0.5` yields a fractional thread count; use the
`"500m"` form).

> **Warning:** putting one of these names into `env` or `extraEnv` makes the chart emit it twice in
> the same container, but nothing refuses it: the render exits 0, and the API server admits the pod.
> `kubectl` prints a warning that the later entry hides the earlier one —
> `Warning: spec.template.spec.containers[0].env[7]: hides previous definition of "TUWUNEL_PORT", which may be dropped when using apply`
> (the index is the entry's position in the container's `env` list). Which definition the server
> ends up with is therefore not something to rely on. Keep the chart's own variable names out of
> `env` and `extraEnv`.

### Which change restarts the server

The pod template carries a `checksum/config` annotation over the rendered ConfigMap plus `env`,
`envRaw` and `envFromSecret` — three of the four environment sources:

| You change | Pod rolls? |
| --- | --- |
| `config` (any key, including a derived one) | yes |
| `env`, `envRaw`, `envFromSecret` | yes |
| `extraEnv` | **yes** — the annotation does not change, but the variable it writes does |
| the *contents* of a Secret referenced by `envFromSecret` | **no** (`checksum/config` hashes the reference, not the Secret data) |

`extraEnv` is not part of `checksum/config`, so an `extraEnv`-only edit leaves the annotation
byte-identical — the annotation is the chart's roll trigger, not the only one. The extra variable
still renders into `containers[].env`, so the pod template changes and the StatefulSet
(`replicas: 1`, default `RollingUpdate`) replaces the pod. A rotated Secret is the case that does
not roll: the upgrade reports success and the running server keeps the old value until the next
restart. Rolling restart, and the fact that the first start after a homeserver upgrade also runs the
blocking database migration, are covered in [Day-2 operations](./operations.md).

> **Tip:** `extraEnv` reaches the server container only — it is not exported on the init container
> that runs `envsubst`. A `${VAR}` placeholder whose value you put in `extraEnv` therefore expands to
> the empty string; use `env`, `envRaw` or `envFromSecret` when a placeholder has to resolve.

## Secret placeholders

Sensitive configuration reaches `config.toml` as a `${VAR}` placeholder that the init container
resolves before the server starts. The pattern is always the same three parts: a Secret, an
`envFromSecret` entry naming it, and a placeholder in the `config` block.

```yaml
envFromSecret:
  EMERGENCY_PASSWORD: my-secret/emergency-password

config:
  global:
    emergency_password: "${EMERGENCY_PASSWORD}"
```

The variables exported on the init container and on the server container are the same three sets, so
a `${VAR}` placeholder and a direct environment reference always carry the same value.

An unset variable expands to the empty string — there is no error and no fallback. Whether that is
loud or silent depends on the key:

| Key | Result of an unset/typo'd variable |
| --- | --- |
| `registration_token` | Loud: v1.9.2 refuses to start with `Registration token was specified but is empty ("")` and `There was a problem with the 'registration_token' directive in your configuration`. |
| any other key (a password, an S3 key) | Silent: the rendered value is `""`, and the server starts with an empty credential. |

Registration specifically:

```yaml
server_name: "matrix.example.org"

envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN

config:
  global:
    allow_registration: true
    registration_token: "${REGISTRATION_TOKEN}"
```

Registration is closed by default and the chart ships no token. If you want the token in a file
instead, point `registration_token_file` at a path on the pod mounted through `extraVolumes` /
`extraVolumeMounts` (multiple whitespace-separated tokens are accepted there). Turn
`allow_registration` back off once the accounts you need exist. The client flow, the
`registration_shared_secret` variant and the open-registration opt-in are documented in
[Registration and the first user](../charts/tuwunel/README.md#registration-and-the-first-user); the
secret-handling rules (what belongs in a Secret, what does not) are in
[Secrets and hardening](./security.md).

## TOML shapes

`config` is a passthrough, so the schema cannot check the *shape* of a nested value — only its type
where the chart pins one. The shapes below are the ones that stop the server rather than the render.

### Array of tables (`[[...]]`) needs a YAML list

Upstream defines some keys as an **array of tables** (TOML `[[global.<key>]]`), e.g.
`[[global.identity_provider]]` and `[[global.well_known.rtc_transports]]`. Write those as a YAML
**list** — the `-` is what produces the double brackets.

```yaml
config:
  global:
    # WRONG: a mapping renders a single table
    # identity_provider:
    #   brand: Authentik
    #   client_id: my-client

    # RIGHT: a list renders [[global.identity_provider]]
    identity_provider:
      - brand: Authentik
        client_id: my-client
```

The difference in the rendered file is exactly one pair of brackets:

```toml
# mapping (wrong)
  [global.identity_provider]
    brand = "Authentik"
    client_id = "my-client"

# list (right)
  [[global.identity_provider]]
    brand = "Authentik"
    client_id = "my-client"
```

The wrong shape passes `helm lint`, `helm template` and any manifest validator, because nothing
reads `config.toml`. At runtime it is not the shape tuwunel deserializes: the chart README records
that v1.9.2 exits with

```text
invalid type: found string "Authentik", expected struct IdentityProvider for key "global.identity_provider.brand"
```

and the pod crash-loops with a deserialization message instead of a Helm error. The chart's
`hack/runtime-check.sh` (the `runtime` CI job) starts the real image precisely because it is the only
gate that reads the rendered configuration; see
[Troubleshooting](./troubleshooting.md) for reading that class of failure.

### Keys with opposite shapes

`config.global.well_known` has two neighbouring keys upstream gives deliberately different shapes,
and the chart validates neither:

| Key | Required shape |
| --- | --- |
| `well_known.client` | a **portless HTTPS URL**, e.g. `https://matrix.example.org` |
| `well_known.server` | a bare **`host:port`**, e.g. `matrix.example.org:443` — not a URL |

Both are only relevant when you delegate a domain; see [Federation and delegation](./federation.md).

### Booleans

Booleans must be TOML booleans. `allow_federation: "false"` renders `allow_federation = "false"` — a
string — and the server exits 1 at startup instead of starting with the wrong behaviour. The schema
catches this one before it can happen (next section).

## Validation

`values.schema.json` is enforced by the chart on every `helm lint`, `helm template` and
`helm install`; failure output looks like this (reproduced here from the chart's own fixtures):

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '<JSON pointer of the offending value>': <reason>
```

The root object sets `additionalProperties: false` and requires `server_name`, `image`, `config`,
`service`, `ingress`, `persistence`, `resources` and `rtc`. The classes of rejection you are most
likely to meet, with the exact message for each:

| Class | What you wrote | Rejection |
| --- | --- | --- |
| Unknown top-level key | `ingres:` (a misspelled block) | `- at '': additional properties 'ingres' not allowed` |
| Wrong scalar type | `config.global.allow_federation: "false"` | `- at '/config/global/allow_federation': got string, want boolean` |
| Bad enum | `config.global.ip_source: x_forwarded_for` | `- at '/config/global/ip_source': value must be one of 'connect_info', 'rightmost_x_forwarded_for', 'rightmost_forwarded', 'x_real_ip', 'cf_connecting_ip', 'true_client_ip', 'fly_client_ip', 'cloudfront_viewer_address'` |
| Bad pattern | `envFromSecret: {LIVEKIT_KEY: livekit-secrets}` | `- at '/envFromSecret/LIVEKIT_KEY': 'livekit-secrets' does not match pattern '^[^/]+/[^/]+$'` |
| Missing property | an `extraEnv` entry without a `value` — `charts/tuwunel/ci/invalid/extra-env-without-value.yaml` carries just `name` | `- at '/extraEnv/0': missing property 'value'` (a `valueFrom:` block in that position adds a second line, `- at '/extraEnv/0': additional properties 'valueFrom' not allowed` — from a render of such values, since the fixture itself stops at the first message) |
| Bad enum | `image.pullPolicy: ifnotpresent` | `- at '/image/pullPolicy': value must be one of 'Always', 'IfNotPresent', 'Never'` |
| Bad enum | `persistence.data.accessMode: RWO` | `- at '/persistence/data/accessMode': value must be one of 'ReadWriteOnce', 'ReadOnlyMany', 'ReadWriteMany', 'ReadWriteOncePod'` |
| Missing property | `resources: {limits: null}` | `- at '/resources': missing property 'limits'` |
| Below minimum | `backup.keep: 0` | `- at '/backup/keep': minimum: got 0, want 1` |
| Bad pattern | `backup.schedule: "0 3 * *"` (four fields) | `- at '/backup/schedule': '0 3 * *' does not match pattern '^\\s*\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s*$'` |
| Missing property | `rtc.enabled: true` without `rtc.domain` | `- at '/rtc/domain': minLength: got 0, want 1` |
| Bad enum | `rtc.livekit.networkMode: bridge` | `- at '/rtc/livekit/networkMode': value must be one of 'hostNetwork', 'pod'` |

Three properties of this gate are worth remembering:

- **It validates the merged values**, not your file alone — chart defaults fill in what you omit, so
  a partial block such as `probes: {startup: {enabled: false}}` is fine. The only way to make a
  defaulted key "missing" is to null it, which is how `resources: {limits: null}` fails.
- **It only knows what the chart pins.** `config` is a passthrough, so an unknown key inside
  `config`, a wrong TOML shape (see [TOML shapes](#toml-shapes)) or an unbindable address all render
  cleanly and are decided by the server at startup.
- `config.global.log` is only checked for being a non-empty string, so a level tuwunel does not
  recognise is not rejected here.

### Render-time guards

Rules the schema cannot express are enforced by the templates, and they fail the same
`helm template` / `helm install` — but with an `execution error` naming the template instead of a
schema pointer:

```text
Error: execution error at (tuwunel/templates/tuwunnel/statefulset.yaml:24:4): config.global.port (8008) must equal service.port (8080): the chart sets TUWUNEL_PORT from service.port
```

The same rule for the server name renders as `config.global.server_name (other.example) must equal
server_name (matrix.ci.example): the chart sets TUWUNEL_SERVER_NAME from server_name`; an empty
`server_name` is stopped by the schema first (`- at '/server_name': minLength: got 0, want 1`),
and only reaches the template's own guard — `You must set a server name otherwise no one will be
able to reach you` — when the schema is skipped (`--skip-schema-validation`).
Both exist because an environment variable beats the configuration file, so a differing config value
would be silently ignored — fix by deleting the duplicated key, not by changing the port. Other
render guards cover the Gateway API and RTC media routes; the error text and their fix sites are in
[Troubleshooting](./troubleshooting.md).

Each rule has a fixture in the repo that CI renders and expects to fail: schema cases under
`charts/tuwunel/ci/invalid/`, template cases under `charts/tuwunel/ci/invalid-render/`. They are
useful as minimal reproductions when your own values file is large. What no fixture can cover —
what the rendered `config.toml` *means* to the server — is the job of
`hack/runtime-check.sh`, which renders each scenario, runs the chart's own init container and boots
the real image.

## Common configurations

### Minimal install

Smallest supported configuration: no persistence (the data volume becomes an `emptyDir`), and both
registration and federation explicitly off, matching the chart defaults.

```yaml
server_name: matrix.ci.example

persistence:
  data:
    enabled: false

config:
  global:
    allow_registration: false
    allow_federation: false
```

### IPv4-only pod network

The default `address: "::"` is one dual-stack socket. A pod network without a usable IPv6 stack
needs `0.0.0.0` instead — a configured address that cannot be bound stops the server rather than
degrading it.

```yaml
server_name: matrix.ci.example

config:
  global:
    address: "0.0.0.0"
    allow_federation: false
```

### Registration with a secret token

Token registration for the first user; the token never appears in values. Turn
`allow_registration` back to `false` afterwards.

```yaml
server_name: "matrix.example.org"

envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN

config:
  global:
    allow_registration: true
    registration_token: "${REGISTRATION_TOKEN}"
```

### Offline server, federation disabled

Federation off is the default; making it explicit documents the intent, and `trusted_servers` stays
empty because it only applies when federating. Configure the worker pool when the node has many
cores.

```yaml
server_name: "matrix.example.org"

config:
  global:
    allow_registration: false
    allow_federation: false
    trusted_servers: []
    log: "info"
    db_pool_max_workers: 64
```

### Passthrough of a nested upstream table

Any upstream key works, including deeply nested tables that the schema does not know about. Media
storage on S3 is the canonical example; the credentials go through `envsubst`, so they belong in a
Secret.

```yaml
server_name: "matrix.example.org"

envFromSecret:
  S3_ACCESS_KEY: tuwunel-secrets/S3_ACCESS_KEY
  S3_SECRET_KEY: tuwunel-secrets/S3_SECRET_KEY

config:
  media_storage_providers: ["media_on_s3"]
  storage_provider:
    media_on_s3:
      s3:
        endpoint: "https://s3.example.com"
        bucket: "tuwunel-media"
        region: "us-east-1"
        key: "${S3_ACCESS_KEY}"
        secret: "${S3_SECRET_KEY}"
```

The chart injects nothing here — it is written into `config.toml` verbatim. See
[Storage and media](./storage-and-media.md) for `startup_check` and the rest of that block.

## Where to find every value

The complete value reference lives in the chart README, which ships inside the packaged chart:

| You need | Look at |
| --- | --- |
| Core values (`server_name`, image, `service.port`, `env`/`envRaw`/`envFromSecret`/`extraEnv`) | [chart README § Core Configuration](../charts/tuwunel/README.md#core-configuration) and [§ Environment Variables](../charts/tuwunel/README.md#environment-variables) |
| The `config` passthrough, pinned keys, bind address | [chart README § Tuwunel Configuration](../charts/tuwunel/README.md#tuwunel-configuration) |
| Backup keys injected into the configuration | [chart README § Backups and Recovery](../charts/tuwunel/README.md#backups-and-recovery) |
| Secrets-for-configuration pattern | [chart README § Using Secrets for Configuration](../charts/tuwunel/README.md#using-secrets-for-configuration) |
| Which values the chart derives from others | [chart README § What the chart derives](../charts/tuwunel/README.md#what-the-chart-derives) |
| Commented examples for every block | [`charts/tuwunel/values.yaml`](../charts/tuwunel/values.yaml) |
| Types, enums and required keys | [`charts/tuwunel/values.schema.json`](../charts/tuwunel/values.schema.json) |
| The template mechanics behind this page (mounts, env assembly, thread derivation, rollout annotation) | [How the chart renders a running server](./internals.md) |
