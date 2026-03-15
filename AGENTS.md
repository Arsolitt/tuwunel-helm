# AGENTS.md

Guidelines for agentic coding agents working in this repository.

## Project Overview

Helm chart for deploying [Tuwunel](https://github.com/matrix-construct/tuwunel), a Matrix homeserver based on Conduit, with optional LiveKit RTC support for Element Call.

## Build/Lint/Test Commands

```bash
# Lint charts
helm lint --quiet charts/tuwunel

# Template charts (render YAML)
helm template release-name charts/tuwunel --include-crds > output.yaml

# Validate against Kubernetes schemas
helm template x charts/tuwunel --include-crds | kubeconform -summary -strict -ignore-missing-schemas -kubernetes-version=1.31.0

# Update dependencies
helm dep up charts/tuwunel

# Install locally (dry-run)
helm install test-release charts/tuwunel --set server_name=test.example.com --dry-run

# Package chart
helm package charts/tuwunel
```

## Code Style Guidelines

### Whitespace Control

Use `{{-` to trim before, `-}}` to trim after:

```yaml
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
{{- end }}
```

### Indentation

Use `nindent` for nested blocks (2-space indent):

```yaml
labels:
  {{- include "tuwunel.labels" . | nindent 4 }}
```

### Conditionals

- Wrap optional resources in `{{- if .Values.xxx.enabled -}}`
- Use `{{- with .Values.xxx }}` for scoping
- Use `required` for mandatory values: `{{ required "error message" .Values.value | quote }}`

### Loops

```yaml
{{- range $key, $val := .Values.env }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- end }}
```

### Helper Templates (_helpers.tpl)

Define with chart name prefix and doc comments:

```yaml
{{/* Expand the name of the chart. */}}
{{- define "tuwunel.name" -}}
  {{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
```

### Standard Labels

Always include on all resources:

```yaml
labels:
  {{- include "tuwunel.labels" . | nindent 4 }}
  app.kubernetes.io/component: <component-name>
```

### Security Contexts

Apply to all containers:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: <uid>
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop:
      - ALL
```

### Values File (values.yaml)

- Use `##` for section headers, `#` for inline comments
- Group related values; set sensible defaults
- Use `enabled: false` for optional features

```yaml
## Ingress configuration
ingress:
  enabled: false
  class: ""
  annotations: {}
```

### Environment Variables

Three patterns:

1. Plain text: `{{- range $key, $val := .Values.env }}`
2. From secrets (`secretName/key`): `name: {{ (split "/" $val)._0 }}`
3. Raw sections: `{{- with .Values.envRaw }}{{- toYaml . | nindent 12 }}{{- end }}`

### File Organization

```
charts/tuwunel/
├── Chart.yaml              # Chart metadata
├── values.yaml             # Default configuration
├── README.md               # Documentation
├── templates/
│   ├── _helpers.tpl        # Reusable functions
│   ├── NOTES.txt           # Post-install notes
│   ├── tuwunnel/           # Main components
│   └── rtc/                # Optional RTC components
└── .helmignore
```

### Naming Conventions

- Templates: `chartname.resourcetype` (e.g., `tuwunel.fullname`)
- Resources: `{{ template "tuwunel.fullname" . }}`
- Component suffixes: `-livekit`, `-jwt`, `-configmap`

### Version Updates

1. Increment `version` in `charts/tuwunel/Chart.yaml`
2. Update `appVersion` if application version changes
3. Release workflow auto-publishes to GitHub Pages

## Common Tasks

### Adding Configuration

1. Add to `values.yaml` with comment and default
2. Reference in template
3. Update `charts/tuwunel/README.md`
4. Test with `helm template`

### Adding Optional Component

1. Create template file in subdirectory
2. Wrap in `{{- if .Values.component.enabled -}}`
3. Add to `values.yaml` with `enabled: false`
4. Include labels and security contexts
5. Document in README
