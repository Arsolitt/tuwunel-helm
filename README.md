# Tuwunel Helm Chart

Helm chart for deploying [Tuwunel](https://github.com/matrix-construct/tuwunel) - a Matrix homeserver based on Conduit. The chart targets tuwunel v1.9.0 or newer.

This chart is designed for tuwunel but can also work with other Conduit forks such as [Continuwuity](https://continuwuity.org/).

> **Note:** This chart is based on [modern-conduwuit-helm](https://github.com/magikid/modern-conduwuit-helm) by magikid.

## Features

- Matrix homeserver deployment, configured through the `TUWUNEL_*` environment contract
- Exec health probes (`tuwunel --health-check`) with a 30-minute startup budget for the one-time database migration after an upgrade
- Optional Matrix RTC support via LiveKit (Element Call), in `hostNetwork` or `pod` network mode
- Optional online database backups on a dedicated volume, with a scheduled SIGUSR2 sidecar
- Local media storage, or an S3-compatible provider through `${VAR}` credentials
- Persistent storage support with per-PVC annotations
- Ingress configuration, including a separate RTC ingress
- Ingress or Gateway API (HTTPRoute) exposure, with optional UDP/TCP routes for RTC media in `pod` mode
- Resource management
- Environment variable injection from secrets
- A `helm test` hook that probes the readiness path from inside the cluster

## Add Repository

```console
helm repo add tuwunel https://arsolitt.github.io/tuwunel-helm
helm repo update
```

## TL;DR

```console
helm install --set server_name=matrix.example.org tuwunel/tuwunel
```

## Installing the Chart

To install the chart with the release name `my-release`:

```console
helm install my-release tuwunel/tuwunel
```

## Uninstalling the Chart

To uninstall/delete the `my-release` deployment:

```console
helm uninstall my-release
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

## Documentation

Task-oriented guides live in [`docs/`](docs/README.md). This README is the short version; each guide
covers one subject in depth:

| Guide | What it covers |
| --- | --- |
| [Installing the chart](docs/installation.md) | Prerequisites, a first install, the objects it creates, verification, uninstall |
| [Upgrading](docs/upgrade.md) | Version contract, the 1.x to 2.0.0 checklist, the migration window, rollback limits |
| [Configuring the server](docs/configuration.md) | How values become `config.toml`, environment variables, secrets, TOML shapes, validation |
| [Ingress](docs/ingress.md) | Service, Ingress, TLS and the Matrix host layout |
| [Gateway API](docs/gateway-api.md) | `HTTPRoute`, `UDPRoute` and `TCPRoute` exposure |
| [Federation and delegation](docs/federation.md) | `server_name`, `.well-known`, DNS and TLS requirements |
| [Matrix RTC](docs/rtc.md) | LiveKit and Element Call in both network modes |
| [Storage and media](docs/storage-and-media.md) | Volumes, PVCs, local media, S3-compatible providers |
| [Backups and restore](docs/backups.md) | Online backups, the scheduled sidecar, the restore drill |
| [Secrets and hardening](docs/security.md) | Secret channels, registration, client IP, pod hardening |
| [Day-2 operations](docs/operations.md) | Probes, migrations, rollouts, resource derivation, maintenance |
| [Troubleshooting](docs/troubleshooting.md) | Rejected values, startup failures, collecting diagnostics |
| [Internals](docs/internals.md) | How a values file becomes a running server, and every render guard |
| [Development and releases](docs/development.md) | Repository layout, CI gates, the release flow |

The complete value-by-value reference is the [chart README](charts/tuwunel/README.md), which ships
inside the packaged chart (`helm show readme`).

## Configuration

For detailed configuration options, see the [chart README](charts/tuwunel/README.md).

Values are validated against [`charts/tuwunel/values.schema.json`](charts/tuwunel/values.schema.json)
on every `helm lint`, `helm template` and `helm install`. Unknown top-level keys
and impossible values (a typo'd `ingres:`, an invalid `accessMode`, an
`envFromSecret` entry without a key) are rejected instead of being silently
ignored. Keys the templates interpolate verbatim accept both the numeric and the
quoted form where Kubernetes accepts both (`service.port`, CPU and memory
quantities).

### Quick Start

The chart deploys with RocksDB storage by default and keeps registration closed:

```yaml
server_name: "yourdomain.com"

envFromSecret:
  REGISTRATION_TOKEN: tuwunel-secrets/REGISTRATION_TOKEN

config:
  global:
    # A TOML boolean, not a string: `allow_registration: "true"` is rejected by
    # values.schema.json ("must be of type boolean") before it can render.
    allow_registration: true
    registration_token: "${REGISTRATION_TOKEN}"
```

`registration_token: "${REGISTRATION_TOKEN}"` is substituted by the chart's envsubst init container
from the value in the secret, so the token itself never has to be written into a values file. Use it
to register the first account, then set `allow_registration: false` again. A placeholder whose
environment variable is missing expands to an empty token, and tuwunel then refuses to start
(`Registration token was specified but is empty`) rather than leaving registration open.

## Matrix RTC (Element Call) Support

This chart supports Matrix RTC via LiveKit for Element Call functionality. See the [chart README](charts/tuwunel/README.md#matrix-rtc-element-call-support) for the full configuration, both network modes and the TURN options.

### Prerequisites

1. Create Kubernetes secret with LiveKit credentials (`LIVEKIT_KEY`, `LIVEKIT_SECRET`)
2. Configure DNS for RTC domain (`rtc.domain`) - it points at the node IP in `hostNetwork` mode and
   at the Service address in `pod` mode
3. Nothing else - `LIVEKIT_URL`, `LIVEKIT_FULL_ACCESS_HOMESERVERS`, the LiveKit webhook URL, the
   LiveKit API keys and `config.global.well_known.livekit_url` are derived from `rtc.domain` and
   `server_name`

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
```

## Using with Other Conduit Forks

This chart is primarily designed for tuwunel but can work with other Conduit forks like Continuwuity. To use with a different fork, override the image:

```yaml
image:
  repository: ghcr.io/continuwuity/continuwuity
  tag: latest
```

The chart's environment, probe and configuration contract targets tuwunel v1.9.0 or newer
(`TUWUNEL_*` variables, `tuwunel --health-check`, `config.toml`); a fork without those needs
`env`, `extraEnv` and `probes.*.enabled` adjustments.

## Releasing New Chart Versions

Releases are automated by [`.github/workflows/ci.yaml`](./.github/workflows/ci.yaml), and a release
exists only because a tag was pushed. Both tracks are cut from `main` and the tag is created by
[`hack/release.sh`](./hack/release.sh) - a chart version is never bumped by hand:

| Track | Tag | GitHub release |
| --- | --- | --- |
| stable | `release-2.1.0` | normal, takes "Latest" |
| release candidate | `release-2.1.0-rc.1` | pre-release, never "Latest" |

1. Write the section the release body comes from: `## [<version>]` in
   [`CHANGELOG.md`](./CHANGELOG.md). A candidate reuses the section of the version it is a candidate
   of, so `2.1.0-rc.1` publishes `## [2.1.0]`.
2. Cut the tag with `hack/release.sh <version>` (for example `hack/release.sh 2.1.0-rc.1`). It refuses
   a version of any other shape, a missing CHANGELOG section, a dirty working tree, a `HEAD` that is
   not the tip of `origin/main`, and a tag that exists locally or on `origin`;
   `hack/release.sh --check <version>` validates without pushing.
3. Pushing the tag starts the pipeline: `release-tag` resolves the version, the channel and the
   section and refuses a tag that is not an ancestor of `origin/main`; `lint`, `schema` and `runtime`
   gate the release; and the `release` job publishes the GitHub release, the `.tgz` and the
   `index.yaml` entry served from the `gh-pages` branch. The chart version is stamped from the tag
   (`helm package --version`), and the release body is the CHANGELOG section, followed by a compare
   link.
4. The job then records the released version in
   [`charts/tuwunel/Chart.yaml`](charts/tuwunel/Chart.yaml) on `main`, in a
   `chore(release): record <tag> [skip ci]` commit - the tag is the source of truth and the branch
   follows it.
5. Consumers pick the version up with `helm repo update`. A candidate is opt-in: it stays invisible to
   an unqualified `helm install` and is reached with
   `helm search repo tuwunel/tuwunel --versions --devel` and `helm install … --version 2.1.0-rc.1`.

Nothing else is a release: a merge publishes nothing, so documentation, CI and even a chart change
are safe until a tag is pushed.

Every pull request runs `lint` (Helm 4 pinned, `helm lint --strict` for the chart defaults and every
scenario values file, then `helm template` + `kubeconform -strict` for the defaults and every
scenario on the Kubernetes versions in the workflow's `env:` block), `schema` (`charts/tuwunel/ci/
invalid/*.yaml` must still be rejected by `values.schema.json`, `charts/tuwunel/ci/invalid-render/*.yaml`
must be rejected by the chart's own template guards, and every supported scenario must render) and
`runtime` ([`hack/runtime-check.sh`](hack/runtime-check.sh) renders each scenario, runs its init
container as rendered to substitute the config, starts the real image with that scenario's env, runs
the declared `tuwunel --health-check` probe and the readiness path, and exercises the backup path
where the scenario enables it). All three jobs run before the release job and are the ones worth
marking as required checks.

## Development

```console
# Chart linting, including values.schema.json validation
helm lint --strict charts/tuwunel

# Every supported scenario must render (the same files CI validates)
for f in charts/tuwunel/ci/*-values.yaml; do
  helm template ci charts/tuwunel -f "$f" > /dev/null || exit 1
done

# Validate rendered manifests against Kubernetes schemas
helm template ci charts/tuwunel --set server_name=matrix.example.org \
  | kubeconform -strict -summary -kubernetes-version 1.31.0

# The schema must reject these
for f in charts/tuwunel/ci/invalid/*.yaml; do
  helm template ci charts/tuwunel -f "$f" > /dev/null && echo "unexpectedly accepted: $f"
done

# These must be rejected by a template guard, not by the schema
for f in charts/tuwunel/ci/invalid-render/*.yaml; do
  helm template ci charts/tuwunel -f "$f" > /dev/null && echo "unexpectedly accepted: $f"
done

# Start the real image per scenario and probe the readiness path (needs docker)
hack/runtime-check.sh
```

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Credits

Based on [modern-conduwuit-helm](https://github.com/magikid/modern-conduwuit-helm) by [magikid](https://github.com/magikid).

## Additional Resources

- [Tuwunel GitHub](https://github.com/matrix-construct/tuwunel)
- [Matrix Protocol](https://matrix.org/)
