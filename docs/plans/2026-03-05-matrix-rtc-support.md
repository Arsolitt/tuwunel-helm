# Matrix RTC Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add optional Matrix RTC (LiveKit) support to tuwunnel Helm chart for Element Call functionality.

**Architecture:** Modular structure with rtc/ subfolder containing separate deployments for lk-jwt-service and livekit-server. Init containers handle envsubst for both tuwunnel and livekit configs. Ports auto-generated from livekit config.

**Tech Stack:** Helm 3, Kubernetes Deployments, Services, Ingress, ConfigMaps, Init Containers

---

## Task 1: Reorganize templates into subfolders

**Files:**
- Move: `charts/tuwunnel/templates/statefulset.yaml` → `charts/tuwunnel/templates/tuwunnel/statefulset.yaml`
- Move: `charts/tuwunnel/templates/service.yaml` → `charts/tuwunnel/templates/tuwunnel/service.yaml`
- Move: `charts/tuwunnel/templates/configmap.yaml` → `charts/tuwunnel/templates/tuwunnel/configmap.yaml`
- Move: `charts/tuwunnel/templates/ingress.yaml` → `charts/tuwunnel/templates/tuwunnel/ingress.yaml`
- Move: `charts/tuwunnel/templates/pvc-data.yaml` → `charts/tuwunnel/templates/pvc-data.yaml` (stays at root)

**Step 1: Create tuwunnel subfolder**

```bash
mkdir -p charts/tuwunnel/templates/tuwunnel
```

**Step 2: Move template files**

```bash
mv charts/tuwunnel/templates/statefulset.yaml charts/tuwunnel/templates/tuwunnel/
mv charts/tuwunnel/templates/service.yaml charts/tuwunnel/templates/tuwunnel/
mv charts/tuwunnel/templates/configmap.yaml charts/tuwunnel/templates/tuwunnel/
mv charts/tuwunnel/templates/ingress.yaml charts/tuwunnel/templates/tuwunnel/
```

**Step 3: Verify Helm still works**

Run: `helm template test charts/tuwunnel/`
Expected: No errors, all resources rendered

**Step 4: Commit**

```bash
git add charts/tuwunnel/templates/
git commit -m "refactor: reorganize templates into tuwunnel subfolder"
```

---

## Task 2: Add initContainer configuration to values.yaml

**Files:**
- Modify: `charts/tuwunnel/values.yaml`

**Step 1: Add initContainer section**

Add after line 9 (after image.pullPolicy):

```yaml
## Init container for envsubst
initContainer:
  image:
    repository: busybox
    tag: latest
    pullPolicy: IfNotPresent
```

**Step 2: Verify YAML syntax**

Run: `helm lint charts/tuwunnel/`
Expected: PASS

**Step 3: Commit**

```bash
git add charts/tuwunnel/values.yaml
git commit -m "feat: add initContainer configuration to values.yaml"
```

---

## Task 3: Add envsubst init container to tuwunnel StatefulSet

**Files:**
- Modify: `charts/tuwunnel/templates/tuwunnel/statefulset.yaml`

**Step 1: Rename config volume to config-template**

Change line 102-103:

```yaml
        - name: config-template
          configMap:
            name: {{ template "tuwunel.fullname" . }}-configmap
```

**Step 2: Add emptyDir volume for processed config**

After line 103, add:

```yaml
        - name: config
          emptyDir: {}
```

**Step 3: Add init container before main container**

After line 42 (before `- name: tuwunel`), add:

```yaml
      initContainers:
        - name: config-processor
          image: "{{ .Values.initContainer.image.repository }}:{{ .Values.initContainer.image.tag }}"
          imagePullPolicy: {{ .Values.initContainer.image.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - envsubst < /config-template/config.toml > /config/config.toml
          env:
            {{- range $key, $val := .Values.config.global.envFromSecret }}
            - name: {{ $key }}
              valueFrom:
                secretKeyRef:
                  name: {{ (split "/" $val)._0 }}
                  key: {{ (split "/" $val)._1 }}
            {{- end }}
          volumeMounts:
            - name: config-template
              mountPath: /config-template
            - name: config
              mountPath: /config
      containers:
```

**Step 4: Verify template renders**

Run: `helm template test charts/tuwunnel/ --set config.global.envFromSecret.TEST_KEY=secret-name/key`
Expected: Init container appears in StatefulSet

**Step 5: Commit**

