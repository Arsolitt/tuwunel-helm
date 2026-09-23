# Tuwunel Helm Chart

Helm chart for deploying [Tuwunel](https://github.com/matrix-construct/tuwunel) - a Matrix homeserver based on Conduit.

This chart is designed for tuwunel but can also work with other Conduit forks such as [Continuwuity](https://continuwuity.org/).

> **Note:** This chart is based on [modern-conduwuit-helm](https://github.com/magikid/modern-conduwuit-helm) by magikid.

## Features

- Matrix homeserver deployment
- Optional Matrix RTC support via LiveKit (Element Call)
- Persistent storage support
- Ingress configuration
- Resource management
- Environment variable injection from secrets

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

The chart deploys with RocksDB storage by default:

```yaml
server_name: "yourdomain.com"

config:
  global:
    allow_registration: "true"
    registration_token: "your-secret-token"
```

## Matrix RTC (Element Call) Support

This chart supports Matrix RTC via LiveKit for Element Call functionality. See the [chart README](charts/tuwunel/README.md#matrix-rtc-element-call-support) for detailed configuration.

### Prerequisites

1. Create Kubernetes secret with LiveKit credentials
2. Configure DNS for RTC domain
3. Update `config.global.well_known.rtc_transports`

## Using with Other Conduit Forks

This chart is primarily designed for tuwunel but can work with other Conduit forks like Continuwuity. To use with a different fork, override the image:

```yaml
image:
  repository: ghcr.io/continuwuity/continuwuity
  tag: latest
```

## Releasing New Chart Versions

Releases are automated by [`.github/workflows/ci.yaml`](./.github/workflows/ci.yaml):

1. Bump `version` in [`charts/tuwunel/Chart.yaml`](charts/tuwunel/Chart.yaml) and merge to `main`.
2. `chart-releaser` packages the chart, creates the `tuwunel-<version>` tag and
   GitHub release, and updates the `index.yaml` served from the `gh-pages` branch.
3. `helm repo update` on a consumer then picks the new version up.

A merge that does not change the chart version publishes nothing, so documentation
and CI changes are safe. Only stable versions are published - there is no
pre-release channel.

Every pull request runs `lint` (Helm 4 pinned, `helm lint --strict` plus
`kubeconform` over the scenario values in [`charts/tuwunel/ci/`](charts/tuwunel/ci)),
`schema` (the value schema must still reject the fixtures in
[`charts/tuwunel/ci/invalid/`](charts/tuwunel/ci/invalid)) and `runtime`
([`hack/runtime-check.sh`](hack/runtime-check.sh) starts the real image once per
scenario and probes the readiness path). All three jobs run before the release
job and are the ones worth marking as required checks.

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
