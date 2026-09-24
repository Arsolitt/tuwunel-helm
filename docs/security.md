# Secrets and hardening

> How secrets reach the server without landing in `values.yaml` or the ConfigMap, the security contexts each pod gets, and the hardening the chart leaves to you.

## Table of Contents

- [Secrets as environment variables](#secrets-as-environment-variables)
- [Secrets inside `config.toml`](#secrets-inside-configtoml)
- [Registration](#registration)
- [Client IP behind a proxy](#client-ip-behind-a-proxy)
- [Pod hardening](#pod-hardening)
- [Image pull secrets and scheduling](#image-pull-secrets-and-scheduling)
- [What the chart does not protect](#what-the-chart-does-not-protect)
- [Checklist](#checklist)

---

## Secrets as environment variables

The chart exposes four environment-variable values, all listed below. Only `envFromSecret` is a
supported secret channel - it renders a `secretKeyRef`. `envRaw` is a raw `EnvVar` list, so it can
carry a `secretKeyRef` you write yourself, and `extraEnv` cannot reference a Secret at all. `env` and
`extraEnv` therefore take literal values only. The value-level reference is
[Configuring the server](./configuration.md), and
[chart README § Environment Variables](../charts/tuwunel/README.md#environment-variables) has the
full wording of each value.

| Value | Default | Shape | Which containers get it |
| --- | --- | --- | --- |
| `envFromSecret` | `{}` | `VARIABLE: secret-name/key` | init container **and** tuwunel container |
| `env` | `{}` | `VARIABLE: value` literals | init container **and** tuwunel container |
| `envRaw` | `[]` | raw `EnvVar` list, passed through with `toYaml` | init container **and** tuwunel container |
| `extraEnv` | `[]` | `- name:` / `- value:` pairs | tuwunel container only, appended last |

`envFromSecret` is the one to use for credentials. The chart splits the value on `/` and renders a
`secretKeyRef`:

```yaml
envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN
```

```yaml
# rendered into the container spec
- name: REGISTRATION_TOKEN
  valueFrom:
    secretKeyRef:
      name: tuwunel-secrets
      key: REGISTRATION_TOKEN
```

`secretKeyRef` carries no namespace field, so the Secret has to live in the release namespace:

```console
$ kubectl create secret generic tuwunel-secrets \
    --from-literal=REGISTRATION_TOKEN=<token>
```

A reference without the key part is rejected before anything is applied. `values.schema.json`
requires `^[^/]+/[^/]+$` for every `envFromSecret` entry:

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/envFromSecret/LIVEKIT_KEY': 'livekit-secrets' does not match pattern '^[^/]+/[^/]+$'
```

`extraEnv` is checked too - both `name` and `value` are required, and no other property is allowed:

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/extraEnv/0': missing property 'value'
```

`extraEnv` cannot reference a Secret at all: its items are `{name, value}` only, with
`additionalProperties: false`, so there is no `valueFrom`. Use `envFromSecret` - or `envRaw`, which
is a raw `EnvVar` list and can carry a `secretKeyRef` you write yourself.

> **Warning:** The schema only validates the *shape* of an `envFromSecret` entry. A Secret name or
> key that does not exist still renders: `helm template` with `tuwunel-secrets/REGISTRATION_TOKEN`
> against a namespace without that Secret succeeds, and the failure surfaces at pod start - the repo
> does not document which form it takes.

The same channel exists per RTC workload as `rtc.jwt.envFromSecret` and `rtc.livekit.envFromSecret`
(both `{}` by default); see [Matrix RTC with LiveKit](./rtc.md) for the LiveKit key material.

## Secrets inside `config.toml`

`config` is written into the ConfigMap as a template. A `${VAR}` placeholder survives into the
rendered `config.toml`, and the `config-processor` init container (image `dibi/envsubst:1`) performs
the substitution at pod start:

```yaml
envFromSecret:
  EMERGENCY_PASSWORD: my-secret/emergency-password

config:
  global:
    emergency_password: "${EMERGENCY_PASSWORD}"
```

```console
# what the init container runs
envsubst < /tmp/config-template/config.toml > /tmp/config/config.toml
```

The ConfigMap holds the placeholder, not the secret, and the substituted file is written to the
`config` emptyDir mounted at `/tmp/config` in the tuwunel container. The variable itself is exported
on the init container from `envFromSecret` (or `env`/`envRaw`), so `envsubst` can expand it.

There is no fallback and no error for a variable the environment does not define: it expands to the
empty string, and the rendered value becomes empty.

> **Warning:** A missing or misnamed Secret is not loud for every key. For `registration_token`
> tuwunel v1.9.2 refuses to start with `Registration token was specified but is empty ("")` followed
> by `There was a problem with the 'registration_token' directive in your configuration` - a broken
> secret is loud rather than an open server. For other keys, such as an S3 credential, an empty
> value is the failure mode: the server starts with an empty credential.

Two details that follow from the same mechanism:

- Only `env`, `envRaw` and `envFromSecret` are exported for `envsubst`. The chart's own
  `TUWUNEL_*` variables and everything in `extraEnv` are absent from the init container, so a
  `${TUWUNEL_PORT}` placeholder renders as an empty string.
- `envsubst` rewrites only the two reference forms `$name` and `${name}`. Everything else is copied
  verbatim: a bare `$`, a digit reference such as `$1` and a `${1}`-shaped token all pass through
  unchanged, and `$$` is not an escape - the first `$` stays literal and the second starts a new
  reference, so `$$HOME` renders as `$/root`. Probed against the chart's pinned `dibi/envsubst:1`
  image; no test in this repo covers it, so treat it as a caution rather than a documented rule.

The LiveKit configuration goes through the same substitution step (its own `config-processor` reads
`livekit.yaml`); see [Matrix RTC with LiveKit](./rtc.md).

## Registration

Registration is closed by default and the chart ships no token:

```yaml
config:
  global:
    allow_registration: false
```

A registration attempt against a closed server is answered
`403 M_FORBIDDEN: Registration has been disabled.` Chart 2.0.0 removed the previously published
default token (`supa-dupa-secret-token`), so an install with registration enabled has to bring its
own - see [Upgrading](./upgrade.md).

Federation is off in the same way: the packaged `values.yaml` sets
`config.global.allow_federation: false`, so a fresh install neither registers new accounts nor talks
to other homeservers until you turn those on - registration needs `allow_registration: true` plus a
token or the explicit opt-in below, federation needs its own key - see
[Federation and delegation](./federation.md) for what turning it on involves.

| Key | Effect | Set by the chart |
| --- | --- | --- |
| `config.global.registration_token` | UIAA token (`m.login.registration_token`) | no (unset) |
| `config.global.registration_token_file` | one or more whitespace-separated tokens from a file on the pod | no (unset) |
| `config.global.registration_shared_secret` (+ `_file`) | Synapse-style `/_synapse/admin/v1/register`, HMAC-SHA1 authenticated; equivalent to an admin access token | no (unset) |
| `allow_registration: true` **and** `yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse: true` | open registration without a token | no |

The recommended flow keeps the token in a Secret and never in a values file:

```yaml
envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN

config:
  global:
    allow_registration: true
    registration_token: "${REGISTRATION_TOKEN}"
```

```console
$ kubectl create secret generic tuwunel-secrets \
    --from-literal=REGISTRATION_TOKEN=<token>
$ helm upgrade my-release tuwunel/tuwunel -f values.yaml
```

Registration is the standard Matrix UIAA exchange: `POST /_matrix/client/v3/register` without a
token answers `401` with `{"flows":[{"stages":["m.login.registration_token"]}], "session": "..."}`,
and the same request with `"auth": {"type": "m.login.registration_token", "token": "..."}` creates
the account and returns an access token. Once the accounts you need exist, set
`allow_registration` back to `false` and upgrade again.

## Client IP behind a proxy

`config.global.ip_source` decides where tuwunel reads the client IP from (unset by default, which
means `connect_info`: the address of whoever opened the TCP connection). Rate limiting, invites and
moderation all read that address.

Behind an ingress every client looks like the proxy, so per-client abuse control silently degrades.
The fix is to set `ip_source` to the header your proxy actually sets, and to keep the in-cluster pod
CIDR in `ip_source_trusted_subnets`:

```yaml
config:
  global:
    ip_source: rightmost_x_forwarded_for
    ip_source_trusted_subnets:
      - 10.42.0.0/16
```

The accepted set is pinned by `values.schema.json`, so a typo fails the render instead of
mis-attributing every address:

| Accepted value |
| --- |
| `connect_info`, `rightmost_x_forwarded_for`, `rightmost_forwarded`, `x_real_ip` |
| `cf_connecting_ip`, `true_client_ip`, `fly_client_ip`, `cloudfront_viewer_address` |

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/config/global/ip_source': value must be one of 'connect_info', 'rightmost_x_forwarded_for', 'rightmost_forwarded', 'x_real_ip', 'cf_connecting_ip', 'true_client_ip', 'fly_client_ip', 'cloudfront_viewer_address'
```

`ip_source_trusted_subnets` (unset by default; an array of non-empty strings) bypasses `ip_source`
entirely for peers whose connection address is already trusted - probes and in-cluster calls then do
not depend on a header. The reverse side: any peer inside those subnets can forge the client IP
through headers, so only list networks you control end to end, and note the list is read at startup
(`Changing the list requires a restart.`).

> **Danger:** A header-based `ip_source` is only correct when the proxy sets that header on
> **every** request. On v1.9.2 a request that needs the client IP and arrives without the header is
> answered `500 M_UNKNOWN` / `Can't extract client IP from configured ip_source` (checked against
> `POST /_matrix/client/v3/register` and `/_matrix/client/v3/login`), while paths that do not need
> it still answer `200` - which hides the cause.

To see which value the server is running with:

```console
# the ConfigMap holds the unresolved template (key: config.toml, ${VAR} placeholders intact)
$ kubectl get configmap my-release-tuwunel-configmap -o yaml
# the server reads the substituted copy at /tmp/config/config.toml; -c tuwunel is required
# because backup.scheduled adds the backup sidecar to the same pod
$ kubectl logs -f statefulset/my-release-tuwunel -c tuwunel | grep ip_source
```

`ip_source` and `ip_source_trusted_subnets` are rendered inside the `[global]` table of that file;
the remaining core keys are in
[chart README § Client IP behind a proxy](../charts/tuwunel/README.md#client-ip-behind-a-proxy).
A header-based source logs the spoofing warning at startup
(`ip_source is set to RightmostXForwardedFor, a header-based source. Ensure a trusted reverse proxy
populates this header for every request; otherwise clients can spoof their IP address.`);
`connect_info` logs no such line.

## Pod hardening

Most workloads get a pod-level identity plus container-level restrictions. The chart exposes no
value to override any of these blocks.

| Workload (name) | Pod securityContext | Container securityContext | Writable paths |
| --- | --- | --- | --- |
| tuwunel StatefulSet (`<fullname>`) | `runAsNonRoot: true`, `runAsUser: 2020`, `runAsGroup: 2020`, `fsGroup: 2020`, `fsGroupChangePolicy: OnRootMismatch`, `seccompProfile: RuntimeDefault` | `tuwunel` and the `backup` sidecar: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | `/data` (PVC or emptyDir), `/tmp` and `/tmp/config` (emptyDir) |
| init container `config-processor` (same pod) | inherits the pod block above | none of its own - no container-level `securityContext` | `/tmp/config-template` (read-only ConfigMap), `/tmp/config`, `/tmp` |
| RTC JWT Deployment (`<fullname>-jwt`) | `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `seccompProfile: RuntimeDefault` | `jwt-service`: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | `/tmp` (emptyDir) |
| LiveKit Deployment (`<fullname>-livekit`) | `seccompProfile: RuntimeDefault` only | `config-processor` and `livekit`: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | `/tmp/config` and `/tmp` (emptyDir) |
| `helm test` pod (`<fullname>-test-connection`) | `runAsNonRoot: true`, `runAsUser: 65534`, `runAsGroup: 65534`, `seccompProfile: RuntimeDefault` | `wget`: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | none declared |

The emptyDir mounts exist because the root filesystem is read-only: `/tmp` and `/tmp/config` are
where the init container writes the substituted configuration and where the server and sidecar keep
scratch state. `/data` is the mount the database lives on.

> **Note:** The LiveKit pod is the one workload without `runAsNonRoot`/`runAsUser` at pod level - an
> observed difference in the template, not a documented decision. Its containers are still
> restricted. If you enforce Pod Security admission, check that pod against your policy before
> switching a namespace to `restricted` - the [Checklist](#checklist) below keeps it as a gate.

Two more pod-spec facts worth knowing:

- With the default `rtc.livekit.networkMode` (`hostNetwork`) the LiveKit pod runs
  `hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet`, and its media ports are node ports.
  See [Matrix RTC with LiveKit](./rtc.md).
- When `backup.scheduled` is on, the pod sets `shareProcessNamespace: true` so the sidecar can
  signal the server by name (`pkill -USR2 -x tuwunel`). See [Backups and restore](./backups.md).

## Image pull secrets and scheduling

| Value | Default | Applied to |
| --- | --- | --- |
| `imagePullSecrets` | `[]` | the tuwunel StatefulSet pod **only** |
| `priorityClassName` | `""` | the tuwunel pod only (rendered when non-empty) |

```yaml
imagePullSecrets:
  - name: registry-credentials
priorityClassName: system-cluster-critical
```

> **Warning:** The values comment and the chart README describe `imagePullSecrets` as "Pull secrets
> for every pod the chart creates", but only the tuwunel StatefulSet renders it. The RTC JWT and
> LiveKit Deployments and the `helm test` pod reference no `imagePullSecrets` at all, and there is
> no chart knob to add one. In a cluster whose images come from a private registry, either publish
> those images somewhere the nodes can pull anonymously or attach the credentials at namespace level
> (an `imagePullSecrets` entry on the namespace's default ServiceAccount).

Scheduling fields exist per workload - `nodeSelector`, `tolerations` and `affinity` on the homeserver
pod, and the RTC workloads carry their own under `rtc.jwt.*` / `rtc.livekit.*`. Only
`priorityClassName` is exclusive to the homeserver pod. See
[chart README § Pod Configuration](../charts/tuwunel/README.md#pod-configuration).

## What the chart does not protect

- **Plaintext values.** `env` and `extraEnv` entries land in the pod spec as-is, literal values
  under `config` land in the ConfigMap as-is, and all three stay readable in the release's stored
  values (`helm get values my-release`). Only `envFromSecret` + `${VAR}` keeps material out of both.
- **The checksum annotation does not cover `extraEnv`.** It is built from the rendered ConfigMap and
  from `env`, `envRaw` and `envFromSecret` - rendering with and without an `extraEnv` entry produces
  the same annotation value. The README's "over the rendered configuration and the environment"
  wording is therefore wider than what the annotation hashes. An `extraEnv`-only edit still restarts
  the pod, because the entry lands in the pod template itself; the genuinely silent case is a Secret
  whose **contents** changed.
- **Secret rotation needs a rollout.** Because the annotation hashes the environment *references*
  and not the Secret data, rotating a token, an S3 key or the RTC secrets does not roll the pod, and
  the new value reaches the containers only on the next restart:

  ```console
  $ kubectl rollout restart statefulset/my-release-tuwunel
  ```

- **No NetworkPolicy, ServiceAccount or RBAC.** The chart creates none of them, and the pods run
  under the namespace's default ServiceAccount with a mounted token; there is no
  `automountServiceAccountToken: false` anywhere.
- **No PodSecurity admission configuration.** The chart writes no namespace labels and no Pod
  Security fields, so enforcement is whatever the namespace already carries - and the LiveKit pod
  without a pod-level `runAsNonRoot` (above) is the one to check first.
- **No exposure beyond the cluster.** The Service is a headless `ClusterIP` (`clusterIP: "None"`),
  so the homeserver is reachable only in-cluster until you add an Ingress, a Gateway route or
  another Service type; the container binds `service.port` (8080), never a privileged port.
- **Certificates.** The chart references an existing TLS Secret for the Ingress and RTC ingress
  (`ingress.tlsSecretName`, `rtc.ingress.tlsSecretName`) and passes `config.global.tls` through
  untouched; it creates and renews nothing. See [Exposing the homeserver with Ingress](./ingress.md).

## Checklist

- [ ] Credentials (registration token, S3 keys, `LIVEKIT_KEY`/`LIVEKIT_SECRET`,
      `emergency_password`) go through `envFromSecret` + a `${VAR}` placeholder - never a literal
      value in `values.yaml`.
- [ ] The Secret exists in the release namespace and its key names match the `secretKeyRef` keys.
- [ ] `allow_registration` is back to `false` once the accounts you need exist.
- [ ] `ip_source` matches the header your proxy sets, and `ip_source_trusted_subnets` is limited to
      the pod CIDR rather than a broad range.
- [ ] `imagePullSecrets` is set for private registries - and you have handled the RTC/test pods,
      which the chart does not cover.
- [ ] A default-deny NetworkPolicy and `automountServiceAccountToken: false` are applied at
      namespace level, since the chart ships neither.
- [ ] Pod Security admission, if you use it, accepts the LiveKit pod (no `runAsNonRoot`).
- [ ] You know that a rotated Secret needs a manual `kubectl rollout restart` (or a pod deletion) to
      take effect, while a `config`/`env` edit in the values file rolls the pod on its own, because
      `checksum/config` changes.
- [ ] TLS is terminated by something you manage, with the certificate Secret named by
      `ingress.tlsSecretName` ([Ingress](./ingress.md)) or `rtc.ingress.tlsSecretName`
      ([Matrix RTC with LiveKit](./rtc.md)).