```bash
git add charts/tuwunnel/templates/tuwunnel/statefulset.yaml
git commit -m "feat: add envsubst init container to tuwunnel StatefulSet"
```

---

## Task 4: Create rtc subfolder and JWT deployment

**Files:**
- Create: `charts/tuwunnel/templates/rtc/jwt-deployment.yaml`

**Step 1: Create rtc subfolder**

```bash
mkdir -p charts/tuwunnel/templates/rtc
```

**Step 2: Create jwt-deployment.yaml**

Create file with content:

```yaml
{{- if .Values.rtc.enabled -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "tuwunel.fullname" . }}-jwt
  labels:
    {{- include "tuwunel.labels" . | nindent 4 }}
    app.kubernetes.io/component: rtc-jwt
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "tuwunel.labels" . | nindent 6 }}
      app.kubernetes.io/component: rtc-jwt
  template:
    metadata:
      labels:
        {{- include "tuwunel.labels" . | nindent 8 }}
        app.kubernetes.io/component: rtc-jwt
    spec:
      containers:
        - name: jwt-service
          image: "{{ .Values.rtc.jwt.image.repository }}:{{ .Values.rtc.jwt.image.tag }}"
          imagePullPolicy: {{ .Values.rtc.jwt.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 8081
          env:
            {{- range $key, $val := .Values.rtc.jwt.envFromSecret }}
            - name: {{ $key }}
              valueFrom:
                secretKeyRef:
                  name: {{ (split "/" $val)._0 }}
                  key: {{ (split "/" $val)._1 }}
            {{- end }}
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
{{- end }}
```

**Step 3: Verify template renders**

Run: `helm template test charts/tuwunnel/ --set rtc.enabled=true`
Expected: Deployment rendered

**Step 4: Commit**

```bash
git add charts/tuwunnel/templates/rtc/
git commit -m "feat: add jwt-service deployment for RTC"
```

---

## Task 5: Create JWT service

**Files:**
- Create: `charts/tuwunnel/templates/rtc/jwt-service.yaml`

**Step 1: Create jwt-service.yaml**

```yaml
{{- if .Values.rtc.enabled -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "tuwunel.fullname" . }}-jwt
  labels:
    {{- include "tuwunel.labels" . | nindent 4 }}
    app.kubernetes.io/component: rtc-jwt
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8081
      targetPort: http
      protocol: TCP
  selector:
    {{- include "tuwunel.labels" . | nindent 4 }}
    app.kubernetes.io/component: rtc-jwt
{{- end }}
```

**Step 2: Verify service renders**

Run: `helm template test charts/tuwunnel/ --set rtc.enabled=true`
Expected: Service rendered

**Step 3: Commit**

```bash
git add charts/tuwunnel/templates/rtc/jwt-service.yaml
git commit -m "feat: add jwt-service ClusterIP for RTC"
```

---

## Task 6: Create livekit ConfigMap

**Files:**
- Create: `charts/tuwunnel/templates/rtc/livekit-configmap.yaml`

**Step 1: Create livekit-configmap.yaml**

```yaml
{{- if .Values.rtc.enabled -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "tuwunel.fullname" . }}-livekit
  labels:
    {{- include "tuwunel.labels" . | nindent 4 }}
    app.kubernetes.io/component: rtc-livekit
data:
  livekit.yaml: |
    {{- with .Values.rtc.livekit.config }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
{{- end }}
```

**Step 2: Verify configmap renders**

Run: `helm template test charts/tuwunnel/ --set rtc.enabled=true`
Expected: ConfigMap with livekit.yaml

**Step 3: Commit**

```bash
git add charts/tuwunnel/templates/rtc/livekit-configmap.yaml
git commit -m "feat: add livekit ConfigMap template"
```

---

## Task 7: Create livekit deployment with init container

**Files:**
- Create: `charts/tuwunnel/templates/rtc/livekit-deployment.yaml`

**Step 1: Create livekit-deployment.yaml**

