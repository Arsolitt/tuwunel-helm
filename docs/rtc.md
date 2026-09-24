# Matrix RTC with LiveKit (Element Call)

> Turn on Matrix RTC in the chart: the objects `rtc.enabled` deploys, the two network modes for media, and the values that wire Element Call to LiveKit.

## Table of Contents

- [What the RTC option deploys](#what-the-rtc-option-deploys)
- [Prerequisites](#prerequisites)
- [Quick start (default `hostNetwork` mode)](#quick-start-default-hostnetwork-mode)
- [`pod` network mode](#pod-network-mode)
- [What the chart derives](#what-the-chart-derives)
- [RTC ingress and Gateway routes](#rtc-ingress-and-gateway-routes)
- [TURN](#turn)
- [Values reference](#values-reference)
- [Troubleshooting](#troubleshooting)

---

## What the RTC option deploys

`rtc.enabled: true` adds a MatrixRTC focus next to the homeserver: the LiveKit SFU carries media, and `lk-jwt-service` mints LiveKit access tokens and serves the HTTP endpoints clients call. Every template under `rtc/` is gated by `rtc.enabled`, and the values schema requires `rtc.domain` whenever it is true, as a non-empty bare lowercase DNS name: the domain is what `LIVEKIT_URL`, the RTC route host and the homeserver's discovery record are built from, and the chart adds the `https://`/`wss://` part itself ([Prerequisites](#2-rtcdomain-and-dns)).

Throughout this page `<fullname>` is `fullnameOverride` when set, otherwise the release name if it contains `tuwunel`, otherwise `<release>-tuwunel`. A release named `matrix` therefore renders `matrix-tuwunel-jwt`, `matrix-tuwunel-livekit`, and so on.

With `rtc.enabled: true` and neither ingress nor Gateway API enabled, the chart renders exactly five RTC objects:

| Kind | Name | What it is |
|---|---|---|
| Deployment | `<fullname>-jwt` | `lk-jwt-service`: token minting, `/get_token` and friends |
| Service | `<fullname>-jwt` | `ClusterIP`, port `8080` (`http`) — the only JWT backend |
| Deployment | `<fullname>-livekit` | LiveKit SFU; mounts the config rendered by an init container |
| Service | `<fullname>-livekit` | `http` `7880/TCP` and `rtc-tcp` `7881/TCP` (plus `rtc-udp` in `pod` mode) |
| ConfigMap | `<fullname>-livekit` | the `livekit.yaml` template (`/tmp/config/livekit.yaml` after `envsubst`) |

Optional objects, each behind its own switch:

| Switch | Kind | Name |
|---|---|---|
| `rtc.ingress.enabled` | Ingress | `<fullname>-rtc` |
| `rtc.gateway.enabled` | HTTPRoute | `<fullname>-rtc` |
| `rtc.livekit.gateway.udpRoute` | UDPRoute | `<fullname>-livekit-udp` |
| `rtc.livekit.gateway.tcpRoute` | TCPRoute | `<fullname>-livekit-tcp` |

Every object carries `app.kubernetes.io/component` — `rtc-jwt`, `rtc-livekit` or `rtc-ingress` — which is the label the chart README's troubleshooting selectors key on. (`app.kubernetes.io/name=tuwunel` matches the RTC pods too, so a guessed selector returns an empty list that looks like "nothing was deployed".)

Image pins, all with `pullPolicy: IfNotPresent`:

| Component | Image | Default tag |
|---|---|---|
| JWT service | `ghcr.io/element-hq/lk-jwt-service` | `0.7.0` |
| LiveKit server | `livekit/livekit-server` | `v1.13.7` |
| Config processor (init container) | `initContainer.image`, default `dibi/envsubst` | `1` |

Both RTC Deployments are hardcoded to `replicas: 1`; LiveKit uses `strategy: Recreate` (it has to replace a `hostNetwork` pod), so every `livekit.yaml` change restarts it with a gap in service — a `LiveKit` config change rolls the pod through the `checksum/livekit-config` annotation, so time those like any restart ([Day-2 operations](./operations.md)).

### What the chart changes on the homeserver side

Exactly one key. When `rtc.enabled` is true and `rtc.domain` is set, the chart injects `config.global.well_known.livekit_url = https://<rtc.domain>` into the rendered `config.toml` ([Configuring the server](./configuration.md)). Nothing else is written to the homeserver config.

> **Note:** the injection never touches `well_known.client`, so an RTC-enabled install still needs its own `.well-known/matrix/client` setup — that belongs to the homeserver's exposure, not to LiveKit ([Exposing the homeserver with Ingress](./ingress.md)).

## Prerequisites

### 1. A LiveKit key/secret

The chart wires everything else itself and only needs the API credentials. Generate a 20-hex-character key and a 64-hex-character secret and store them in one Secret:

```console
$ LIVEKIT_KEY=$(openssl rand -hex 10)
$ LIVEKIT_SECRET=$(openssl rand -hex 32)
$ kubectl create secret generic livekit-secrets \
    --from-literal=LIVEKIT_KEY=$LIVEKIT_KEY \
    --from-literal=LIVEKIT_SECRET=$LIVEKIT_SECRET
```

Both workloads reference it through `envFromSecret`, whose format is `secret-name/key-name`:

```yaml
rtc:
  jwt:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
  livekit:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
```

The secret name is yours to choose; both maps must point at the same `LIVEKIT_KEY`/`LIVEKIT_SECRET` pair. On the JWT side the variables are the token-signing credentials; on the LiveKit side they are substituted into `livekit.yaml` (`keys`, `webhook.api_key`), which is why the placeholders and the secret must agree ([Secrets and hardening](./security.md)).

### 2. `rtc.domain` and DNS

`rtc.domain` is the host clients reach the focus on, and it is not the homeserver host. It has to be a bare lowercase DNS name: the chart writes it verbatim into the RTC Ingress rule host and the RTC HTTPRoute hostname, and it prefixes the scheme itself — `https://<rtc.domain>` for the `livekit_url` it injects into `config.toml`, `wss://<rtc.domain>` for the derived `LIVEKIT_URL`. A scheme in the value is what used to render `https://https://rtc.ci.example` (and `wss://wss://…` on the JWT side) next to a host the API server refuses, so the schema's enabled branch pins the value to `^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$` — a scheme, a port, uppercase and underscores are all rejected before any template runs:

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/rtc/domain': 'https://rtc.ci.example' does not match pattern '^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$'
```

The same render of `rtc.domain: "rtc.ci.example:8448"`, `"RTC.ci.example"` or `"rtc_ci.example"` fails on the same line with the value it read. Where the domain points depends on the network mode:

| Mode | `rtc.domain` must resolve to |
|---|---|
| `hostNetwork` (default) | the IP of the node the LiveKit pod lands on |
| `pod` | the Service address (a `LoadBalancer`/`NodePort` address), not a node |

### 3. TLS or a plain HTTP host

The chart references an existing TLS Secret for the RTC host (`rtc.ingress.tlsSecretName`, default `<fullname>-rtc-tls`) and creates no certificate. Either add a cert-manager annotation or create the Secret yourself — a TLS block pointing at a missing Secret leaves the host without a working listener ([Exposing the homeserver with Ingress](./ingress.md)).

### 4. Nothing else

`LIVEKIT_URL`, `LIVEKIT_FULL_ACCESS_HOMESERVERS`, `LIVEKIT_JWT_BIND`, the LiveKit `keys` entry, the webhook URL and `livekit_url` all follow from `rtc.domain` and `server_name` — see [What the chart derives](#what-the-chart-derives).

## Quick start (default `hostNetwork` mode)

Start from `charts/tuwunel/ci/rtc-values.yaml`: it enables RTC, sources the credentials from the Secret, exposes the RTC host through an nginx Ingress with TLS, and deliberately leaves every derived value unset.

```yaml
server_name: matrix.ci.example

rtc:
  enabled: true
  domain: rtc.ci.example

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
    tlsSecretName: rtc-ci-tls
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod

config:
  global:
    allow_federation: false
```

`networkMode` is unset, so it keeps its default `hostNetwork`. Install it:

```console
$ helm install matrix tuwunel/tuwunel -f values.yaml
```

`hostNetwork: true` means the pod shares the node's network namespace, so clients connect to the node's address — not to the Service. The ports clients need are node ports and each one needs a firewall rule:

| Port | Source | Purpose |
|---|---|---|
| `7880/tcp` | `rtc.livekit.config.port` | LiveKit HTTP API (also the Ingress catch-all backend) |
| `7881/tcp` | `rtc.livekit.config.rtc.tcp_port` | RTC TCP |
| `50100-50200/udp` | `rtc.livekit.config.rtc.port_range_start` / `port_range_end` | RTC UDP media |

`rtc.livekit.config.port` is one value behind four manifests — the LiveKit container port, the port of `<fullname>-livekit`, and the backend port of the RTC Ingress and the RTC HTTPRoute — so it has to be a port number: digits only, and never empty. Both mistakes are refused at render time, before any of the four objects is written, with the messages quoted in [Troubleshooting](#troubleshooting).

Point `rtc.domain` at that node's address, and pin the pod to that node with the placement knobs so the DNS record keeps matching — for example with Kubernetes' built-in `kubernetes.io/hostname` label, or whatever label your nodes carry:

```yaml
rtc:
  livekit:
    nodeSelector:
      kubernetes.io/hostname: node-1
```

Because LiveKit runs with `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet` (the chart sets it so the webhook hostname `<fullname>-jwt` resolves), the LiveKit Service is still rendered but carries only `http` `7880/TCP` and `rtc-tcp` `7881/TCP` — there is no `rtc-udp` port in this mode, and media never flows through the Service. ICE candidates come from `rtc.livekit.config.rtc.use_external_ip: true` (the default, which asks an external service for the advertised address) or from `node_ip` while `use_external_ip` is false. Add `external_ip_only: true` when clients are offered unreachable bridge addresses such as `docker0`.

Verify what actually rendered:

```console
$ kubectl get pods -l app.kubernetes.io/name=tuwunel
$ kubectl get svc -l app.kubernetes.io/component=rtc-livekit
$ curl https://<server_name>/_matrix/client/unstable/org.matrix.msc4143/rtc/transports
```

An empty `rtc_transports` list from that endpoint means `livekit_url` is missing from the rendered `config.toml`, not that LiveKit is down.

## `pod` network mode

In `pod` mode media arrives through `rtc.livekit.service` instead of the node's network namespace. The complete scenario is `charts/tuwunel/ci/rtc-pod-network-values.yaml`:

```yaml
server_name: matrix.ci.example

rtc:
  enabled: true
  domain: rtc.ci.example

  jwt:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET

  livekit:
    networkMode: pod
    nodeSelector:
      ci.example/pool: rtc
    podAnnotations:
      ci.example/note: rtc
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
    service:
      type: LoadBalancer
      externalTrafficPolicy: Local
      annotations:
        ci.example/managed: "true"
      loadBalancerIP: 203.0.113.30
      loadBalancerSourceRanges:
        - 203.0.113.0/24
    config:
      rtc:
        # A single multiplexed UDP port, exposed by the Service as rtc-udp
        udp_port: 7882
        tcp_port: 7881
        use_external_ip: false
        node_ip: 203.0.113.30
```

Setting `networkMode: pod` alone is not enough: a Kubernetes Service forwards one port per entry, never a range, so `config.rtc.udp_port` is mandatory and must be a single port. The chart refuses both mistakes at render time with the messages quoted in [Troubleshooting](#troubleshooting).

The `rtc.livekit.service` block is what carries media out of the cluster:

| Value | Default | Effect |
|---|---|---|
| `type` | `ClusterIP` | `ClusterIP`, `NodePort` or `LoadBalancer`; only meaningful in `pod` mode |
| `externalTrafficPolicy` | `Cluster` | rendered only for `NodePort`/`LoadBalancer`; use `Local` so a client reaches the node that actually hosts the pod |
| `loadBalancerIP` | `""` | rendered only for `LoadBalancer`; requests that address for the Service |
| `loadBalancerSourceRanges` | `[]` | rendered only for `LoadBalancer`; restricts which source CIDRs may reach it |

The Service exposes three ports — `http` `7880/TCP`, `rtc-tcp` `7881/TCP` and `rtc-udp` `7882/UDP` — and the Deployment's container ports match (`7880`, `7881`, `7882/UDP`). The rendered `livekit.yaml` for this fixture keeps the values it was given:

```yaml
bind_addresses:
- ""
keys:
  ${LIVEKIT_KEY}: ${LIVEKIT_SECRET}
port: 7880
room:
  auto_create: false
rtc:
  enable_loopback_candidate: false
  node_ip: 203.0.113.30
  port_range_end: 50200
  port_range_start: 50100
  tcp_port: 7881
  udp_port: 7882
  use_external_ip: false
webhook:
  api_key: ${LIVEKIT_KEY}
  urls:
  - http://podfull-tuwunel-jwt:8080/sfu_webhook
```

> **Note:** in `pod` mode only the Deployment and Service ports collapse to the single `udp_port`; the rendered `livekit.yaml` still carries `port_range_start: 50100` and `port_range_end: 50200` next to `udp_port: 7882`, because the chart merges your `rtc.livekit.config` into the file as-is. What LiveKit itself does with those range keys when a `udp_port` is present is not determinable from the chart — the render is all this repository defines.

Two ways to get media to that Service, and the default one is not a path at all:

- `LoadBalancer`/`NodePort` with `externalTrafficPolicy: Local`: point `rtc.domain` at the Service address (the fixture uses `loadBalancerIP: 203.0.113.30`) instead of a node.
- Gateway API media routes: `rtc.livekit.gateway.udpRoute` / `tcpRoute`, which need `pod` mode and their own `parentRefs` ([Exposing the homeserver with Gateway API](./gateway-api.md)).

With the default `type: ClusterIP` and only an Ingress, clients can signal over HTTP but media has no path out of the cluster — that combination is a plausible-looking configuration that never carries a call.

## What the chart derives

Each value below is written only when you left it unset — the guards are `hasKey` checks, so an explicit value always wins, including a wrong one.

| Value | Derived from | Applied when |
|---|---|---|
| `rtc.jwt.env.LIVEKIT_URL` = `wss://<rtc.domain>` | `rtc.domain` | `rtc.jwt.env` has no `LIVEKIT_URL` |
| `rtc.jwt.env.LIVEKIT_FULL_ACCESS_HOMESERVERS` = `server_name` | `server_name` | `rtc.jwt.env` has no `LIVEKIT_FULL_ACCESS_HOMESERVERS` |
| `rtc.jwt.env.LIVEKIT_JWT_BIND` = `:8080` | fixed | `rtc.jwt.env` has no `LIVEKIT_JWT_BIND` |
| `rtc.livekit.config.keys` = `{"${LIVEKIT_KEY}": "${LIVEKIT_SECRET}"}` | fixed placeholders, resolved by the init container's `envsubst` | `rtc.livekit.config.keys` is absent |
| `rtc.livekit.config.room.auto_create` = `false` | fixed | `room.auto_create` is absent |
| `rtc.livekit.config.webhook.api_key` = `${LIVEKIT_KEY}` | fixed placeholder | `webhook.api_key` is absent |
| `rtc.livekit.config.webhook.urls` = `["http://<fullname>-jwt:8080/sfu_webhook"]` | `<fullname>` | `webhook.urls` is absent |
| `config.global.well_known.livekit_url` = `https://<rtc.domain>` | `rtc.domain` | `rtc.enabled` and `rtc.domain` are set, and neither `livekit_url` nor `rtc_transports` is present |

`LIVEKIT_FULL_ACCESS_HOMESERVERS` is mandatory in `lk-jwt-service` 0.7.0 — it used to default to `*`, and without it every token request fails. It is set to `server_name`, i.e. the name clients and federating servers use ([Federation and delegation](./federation.md)).

`room.auto_create: false` and the webhook URL are the pairing the JWT service expects: a token request must not create a room (that is the hole the service closes), and LiveKit reports room events back to `http://<fullname>-jwt:8080/sfu_webhook`. Override either half and you break the pair — a LiveKit that cannot reach the JWT service silently stops reporting room events.

Three values fall back rather than being derived: `rtc.ingress.class` falls back to `ingress.class` (both empty means no `ingressClassName` at all), `rtc.ingress.tlsSecretName` to `<fullname>-rtc-tls`, and both `rtc.gateway.parentRefs` and `rtc.livekit.gateway.parentRefs` to `gateway.parentRefs`. The media routes never fall back to `rtc.gateway.parentRefs`.

> **Warning:** overriding `rtc.jwt.env.LIVEKIT_JWT_BIND` does not move anything else. The container port, the JWT Service port, the probe port, the Ingress/HTTPRoute backend port and the derived webhook URL all stay `8080`, so the service would listen on a port nothing routes to.

The full list of derivations, with the same wording the packaged chart ships, is in the [chart README § What the chart derives](../charts/tuwunel/README.md#what-the-chart-derives).

## RTC ingress and Gateway routes

`rtc.ingress.enabled` and `rtc.gateway.enabled` are independent of each other and of the homeserver's own `ingress`/`gateway` settings; both need `rtc.enabled`. The routing table is identical either way: five paths to the JWT service and everything else to LiveKit.

| Path | Backend |
|---|---|
| `/get_token` | `<fullname>-jwt:8080` |
| `/sfu/get` | `<fullname>-jwt:8080` |
| `/healthz` | `<fullname>-jwt:8080` |
| `/delegate_delayed_leave` | `<fullname>-jwt:8080` |
| `/sfu_webhook` | `<fullname>-jwt:8080` |
| `/` (catch-all) | `<fullname>-livekit:<rtc.livekit.config.port>` (`7880`) |

The path set is fixed in 2.0.0 — `rtc.ingress.path` and `rtc.ingress.extraHosts` no longer exist and are rejected by the schema, so the RTC host cannot serve a sub-path.

The Ingress is named `<fullname>-rtc`, serves `rtc.domain` with `pathType: Prefix` for every entry, and always carries four nginx annotations plus yours (yours are merged last and win):

```yaml
nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
nginx.ingress.kubernetes.io/websocket-services: <fullname>-livekit
nginx.ingress.kubernetes.io/proxy-buffering: "off"
```

With `rtc.ingress.tls: true` the Ingress gets a `tls` block for host `rtc.domain` and secret `rtc.ingress.tlsSecretName` (default `<fullname>-rtc-tls`). The catch-all means the RTC host also exposes LiveKit's own HTTP surface — anything outside the five JWT paths is LiveKit's API.

The Gateway API variant is an `HTTPRoute` named `<fullname>-rtc` with `hostnames: [rtc.domain]` and the same two rules. The chart renders routes only — the Gateway, its listeners and its GatewayClass are yours to own ([Exposing the homeserver with Gateway API](./gateway-api.md)). Rendered for a release named `rtcgw` that shares the homeserver's `gateway.parentRefs`:

```yaml
spec:
  parentRefs:
    - name: eg
      namespace: gateway-system
      sectionName: web
  hostnames:
    - rtc.ci.example
  rules:
    - matches:            # the five JWT path prefixes
        - path: {type: PathPrefix, value: /get_token}
        # ... /sfu/get, /healthz, /delegate_delayed_leave, /sfu_webhook
      backendRefs:
        - name: rtcgw-tuwunel-jwt
          port: 8080
    - matches:
        - path: {type: PathPrefix, value: /}
      backendRefs:
        - name: rtcgw-tuwunel-livekit
          port: 7880
```

Media routes are separate objects, `pod` mode only, and target the Service ports the mode creates. From `charts/tuwunel/ci/gateway-media-values.yaml` (release `rtcmedia`), which keeps `gateway.enabled: false`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: UDPRoute
metadata:
  name: rtcmedia-tuwunel-livekit-udp
spec:
  parentRefs:
    - name: eg
      namespace: gateway-system
      sectionName: media
  rules:
    - backendRefs:
        - name: rtcmedia-tuwunel-livekit
          port: 7882
```

`rtc.livekit.gateway.tcpRoute` renders the mirror image as `<fullname>-livekit-tcp` on `config.rtc.tcp_port`. Both routes share `rtc.livekit.gateway.parentRefs` and `rtc.livekit.gateway.annotations`, and both refuse to render in `hostNetwork` mode or without their port.

> **Warning:** `UDPRoute` and `TCPRoute` only reached Gateway API `v1` in Gateway API v1.6; earlier bundles serve them at `v1alpha2` only. On such a cluster the chart's `gateway.networking.k8s.io/v1` media routes are **refused by the API server** (`no matches for kind "UDPRoute" in version "gateway.networking.k8s.io/v1"`) and the release fails until the bundle is upgraded. And a kind that exists but is not implemented by your data plane renders and is simply never programmed — UDP/TCP proxying is a conformance question, not a universal capability the way `HTTPRoute` is.

## TURN

There is no `turn` block in the chart's own values. TURN is passthrough LiveKit configuration under `rtc.livekit.config`, with commented examples in `values.yaml` and nothing else:

| Form | Key | Shape |
|---|---|---|
| External TURN (coturn, etc.) | `rtc.livekit.config.rtc.turn_servers` | list of `host`, `port`, `protocol`, `secret` — the commented example uses `host: turn.yourdomain.com`, `port: 5349`, `protocol: tls` |
| LiveKit's own TURN | `rtc.livekit.config.turn` | `enabled`, `udp_port` (`3478` in the example), `relay_range_start` (`50300`), `relay_range_end` (`65535`), `domain` |

What the chart supports today is exactly that: your object is merged into `livekit.yaml` verbatim. What it does not support is any validation or exposure of that path — a typo lands in `livekit.yaml` unchanged, there is no CI fixture, README example block or verification recipe for a TURN configuration, and LiveKit's own TURN server needs its own UDP ports reachable from the internet (`udp_port`, `relay_range_start`/`relay_range_end`), which in `pod` mode are not covered by the single multiplexed `rtc-udp` port or by the media routes.

If calls connect but no media flows, check the mode and the UDP path first — see [Troubleshooting](./troubleshooting.md) for the media-side failure modes.

## Values reference

The values this page uses, with their defaults from `charts/tuwunel/values.yaml`:

| Value | Default | Notes |
|---|---|---|
| `rtc.enabled` | `false` | master switch; all `rtc/*` templates |
| `rtc.domain` | `""` | required when `rtc.enabled` is true; a bare lowercase DNS name, since the chart prefixes `https://`/`wss://` itself |
| `rtc.jwt.image.repository` / `.tag` | `ghcr.io/element-hq/lk-jwt-service` / `0.7.0` | |
| `rtc.jwt.env` / `.envRaw` / `.envFromSecret` | `{}` / `[]` / `{}` | `envFromSecret` format `secret/key` |
| `rtc.jwt.resources` | `50m-200m` CPU, `128Mi-256Mi` memory | |
| `rtc.livekit.image.repository` / `.tag` | `livekit/livekit-server` / `v1.13.7` | |
| `rtc.livekit.networkMode` | `hostNetwork` | enum: `hostNetwork`, `pod` |
| `rtc.livekit.env` / `.envRaw` / `.envFromSecret` | `{}` / `[]` / `{}` | applied to the config-processor init container only |
| `rtc.livekit.service.type` | `ClusterIP` | `ClusterIP`, `NodePort`, `LoadBalancer` |
| `rtc.livekit.service.externalTrafficPolicy` | `Cluster` | `Cluster` or `Local`; `NodePort`/`LoadBalancer` only |
| `rtc.livekit.service.loadBalancerIP` | `""` | `LoadBalancer` only |
| `rtc.livekit.service.loadBalancerSourceRanges` | `[]` | `LoadBalancer` only |
| `rtc.livekit.gateway.udpRoute` / `.tcpRoute` | `false` / `false` | `pod` mode only |
| `rtc.livekit.gateway.parentRefs` | `[]` | falls back to `gateway.parentRefs` |
| `rtc.livekit.nodeSelector` / `.tolerations` / `.affinity` / `.podAnnotations` | `{}` / `[]` / `{}` / `{}` | where you pin LiveKit in `hostNetwork` mode |
| `rtc.livekit.config.port` | `7880` | HTTP API; digits only, and drives the container, Service, Ingress and HTTPRoute ports |
| `rtc.livekit.config.rtc.tcp_port` | `7881` | `rtc-tcp` port when set |
| `rtc.livekit.config.rtc.port_range_start` / `port_range_end` | `50100` / `50200` | hostNetwork media range; their presence without `udp_port` fails a `pod`-mode render |
| `rtc.livekit.config.rtc.udp_port` | unset | single multiplexed UDP port; mandatory in `pod` mode |
| `rtc.livekit.config.rtc.use_external_ip` | `true` | ask an external service for the advertised address |
| `rtc.livekit.config.rtc.node_ip` | unset | advertised address; only takes effect while `use_external_ip` is false |
| `rtc.livekit.config.rtc.external_ip_only` | unset | drops private/bridge interfaces from the candidates |
| `rtc.livekit.config.rtc.enable_loopback_candidate` | `false` | |
| `rtc.livekit.gateway.annotations` | `{}` | shared by UDPRoute and TCPRoute |
| `rtc.ingress.enabled` | `false` | RTC Ingress |
| `rtc.ingress.class` | `""` | falls back to `ingress.class` |
| `rtc.ingress.annotations` | `{}` | merged last, wins over the chart's four |
| `rtc.ingress.tls` | `false` | adds a `tls` block for `rtc.domain` |
| `rtc.ingress.tlsSecretName` | `""` → `<fullname>-rtc-tls` | the chart does not create it |
| `rtc.gateway.enabled` | `false` | RTC HTTPRoute |
| `rtc.gateway.parentRefs` / `.annotations` | `[]` / `{}` | falls back to `gateway.parentRefs` |
| `rtc.livekit.config` | LiveKit defaults above | passthrough: any LiveKit key is accepted |

For the complete parameter list including `rtc.jwt.podAnnotations`, `rtc.livekit.gateway.*` and the resource knobs, see the [chart README § RTC Configuration Parameters](../charts/tuwunel/README.md#rtc-configuration-parameters). The [chart README § Matrix RTC (Element Call) Support](../charts/tuwunel/README.md#matrix-rtc-element-call-support) and [§ Network Modes](../charts/tuwunel/README.md#network-modes) carry the same material the page above summarises; [§ RTC ingress](../charts/tuwunel/README.md#rtc-ingress) covers the route table.

## Troubleshooting

Messages in this table are verbatim from `helm template`: schema rejections abort before any template runs, and template failures cite the file they came from.

| Symptom | Cause | Fix |
|---|---|---|
| Calls connect, then no audio/video, in `pod` mode | `rtc.livekit.service.type` is left at the `ClusterIP` default, so media has no path out of the cluster | Use `LoadBalancer`/`NodePort` (with `externalTrafficPolicy: Local`) or the Gateway API media routes |
| Clients report no MatrixRTC transport; `/rtc/transports` returns an empty list | `config.global.well_known.livekit_url` is not in `config.toml` — commonly because `rtc_transports` or `livekit_url` is set explicitly, which suppresses the injection | Remove the explicit key, or set `livekit_url` yourself |
| `rtc.livekit.gateway.udpRoute needs rtc.livekit.networkMode=pod (it is "hostNetwork"): with hostNetwork the media ports are node ports, and the Service exposes rtc-udp only in pod mode` (`tcpRoute` says `rtc-tcp`) | A media route was enabled while `networkMode` was left at its `hostNetwork` default | Set `rtc.livekit.networkMode: pod`, or drop the media routes and open the node ports |
| `rtc.livekit.networkMode=pod needs rtc.livekit.config.rtc.udp_port: a Kubernetes Service cannot forward rtc.livekit.config.rtc.port_range_start/end, so media would have no path to the pod (use a single udp_port, or networkMode=hostNetwork)` | `pod` mode without `udp_port`; the default `port_range_start`/`port_range_end` trigger the guard even though you never set them | Add `rtc.livekit.config.rtc.udp_port: 7882` (a single port) |
| `rtc.livekit.config.rtc.udp_port: a Kubernetes Service cannot expose a UDP port range; set a single port (e.g. 7882) or use rtc.livekit.networkMode=hostNetwork` | `udp_port` holds a range such as `"7882-7892"` — the `hostNetwork` habit carried into `pod` mode | Set one port; keep the range only for `hostNetwork` |
| `rtc.livekit.gateway.udpRoute needs rtc.livekit.config.rtc.udp_port: the Service exposes no rtc-udp port without it` (`tcpRoute` names `rtc.livekit.config.rtc.tcp_port`) | A media route without its port | Set the port the route targets |
| `rtc.livekit.gateway.udpRoute needs parentRefs: set rtc.livekit.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` | Media routes only fall back to `gateway.parentRefs` — a list set under `rtc.gateway.parentRefs` is not inherited | Set `rtc.livekit.gateway.parentRefs` or `gateway.parentRefs` |
| `rtc.gateway.enabled needs parentRefs: set rtc.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` | RTC HTTPRoute enabled with no parentRefs anywhere | Set one of the two lists; `gateway.enabled` is not required |
| `at '/rtc/domain': minLength: got 0, want 1` | `rtc.enabled: true` with an empty `rtc.domain` | Set `rtc.domain` to the host clients use |
| `at '/rtc/domain': 'https://rtc.ci.example' does not match pattern '^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$'` | `rtc.domain` carries a scheme, a port, uppercase or an underscore. The pattern is the schema's enabled branch; the value is written verbatim into an Ingress/HTTPRoute host and the chart prefixes `https://`/`wss://` itself, so a scheme used to render `https://https://…` | Write the bare lowercase DNS name, without a scheme or a port — `rtc.ci.example` |
| `rtc.livekit.config.port is empty: the LiveKit container port, this Service, the RTC Ingress and the RTC HTTPRoute are all built from rtc.livekit.config.port, so a release without it cannot be applied; set a port (the chart's default is 7880)` | `rtc.livekit.config.port` is `""`/null while one value has to fill the container, Service, Ingress and HTTPRoute ports — an empty one would render `port:`/`number:` (null) in all four | Give it a port number, or drop your `rtc.livekit.config` override so the `7880` default applies |
| `rtc.livekit.config.port: "78x0" is not a port number - it has to be digits only, because the same value is rendered as the LiveKit container port, the port of ci-tuwunel-livekit and the backend port of the RTC Ingress and the RTC HTTPRoute` (rendered for a release named `ci`; `ci-tuwunel-livekit` is that release's `<fullname>-livekit`) | Same value, a non-numeric one (a range such as `"7880-7890"` lands here too) | Digits only — the media port *range* belongs under `rtc.livekit.config.rtc.port_range_start`/`port_range_end`, not in `port` |
| `at '/rtc/livekit/networkMode': value must be one of 'hostNetwork', 'pod'` | A 1.x values file with `networkMode: bridge`, which was accepted and ignored before 2.0.0 | Delete the key or set `hostNetwork`/`pod` ([Upgrading](./upgrade.md)) |
| `at '/rtc/ingress': additional properties 'path' not allowed` | A 1.x values file carrying `rtc.ingress.path` (or `extraHosts`) | Drop the key; the RTC path set is fixed |
| Media never flows in `pod` mode although the Service exposes `rtc-udp` | The rendered `livekit.yaml` still carries `port_range_start`/`port_range_end` alongside `udp_port`; only the Deployment/Service ports collapse to the multiplexed port | Align the advertised candidates (`node_ip`/`use_external_ip`) and the range with what the Service actually forwards; the chart defines no LiveKit-side mapping from `udp_port` to the range |
| Clients are offered unreachable addresses (e.g. `docker0`), so calls connect without media | ICE candidates include the host's private/bridge interfaces | Set `rtc.livekit.config.rtc.external_ip_only: true`, or pin `node_ip` with `use_external_ip: false` |
| Media never flows in `hostNetwork` mode | `rtc.domain` points somewhere else (the Service, or another node) or a node port is not reachable | Point it at the IP of the node the pod is pinned to and open `7880/tcp`, `7881/tcp` and `50100-50200/udp` |
| Room events stop arriving from LiveKit | The webhook target was overridden, or the hostNetwork pod cannot resolve `<fullname>-jwt` | Keep `webhook.urls` at `http://<fullname>-jwt:8080/sfu_webhook` and keep the chart's `dnsPolicy: ClusterFirstWithHostNet` |
| RTC host has no working TLS listener | `rtc.ingress.tlsSecretName` is left at its `<fullname>-rtc-tls` default and the chart creates no certificate | Add a cert-manager annotation or pre-create the Secret named in `rtc.ingress.tlsSecretName` |
| `kubectl get` lists nothing that looks like RTC | A selector on the wrong label — the documented selectors use `app.kubernetes.io/component` | `kubectl get pods -l app.kubernetes.io/component=rtc-livekit`, `kubectl logs -l app.kubernetes.io/component=rtc-jwt` |
| RTC pods sit in `Init:0/1` on an arm64 cluster | The init container image `initContainer.image` (`dibi/envsubst:1`) is published for `linux/amd64` only | Point `initContainer.image` at a multi-arch or mirrored equivalent, or pin the pod to an amd64 node |
| LiveKit env vars seem to do nothing | `rtc.livekit.env`/`envRaw`/`envFromSecret` are rendered on the config-processor init container, not on the LiveKit container; only `${VAR}` placeholders inside `livekit.yaml` reach LiveKit, and an undefined placeholder becomes an empty string | Reference the variable in `rtc.livekit.config` or check the init container's log |

The `livekit.yaml` the container actually runs is not the ConfigMap: it is `/tmp/config/livekit.yaml`, produced by the init container. When substitution looks wrong, read that container's log:

```console
$ kubectl logs <pod> -n <namespace> [-c config-processor]
```
