# AGENTS.md

Guidelines for agentic coding agents working in this repository.

## Project Overview

Helm chart for deploying [Tuwunel](https://github.com/matrix-construct/tuwunel), a Matrix homeserver based on Conduit, with optional LiveKit RTC support for Element Call.

## Build/Lint/Test Commands

```bash
# Lint charts (also validates values against charts/tuwunel/values.schema.json)
helm lint --strict charts/tuwunel

# Every supported scenario must render - these are the files CI validates
for f in charts/tuwunel/ci/*-values.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null; done

# The schema must reject these
for f in charts/tuwunel/ci/invalid/*.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null && echo "accepted: $f"; done

# Template charts (render YAML)
helm template release-name charts/tuwunel --include-crds > output.yaml

# Validate against Kubernetes schemas (CI checks 1.31.0 and the newest release)
helm template x charts/tuwunel --include-crds | kubeconform -summary -strict -kubernetes-version=1.31.0

# Update dependencies
helm dep up charts/tuwunel

# Install locally (dry-run)
helm install test-release charts/tuwunel --set server_name=test.example.com --dry-run

# Package chart
helm package charts/tuwunel
```

## CI and Releases

`.github/workflows/ci.yaml` is the only pipeline; job ids double as status-check contexts.

- `lint` - `helm lint --strict` for the chart defaults and every `charts/tuwunel/ci/*-values.yaml`
  scenario, then `helm template` + `kubeconform -strict` for each scenario on the Kubernetes
  versions in `env.KUBERNETES_VERSIONS`.
- `schema` - asserts that `charts/tuwunel/ci/invalid/*.yaml` is still rejected **by the schema**
  (not by an unrelated template error) and that every supported scenario still renders.
- `runtime` - starts the real image once per `charts/tuwunel/ci/*-values.yaml` scenario with that
  scenario's rendered env vars and a bind-mounted rendered `config.toml`, and polls the readiness
  probe's port and path until it answers 200 (90 s per scenario; a container that exits by itself,
  or a path that never returns 200, fails with the container's `docker logs`). It is the only job
  that can see a config value written with the wrong TOML type (`allow_federation = "false"` makes
  tuwunel exit 1 at startup) or a readiness path that answers 403 in the default
  federation-disabled configuration; the other jobs check manifest shape only and never read the
  rendered config file.
- `release` - `push` to `main` only, `needs: [lint, schema, runtime]`, runs `chart-releaser`. It packages
  charts whose `version` is not released yet, creates the `tuwunel-<version>` tag and GitHub
  release, and updates `index.yaml` on `gh-pages`. Unchanged versions are skipped, so a
  documentation-only merge publishes nothing.

Rules that keep this honest:

- Tool pins live in the workflow `env:` block (Helm, kubeconform + its sha256, chart-releaser,
  Kubernetes versions). Nothing uses `@latest`; Dependabot bumps the actions.
- Adding a value means touching three places: `values.yaml`, `values.schema.json`, and the value
  tables in `charts/tuwunel/README.md`.
- `charts/tuwunel/.helmignore` excludes `ci/`; scenario and invalid fixtures never ship.
- There is no `paths:` filter on `pull_request` - a job skipped by a filter never reports a
  status, which would deadlock a future required check.

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
├── values.schema.json      # Value validation, enforced by CI
├── README.md               # Documentation
├── ci/                     # CI value fixtures (*-values.yaml, invalid/)
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
3. Merge to `main` - the `release` job in `.github/workflows/ci.yaml` publishes to GitHub Releases
   and GitHub Pages whenever the version is not released yet

## Common Tasks

### Adding Configuration

1. Add to `values.yaml` with comment and default
2. Reference in template
3. Cover the key in `values.schema.json` (and add a `ci/invalid/` fixture if the key has a shape
   that must be rejected)
4. Update `charts/tuwunel/README.md`
5. Test with `helm template`, or add a scenario under `charts/tuwunel/ci/` when the combination of
   values deserves permanent coverage

### Adding Optional Component

1. Create template file in subdirectory
2. Wrap in `{{- if .Values.component.enabled -}}`
3. Add to `values.yaml` with `enabled: false`
4. Include labels and security contexts
5. Document in README
