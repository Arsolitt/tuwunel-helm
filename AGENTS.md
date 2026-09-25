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

# Only a template can reject these (values.schema.json says nothing about a rule
# that spans two values) - each fixture declares the value its refusal must name
for f in charts/tuwunel/ci/invalid-render/*.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null && echo "accepted: $f"; done

# The runtime gate: renders every fixture and starts its image (needs docker)
hack/runtime-check.sh charts/tuwunel

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
  scenario, then `helm template` + `kubeconform -strict` for the **default values** and each
  scenario on the Kubernetes versions in `env.KUBERNETES_VERSIONS` (the defaults are what
  the release job packages as-is, so they are validated too). kubeconform has no built-in schema for
  `gateway.networking.k8s.io`, and `-strict` turns a missing schema into a failure, so the job
  downloads the `HTTPRoute`/`UDPRoute`/`TCPRoute` JSON schemas from a pinned `datreeio/CRDs-catalog`
  commit, checksum-verifies them, passes their directory as a second `-schema-location` next to
  `default`, and fails whenever the summary is not `Skipped: 0` - a skipped resource is a kind with
  no schema. The job also carries the render assertions no schema can express: an applyable
  `clusterIP` per Service type, host lists without empty entries, and the selector check
  (`hack/selector-check.py`, below) over the defaults and every fixture.
- `schema` - asserts that `charts/tuwunel/ci/invalid/*.yaml` is still rejected **by the schema**
  (not by an unrelated template error), that `charts/tuwunel/ci/invalid-render/*.yaml` is
  rejected **by a template** for the value its `# expect-error:` line names, and that every
  supported scenario still renders.
- `runtime` - renders each `charts/tuwunel/ci/*-values.yaml` scenario and drives the real image
  with what that render says: it runs the scenario's own init container (`dibi/envsubst`) to
  produce the config.toml the server reads, starts the server with the rendered env, config and
  database path, then requires the rendered probe command (`tuwunel --health-check`) to exit 0
  and the readiness URL from the `helm.sh/hook: test` pod to answer 200. A config that turns on
  online backups additionally gets the crontab's SIGUSR2 from a container sharing the server's
  PID namespace and has to produce a backup repository. `hack/runtime-check.sh` hardcodes no env
  name, path or probe - it is the only job that can see a config value written with the wrong
  TOML type (`allow_federation = "false"` makes tuwunel exit 1 at startup) or a readiness path
  that answers 403 in the default federation-disabled configuration; the other jobs check
  manifest shape only and never read the rendered config file.
- `release-tag` - a `push` of a `release-*` tag only, and it runs before the gates. It resolves the
  release with `hack/release.sh --check "$GITHUB_REF_NAME"` - the same script that cuts the tag, so
  the shape rules cannot drift - and refuses a tag that is not an ancestor of `origin/main`. A
  version is either `<major>.<minor>.<patch>` (stable) or `<major>.<minor>.<patch>-rc.<n>` (release
  candidate); anything else, and a missing `## [<version>]` CHANGELOG section, fails here in seconds
  instead of after the ~25-minute `runtime` gate. It publishes `version`, `channel`, `section` and
  `tag` as job outputs.
- `release` - a `push` of a `release-*` tag only, `needs: [release-tag, lint, schema, runtime]`,
  `concurrency: chart-release`. It packages the tagged tree itself with `helm package --version`
  (the tag carries the version; the tree still records the previous release), reads the package back
  to prove its `Chart.yaml` carries that version, then creates the GitHub release with
  `gh release create`: the body is the `## [<version>]` section from
  `hack/release-notes.sh "$VERSION" "$SECTION"`, the package is the uploaded asset, and the track is
  the flag - `--prerelease --latest=false` for a candidate, `--latest` for a stable release (a
  pre-release has to be born one: `cr` cannot create it, and an unflagged candidate is one consumers
  see as stable). Then `cr index --push` rewrites `index.yaml` on `gh-pages`; the pinned `cr` comes
  from `chart-releaser-action@v1.7.0` with `install_only: true`, because the action's own release
  path packages "charts changed since the previous tag" and its script dies on an unbound variable
  when packaging is skipped (fixed on its `main`, unreleased). Finally it commits
  `chore(release): record <tag> [skip ci]` to `main`, recording the released `version`. Nothing is
  published without a tag push: a merge publishes nothing.

Rules that keep this honest:

- Tool pins live in the workflow `env:` block (Helm, kubeconform + its sha256, chart-releaser,
  Kubernetes versions, the pinned `datreeio/CRDs-catalog` commit and the
  `HTTPROUTE_SCHEMA_SHA256`/`UDPROUTE_SCHEMA_SHA256`/`TCPROUTE_SCHEMA_SHA256` schema checksums).
  Nothing uses `@latest`; Dependabot bumps the actions.
- Three fixture categories, one meaning each: `charts/tuwunel/ci/*-values.yaml` must render,
  `ci/invalid/*.yaml` must be rejected by `values.schema.json`, and `ci/invalid-render/*.yaml`
  must be rejected by a template `fail` (each names the value in its `# expect-error:` line).
  A fixture in the wrong folder makes the job that owns it fail, not pass.
- The chart defaults are a supported configuration, so `lint` renders and validates them next to
  the fixtures - the release job packages the tagged tree as-is, so the defaults are what users get.
- A release is a pushed tag of one of two shapes - `release-<major>.<minor>.<patch>` (stable) or
  `release-<major>.<minor>.<patch>-rc.<n>` (release candidate) - and `hack/release.sh <version>` is
  the only thing that creates one. Nothing in the tree is bumped to publish: the version is stamped
  into the package with `helm package --version` and recorded on `main` afterwards in a
  `chore(release): record <tag> [skip ci]` commit.
- `hack/runtime-check.sh` reads its images, env, paths and probes out of the render. If it needs to
  know something the manifests do not say, that is a bug in the manifests.
- `hack/selector-check.py` is the gate that keeps `spec.selector` applyable: no selector, on a
  workload or on a Service, may carry `helm.sh/chart`, `app.kubernetes.io/version` or
  `app.kubernetes.io/managed-by`, and every workload's own pod template has to carry the pairs its
  selector asks for. The first defect is invisible in a single render - the API server only refuses
  the *next* chart version - and chart 2.0.1 shipped it, which made every upgrade of every release
  it created fail with `spec.selector: Invalid value: …: field is immutable`.
- `dibi/envsubst` (the init image) is published for `linux/amd64` only; the runtime gate passes
  `--platform linux/amd64` to the init container on a non-amd64 daemon and nothing else, so a
  native amd64 runner needs no emulation. Overriding `initContainer.image` to a multi-arch or
  mirrored equivalent is supported and takes the same path.
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
├── ci/                     # CI value fixtures (*-values.yaml, invalid/, invalid-render/)
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

- No hand bump: a release is a pushed tag, and `version` in `charts/tuwunel/Chart.yaml` comes from it.
  The `release` job stamps the tag's version into the package with `helm package --version` and
  records it on `main` afterwards, in a `chore(release): record <tag> [skip ci]` commit. Do not edit
  the line to publish a release.
- Update `appVersion` in a pull request when the application version changes.
- `CHANGELOG.md` has to carry the section the release publishes (`## [<version>]`, or for a candidate
  the section of the version it is a candidate of) **before** `hack/release.sh <version>` cuts the
  tag - the release body is that section, and both the script and the `release-tag` job refuse a tag
  without one.

## Common Tasks

### Adding Configuration

1. Add to `values.yaml` with comment and default
2. Reference in template
3. Cover the key in `values.schema.json` (and add a `ci/invalid/` fixture if the key has a shape
   that must be rejected, or a `ci/invalid-render/` fixture if the refusal belongs to a template
   that has to compare two values)
4. Update `charts/tuwunel/README.md`
5. Test with `helm template`, or add a scenario under `charts/tuwunel/ci/` when the combination of
   values deserves permanent coverage

### Adding Optional Component

1. Create template file in subdirectory
2. Wrap in `{{- if .Values.component.enabled -}}`
3. Add to `values.yaml` with `enabled: false`
4. Include labels and security contexts
5. Document in README
