# Federation and delegation

> What `server_name`, `config.global.allow_federation` and the `[global.well_known]` keys do in a chart deployment, how the two exposure layouts differ, and how to verify federation from outside the cluster.

## Table of Contents

- [What `server_name` means](#what-server_name-means)
- [Federation on or off](#federation-on-or-off)
- [Delegation and `.well-known`](#delegation-and-well-known)
- [TLS and DNS requirements](#tls-and-dns-requirements)
- [Verification from outside](#verification-from-outside)
- [Reference](#reference)
- [Common make-mistakes](#common-make-mistakes)

---

## What `server_name` means

`server_name` is the Matrix identity of the deployment, not a hostname you can rename. It is the domain part of every user and room ID the server creates — `@steve:example.com` — which is exactly what the chart's own comment in `values.yaml` describes, and why it recommends the apex domain. The rest of the exposure story (which host answers HTTP) is separate and can be delegated; the identity cannot.

> **Warning:** The chart's default is the placeholder `yourdomain.com`, and a values file that never overrides it renders successfully. An install that goes to production on the default registers users on `yourdomain.com`. Set `server_name` before the first install — see [Installing the chart](./installation.md).

The value is frozen for the lifetime of the database. Upstream's generated configuration file says so next to the key:

```text
# YOU NEED TO EDIT THIS. THIS CANNOT BE CHANGED AFTER WITHOUT A DATABASE WIPE.
```

Migration to a different server name therefore means a new database and a re-created deployment; moving an existing deployment to another domain is a delegation problem, not a `server_name` edit (see [Upgrading](./upgrade.md) and [Backups and restore](./backups.md)).

### How the chart owns the value

The chart does not write `server_name` into `config.toml` as the primary source — it passes the identity through the environment (`TUWUNEL_SERVER_NAME`), which outranks the configuration file. `config.global.server_name` is accepted only for compatibility, and `values.schema.json` says as much: "Accepted for compatibility, but it must match the server_name value: the chart sets TUWUNEL_SERVER_NAME, which wins over the file."

Because an environment variable would otherwise silently win, the StatefulSet fails the render when the two disagree:

```console
$ helm template ci charts/tuwunel --set server_name=matrix.ci.example \
    --set config.global.server_name=other.example.com
Error: execution error at (tuwunel/templates/tuwunnel/statefulset.yaml:28:4): config.global.server_name (other.example.com) must equal server_name (matrix.ci.example): the chart sets TUWUNEL_SERVER_NAME from server_name
```

The same guard exists for `config.global.port` versus `service.port`. Both are template `fail`s, and only the port one has a CI fixture (`ci/invalid-render/config-port-mismatch.yaml`) — there is no `ci/invalid-render` case for the `server_name` rule, so it is protected by the template alone.

The schema itself rejects a missing or malformed value before any template runs:

| Values | Result |
|---|---|
| `server_name` omitted | chart default `yourdomain.com` is used; the render succeeds |
| `server_name: ""` | `at '/server_name': minLength: got 0, want 1` |
| `server_name: null` | `at '': missing property 'server_name'` |
| `server_name: 123` | `at '/server_name': got number, want string` |

### Relationship to the ingress host

Everything the chart exposes is host-derived from `server_name` (plus any delegation):

- With an Ingress, the rule `host` is `server_name` and — without delegation — its path set is `ingress.path` (default `/`); once `well_known.server` is set, that host keeps only the narrowed pair of prefixes described below.
- With Gateway API, the `HTTPRoute` lists `server_name` among its `hostnames`.
- TLS must cover that name, and DNS must point it at the ingress or Gateway — the chart renders neither. See [Exposing the homeserver with Ingress](./ingress.md) or [Gateway API](./gateway-api.md).

Without delegation the server name *is* the host clients and remote servers reach. With delegation, the server name stays the identity and the traffic moves to another host — the next two sections.

## Federation on or off

`config.global.allow_federation` is `false` in the chart. Upstream's default for the same field is `true`, so the chart ships a closed server: nothing federates until you say so. The value must be a TOML boolean — the schema pins it, and the quoted form is rejected before rendering:

```console
$ helm template ci charts/tuwunel --set config.global.allow_federation='"false"'
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/config/global/allow_federation': got string, want boolean
```

(The chart README records what the pin prevents: a rendered `allow_federation = "false"` makes tuwunel exit 1 with `invalid type: found string "false", expected a boolean for key "global.allow_federation"`.)

### What "off" does to the API

With federation disabled, tuwunel still starts and serves the client API, but it registers the whole server-to-server surface against a handler that refuses everything:

| Path | With `allow_federation: false` |
|---|---|
| `/_matrix/federation/*` | 403, message `Federation is disabled.` |
| `/_matrix/key/*` | 403, same handler |
| `/_tuwunel/local_user_count` | 403, same handler |
| `/_matrix/federation/v1/version` | 403 — it is part of the federation surface |
| `/.well-known/matrix/*` | routed as usual (discovery is *not* gated on federation) |
| `/_tuwunel/server_version` | routed as usual (registered outside the federation block) |

Two consequences matter operationally:

1. **A Ready pod is not a federating pod.** The probes are `exec: tuwunel --health-check`, and the `helm test` hook fetches `/_tuwunel/server_version` — neither touches a federation path. Chart 1.2.0 had to move the readiness probe off `/_matrix/federation/v1/version` precisely because that path answers 403 while federation is off, "which left the pod NotReady while the server itself was running". The current probe arrangement means federation can be broken (or disabled) in a green deployment. See [Day-2 operations](./operations.md).
2. **Disabled federation fails closed.** Remote servers cannot fetch signing keys or send transactions, so requests from the wider Matrix network are refused rather than queued.

### What the default configuration exposes

Out of the box, with `well_known: {}` (the chart default):

- the federation and key APIs answer 403;
- `/.well-known/matrix/client` and `/.well-known/matrix/server` both answer 404 — the chart renders an empty `[global.well_known]` table, which tuwunel treats as unset;
- nothing about the deployment is discoverable, so clients must be configured with the homeserver URL by hand.

Turning federation on is the pair of values the chart README's federation example uses:

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

> **Danger:** The well-known endpoints are registered regardless of `allow_federation`. Advertising `m.server` while federation is off tells remote servers to connect to an endpoint that answers 403, and peers cache the delegation document (the specification recommends re-checking roughly daily). Change both settings together.

## Delegation and `.well-known`

Delegation is what lets the identity stay on the apex while the traffic lives elsewhere: upstream's root-domain guide describes hosting on `matrix.example.com` and delegating from `example.com`, so usernames read `@user:example.com` rather than `@user:matrix.example.com`.

The chart expresses it with two sibling keys under `config.global.well_known` — there is no nested delegation object:

| Key | Shape (upstream) | Drives | Empty/unset |
|---|---|---|---|
| `config.global.well_known.client` | HTTPS **URL without a port** ("should just be a valid HTTPS URL") | `/.well-known/matrix/client`, as `m.homeserver.base_url` (plus the RTC transports, see [Matrix RTC with LiveKit](./rtc.md)) | the endpoint answers 404 `Not found.` |
| `config.global.well_known.server` | **Bare `host:port`, not a URL** — upstream's example is `"matrix.example.com:443"` | `/.well-known/matrix/server`, as `m.server` | the endpoint answers 404 `Not found.` |

```yaml
config:
  global:
    allow_federation: true
    well_known:
      client: "https://matrix.example.com"
      server: "matrix.example.com:443"
```

Upstream also serves `/.well-known/matrix/support`, built from support contact/policy/page configuration. No chart value drives it, and `config` is a passthrough, so you would set it as a raw upstream key.

> **Note:** `config` is a passthrough, so the schema validates neither key: a `client` value reaches `config.toml` in any shape, and a `server` value does too unless it is written as a URL. What happens next differs. A `client` value carrying a port is accepted: the server starts and serves a discovery document whose `base_url` keeps the port (`{"m.homeserver":{"base_url":"https://matrix.example.com:8448/"}}`), which is not the portless HTTPS URL upstream asks for. A `server` value written as a URL never gets that far — the render refuses it, whether or not an Ingress or a Gateway is enabled, with `config.global.well_known.server must be a bare host:port, not a URL: "https://matrix.example.com" - it is written into config.toml and served as m.server, and the server refuses a URL at startup`. The key is the delegated domain as upstream reads it out of the file, so there is nothing to strip back out of a scheme, and the server would stop at startup anyway with `server name is not a valid IP address or domain name for key "global.well_known.server"` (exit code 1, without ever listening).

### How delegation changes the Ingress layout

Setting `config.global.well_known.server` switches the Ingress template into its delegated branch. The delegated host is `well_known.server` with the port stripped, and the render becomes two hosts:

```yaml
# helm template ci charts/tuwunel --set ingress.enabled=true --set ingress.class=nginx \
#   --set ingress.tls=true --set server_name=example.com \
#   --set config.global.well_known.server=matrix.example.com:443
spec:
  tls:
    - hosts:
        - example.com
        - matrix.example.com
      secretName: ci-tuwunel-tls
  rules:
    - host: example.com
      http:
        paths:
          - path: "/.well-known/matrix"
            pathType: Prefix
          - path: "/_matrix"
            pathType: Prefix
    - host: matrix.example.com
      http:
        paths:
          - path: /            # ingress.path
            pathType: Prefix
```

Without `well_known.server`, the same Ingress renders one host and one catch-all path:

```yaml
# server_name: matrix.example.com, no well_known
  rules:
    - host: matrix.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
```

`ingress.extraHosts` get their own rule with `ingress.path`, after the server_name/delegated rules. If `well_known.server` names the same host as `server_name`, you get that host twice — once narrowed, once with `/` — and it appears twice in `tls.hosts` too; that is exactly what the chart's canonical federation fixture renders.

> **Warning:** Enabling delegation narrows what the `server_name` host serves — but both rules on that host are `Prefix` rules, `/.well-known/matrix` and `/_matrix`, so everything underneath them stays routed on the apex host, `/.well-known/matrix/support` and the client API at `/_matrix/client/*` included. What moves to the delegated host's `/` rule is every path outside those two prefixes: `/_tuwunel/server_version`, the admin surface (`/_synapse/admin/*`, `/_synapse/mas/*`), `/.well-known/openid-configuration`, and anything else the server registers at another root. See [Troubleshooting](./troubleshooting.md).

> **Note:** Both exposure templates read `.Values.config.global.well_known.server` defensively (`get … | default dict`), so a values set that nulls `config.global` renders with either or both enabled — the delegated host is simply treated as absent.

### Gateway API instead of an Ingress

The HTTPRoute carries every hostname the server must answer for — `server_name`, the delegated domain with its port stripped, and `gateway.hostnames` — de-duplicated, behind a single `PathPrefix /` rule. With `server_name: example.com`, `well_known.server: matrix.example.com:443` and `gateway.hostnames: [alias.example.com]`:

```yaml
spec:
  hostnames:
    - example.com
    - matrix.example.com
    - alias.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
```

Unlike the Ingress, there is no narrowed path set: one catch-all rule covers both the delegated paths and everything else. The chart creates no `Gateway` and no `GatewayClass` — exactly as the Ingress does not create its class. See [Gateway API](./gateway-api.md).

### The DNS alternatives

Delegation does not have to be served by the homeserver. Matrix resolves a server name in this order:

1. an explicit port in the server name (`example.com:8448`);
2. `https://<hostname>/.well-known/matrix/server`, whose `m.server` gives the `delegated_hostname[:port]` (port defaults to 8448 when omitted);
3. SRV `_matrix-fed._tcp.<hostname>`;
4. the deprecated SRV `_matrix._tcp.<hostname>`;
5. A/AAAA records on the hostname, contacted on port 8448.

A well-known error response falls through to the SRV steps, so either mechanism alone is sufficient. The specification's order contains no TXT step; SRV is the DNS-based alternative. Nothing in this chart creates DNS records of any kind, and none of it can be verified from inside the cluster.

Whatever serves the traffic must present, for the contacted name:

- DNS for the `server_name` host (where the well-known documents are fetched) and for the delegated host (`m.server` target, or the SRV target);
- a TLS certificate valid for the contacted name;
- the request's `Host` header set to that name — with the port included when the server name carried one.

## TLS and DNS requirements

The chart has exactly one listener: container port `http` = `service.port` (default 8080), one Service port, and no representation of Matrix's 8448 anywhere (there is no `8448` string in `charts/tuwunel`, no second Service, Ingress or HTTPRoute). Federation therefore arrives on whatever port your Ingress, Gateway or LoadBalancer fronts — which is why the announced `m.server` has to name that port and host.

| Case | Must resolve | Must be certified | Routed to |
|---|---|---|---|
| No delegation | `server_name` | `server_name` | Ingress rule `host: <server_name>`, path `ingress.path` |
| Delegation (`well_known.server` set) | `server_name` **and** the delegated host | both, in `tls.hosts` | `server_name`: only `/.well-known/matrix` + `/_matrix`; delegated host: `ingress.path` |
| `ingress.extraHosts` | each extra host | each, in `tls.hosts` | own rule, `ingress.path` |
| Gateway API | every `HTTPRoute` hostname | the Gateway listener's certificates (yours, not the chart's) | one `PathPrefix /` rule |

Two rendered details are worth reading off the manifest before you apply it:

- With `ingress.tls: true` and **no** delegation, the `tls.hosts` list still contains a second, empty entry (`hosts: [matrix.example.com, null]` in the rendered YAML). The template emits `server_name` and the delegated domain unconditionally and the delegated one is empty in that case.
- With delegation, the delegated host is appended to `tls.hosts` automatically; you do not list it in `ingress.extraHosts` (that would render a third, redundant rule for the same host).

### Host sensitivity

The chart's exposure model is host-based: Ingress rules and HTTPRoute hostnames are matched by the request's `Host` header, and the well-known endpoints are ordinary paths on the same single listener as the client API. A request with a `Host` that matches no rule never reaches tuwunel — the ingress controller or Gateway answers instead, which is a different 404 from the homeserver's `Not found.`.

TLS terminates at the ingress or the Gateway listener, never at the pod, so the certificate that has to cover every hostname is the one on the Ingress (`ingress.tls` / `ingress.tlsSecretName`, usually issued through the annotations you set) or on your own Gateway listener; the client-IP configuration behind that proxy (and the spoofing that goes with it) is covered in [Secrets and hardening](./security.md).

## Verification from outside

These checks run from wherever DNS resolves. Replace `example.com` with your `server_name` and `matrix.example.com` with your delegated host.

```console
# Is the federation API answering? 403 while allow_federation is false, 200 once it is true.
$ curl -sS -o /dev/null -w '%{http_code}\n' https://example.com/_matrix/federation/v1/version
200

# Is the server up at all? This path is registered regardless of federation.
$ curl -sS -o /dev/null -w '%{http_code}\n' https://example.com/_tuwunel/server_version
200

# Does the client discovery document advertise a homeserver? Drives from well_known.client.
$ curl -sS https://example.com/.well-known/matrix/client | jq -e 'has("m.homeserver")'
true

# The federation delegation document: m.server must print the host:port you configured.
$ curl -sS https://example.com/.well-known/matrix/server | jq -r '.m.server'
matrix.example.com:443
```

A configured document echoes the value you set; an unset one answers 404 with the homeserver's error body, which is how you tell "delegation not configured" apart from "ingress in the way":

```console
$ curl -sS -o /dev/null -w '%{http_code}\n' https://example.com/.well-known/matrix/server
404

$ curl -sS https://example.com/.well-known/matrix/server | jq -r '.errcode, .error'
M_NOT_FOUND
M_NOT_FOUND: Not found.
```

A 404 that is *not* `Not found.` (an ingress/Gateway default-backend page, or a body naming a different host) means the request never reached the pod: the `Host` header did not match any Ingress rule or HTTPRoute hostname for this release.

### Testing before DNS is published

Point curl at the ingress address while sending the hostname you are testing:

```console
$ curl -sS --resolve example.com:443:<ingress-address> https://example.com/.well-known/matrix/server | jq -r '.m.server'
matrix.example.com:443

# Same idea, plain HTTP and an explicit Host header, for the ingress by IP:
$ curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: example.com' http://<ingress-address>/.well-known/matrix/server
200
```

For the server side of a suspected ingress problem, bypass it entirely and talk to the pod (port `8080` is the default `service.port`):

```console
$ kubectl port-forward svc/my-release-tuwunel 8080:8080 &
$ curl -sS -H 'Host: example.com' http://127.0.0.1:8080/.well-known/matrix/server | jq -r '.m.server'
matrix.example.com:443
```

If the port-forward answer is correct but the public host is not, the difference is routing, DNS or TLS — not the homeserver.

### Expected answers per configuration

| Configuration | `/.well-known/matrix/client` | `/.well-known/matrix/server` | `/_matrix/federation/v1/version` |
|---|---|---|---|
| Chart default (`allow_federation: false`, `well_known: {}`) | 404 `M_NOT_FOUND` | 404 `M_NOT_FOUND` | 403 |
| `allow_federation: true` only | 404 | 404 | 200 |
| + `well_known.server: matrix.example.com:443` | 404 | 200, `m.server` | 200 |
| + `well_known.client: https://matrix.example.com` | 200, `m.homeserver.base_url` | 200 | 200 |
| `rtc.enabled: true`, no `well_known.client` | 404 (the chart injects only `livekit_url`) | 404 | depends on `allow_federation` |

> **Tip:** The end-to-end check upstream recommends is the Matrix Federation Tester (`https://federationtester.matrix.org/`) against your server name: it walks the real resolution chain — well-known, SRV, TLS, `Host` — which nothing inside the cluster can do.

## Reference

### Federation-related values

| Value | Default | Notes |
|---|---|---|
| `server_name` | `yourdomain.com` (placeholder) | Identity; required non-empty string; immutable for the life of the database |
| `config.global.allow_federation` | `false` | Upstream default is `true`; schema-pinned to a TOML boolean |
| `config.global.trusted_servers` | `[]` | "Servers to trust when federating"; passed through unchanged |
| `config.global.well_known` | `{}` | Rendered as an empty `[global.well_known]` table, which means unset |
| `config.global.well_known.client` | unset | Portless HTTPS URL → `m.homeserver.base_url` |
| `config.global.well_known.server` | unset | Bare `host:port` → `m.server`; also drives the delegated host in the Ingress/HTTPRoute |
| `config.global.server_name` | unset | Compatibility only; must equal `server_name` |
| `service.port` | `8080` | The only port; the port federation arrives on |
| `service.type` / `service.clusterIP` | `ClusterIP` / `"None"` | Headless; exposure comes from an Ingress/route. An override to `NodePort`/`LoadBalancer` installs as configured and renders no `clusterIP` unless you set one |
| `ingress.enabled` / `class` / `path` / `tls` / `extraHosts` | `false` / `""` / `"/"` / `false` / `[]` | Delegation changes the rules and TLS hosts these render |

The complete value list, including the client-IP keys a proxied federation deployment needs, is in the chart reference: [chart README § Tuwunel Configuration](../charts/tuwunel/README.md#tuwunel-configuration) and [§ Ingress Configuration](../charts/tuwunel/README.md#ingress-configuration).

### Rendered `config.toml` keys

Rendering the chart's federation fixture (`charts/tuwunel/ci/ingress-federation-values.yaml`) produces exactly this under `[global]`:

```toml
    [global]
      address = "::"
      allow_federation = true
      allow_registration = false
      ip_source = "rightmost_x_forwarded_for"
      ip_source_trusted_subnets = ["10.42.0.0/16"]
      log = "info"
      trusted_servers = ["matrix.org"]
      [global.ldap]
      [global.tls]
      [global.well_known]
        client = "https://matrix.ci.example"
        server = "matrix.ci.example:443"
```

Without a `well_known` block the last table is still rendered, empty — which is why the default install answers 404 on both documents.

### Host layout per case

| Rendered object | No delegation | Delegation (`well_known.server` set) |
|---|---|---|
| Ingress rule for `server_name` | `ingress.path` (`/`) | only `/.well-known/matrix` and `/_matrix` (Prefix) |
| Ingress rule for the delegated host | — | `ingress.path` (`/`) |
| `tls.hosts` | `[server_name, null]` | `[server_name, delegated, ...extraHosts]` |
| HTTPRoute `hostnames` | `[server_name, ...gateway.hostnames]` | `[server_name, delegated, ...gateway.hostnames]`, de-duplicated |
| HTTPRoute rules | one `PathPrefix /` | one `PathPrefix /` |

## Common make-mistakes

| Symptom | Cause | Go to |
|---|---|---|
| Remote servers cannot join or send; every federation call is 403 | `config.global.allow_federation` is still `false` (the chart default) — and `/_matrix/federation/v1/version` answering 403 is the same setting, not a broken pod | [Troubleshooting](./troubleshooting.md) |
| Users report their IDs are on the wrong domain, or an upgrade wants a different server name | `server_name` was changed on a database created with another one; the value is baked into the identity and needs a database wipe | [Troubleshooting](./troubleshooting.md) |
| `m.server` is served (or advertised) but nothing federates | Delegation configured without DNS: the delegated host does not resolve to the ingress/Gateway that carries it — or the setting was left on while federation is disabled | [Troubleshooting](./troubleshooting.md) |
| `/.well-known/matrix/*` answers 404 in one place and 200 in another | Wrong `Host`: the request hit a hostname no Ingress rule or HTTPRoute hostname matches, so the ingress controller answered instead of tuwunel | [Troubleshooting](./troubleshooting.md) |
| After adding delegation, the apex host stops serving `/_tuwunel/server_version` and admin paths | The delegated branch narrows the `server_name` host's rules to `/.well-known/matrix` and `/_matrix` | [Troubleshooting](./troubleshooting.md) |
| Clients find no homeserver although RTC is fully wired | `rtc.enabled` injects `well_known.livekit_url`, never `well_known.client`, so the discovery document still 404s | [Troubleshooting](./troubleshooting.md) |
| A values file ported from an older release fails to render | `config.global.server_name` or `config.global.port` no longer matches the top-level `server_name` / `service.port` | [Troubleshooting](./troubleshooting.md) |
