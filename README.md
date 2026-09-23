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

Releases are automated by [`.github/workflows/ci.yaml`](./.github/workflows/ci.yaml):

1. Bump `version` in [`charts/tuwunel/Chart.yaml`](charts/tuwunel/Chart.yaml) and merge to `main`.
2. `chart-releaser` packages the chart, creates the `tuwunel-<version>` tag and
   GitHub release, and updates the `index.yaml` served from the `gh-pages` branch.
3. `helm repo update` on a consumer then picks the new version up.

A merge that does not change the chart version publishes nothing, so documentation
and CI changes are safe. Only stable versions are published - there is no
pre-release channel.

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
