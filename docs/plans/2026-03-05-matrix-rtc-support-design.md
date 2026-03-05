# Matrix RTC Support Design

Date: 2026-03-05

## Overview

Add optional Matrix RTC (Real-Time Communication) support to the tuwunnel Helm chart, enabling Element Call functionality through LiveKit integration.

## Requirements

- Deploy lk-jwt-service and livekit-server as optional components
- Support both hostNetwork and LoadBalancer networking modes for LiveKit
- Add separate Ingress for RTC domain with proper routing
- Support environment variable substitution (envsubst) in configurations
- Maintain consistency with existing chart patterns

## Architecture

### File Structure

```
charts/tuwunnel/
├── templates/
│   ├── tuwunnel/
│   │   ├── statefulset.yaml      # + init container for envsubst
│   │   ├── service.yaml          # unchanged
│   │   ├── configmap.yaml        # template with placeholder support
│   │   └── ingress.yaml          # existing tuwunel ingress
│   ├── rtc/
│   │   ├── jwt-deployment.yaml   # Deployment for lk-jwt-service
│   │   ├── livekit-deployment.yaml
│   │   ├── livekit-service.yaml  # LoadBalancer or ClusterIP
│   │   ├── livekit-configmap.yaml
│   │   └── ingress.yaml          # separate ingress for RTC domain
│   ├── pvc-data.yaml
│   └── _helpers.tpl
└── values.yaml
```

### Components

1. **lk-jwt-service** - JWT token service for LiveKit authentication
2. **livekit-server** - WebRTC media server for real-time communication
3. **RTC Ingress** - Routes traffic to appropriate services based on path

## Design Decisions

### 1. Modular Architecture

Chosen approach: Subfolders (`tuwunnel/` and `rtc/`) for clean separation.

Rationale:
- Easy to enable/disable RTC via single flag
- Clear separation of concerns
- Easier navigation as chart grows

### 2. Network Modes for LiveKit

Support both modes via `rtc.livekit.networkMode`:

**hostNetwork mode:**
- Pod uses host network namespace
- Required for some Kubernetes setups
- Needs appropriate privileges

**LoadBalancer mode:**
- External traffic policy: Local
- Preserves client source IP
- Standard Kubernetes approach

### 3. Port Configuration

Ports are auto-generated from `rtc.livekit.config`:
- `config.port` → HTTP port (7880)
- `config.rtc.tcp_port` → RTC TCP port (7881)
- `config.rtc.port_range_start` to `port_range_end` → UDP range (50100-50200)

Rationale: Single source of truth, no duplication in values.yaml.

### 4. Secret Management

Use `envFromSecret` pattern:
```yaml
envFromSecret:
  LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
  LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
```

Template generates:
```yaml
env:
  - name: LIVEKIT_KEY
    valueFrom:
      secretKeyRef:
        name: livekit-secrets
        key: LIVEKIT_KEY
```

Rationale: Standard Kubernetes pattern, integrates with external-secrets.

### 5. Configuration with envsubst

Init container processes configuration templates:

```yaml
initContainers:
  - name: config-processor
    image: {{ .Values.initContainer.image.repository }}:{{ .Values.initContainer.image.tag }}
    command: ["/bin/sh", "-c"]
    args:
      - envsubst < /config-template/config.toml > /config/config.toml
    env:
      - name: LIVEKIT_KEY
        valueFrom:
          secretKeyRef: ...
    volumeMounts:
      - name: config-template
        mountPath: /config-template
      - name: config
        mountPath: /config
```

ConfigMap contains placeholders:
```yaml
keys:
  ${LIVEKIT_KEY}: ${LIVEKIT_SECRET}
```

Applied to both:
- Tuwunnel StatefulSet (config.toml)
- LiveKit Deployment (livekit.yaml)

### 6. well_known Configuration

Manual configuration in `config.global.well_known`:

```yaml
config:
  global:
    well_known:
      rtc_transports:
        - type: livekit
          livekit_service_url: "https://matrix-rtc.yourdomain.com"
```

Rationale: Full control, explicit configuration, no magic.

### 7. RTC Ingress

Separate Ingress resource with path-based routing:

- `/sfu/get*` → jwt-service (port 8081)
- `/healthz*` → jwt-service (port 8081)
- `/` → livekit-server (port 7880)

Includes WebSocket support annotations for nginx-ingress.

## values.yaml Structure

```yaml
## Init container for envsubst
initContainer:
  image:
    repository: busybox
    tag: latest
    pullPolicy: IfNotPresent

## Matrix RTC configuration
rtc:
  enabled: false
  domain: ""
  
  jwt:
    image:
      repository: ghcr.io/element-hq/lk-jwt-service
      tag: latest
      pullPolicy: IfNotPresent
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
      LIVEKIT_JWT_BIND: ":8081"
      LIVEKIT_URL: "wss://matrix-rtc.yourdomain.com"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "yourdomain.com"
  
  livekit:
    image:
      repository: livekit/livekit-server
      tag: latest
      pullPolicy: IfNotPresent
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
    
    networkMode: "loadBalancer"  # or "hostNetwork"
    
    service:
      type: LoadBalancer
      externalTrafficPolicy: Local
    
    config:
      port: 7880
      bind_addresses: [""]
      rtc:
        tcp_port: 7881
        port_range_start: 50100
        port_range_end: 50200
        use_external_ip: true
        enable_loopback_candidate: false
      keys:
        "${LIVEKIT_KEY}": "${LIVEKIT_SECRET}"
  
  ingress:
    enabled: true
    class: ""
    annotations: {}
    tls: false
    tlsSecretName: ""
```

## Implementation Notes

1. Create Kubernetes Secret for LiveKit credentials before deployment
2. Configure DNS for RTC domain (e.g., matrix-rtc.yourdomain.com)
3. Set `rtc.enabled: true` to deploy RTC components
4. Update `config.global.well_known.rtc_transports` for Matrix RTC discovery
5. For LoadBalancer mode, ensure cloud provider supports LoadBalancer services
6. For hostNetwork mode, ensure cluster allows host network access

## Testing Strategy

1. Deploy with RTC disabled - verify no RTC resources created
2. Deploy with RTC enabled - verify all components created
3. Test JWT service endpoints via Ingress
4. Test LiveKit WebSocket connections
5. Verify envsubst processes config correctly
6. Test both network modes (hostNetwork and LoadBalancer)
7. Verify port generation from config
8. Test secret reference resolution