```yaml
{{- if .Values.rtc.enabled -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "tuwunel.fullname" . }}-livekit
  labels:
    {{- include "tuwunel.labels" . | nindent 4 }}
    app.kubernetes.io/component: rtc-livekit
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "tuwunel.labels" . | nindent 6 }}
      app.kubernetes.io/component: rtc-livekit
  template:
    metadata:
      labels:
        {{- include "tuwunel.labels" . | nindent 8 }}
        app.kubernetes.io/component: rtc-livekit
    spec:
      {{- if eq .Values.rtc.livekit.networkMode "hostNetwork" }}
      hostNetwork: true
      {{- end }}
      initContainers:
        - name: config-processor
          image: "{{ .Values.initContainer.image.repository }}:{{ .Values.initContainer.image.tag }}"
          imagePullPolicy: {{ .Values.initContainer.image.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - envsubst < /config-template/livekit.yaml > /config/livekit.yaml
          env:
            {{- range $key, $val := .Values.rtc.livekit.envFromSecret }}
            - name: {{ $key }}
              valueFrom:
                secretKeyRef:
                  name: {{ (split "/" $val)._0 }}
                  key: {{ (split "/" $val)._1 }}
            {{- end }}
          volumeMounts:
            - name: config-template
              mountPath: /config-template
            - name: config
              mountPath: /config
      containers:
        - name: livekit
          image: "{{ .Values.rtc.livekit.image.repository }}:{{ .Values.rtc.livekit.image.tag }}"
          imagePullPolicy: {{ .Values.rtc.livekit.image.pullPolicy }}
          command: ["livekit-server"]
          args: ["--config", "/config/livekit.yaml"]
          ports:
            - name: http
              containerPort: {{ .Values.rtc.livekit.config.port }}
            - name: rtc-tcp
              containerPort: {{ .Values.rtc.livekit.config.rtc.tcp_port }}
          volumeMounts:
            - name: config
              mountPath: /config
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi
      volumes:
        - name: config-template
          configMap:
            name: {{ include "tuwunel.fullname" . }}-livekit
        - name: config
          emptyDir: {}
{{- end }}
```

**Step 2: Verify deployment renders**

Run: `helm template test charts/tuwunnel/ --set rtc.enabled=true`
Expected: Deployment with init container

**Step 3: Commit**

```bash
git add charts/tuwunnel/templates/rtc/livekit-deployment.yaml
git commit -m "feat: add livekit deployment with envsubst init container"
```

---

## Task 8: Create livekit service with auto-generated ports

**Files:**
- Create: `charts/tuwunnel/templates/rtc/livekit-service.yaml`

**Step 1: Create livekit-service.yaml**

```yaml
{{- if and .Values.rtc.enabled (eq .Values.rtc.livekit.networkMode "loadBalancer") -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "tuwunel.fullname" . }}-livekit
  labels:
    {{- include "tuwunel.labels" . | nindent 4 }}
    app.kubernetes.io/component: rtc-livekit
spec:
  type: {{ .Values.rtc.livekit.service.type }}
  {{- if .Values.rtc.livekit.service.externalTrafficPolicy }}
  externalTrafficPolicy: {{ .Values.rtc.livekit.service.externalTrafficPolicy }}
  {{- end }}
  ports:
    - name: http
      port: {{ .Values.rtc.livekit.config.port }}
      targetPort: http
      protocol: TCP
    - name: rtc-tcp
      port: {{ .Values.rtc.livekit.config.rtc.tcp_port }}
      targetPort: rtc-tcp
      protocol: TCP
    {{- $start := .Values.rtc.livekit.config.rtc.port_range_start -}}
    {{- $end := .Values.rtc.livekit.config.rtc.port_range_end -}}
    {{- range $i := until (add1 (sub $end $start)) }}
    - name: rtc-udp-{{ $i }}
      port: {{ add $start $i }}
      targetPort: {{ add $start $i }}
      protocol: UDP
    {{- end }}
  selector:
    {{- include "tuwunel.labels" $ | nindent 4 }}
    app.kubernetes.io/component: rtc-livekit
{{- end }}
```

**Step 2: Verify service renders with correct ports**

Run: `helm template test charts/tuwunnel/ --set rtc.enabled=true --set rtc.livekit.networkMode=loadBalancer`
Expected: Service with HTTP (7880), RTC-TCP (7881), and UDP range (50100-50200)

**Step 3: Verify no service when hostNetwork**

Run: `helm template test charts/tuwunnel/ --set rtc.enabled=true --set rtc.livekit.networkMode=hostNetwork`
Expected: No livekit Service rendered

**Step 4: Commit**

```bash
git add charts/tuwunnel/templates/rtc/livekit-service.yaml
git commit -m "feat: add livekit LoadBalancer service with auto-generated ports"
```

---

## Task 9: Create RTC ingress

**Files:**
- Create: `charts/tuwunnel/templates/rtc/ingress.yaml`

