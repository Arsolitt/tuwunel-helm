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

## Add Repository

```console
helm repo add tuwunel https://arsolitt.github.io/tuwunel-helm
helm repo update
```

## TL;DR

```console
helm install --set config.server_name=matrix.example.org tuwunel/tuwunel
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

The following tables lists the configurable parameters of the tuwunel chart and their default values.

| Parameter                          | Description                                                                                 | Default                            |
| ---------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------- |
| `image.repository`                 | Image repository                                                                            | `ghcr.io/matrix-construct/tuwunel`        |
| `image.tag`                        | Image tag                                                                                   | `v1.5.0`                           |
| `image.pullPolicy`                 | Image pull policy                                                                           | `IfNotPresent`                     |
| `config.server_name`               | Server name                                                                                 | `your.server.name`                 |
| `config.max_request_size`          | Maximum upload size                                                                         | `20000000` (20MB)                  |
| `config.allow_registration`        | Whether or not to allow users to register new accounts                                      | `false`                            |
| `config.registration_token`        | Must be set in order to use registrations                                                   | `supa-dupa-secret-token`           |
| `config.allow_federation`          | Whether or not to allow federating with other Matrix servers                                | `false`                            |
| `config.trusted_servers`           | Servers to trust when federating; if enabling federating, `matrix.org` usually makes sense  | `[]`                               |
| `config.delegatedDomain`           | Set the domain that you're delegating to. See [synapse delegate docs][delegate] for details |                                    |
| `extraLabels`                      | Additional labels to apply to all created resources                                         | `{}`                               |
| `service.annotations`              | Annotations for Service resource                                                            | `{}`                               |
| `service.type`                     | Type of service to deploy                                                                   | `ClusterIP`                        |
| `service.clusterIP`                | ClusterIP of service; if blank, it will be selected at random from the cluster CIDR range   | `None`                             |
| `service.port`                     | Port to expose service                                                                      | `8200`                             |
| `service.externalIPs`              | External IPs for service                                                                    | `[]`                               |
| `service.loadBalancerIP`           | Load balancer IP                                                                            | `""`                               |
| `service.loadBalancerSourceRanges` | List of IP CIDRs allowed to access the load balancer (if supported)                         | `[]`                               |
| `ingress.enabled`                  | Whether or not to deploy the Ingress resource                                               | `false`                            |
| `ingress.class`                    | Ingress class (included in annotations)                                                     | ``                                 |
| `ingress.annotations`              | Ingress annotations                                                                         | `{}`                               |
| `ingress.path`                     | Ingress path                                                                                | `/`                                |
| `ingress.hosts`                    | Ingress accepted hostnames                                                                  | `[tuwunel]`                       |
| `ingress.tls`                      | Whether or not to configure TLS for the ingress                                             | `false`                            |
| `persistence.data.enabled`         | Use persistent volume to store data                                                         | `true`                             |
| `persistence.data.size`            | Size of persistent volume claim                                                             | `1Gi`                              |
| `persistence.data.existingClaim`   | Use an existing PVC to persist data                                                         | ``                                 |
| `persistence.data.storageClass`    | Type of persistent volume claim                                                             | ``                                 |
| `persistence.data.accessMode`      | PVC access mode                                                                             | `ReadWriteMany`                    |
| `resources.requests`               | CPU/Memory resource requests                                                                | 1CPU/256MiB                        |
| `resources.limits`                 | CPU/Memory resource limits                                                                  | 2CPU/512MiB                        |
| `nodeSelector`                     | Node labels for pod assignment                                                              | `{}`                               |
| `tolerations`                      | Toleration labels for pod assignment                                                        | `[]`                               |
| `affinity`                         | Affinity settings for pod assignment                                                        | `{}`                               |

Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example,

```console
helm install my-release \
	--set ingress.enabled=true \
	tuwunel/tuwunel
```

Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart. For example,

```console
helm install my-release -f values.yaml tuwunel/tuwunel
```

Read through the [values.yaml](charts/tuwunel/values.yaml) file.

## Matrix RTC (Element Call) Support

This chart supports Matrix RTC via LiveKit for Element Call functionality. This enables audio/video calling features in Element Web and other Matrix clients.

### Prerequisites

1. **Create Kubernetes secret with LiveKit credentials:**

```bash
LIVEKIT_KEY=$(openssl rand -hex 10)
LIVEKIT_SECRET=$(openssl rand -hex 32)

kubectl create secret generic livekit-secrets \
  --from-literal=LIVEKIT_KEY=$LIVEKIT_KEY \
  --from-literal=LIVEKIT_SECRET=$LIVEKIT_SECRET
```

2. **Configure DNS for RTC domain:**
   - Point `matrix-rtc.yourdomain.com` to your cluster's LoadBalancer IP
   - Or use your cloud provider's DNS solution

### Basic Configuration

Add the following to your `values.yaml`:

```yaml
rtc:
  enabled: true
  domain: "matrix-rtc.yourdomain.com"
  
  jwt:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
      LIVEKIT_URL: "wss://matrix-rtc.yourdomain.com"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "yourdomain.com"
  
  livekit:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
    config:
      keys:
        "${LIVEKIT_KEY}": "${LIVEKIT_SECRET}"
  
  ingress:
    enabled: true
    class: nginx
    tls: true
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"

config:
  global:
    well_known:
      rtc_transports:
        - type: livekit
          livekit_service_url: "https://matrix-rtc.yourdomain.com"
```

### Network Modes

**hostNetwork (current):**
- Pod uses host network namespace
- Direct access to host ports
- Required for WebRTC connections
- Ensure firewall allows ports 7880, 7881, and 50100-50200

**LoadBalancer (TODO):**
- Will use Kubernetes LoadBalancer service
- Will preserve client source IP with `externalTrafficPolicy: Local`
- Will require cloud provider LoadBalancer support
- Not yet implemented

### Port Configuration

Ensure firewall allows the following ports on the node:
- `7880/tcp` - HTTP API
- `7881/tcp` - RTC TCP
- `50100-50200/udp` - RTC UDP range (media streams)

### Deployment

```bash
helm install matrix tuwunel/tuwunel \
  -f values.yaml \
  --set config.server_name=yourdomain.com
```

### Troubleshooting

1. **Check pods are running:**
   ```bash
   kubectl get pods -l app.kubernetes.io/name=tuwunel
   ```

2. **Check LoadBalancer IP:**
   ```bash
   kubectl get svc -l app.kubernetes.io/component=rtc-livekit
   ```

3. **Test well-known:**
   ```bash
   curl https://yourdomain.com/.well-known/matrix/client
   ```

4. **Check logs:**
   ```bash
   kubectl logs -l app.kubernetes.io/component=rtc-jwt
   kubectl logs -l app.kubernetes.io/component=rtc-livekit
   ```

## Using with Other Conduit Forks

This chart is primarily designed for tuwunel but can work with other Conduit forks like Continuwuity. To use with a different fork, override the image:

```yaml
image:
  repository: ghcr.io/continuwuity/continuwuity
  tag: latest
```

## TODO

- [ ] Support for Coturn (TURN server)
- [ ] S3 backup support
- [ ] Backup restoration instructions
- [ ] Gateway API support
- [ ] LoadBalancer support for LiveKit (currently only hostNetwork is available)

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Credits

Based on [modern-conduwuit-helm](https://github.com/magikid/modern-conduwuit-helm) by [magikid](https://github.com/magikid).

## Additional Resources

- [tuwunel GitHub](https://github.com/matrix-construct/tuwunel)

[delegate]: https://matrix-org.github.io/synapse/v1.46/delegate.html
