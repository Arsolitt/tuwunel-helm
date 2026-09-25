# Exposing the homeserver with Gateway API

> Render `HTTPRoute`, `UDPRoute` and `TCPRoute` objects that attach to a Gateway you run, instead of or next to an Ingress.

## Table of Contents

- [When to choose Gateway API](#when-to-choose-gateway-api)
- [What the chart renders](#what-the-chart-renders)
- [Required CRDs and versions](#required-crds-and-versions)
- [Parent refs and hostnames](#parent-refs-and-hostnames)
- [Media routes for RTC](#media-routes-for-rtc)
- [A complete example](#a-complete-example)
- [Mixing with Ingress](#mixing-with-ingress)

---

## When to choose Gateway API

Gateway API exposure is off by default (`gateway.enabled: false`), so a default install renders no route objects at all. Turn it on when your cluster already runs a Gateway controller and you want the chart to publish the homeserver as a `HTTPRoute` on a `Gateway` — a model that suits clusters where a platform team owns the listeners and the TLS certificates.

The chart is a route producer, not an exposure stack. It creates no `Gateway`, no `GatewayClass` and no `IngressClass`: the listeners, the certificates and the addresses stay yours, and `parentRefs` name the Gateway your controller serves — the same relationship `ingress.class` has with an IngressClass. Ingress and Gateway API can be enabled at the same time; they are served by different controllers, so running both is the supported state during a cutover. Pick the Gateway model when a platform team already owns a Gateway, and read [Exposing the homeserver with Ingress](./ingress.md) if your cluster's exposure is an Ingress instead.

The values below are the ones this page uses; the chart README's [Gateway API](../charts/tuwunel/README.md#gateway-api) section carries the same reference tables next to the Ingress ones.

| Parameter             | Description                              | Default |
| --------------------- | ---------------------------------------- | ------- |
| `gateway.enabled`     | Render the homeserver `HTTPRoute`        | `false` |
| `gateway.parentRefs`  | Gateways the route attaches to           | `[]`    |
| `gateway.hostnames`   | Additional hostnames for the route       | `[]`    |
| `gateway.annotations` | Annotations for the `HTTPRoute`          | `{}`    |

## What the chart renders

Four objects at most, one per purpose:

| Object name               | Kind        | Rendered when                                          | Carries                                            |
| ------------------------- | ----------- | ------------------------------------------------------ | -------------------------------------------------- |
| `<fullname>`              | `HTTPRoute` | `gateway.enabled`                                      | the homeserver, all of its hostnames               |
| `<fullname>-rtc`          | `HTTPRoute` | `rtc.enabled` and `rtc.gateway.enabled`                | `rtc.domain`: the JWT paths and LiveKit's HTTP API |
| `<fullname>-livekit-udp`  | `UDPRoute`  | `rtc.enabled` and `rtc.livekit.gateway.udpRoute`       | LiveKit UDP media                                  |
| `<fullname>-livekit-tcp`  | `TCPRoute`  | `rtc.enabled` and `rtc.livekit.gateway.tcpRoute`       | LiveKit TCP media                                  |

The snippets below are objects quoted verbatim from `helm template` (a whitespace-only line inside the labels block is trimmed).

### The homeserver route

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tuwunel
  labels:
    app.kubernetes.io/name: tuwunel
    app.kubernetes.io/instance: tuwunel
    app.kubernetes.io/managed-by: Helm
    helm.sh/chart: tuwunel-2.0.2
    app.kubernetes.io/component: tuwunel
spec:
  parentRefs:
    - name: eg
      sectionName: https
  hostnames:
    - example.com
    - matrix.example.com
    - alt.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: tuwunel
          port: 8080
```

- The name is the chart's `<fullname>` helper output: `fullnameOverride` when set, otherwise the release name if it already contains the chart name (or `nameOverride`), otherwise `<release>-<chart>` — `tuwunel` for a release named `tuwunel`.
- `parentRefs` is emitted verbatim from `gateway.parentRefs` (no defaults injected, no field filtering).
- `hostnames` is derived, not copied from a single value: `server_name` first, then the delegated domain from `config.global.well_known.server` with any `:port` stripped, then every entry of `gateway.hostnames`. The list is deduplicated, so a delegated host that equals `server_name` (as in the chart's CI fixture `charts/tuwunel/ci/gateway-values.yaml`) shows up once.
- `gateway.annotations` are copied onto the object as-is (controller-specific opt-ins).
- There is exactly one rule: a single `PathPrefix /` catch-all whose backend is the chart's Service (`<fullname>`) on `service.port` (8080 by default). Unlike the Ingress, the delegated host needs no separate path set — the server answers for both hostnames itself.

### The RTC route

With `rtc.enabled` and `rtc.gateway.enabled` the chart adds a second `HTTPRoute` for `rtc.domain`. It is `rtc.enabled` that gates it, exactly like `rtc.ingress`: setting `rtc.gateway.enabled` alone renders nothing, and no error.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tuwunel-rtc
  labels:
    app.kubernetes.io/name: tuwunel
    app.kubernetes.io/instance: tuwunel
    app.kubernetes.io/managed-by: Helm
    helm.sh/chart: tuwunel-2.0.2
    app.kubernetes.io/component: rtc-ingress
spec:
  parentRefs:
    - name: eg
      sectionName: https
  hostnames:
    - rtc.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /get_token
        - path:
            type: PathPrefix
            value: /sfu/get
        - path:
            type: PathPrefix
            value: /healthz
        - path:
            type: PathPrefix
            value: /delegate_delayed_leave
        - path:
            type: PathPrefix
            value: /sfu_webhook
      backendRefs:
        - name: tuwunel-jwt
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: tuwunel-livekit
          port: 7880
```

The routing table is the RTC Ingress one reproduced on a route: the five JWT prefixes go to `<fullname>-jwt` on port 8080, everything else to `<fullname>-livekit` on `rtc.livekit.config.port` (7880 by default). The JWT port is hardcoded in the template, not derived from a value — if that Service's port ever changes, the route keeps pointing at 8080 and the Gateway controller reports `ResolvedRefs=False` instead of the chart failing. See [Matrix RTC with LiveKit](./rtc.md) for the JWT and LiveKit deployment behind these routes.

## Required CRDs and versions

The chart installs no CRDs. Your cluster must provide the `gateway.networking.k8s.io` kinds you use:

| Kind        | Available at `v1` since                                   | Needed for                    |
| ----------- | --------------------------------------------------------- | ----------------------------- |
| `Gateway`   | Gateway API v1.0                                          | the parent the routes attach to (yours, not the chart's) |
| `HTTPRoute` | Gateway API v1.0                                          | the homeserver and RTC routes |
| `UDPRoute`  | Gateway API v1.6 — absent from some vendor bundles        | LiveKit UDP media             |
| `TCPRoute`  | Gateway API v1.6 — absent from some vendor bundles        | LiveKit TCP media             |

A cluster running an older bundle loses only the media routes: the two `HTTPRoute`s are unaffected. If a kind is missing entirely, the API server rejects that object at install/upgrade time, and nothing in the chart catches it first: the route templates do not gate on `Capabilities`, so they cannot tell whether a route kind exists in the cluster. Rendering does consult cluster API versions elsewhere — the Ingress template picks its `apiVersion` from `.Capabilities.APIVersions.Has "networking.k8s.io/v1"`, and on install/upgrade Helm fills those capabilities from the target cluster (`helm template` uses its built-in defaults unless `--api-versions` says otherwise). The route templates have no such gate: they render the kinds you enable, and the API server is what refuses them.

What CI does check, on every run:

- The rendered manifests are validated with `kubeconform -strict` against pinned JSON schemas for `httproute_v1`, `udproute_v1` and `tcproute_v1`, fetched from the `datreeio/CRDs-catalog` commit `ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2` and checksum-verified before use. `kubeconform` resolves them by lower-cased kind name plus API version, via `-schema-location "$RUNNER_TEMP/gateway-api/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"`.
- A resource that matches no schema is a hard failure (`Skipped: 0` is asserted), so a new CRD kind cannot slip into the chart unvalidated.
- Every fixture is rendered for Kubernetes 1.31.0 and 1.37.0, the oldest and newest releases checked against the chart's own `kubeVersion` floor of 1.31.0.

> **Warning:** CI validates the *shape* of the routes against those pinned schemas, not their behaviour on your cluster — no Gateway controller is installed anywhere in the repo, and the manifests are never applied. Route attachment and the media data path must be verified on the real cluster; see [Troubleshooting](./troubleshooting.md). The pinned catalog commit is evidence for the schema shape only, not for which Gateway API release your cluster installs.

## Parent refs and hostnames

`gateway.parentRefs` is mandatory in practice, and the chart refuses to render without it:

```console
$ helm template ci charts/tuwunel -f charts/tuwunel/ci/invalid-render/gateway-without-parentrefs.yaml
Error: execution error at (tuwunel/templates/gateway/httproute.yaml:5:4): gateway.enabled needs gateway.parentRefs: the chart renders HTTPRoutes that attach to a Gateway you run, it does not create one
```

This is a template failure, not a schema failure: an `HTTPRoute` with an empty `parentRefs` list is valid for the CRD — it would simply attach to nothing and carry no traffic — so `values.schema.json` accepts the values. `helm lint --strict -f charts/tuwunel/ci/invalid-render/gateway-without-parentrefs.yaml charts/tuwunel` does surface the guard, but as a note rather than a failure: it prints `level=INFO msg="funcMap fail" message="gateway.enabled needs gateway.parentRefs: …"` and still exits 0 with `0 chart(s) failed`. CI fails the fixture with `helm template` instead, which reports the error above and exits non-zero. Either way the message names the value to set.

Each entry is passed through to the route unchanged. Only `name` is required, and the chart's schema validates that before the template runs:

| Member        | Required | Meaning                                                                 |
| ------------- | -------- | ----------------------------------------------------------------------- |
| `name`        | yes      | Name of the Gateway                                                     |
| `namespace`   | no       | Defaults to the release namespace when omitted                          |
| `sectionName` | no       | Picks one listener of a multi-listener Gateway (TLS and hostname binding belong to that listener) |
| `group`       | no       | Gateway API group of the parent                                         |
| `kind`        | no       | Kind of the parent                                                      |
| `port`        | no       | Listener port of the parent                                             |

Unknown members are allowed here — the field set belongs to Gateway API, not to the chart — and the rendered route is what CI validates against the real CRD schema.

Hostnames are derived from three sources, in this order, then deduplicated:

1. `server_name` — always added.
2. the delegated domain from `config.global.well_known.server`, with any `:port` stripped (the [federation delegation](./federation.md) rule the Ingress already follows). Setting only `config.global.well_known.client` adds nothing to the route.
3. every entry of `gateway.hostnames`.

So `server_name: example.com` plus `config.global.well_known.server: matrix.example.com:8448` plus `gateway.hostnames: [alt.example.com]` renders `[example.com, matrix.example.com, alt.example.com]`.

> **Note:** adding a hostname to the route is not enough on its own — the Gateway listener must also serve it. The chart cannot check that, and a listener that does not bind the hostname rejects the route or never matches it.

The RTC route has no hostnames knob: its only hostname is `rtc.domain`. Its `parentRefs` fall back to `gateway.parentRefs` when `rtc.gateway.parentRefs` is empty, and a render with neither fails with `rtc.gateway.enabled needs parentRefs: set rtc.gateway.parentRefs, or gateway.parentRefs to share the homeserver's`.

## Media routes for RTC

LiveKit media is UDP and raw TCP, which an `HTTPRoute` cannot carry, so the chart renders a `UDPRoute` and a `TCPRoute` for the media ports:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: UDPRoute
metadata:
  name: tuwunel-livekit-udp
  labels:
    app.kubernetes.io/name: tuwunel
    app.kubernetes.io/instance: tuwunel
    app.kubernetes.io/managed-by: Helm
    helm.sh/chart: tuwunel-2.0.2
    app.kubernetes.io/component: rtc-livekit
spec:
  parentRefs:
    - name: eg
      sectionName: media
  rules:
    - backendRefs:
        - name: tuwunel-livekit
          port: 7882
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: TCPRoute
metadata:
  name: tuwunel-livekit-tcp
  labels:
    app.kubernetes.io/name: tuwunel
    app.kubernetes.io/instance: tuwunel
    app.kubernetes.io/managed-by: Helm
    helm.sh/chart: tuwunel-2.0.2
    app.kubernetes.io/component: rtc-livekit
spec:
  parentRefs:
    - name: eg
      sectionName: media
  rules:
    - backendRefs:
        - name: tuwunel-livekit
          port: 7881
```

| Parameter                         | Description                                               | Default |
| --------------------------------- | --------------------------------------------------------- | ------- |
| `rtc.livekit.gateway.udpRoute`    | Render a `UDPRoute` for `rtc.livekit.config.rtc.udp_port` | `false` |
| `rtc.livekit.gateway.tcpRoute`    | Render a `TCPRoute` for `rtc.livekit.config.rtc.tcp_port` | `false` |
| `rtc.livekit.gateway.parentRefs`  | Gateways the media routes attach to                       | `[]`    |
| `rtc.livekit.gateway.annotations` | Annotations for both media routes                         | `{}`    |

Both values need four things before they render: `rtc.enabled`, `rtc.livekit.networkMode: pod`, the port value being set, and `parentRefs`. The ports are the ones the LiveKit Service exposes in `pod` mode — `rtc.livekit.config.rtc.udp_port` (a single port, never a range; a range fails the render) and `rtc.livekit.config.rtc.tcp_port` (7881 by default). Both are keys of the `rtc` section in the `livekit.yaml` the chart renders from `rtc.livekit.config`. See [Matrix RTC with LiveKit](./rtc.md) and the chart README's [Network Modes](../charts/tuwunel/README.md#network-modes).

The default `networkMode` is `hostNetwork`, and the chart refuses the combination:

```console
$ helm template ci charts/tuwunel -f charts/tuwunel/ci/invalid-render/rtc-media-route-without-pod-mode.yaml
Error: execution error at (tuwunel/templates/rtc/udproute.yaml:4:4): rtc.livekit.gateway.udpRoute needs rtc.livekit.networkMode=pod (it is "hostNetwork"): with hostNetwork the media ports are node ports, and the Service exposes rtc-udp only in pod mode
```

The other refusals you can hit, each naming the value at fault:

| Situation                                                  | Message                                                                                                                            |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| media route without `parentRefs` anywhere                  | `rtc.livekit.gateway.udpRoute needs parentRefs: set rtc.livekit.gateway.parentRefs, or gateway.parentRefs to share the homeserver's` |
| media route with the port value unset                      | `rtc.livekit.gateway.udpRoute needs rtc.livekit.config.rtc.udp_port: the Service exposes no rtc-udp port without it`                |

(The `tcpRoute` variants of these messages say `tcpRoute`, `rtc.livekit.gateway.tcpRoute` and `rtc-tcp`.)

> **Warning:** `rtc.livekit.gateway.parentRefs` falls back to `gateway.parentRefs`, never to `rtc.gateway.parentRefs`. A media-only configuration that sets only the RTC route's refs fails with a `parentRefs` message that does not name the value you set.

A media route has no `matches` at all — one rule carrying only `backendRefs`, since UDP and TCP have no paths. That means the listener your `parentRef` selects decides which port is routed: pick the listener that terminates the UDP or TCP port clients connect to (`sectionName: media` above), not the HTTPS one.

> **Note:** whether a `UDPRoute`/`TCPRoute` actually carries media depends on the Gateway implementation's data plane — `HTTPRoute` proxying is universally implemented, UDP/TCP proxying is not. Check your controller's conformance before relying on the media routes; the `LoadBalancer`/`NodePort` Service path described in [Matrix RTC with LiveKit](./rtc.md#pod-network-mode) works on any controller, or on none.

## A complete example

Save this as `gateway-values.yaml` — it attaches both HTTP routes to an existing Gateway `eg`, picks its `https` listener for HTTP and its `media` listener for the LiveKit ports, and runs LiveKit in `pod` mode so the media ports exist on the Service:

```yaml
server_name: example.com

ingress:
  enabled: false

gateway:
  enabled: true
  parentRefs:
    - name: eg
      sectionName: https
  hostnames:
    - alt.example.com

config:
  global:
    well_known:
      server: matrix.example.com:8448

rtc:
  enabled: true
  domain: rtc.example.com
  gateway:
    enabled: true
  jwt:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
  livekit:
    networkMode: pod
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
    gateway:
      udpRoute: true
      tcpRoute: true
      parentRefs:
        - name: eg
          sectionName: media
    config:
      rtc:
        udp_port: 7882
```

The two `envFromSecret` entries point at the LiveKit `Secret` the RTC workloads read (`livekit-secrets` in the example) — see [Matrix RTC with LiveKit](./rtc.md) if you have not created it yet.

Render it before installing, and confirm which route objects the release will carry:

```console
$ helm template tuwunel charts/tuwunel -f gateway-values.yaml | grep -A2 -E '^kind: (HTTPRoute|UDPRoute|TCPRoute)$'
kind: HTTPRoute
metadata:
  name: tuwunel
--
kind: HTTPRoute
metadata:
  name: tuwunel-rtc
--
kind: TCPRoute
metadata:
  name: tuwunel-livekit-tcp
--
kind: UDPRoute
metadata:
  name: tuwunel-livekit-udp
```

After the install, check attachment — the routes only carry traffic once a Gateway controller accepts them, and that happens asynchronously after the objects exist. The commands below assume the release lives in the `matrix` namespace, and `eg` is the Gateway your values name:

```console
$ kubectl -n matrix get httproute
$ kubectl -n matrix describe httproute tuwunel
$ kubectl -n matrix get httproute tuwunel -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")]}'
$ kubectl -n matrix get httproute tuwunel -o jsonpath='{.status.parents[*].conditions[?(@.type=="ResolvedRefs")].message}'
$ kubectl -n matrix get udproute,tcproute -o wide
```

What to look for, per parent in `status.parents`:

| Condition      | Value that means the route is live                                                       | Value that means it is not                                                           |
| -------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `Accepted`     | `status: "True"` — the controller that owns the parent Gateway accepted the route         | `status: "False"` — no listener matched the hostname, or the listener's `allowedRoutes` refuses the route's namespace |
| `ResolvedRefs` | `status: "True"` — every `backendRef` resolved                                           | `status: "False"` — the backend Service/port could not be used, e.g. `RefNotPermitted` for a cross-namespace reference without a `ReferenceGrant` |

The same conditions appear on `tuwunel-rtc`. `UDPRoute` and `TCPRoute` carry `status.parents[].conditions[]` as well, so the same `jsonpath` queries work on them; what their CRDs do not define is any printer column beyond `Age`, so `kubectl get -o wide` shows a name and an age and nothing more — no listener, no port. And that status is only populated by a controller that implements UDP/TCP proxying, so even a populated `Accepted` is evidence of attachment at best: prove the media path with traffic, not with the object.

To prove the backend itself answers on `service.port`, run the chart's in-cluster test, which fetches `/_tuwunel/server_version` from the Service:

```console
$ helm test tuwunel
```

> **Warning:** the route backend is the chart's Service, which is headless (`clusterIP: "None"`). Nothing in the chart or its CI proves that a particular Gateway implementation forwards to a headless Service — attachment (`Accepted: "True"`) and a working data path are two different things. If `helm test` passes but requests through the Gateway never reach the pod, the hop to inspect is Gateway → Service, not the chart.

## Mixing with Ingress

Turning both on is supported: the release then carries an `Ingress` and the `HTTPRoute`s, served by two different controllers. That is the state you want during a cutover — point DNS at the new address, watch the Gateway's status, then disable the old path. `ingress.enabled` and `gateway.enabled` are both `false` by default; the chart's install example turns the Ingress on with `--set ingress.enabled=true`.

The two describe the same host differently, so do not compare their manifests 1:1:

|                          | Ingress                                                                                 | Gateway API                                          |
| ------------------------ | --------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| Object                    | `Ingress` `<fullname>`                                                                   | `HTTPRoute` `<fullname>`                             |
| `server_name` host        | split into `/.well-known/matrix` and `/_matrix` `Prefix` paths                            | one `PathPrefix /` rule covering everything          |
| Delegated host            | its own `/` path set                                                                      | the same catch-all rule, hostname added to `hostnames` |
| Extra hostnames           | `ingress.extraHosts`                                                                      | `gateway.hostnames`                                  |
| TLS                       | chart-managed: `ingress.tls`, `ingress.tlsSecretName`                                     | the Gateway listener owns TLS and hostname binding   |
| Class/controller          | `ingress.class` + an IngressClass                                                         | `parentRefs` + a Gateway your controller serves      |

Prefer the Ingress when the cluster's ingress controller is the standard path, when you want the chart to manage TLS, or when you want the simplest option every controller supports. Prefer Gateway API when a platform team owns the Gateway and its listeners, when you want the RTC media ports carried by routes instead of a LoadBalancer Service, or when you are standardising on `gateway.networking.k8s.io` across services. Migrating between the two is a values change — the paths and the JWT path set are identical — so the [Ingress page](./ingress.md) and [Upgrading](./upgrade.md) cover the value-level steps.

The two templates read `config.global` the same defensive way (`get … | default dict`), so a values set that nulls or omits the block — `config: {global: null}`, the way to drop the chart's default `global` table — renders through either path: the delegated hostname is simply left out. Nothing in a cutover depends on which template reads the value, so a values set that renders an Ingress renders an HTTPRoute too.

One difference remains in the output, not in the values: the Ingress is the only object that carries TLS (`ingress.tls` and `ingress.tlsSecretName`). With both enabled during a cutover, the Gateway's listener owns TLS for the routes, and the Ingress keeps its own `spec.tls`.