**Step 1: Create ingress.yaml**

```yaml
{{- if and .Values.rtc.enabled .Values.rtc.ingress.enabled -}}
{{- $fullName := include "tuwunel.fullname" . -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $fullName }}-rtc
  labels:
    {{- include "tuwunel.labels" . | nindent 4 }}
    app.kubernetes.io/component: rtc-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/websocket-services: {{ $fullName }}-livekit
    {{- with .Values.rtc.ingress.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- if .Values.rtc.ingress.class }}
  ingressClassName: {{ .Values.rtc.ingress.class | quote }}
  {{- end }}
  {{- if .Values.rtc.ingress.tls }}
  tls:
    - hosts:
        - {{ .Values.rtc.domain }}
      secretName: {{ .Values.rtc.ingress.tlsSecretName | default (printf "%s-rtc-tls" $fullName) }}
  {{- end }}
  rules:
    - host: {{ .Values.rtc.domain }}
      http:
        paths:
          - path: /sfu/get
            pathType: Prefix
            backend:
              service:
                name: {{ $fullName }}-jwt
                port:
                  number: 8081
          - path: /healthz
            pathType: Prefix
            backend:
              service:
                name: {{ $fullName }}-jwt
                port:
                  number: 8081
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $fullName }}-livekit
                port:
                  number: {{ .Values.rtc.livekit.config.port }}
{{- end }}
```

**Step 2: Verify ingress renders**

Run: `helm template test charts/tuwunnel/ --set rtc.enabled=true --set rtc.ingress.enabled=true --set rtc.domain=matrix-rtc.example.com`
Expected: Ingress with correct paths

**Step 3: Commit**

```bash
git add charts/tuwunnel/templates/rtc/ingress.yaml
git commit -m "feat: add RTC ingress with JWT and LiveKit routing"
```

---

## Task 10: Update values.yaml with RTC configuration

**Files:**
- Modify: `charts/tuwunnel/values.yaml`

**Step 1: Add RTC configuration section**

Add after line 100 (after `affinity: {}`):

```yaml

## Matrix RTC configuration (optional)
## Requires separate Kubernetes secret with LIVEKIT_KEY and LIVEKIT_SECRET
rtc:
  enabled: false
  
  ## RTC domain (e.g., matrix-rtc.yourdomain.com)
  domain: ""
  
  jwt:
    image:
      repository: ghcr.io/element-hq/lk-jwt-service
      tag: latest
      pullPolicy: IfNotPresent
    
    ## Environment variables from secrets
    ## Format: VAR_NAME: secret-name/key-name
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
      ## Update these for your deployment
      LIVEKIT_JWT_BIND: ":8081"
      LIVEKIT_URL: "wss://matrix-rtc.yourdomain.com"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "yourdomain.com"
  
  livekit:
    image:
      repository: livekit/livekit-server
      tag: latest
      pullPolicy: IfNotPresent
    
    ## Environment variables from secrets
    envFromSecret:
      LIVEKIT_KEY: livekit-secrets/LIVEKIT_KEY
      LIVEKIT_SECRET: livekit-secrets/LIVEKIT_SECRET
    
    ## Network mode: "loadBalancer" or "hostNetwork"
    networkMode: "loadBalancer"
    
    ## Service configuration (only used when networkMode is loadBalancer)
    service:
      type: LoadBalancer
      externalTrafficPolicy: Local
    
    ## LiveKit configuration (converted to livekit.yaml)
    ## Service ports are auto-generated from this config
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
    ## TLS secret name (defaults to <release-name>-rtc-tls if not specified)
    tlsSecretName: ""
```

**Step 2: Add example to config.global.well_known**

Modify line 21 to show RTC example:

```yaml
    well_known: {}
    ## Example RTC configuration (uncomment when enabling RTC)
    # rtc_transports:
    #   - type: livekit
    #     livekit_service_url: "https://matrix-rtc.yourdomain.com"
```

**Step 3: Verify YAML syntax**

Run: `helm lint charts/tuwunnel/`
Expected: PASS

**Step 4: Commit**

```bash
git add charts/tuwunnel/values.yaml
git commit -m "feat: add RTC configuration to values.yaml with examples"
```

---

## Task 11: Update _helpers.tpl if needed

**Files:**
- Check: `charts/tuwunnel/templates/_helpers.tpl`

**Step 1: Check if _helpers.tpl exists**

Run: `ls charts/tuwunnel/templates/_helpers.tpl`
Expected: File exists or not

