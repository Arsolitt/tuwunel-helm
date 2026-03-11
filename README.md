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

The following tables list the configurable parameters of the tuwunel chart and their default values.

### Core Configuration

| Parameter                          | Description                                                                                 | Default                            |
| ---------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------- |
| `server_name`                      | Server name (your Matrix domain)                                                            | `yourdomain.com`                   |
| `image.repository`                 | Image repository                                                                            | `ghcr.io/matrix-construct/tuwunel` |
| `image.tag`                        | Image tag                                                                                   | `v1.5.1`                           |
| `image.pullPolicy`                 | Image pull policy                                                                           | `IfNotPresent`                     |
| `initContainer.image.repository`   | Init container image for envsubst                                                           | `dibi/envsubst`                    |
| `initContainer.image.tag`          | Init container image tag                                                                    | `1`                                |
| `initContainer.image.pullPolicy`   | Init container pull policy                                                                  | `IfNotPresent`                     |

### Environment Variables

| Parameter              | Description                                          | Default |
| ---------------------- | ---------------------------------------------------- | ------- |
| `env`                  | Plain text environment variables for config          | `{}`    |
| `envRaw`               | Raw environment variable sections (complex configs)  | `[]`    |
| `envFromSecret`        | Environment variables from Kubernetes secrets        | `{}`    |
| `extraEnv`             | Additional environment variables for the container   | `[]`    |

### Tuwunel Configuration

| Parameter                                   | Description                                                                                 | Default                  |
| ------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------ |
| `config.global.allow_registration`          | Whether to allow users to register new accounts                                             | `true`                   |
| `config.global.registration_token`          | Token required for registration                                                             | `supa-dupa-secret-token` |
| `config.global.allow_federation`            | Whether to allow federating with other Matrix servers                                       | `false`                  |
| `config.global.trusted_servers`             | Servers to trust when federating                                                            | `[]`                     |
| `config.global.tls`                         | TLS configuration                                                                           | `{}`                     |
| `config.global.well_known.client`           | Client delegation URL (for delegated domains)                                               |                          |
| `config.global.well_known.server`           | Server delegation (for delegated domains)                                                   |                          |
| `config.global.well_known.rtc_transports`   | RTC transports configuration for Element Call                                               |                          |
| `config.global.blurhashing`                 | Blurhash configuration                                                                      | `{}`                     |
| `config.global.ldap`                        | LDAP configuration                                                                          | `{}`                     |
| `config.global.antispam`                    | Antispam configuration (meowlnir, draupnir)                                                 | `{}`                     |

### Service Configuration

| Parameter                          | Description                                                                                 | Default                            |
| ---------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------- |
| `service.annotations`              | Annotations for Service resource                                                            | `{}`                               |
| `service.type`                     | Type of service to deploy                                                                   | `ClusterIP`                        |
| `service.clusterIP`                | ClusterIP of service; if blank, selected at random                                          | `None`                             |
| `service.port`                     | Port to expose service                                                                      | `8080`                             |
| `service.externalIPs`              | External IPs for service                                                                    | `[]`                               |
| `service.loadBalancerIP`           | Load balancer IP                                                                            | `""`                               |
| `service.loadBalancerSourceRanges` | List of IP CIDRs allowed to access the load balancer                                        | `[]`                               |

### Ingress Configuration

| Parameter                    | Description                                           | Default       |
| ---------------------------- | ----------------------------------------------------- | ------------- |
| `ingress.enabled`            | Whether to deploy the Ingress resource                | `false`       |
| `ingress.class`              | Ingress class                                         | `""`          |
| `ingress.annotations`        | Ingress annotations                                   | `{}`          |
| `ingress.path`               | Ingress path                                          | `/`           |
| `ingress.extraHosts`         | Additional hostnames                                  | `[]`          |
| `ingress.tls`                | Whether to configure TLS for the ingress              | `false`       |
| `ingress.tlsSecretName`      | TLS secret name (defaults to `<release-name>-tls`)    | `""`          |

