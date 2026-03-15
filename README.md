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

New chart versions are automatically published through [GitHub Actions](./.github/workflows/release.yml). To deploy a new version, increment the chart version in `charts/tuwunel/Chart.yaml`.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Credits

Based on [modern-conduwuit-helm](https://github.com/magikid/modern-conduwuit-helm) by [magikid](https://github.com/magikid).

## Additional Resources

- [Tuwunel GitHub](https://github.com/matrix-construct/tuwunel)
- [Matrix Protocol](https://matrix.org/)
