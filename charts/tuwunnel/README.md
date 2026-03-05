# Conduwuit

This helm chart started out as a fork of the [tuwunel-helm][tuwunel-helm] chart. There's been a bunch of drama between forks since [conduwuit][conduwuit] shuttered. This repo works for both [tuwunel][tuwunel-homepage] and [continuwuity][cont-homepage] and probably any other forks of conduwuit. If it doesn't open an issue and I'll see what I can do for it.

## TL;DR;

```console
helm install --set server_name=matrix.example.org oci://ghcr.io/magikid/modern-conduwuit-helm/conduwuit
```

## Installing the Chart

To install the chart with the release name `my-release`:

```console
helm install --name my-release oci://ghcr.io/magikid/modern-conduwuit-helm/conduwuit
```

## Uninstalling the Chart

To uninstall/delete the `my-release` deployment:

```console
helm delete my-release
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

## Configuration

The following tables lists the configurable parameters of the tuwunel chart and their default values.

| Parameter                          | Description                                                                                 | Default                            |
| ---------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------- |
| `image.repository`                 | Image repository                                                                            | `ghcr.io/matrix-construct/tuwunel` |
| `image.tag`                        | Image tag. Possible values listed [here][docker].                                           | `v1.4.1`                           |
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
| `ingress.hosts`                    | Ingress accepted hostnames                                                                  | `[tuwunel]`                        |
| `ingress.tls`                      | Whether or not to configure TLS for the ingerss                                             | `false`                            |
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
helm install --name my-release \
	--set ingress.enabled=true \
	oci://ghcr.io/magikid/modern-conduwuit-helm/conduwuit
```

Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart. For example,

```console
helm install --name my-release -f values.yaml oci://ghcr.io/magikid/modern-conduwuit-helm/conduwuit
```

Read through the [values.yaml](values.yaml) file.

## Matrix RTC (Element Call) Configuration

This chart optionally supports Matrix RTC via LiveKit for Element Call functionality. This enables audio/video calling features in Element Web and other Matrix clients.

### Prerequisites

1. **Create Kubernetes secret with LiveKit credentials:**

```bash
# Generate random credentials
LIVEKIT_KEY=$(openssl rand -hex 10)
LIVEKIT_SECRET=$(openssl rand -hex 32)

# Create secret
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
# Enable Matrix RTC
rtc:
  enabled: true
  domain: "matrix-rtc.yourdomain.com"
  
  # JWT service (handles authentication)
  jwt:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
      LIVEKIT_URL: "wss://matrix-rtc.yourdomain.com"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "yourdomain.com"
  
  # LiveKit media server
  livekit:
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
    config:
      keys:
        "${LIVEKIT_KEY}": "${LIVEKIT_SECRET}"
  
  # Ingress for RTC services
  ingress:
    enabled: true
    class: nginx
    tls: true
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"

# Configure well-known for RTC discovery
config:
  global:
    well_known:
      rtc_transports:
        - type: livekit
          livekit_service_url: "https://matrix-rtc.yourdomain.com"
```

### Network Modes

**LoadBalancer (default):**
- Uses Kubernetes LoadBalancer service
- Preserves client source IP with `externalTrafficPolicy: Local`
- Requires cloud provider LoadBalancer support
- Recommended for most deployments

**hostNetwork:**
- Pod uses host network namespace
- Direct access to host ports
- Required for some bare-metal setups
- Set with `rtc.livekit.networkMode: "hostNetwork"`

### Port Configuration

For LoadBalancer mode, ensure your cloud provider allows the following ports:
- `7880/tcp` - HTTP API
- `7881/tcp` - RTC TCP
- `50100-50200/udp` - RTC UDP range (media streams)

For hostNetwork mode, ensure firewall allows these ports on the node.

### Deployment

```bash
# Install with RTC enabled
helm install matrix oci://ghcr.io/magikid/modern-conduwuit-helm/conduwuit \
  -f values.yaml \
  --set server_name=yourdomain.com
```

### Troubleshooting

1. **Check pods are running:**
   ```bash
   kubectl get pods -l app.kubernetes.io/name=conduwuit
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

### Additional Resources

- [LiveKit Documentation](https://docs.livekit.io/)
- [Matrix RTC Specification](https://github.com/matrix-org/matrix-spec-proposals/pull/4143)
- [Element Call](https://call.element.io/)

[docker]: https://ghcr.io/matrix-construct/tuwunel:latest
[github]: https://github.com/matrix-construct/tuwunel
[tuwunel-homepage]: https://tuwunel.chat/
[cont-homepage]: https://continuwuity.org/
[conduwuit]: https://gitlab.cronce.io/charts/conduwuit
[tuwunel-helm]: https://github.com/AreYouLoco/tuwunel-helm
[delegate]: https://matrix-org.github.io/synapse/v1.46/delegate.html