### Persistence Configuration

| Parameter                          | Description                                           | Default          |
| ---------------------------------- | ----------------------------------------------------- | ---------------- |
| `persistence.data.enabled`         | Use persistent volume to store data                   | `true`           |
| `persistence.data.size`            | Size of persistent volume claim                       | `4Gi`            |
| `persistence.data.existingClaim`   | Use an existing PVC to persist data                   | `""`             |
| `persistence.data.storageClass`    | Type of persistent volume claim                       | `""`             |
| `persistence.data.accessMode`      | PVC access mode                                       | `ReadWriteOnce`  |

### Resource Configuration

| Parameter              | Description                   | Default         |
| ---------------------- | ----------------------------- | --------------- |
| `resources.requests`   | CPU/Memory resource requests  | 50m/128Mi       |
| `resources.limits`     | CPU/Memory resource limits    | 1/512Mi         |

### Pod Scheduling

| Parameter                  | Description                       | Default |
| -------------------------- | --------------------------------- | ------- |
| `nodeSelector`             | Node labels for pod assignment    | `{}`    |
| `tolerations`              | Toleration labels for pod assignment | `[]`  |
| `affinity`                 | Affinity settings for pod assignment | `{}`  |
| `extraLabels`              | Additional labels for all resources | `{}`  |
| `statefulsetAnnotations`   | Annotations for the StatefulSet   | `{}`    |

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
server_name: "yourdomain.com"

rtc:
  enabled: true
  domain: "matrix-rtc.yourdomain.com"
  
  jwt:
    env:
      LIVEKIT_URL: "wss://matrix-rtc.yourdomain.com"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "yourdomain.com"
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
  
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

### RTC Configuration Parameters

| Parameter                              | Description                                           | Default                    |
| -------------------------------------- | ----------------------------------------------------- | -------------------------- |
| `rtc.enabled`                          | Enable Matrix RTC support                             | `false`                    |
| `rtc.domain`                           | RTC domain for LiveKit services                       | `""`                       |
| `rtc.jwt.image.repository`             | JWT service image                                     | `ghcr.io/element-hq/lk-jwt-service` |
| `rtc.jwt.image.tag`                    | JWT service image tag                                 | `0.4.1`                    |
| `rtc.jwt.resources`                    | JWT service resources                                 | 50m-200m/128Mi-256Mi       |
| `rtc.jwt.env`                          | JWT service environment variables                     | `{}`                       |
| `rtc.jwt.envFromSecret`                | JWT service env from secrets                          | `{}`                       |
| `rtc.livekit.image.repository`         | LiveKit server image                                  | `livekit/livekit-server`   |
| `rtc.livekit.image.tag`                | LiveKit server image tag                              | `v1.9.12`                  |
| `rtc.livekit.resources`                | LiveKit server resources                              | 50m-1/128Mi-1Gi            |
| `rtc.livekit.networkMode`              | Network mode (currently only `hostNetwork`)           | `hostNetwork`              |
| `rtc.livekit.config.port`              | HTTP API port                                         | `7880`                     |
| `rtc.livekit.config.rtc.tcp_port`      | RTC TCP port                                          | `7881`                     |
| `rtc.livekit.config.rtc.port_range_start` | UDP port range start                               | `50100`                    |
| `rtc.livekit.config.rtc.port_range_end` | UDP port range end                                  | `50200`                    |
| `rtc.ingress.enabled`                  | Enable RTC ingress                                    | `false`                    |
| `rtc.ingress.class`                    | Ingress class                                         | `""`                       |
| `rtc.ingress.tls`                      | Enable TLS                                            | `false`                    |
| `rtc.ingress.tlsSecretName`            | TLS secret name                                       | `""`                       |

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
  -f values.yaml
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

## Using Secrets for Configuration

You can inject sensitive configuration from Kubernetes secrets:

```yaml
envFromSecret:
  DATABASE_PASSWORD: my-secret/db-password

config:
  global:
    registration_token:
      __env: REGISTRATION_TOKEN
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