**Step 2: If exists, verify labels helper**

Run: `grep -A5 "{{- define \"tuwunel.labels\"" charts/tuwunnel/templates/_helpers.tpl`
Expected: Labels helper exists

**Step 3: If no issues, skip this task**

If _helpers.tpl is fine, just note it in commit message.

**Step 4: Commit (if changes made)**

```bash
git add charts/tuwunnel/templates/_helpers.tpl
git commit -m "chore: verify _helpers.tpl compatibility with RTC labels"
```

---

## Task 12: Test complete chart rendering

**Files:**
- Test: Full chart rendering

**Step 1: Test with RTC disabled**

Run: `helm template test-release charts/tuwunnel/ --set server_name=example.com`
Expected: Only tuwunnel resources rendered

**Step 2: Test with RTC enabled**

Run: `helm template test-release charts/tuwunnel/ --set server_name=example.com --set rtc.enabled=true --set rtc.domain=matrix-rtc.example.com`
Expected: All tuwunnel + RTC resources rendered

**Step 3: Test with hostNetwork**

Run: `helm template test-release charts/tuwunnel/ --set server_name=example.com --set rtc.enabled=true --set rtc.livekit.networkMode=hostNetwork`
Expected: No livekit Service, deployment has hostNetwork: true

**Step 4: Test with envFromSecret**

Run: `helm template test-release charts/tuwunnel/ --set server_name=example.com --set rtc.enabled=true --set rtc.jwt.envFromSecret.LIVEKIT_KEY=my-secret/key`
Expected: secretKeyRef in deployment

**Step 5: Commit test results**

Document test results in commit:

```bash
git add -A
git commit -m "test: verify RTC chart rendering with various configurations"
```

---

## Task 13: Update README with RTC documentation

**Files:**
- Modify: `charts/tuwunnel/README.md`

**Step 1: Add RTC section to README**

Add after existing configuration sections:

```markdown
## Matrix RTC (Element Call) Configuration

This chart optionally supports Matrix RTC via LiveKit for Element Call functionality.

### Prerequisites

1. Create Kubernetes secret with LiveKit credentials:
```bash
kubectl create secret generic livekit-secrets \
  --from-literal=LIVEKIT_KEY=your-20-char-key \
  --from-literal=LIVEKIT_SECRET=your-64-char-secret
```

2. Configure DNS for RTC domain (e.g., `matrix-rtc.yourdomain.com`)

### Basic Configuration

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
  
  ingress:
    enabled: true
    class: nginx
    tls: true

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
- Preserves client source IP with externalTrafficPolicy: Local
- Requires cloud provider LoadBalancer support

**hostNetwork:**
- Pod uses host network namespace
- Direct access to host ports
- Requires appropriate cluster permissions

### Port Configuration

Ports are auto-generated from `rtc.livekit.config`:
- HTTP: `config.port` (default: 7880)
- RTC TCP: `config.rtc.tcp_port` (default: 7881)
- RTC UDP: `config.rtc.port_range_start` to `port_range_end` (default: 50100-50200)
```

**Step 2: Commit README**

```bash
git add charts/tuwunnel/README.md
git commit -m "docs: add Matrix RTC configuration documentation"
```

---

## Task 14: Final validation and commit

**Files:**
- All modified files

**Step 1: Run helm lint**

Run: `helm lint charts/tuwunnel/`
Expected: PASS

**Step 2: Run helm template with full config**

Run: `helm template test charts/tuwunnel/ -f charts/tuwunnel/values.yaml --set rtc.enabled=true --set server_name=test.com`
Expected: All resources render without errors

**Step 3: Review git status**

Run: `git status`
Expected: All changes committed

**Step 4: Create final commit if needed**

```bash
git add -A
git commit -m "feat: complete Matrix RTC support implementation"
```

---

## Summary

This plan adds complete Matrix RTC support to the tuwunnel Helm chart:

1. ✅ Modular architecture with tuwunnel/ and rtc/ subfolders
2. ✅ envsubst init containers for both tuwunnel and livekit configs
3. ✅ JWT service deployment and service
4. ✅ LiveKit deployment with hostNetwork/LoadBalancer support
5. ✅ Auto-generated ports from livekit config
6. ✅ Separate RTC ingress with path-based routing
7. ✅ Comprehensive values.yaml with examples
8. ✅ Full documentation in README

All tasks follow TDD principles with verification at each step.
