# Documentation

> Task-oriented guides for the tuwunel Helm chart; the value-by-value reference stays in [`charts/tuwunel/README.md`](../charts/tuwunel/README.md) — the README that ships inside the packaged chart.

## Table of Contents

| Page | Description |
|------|-------------|
| [Installing the chart](./installation.md) | Install the tuwunel Helm chart into a Kubernetes cluster, watch the pod come up, and verify that the homeserver actually answers. |
| [Upgrading](./upgrade.md) | How to move an existing release onto a newer chart version: the values migrations for 2.0.0, the database migration window, and the checks that prove the result. |
| [Configuring the server](./configuration.md) | How your values become the server's `config.toml`: the `config` passthrough, the four environment sources, secret placeholders, TOML shape rules, and the two gates that reject a broken configuration before the pod starts. |
| [Exposing the homeserver with Ingress](./ingress.md) | How to publish the chart's headless Service through an Ingress: the values, the rendered host and path layout, TLS, and the client-IP settings an ingress makes necessary. |
| [Exposing the homeserver with Gateway API](./gateway-api.md) | Render `HTTPRoute`, `UDPRoute` and `TCPRoute` objects that attach to a Gateway you run, instead of or next to an Ingress. |
| [Federation and delegation](./federation.md) | What `server_name`, `config.global.allow_federation` and the `[global.well_known]` keys do in a chart deployment, and how to verify federation from outside the cluster. |
| [Matrix RTC with LiveKit (Element Call)](./rtc.md) | Turn on Matrix RTC in the chart: the objects `rtc.enabled` deploys, the two network modes for media, and the values that wire Element Call to LiveKit. |
| [Storage and media](./storage-and-media.md) | What the chart persists, where the database and uploaded media live, and how to put either of them on other storage. |
| [Backups and restore](./backups.md) | How the chart gives tuwunel's built-in online backups their own volume, what its cron sidecar does, and how to trigger, verify and restore a backup. |
| [Secrets and hardening](./security.md) | How secrets reach the server without landing in `values.yaml` or the ConfigMap, the security contexts each pod gets, and the hardening the chart leaves to you. |
| [Day-2 operations](./operations.md) | What a running tuwunel release looks like from the outside: probe behaviour, the migration budget, what a values edit restarts, storage growth and the routine checks. |
| [Troubleshooting](./troubleshooting.md) | Symptom catalogue for the tuwunel chart: the exact error text it produces, what each one means, and the page that owns the fix. |
| [How the chart renders a running server](./internals.md) | What happens between your values and a running tuwunel process: the ConfigMap template, the envsubst init container, the chart-owned environment, and every guard that stops a bad render. |
| [Development and releases](./development.md) | Repository layout, the fixture contract, the local command set and the CI jobs behind this chart, and how a `Chart.yaml` bump becomes a published release. |

## Where to go for what

- **Value reference** — every chart option, its type and its default: [`charts/tuwunel/README.md`](../charts/tuwunel/README.md), also available from a packaged chart with `helm show readme`.
- **Packaging and release of the chart** — version history in [`CHANGELOG.md`](../CHANGELOG.md) and the release flow in [Development and releases](./development.md).
- **Upstream homeserver** — the server's own configuration keys and behaviour: <https://github.com/matrix-construct/tuwunel>.
