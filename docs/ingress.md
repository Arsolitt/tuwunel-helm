# Exposing the homeserver with Ingress

> How to publish the chart's headless Service through an Ingress: the values, the rendered host and path layout, TLS, and the client-IP settings an ingress makes necessary.

## Table of Contents

- [The Service](#the-service)
- [Enabling an Ingress](#enabling-an-ingress)
- [TLS](#tls)
- [Serving the Matrix hostnames](#serving-the-matrix-hostnames)
- [Client IP behind a proxy](#client-ip-behind-a-proxy)
- [A complete example](#a-complete-example)
- [Troubleshooting pointers](#troubleshooting-pointers)

---

## The Service

The chart renders exactly one Service for the homeserver. It is **headless** by default and it is not meant to be the object your users reach (labels and selector omitted from this excerpt):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-demo-tuwunel
spec:
  clusterIP: "None"
  ports:
    - name: http
      protocol: TCP
      port: 8080
      targetPort: http
  type: ClusterIP
```

`spec.clusterIP` is rendered from `service.clusterIP`, whose default is the string `None`, because the StatefulSet names this Service as its governing service — and `None` (a headless Service) is only legal on a `ClusterIP` Service. A `NodePort`/`LoadBalancer` therefore renders the field only when it names an explicit address, and omits it otherwise so the cluster allocates a VIP. Exposure is a separate object: an Ingress (this page) or a Gateway API route (see [Exposing the homeserver with Gateway API](./gateway-api.md)).

| Value | Default | Notes |
| --- | --- | --- |
| `service.port` | `8080` | The chart's single port knob: the Service port, the Ingress backend, the container port and `TUWUNEL_PORT` all come from it |
| `service.type` | `ClusterIP` | Rendered verbatim; `NodePort`/`LoadBalancer` install as configured (no `clusterIP` unless you set one). `ExternalName` is not offered — the chart has no `externalName` value and the schema refuses it |
| `service.clusterIP` | `None` | `None` keeps the Service headless, which is what the StatefulSet needs and what only a `ClusterIP` Service may carry. On a `ClusterIP` Service an address — or `""`, letting the cluster allocate — pins a VIP; on `NodePort`/`LoadBalancer`, `None`/`""` omit the field |
| `service.annotations` | `{}` | Rendered only when non-empty |
| `service.externalIPs` | `[]` | Rendered only when non-empty, on any type |
| `service.loadBalancerIP` | `""` | `LoadBalancer` only, rendered when set |
| `service.loadBalancerSourceRanges` | `[]` | `LoadBalancer` only, rendered when non-empty |

The Service exposes one port named `http` and points at the named container port `http`. The full reference is in the [chart README § Service Configuration](../charts/tuwunel/README.md#service-configuration).

### `config.global.port` must equal `service.port`

The chart pushes `service.port` into the container as `TUWUNEL_PORT`, and an environment variable beats the configuration file. Rather than let a conflicting file value be silently ignored, the chart refuses the render:

```text
Error: execution error at (tuwunel/templates/tuwunnel/statefulset.yaml:24:4): config.global.port (8008) must equal service.port (8080): the chart sets TUWUNEL_PORT from service.port
```

So don't set `config.global.port` at all, or set it to the same number as `service.port`. `config.global.server_name` has the same rule against the top-level `server_name` (the chart sets `TUWUNEL_SERVER_NAME`), which is also why `server_name` is the host a federation peer resolves:

```text
Error: execution error at (tuwunel/templates/tuwunnel/statefulset.yaml:28:4): config.global.server_name (other.example) must equal server_name (yourdomain.com): the chart sets TUWUNEL_SERVER_NAME from server_name
```

### There is no `externalTrafficPolicy` on this Service

The homeserver Service has no traffic-policy key. Handing the chart the value fails schema validation, not the render:

```text
at '/service': additional properties 'externalTrafficPolicy' not allowed
```

If you expected that knob because you came from a WebRTC deployment, it lives under `rtc.livekit.service`, where it defaults to `Cluster`.

> **Note:** `service.type: NodePort` or `LoadBalancer` installs as configured. The chart renders no `clusterIP` for those types unless `service.clusterIP` names an explicit address — the headless `None` default is legal on a `ClusterIP` Service only — and `loadBalancerIP`/`loadBalancerSourceRanges` render for a `LoadBalancer` alone, so a leftover value cannot leak into a `ClusterIP` or `NodePort` render. This is what the CI fixture renders, source ranges included:

```yaml
spec:
  loadBalancerSourceRanges:
    - 203.0.113.0/24
  ports:
    - name: http
      protocol: TCP
      port: 8080
      targetPort: http
  type: LoadBalancer
```

> **Tip:** The headless `None` is what gives the StatefulSet its stable per-pod DNS, so keep it unless you have a reason not to. For an ordinary (non-headless) `ClusterIP` Service, leave `service.type` at `ClusterIP` and set `service.clusterIP: ""` — the cluster allocates a VIP.

## Enabling an Ingress

The Ingress is off by default; a default install exposes nothing but the headless ClusterIP Service.

```yaml
ingress:
  enabled: true
  class: nginx
  path: /
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
```

| Value | Default | Notes |
| --- | --- | --- |
| `ingress.enabled` | `false` | Renders the Ingress resource |
| `ingress.class` | `""` | **Required whenever `enabled` is true** — see the refusal below |
| `ingress.annotations` | `{}` | Merged into `metadata.annotations` verbatim; the chart adds none of its own |
| `ingress.path` | `/` | The catch-all path; the schema requires a leading `/` |
| `ingress.extraHosts` | `[]` | One extra rule (and one extra TLS host) per entry |
| `ingress.tls` | `false` | Renders `spec.tls`; read [TLS](#tls) before enabling it |
| `ingress.tlsSecretName` | `""` | Empty means `<fullname>-tls` |

`ingress.class` is documented with an empty default, but an empty value cannot be used:

```text
Error: execution error at (tuwunel/templates/tuwunnel/ingress.yaml:31:23): If ingress.enabled is set to true, ingress.class is required
```

The template wraps the value in `required`, so name the class your controller watches (`nginx`, `traefik`, …). The complete value list is in the [chart README § Ingress Configuration](../charts/tuwunel/README.md#ingress-configuration).

### What the chart renders

The object is a `networking.k8s.io/v1` Ingress named after the release (`<fullname>`), with `spec.ingressClassName` set from `ingress.class` and your annotations copied through unchanged. Every rule points at the chart's own Service on `service.port`, and every path is `pathType: Prefix`.

Without a delegated domain there is exactly **one** rule — a single prefix that already covers `/.well-known/matrix` and `/_matrix`:

```console
$ helm template ci charts/tuwunel --set ingress.enabled=true --set ingress.class=nginx
```

```yaml
spec:
  ingressClassName: "nginx"
  rules:
    - host: yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ci-tuwunel
                port:
                  number: 8080
```

There is no `ingress.hosts` value. The host list is derived: `server_name` is always present, the delegated domain (from `config.global.well_known.server`, with a trailing `:port` stripped) takes over the catch-all rule when delegation is on, and every `ingress.extraHosts` entry gets a rule of its own. The values file states this directly: "Your server_name and delegated domain (if any) are already added to the Ingress".

> **Note:** With an empty `ingress.annotations` the template still emits an `annotations:` key with nothing under it, so the rendered manifest carries `metadata.annotations: null`. It is cosmetic, but it shows up in diffs.

## TLS

`ingress.tls` is a boolean, not a list of hosts. When it is true the chart renders one `spec.tls` entry whose hosts are, in this order:

1. `server_name`,
2. the delegated domain derived from `config.global.well_known.server` — only when that block sets one,
3. every `ingress.extraHosts` entry.

The list is **not** deduplicated, so delegating to your own `server_name` renders that host twice. The secret name is `ingress.tlsSecretName`, or `<fullname>-tls` when the value is empty.

```yaml
ingress:
  enabled: true
  class: nginx
  tls: true
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
```

**The chart never creates certificates.** There is no `Certificate`, no `Issuer` and no cert-manager annotation in the chart's templates — TLS is a `secretName` reference plus whatever you put in `ingress.annotations`. The values file puts it plainly: "If you enable TLS, don't forget to set annotations for cert-manager". The annotations used by the chart's own examples and CI fixture are `cert-manager.io/cluster-issuer: letsencrypt-prod` and (for uploads) `nginx.ingress.kubernetes.io/proxy-body-size: "0"`; the secret named in `spec.tls` has to exist by the time the controller serves the host.

The chart also renders no redirect and no forced-HTTPS behaviour: `ingress.annotations` is passed through verbatim, so HTTP→HTTPS redirection is a controller concern, not a chart feature. Write your published URLs as `https://` — the chart's own delegation example uses `client: "https://matrix.example.com"` and `server: "matrix.example.com:443"` (the exact shapes belong to [Federation and delegation](./federation.md)).

> **Note:** `ingress.tls: true` installs with or without delegation: the delegated host joins `spec.tls.hosts` only when `config.global.well_known.server` is set, so a non-delegated install renders a TLS block holding `server_name` and your `ingress.extraHosts`, and nothing else. The CI fixture for exactly that case renders:

```yaml
spec:
  tls:
    - hosts:
        - matrix.ci.example
        - alias.ci.example
      secretName: ci-tuwunel-tls
```

> Enabling delegation later adds its host to that list automatically, so no `ingress` value changes with it.

## Serving the Matrix hostnames

The layout depends on one config value: `config.global.well_known.server`. Setting only `config.global.well_known.client` changes nothing in the Ingress.

**No delegation** (`well_known.server` unset) — one catch-all rule on `server_name`, which serves everything: the client API, the well-known documents and the federation endpoints alike.

**Delegated** (`well_known.server` set) — the chart splits the two host roles:

| Host | Paths | Purpose |
| --- | --- | --- |
| `server_name` | `/.well-known/matrix` and `/_matrix` (Prefix) | The documents that tell peers and clients where the server actually lives, plus the federation path space |
| delegated domain | `ingress.path` (`/`) | The catch-all: every other API path |
| each `ingress.extraHosts` entry | `ingress.path` (`/`) | Same catch-all on an alias host |

Rendering `server_name: example.com` with `config.global.well_known.server: "matrix.example.com:443"` therefore produces:

```yaml
spec:
  ingressClassName: "nginx"
  tls:
    - hosts:
        - example.com
        - matrix.example.com
        - alias.example.com
      secretName: ingress-demo-tuwunel-tls
  rules:
    - host: example.com
      http:
        paths:
          - path: "/.well-known/matrix"
            pathType: Prefix
            backend:
              service:
                name: ingress-demo-tuwunel
                port:
                  number: 8080
          - path: "/_matrix"
            pathType: Prefix
            backend:
              service:
                name: ingress-demo-tuwunel
                port:
                  number: 8080
    - host: matrix.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ingress-demo-tuwunel
                port:
                  number: 8080
    - host: alias.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ingress-demo-tuwunel
                port:
                  number: 8080
```

> **Warning:** Enabling delegation is not additive. Any path on the `server_name` host outside `/.well-known/matrix*` and `/_matrix*` matches no rule of this Ingress — including `/_tuwunel/server_version`, the RTC endpoints and admin paths. Those belong on the delegated host, or on a host you add through `ingress.extraHosts`. If RTC is involved, add its own routing ([Matrix RTC with LiveKit](./rtc.md)).

The chart routes paths; it serves no JSON. The homeserver answers `/.well-known/matrix/*` from `config.global.well_known.*`, and the chart publishes no DNS records — the delegated name has to resolve to this Ingress for any of it to be reachable. The DNS and delegation side is covered in [Federation and delegation](./federation.md).

## Client IP behind a proxy

Once a proxy is in front, the address of the TCP connection belongs to the proxy. `config.global.ip_source` is unset by default, which means `connect_info`: every client then looks like the same IP, and rate limiting, invites and moderation all key off that address. Correct it in the same values file as the Ingress:

```yaml
config:
  global:
    ip_source: rightmost_x_forwarded_for
    ip_source_trusted_subnets:
      - 10.42.0.0/16
```

The accepted sources are `connect_info`, `rightmost_x_forwarded_for`, `rightmost_forwarded`, `x_real_ip`, `cf_connecting_ip`, `true_client_ip`, `fly_client_ip` and `cloudfront_viewer_address`; anything else stops the server at startup. A header-based source only works when the proxy sets that header on **every** request — otherwise requests that need the client IP answer `500 M_UNKNOWN` / `Can't extract client IP from configured ip_source` while paths that don't, such as `/_tuwunel/server_version`, still answer 200.

`ip_source_trusted_subnets` is the escape hatch for peers whose connection address is already trustworthy: they bypass `ip_source`. Put the in-cluster pod CIDR there so probes and in-cluster calls do not depend on a header. The trade-offs (spoofing, header trust) are on [Secrets and hardening](./security.md); the value reference is in the [chart README § Client IP behind a proxy](../charts/tuwunel/README.md#client-ip-behind-a-proxy).

## A complete example

`values.yaml` for a federating install on the apex domain, with the homeserver served from the delegated `matrix.` host:

```yaml
server_name: "example.com"

ingress:
  enabled: true
  class: nginx
  tls: true
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
  extraHosts:
    - alias.example.com

config:
  global:
    allow_federation: true
    trusted_servers:
      - matrix.org
    ip_source: rightmost_x_forwarded_for
    ip_source_trusted_subnets:
      - 10.42.0.0/16
    well_known:
      client: "https://matrix.example.com"
      server: "matrix.example.com:443"
```

Install it, then check that the object the chart rendered is attached and that the Service answers on the port the chart chose:

```console
$ helm install ingress-demo tuwunel/tuwunel -f values.yaml
$ kubectl get ingress ingress-demo-tuwunel
$ helm test ingress-demo
```

`kubectl get ingress` has to show your class (`nginx`) and all three hosts — `example.com`, `matrix.example.com`, `alias.example.com` — otherwise the values did not reach the Ingress. The test hook is a busybox pod that fetches `http://ingress-demo-tuwunel.<namespace>.svc:8080/_tuwunel/server_version` from inside the cluster, the one check a rendered manifest cannot make; `helm test` reports success when that pod exits 0 ([chart README § Verifying the deployment](../charts/tuwunel/README.md#verifying-the-deployment)). Finally, verify the path through the Ingress from outside. With delegation enabled the readiness path is served by the *delegated* host, not the apex, and it answers `200`:

```console
$ curl -sS -o /dev/null -w '%{http_code}\n' https://matrix.example.com/_tuwunel/server_version
```

Creating the first account is a registration concern, not an ingress one — see [Installing the chart](./installation.md). `/.well-known/matrix/client` and `/_matrix/federation/v1/version` are answered by the homeserver according to the delegation values; their reachability and DNS are covered in [Federation and delegation](./federation.md).

## Troubleshooting pointers

| Symptom | Where to look |
| --- | --- |
| `helm install` aborts with "If ingress.enabled is set to true, ingress.class is required", or with the `config.global.port`/`server_name` equality message | [Rejected at render time (template guards)](./troubleshooting.md#rejected-at-render-time-template-guards) |
| `service.type: ExternalName` is refused by the schema (`value must be one of 'ClusterIP', 'NodePort', 'LoadBalancer'`) | [Rejected before render (schema)](./troubleshooting.md#rejected-before-render-schema) |
| Everything worked until delegation was switched on; now other endpoints on the apex host return no route / 404 | [Delegation narrowed the server_name host](./troubleshooting.md#delegation-narrowed-the-server-name-host) |
| Requests fail with `500 M_UNKNOWN` / `Can't extract client IP from configured ip_source`, or every client has the same IP in the logs | [Client IP and ip_source](./troubleshooting.md#client-ip-and-ip_source) |
| Peers or clients cannot find the server at all, well-known documents missing | [Exposure and federation](./troubleshooting.md#exposure-and-federation) |
