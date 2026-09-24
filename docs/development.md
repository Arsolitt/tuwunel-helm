# Development and releases

> Repository layout, the fixture contract, the local command set and the CI jobs behind this chart, and how a `Chart.yaml` bump becomes a published release.

## Table of Contents

- [Repository layout](#repository-layout)
- [Fixture categories](#fixture-categories)
- [Local validation](#local-validation)
- [The CI jobs](#the-ci-jobs)
- [The runtime check](#the-runtime-check)
- [Releasing](#releasing)
- [Adding or changing a value](#adding-or-changing-a-value)
- [Working in this repo](#working-in-this-repo)

---

## Repository layout

This is a single-chart repository: `charts/tuwunel` is the only chart, and `.github/workflows/ci.yaml` the only pipeline.

```text
tuwunel-helm/
├── .github/
│   ├── workflows/ci.yaml          # the only pipeline: jobs lint, schema, runtime, release
│   ├── ISSUE_TEMPLATE/            # bug_report.yml, feature_request.yml, config.yml
│   ├── CODEOWNERS                 # `* @Arsolitt`
│   ├── dependabot.yml             # weekly, grouped GitHub Actions updates
│   └── PULL_REQUEST_TEMPLATE.md   # what changed / how it was verified / checklist
├── charts/tuwunel/                # the chart
│   ├── Chart.yaml                 # name tuwunel, version 2.0.1, appVersion v1.9.2, kubeVersion '>=1.31.0-0'
│   ├── values.yaml                # defaults (server_name: "yourdomain.com", image.tag: v1.9.2)
│   ├── values.schema.json         # applied by every helm command
│   ├── README.md                  # canonical value reference; ships inside the packaged chart
│   ├── .helmignore                # excludes ci/ - fixtures never ship
│   ├── ci/                        # 30 fixtures: 12 scenarios, 13 invalid, 5 invalid-render
│   └── templates/
│       ├── _helpers.tpl           # named templates (labels, fullname, ...)
│       ├── NOTES.txt              # post-install notes
│       ├── backup-crontabs.yaml   # crontab ConfigMap for the scheduled-backup sidecar
│       ├── pvc-data.yaml          # data volume claim
│       ├── pvc-backup.yaml        # backup repository claim
│       ├── gateway/httproute.yaml # homeserver HTTPRoute (Gateway API exposure)
│       ├── rtc/                   # livekit + jwt workloads, configmap, services, ingress, http/udp/tcp routes
│       ├── tests/test-connection.yaml  # the `helm test` hook: the only file named *test*
│       └── tuwunnel/              # configmap, statefulset, service, ingress
├── docs/                          # this documentation tree
├── hack/
│   ├── runtime-check.sh           # the runtime gate - the `runtime` job just calls it
│   └── release-notes.sh           # prints a CHANGELOG section as the GitHub release body
├── AGENTS.md                      # conventions: style, fixture rules, CI/release rules
├── CHANGELOG.md                   # Keep a Changelog; a released version's section is its release body
├── LICENSE                        # GPL-3.0
└── README.md                      # landing page, install instructions, the release flow
```

There is no test framework. `find . -name '*test*'` returns only `charts/tuwunel/templates/tests/test-connection.yaml` (the `helm test` hook), and `hack/` holds exactly two scripts. Local build artifacts are gitignored: `.tmp`, `output`, `*.tgz`, `.cr-release-packages/`, `.cr-index/`.

## Fixture categories

Three folders, one meaning each. The folder is the contract: a fixture in the wrong folder makes the job that owns it fail, not pass.

| Folder | What the fixture must do | Owning job | Count |
|---|---|---|---|
| `charts/tuwunel/ci/*-values.yaml` | render `helm template` **and** start its image | `lint`, `runtime` | 12 |
| `charts/tuwunel/ci/invalid/*.yaml` | be rejected by `values.schema.json` | `schema` | 13 |
| `charts/tuwunel/ci/invalid-render/*.yaml` | be rejected by a template `fail`, naming the value in its `# expect-error:` line | `schema` | 5 |

### Scenarios - `charts/tuwunel/ci/*-values.yaml`

| Fixture | What it exercises |
|---|---|
| `gateway-media-values.yaml` | RTC media routes on Gateway API with `gateway.enabled: false` (the UDP/TCP routes belong to `rtc.livekit`); LiveKit pod mode, single multiplexed `udp_port: 7882` next to the TCP port `7881` |
| `gateway-values.yaml` | Gateway API instead of Ingress: two `parentRefs` (one namespaced, one picking a listener by `sectionName`), an extra hostname, a delegated domain derived from `well_known.server` (port dropped), route annotations, and an RTC HTTPRoute that inherits `gateway.parentRefs` |
| `ingress-federation-values.yaml` | Ingress with a delegated domain, TLS, extra hosts, federation settings, the client-IP knobs behind a proxy, and the pod-level passthrough (annotations, extra volume/mount) |
| `ingress-tls-values.yaml` | Ingress TLS without a delegated domain, so the TLS host list has to hold `server_name` and the extra host and no empty entry; the previously broken combination |
| `ipv4-only-values.yaml` | `config.global.address: 0.0.0.0` for a netns without a usable IPv6 stack; no PVC |
| `minimal-values.yaml` | Smallest supported install: no Ingress, no RTC, `emptyDir` instead of a PVC |
| `overrides-values.yaml` | Values that worked before `values.schema.json` existed: numeric and string CPU quantities, a quoted service port, a numeric init-container tag, extra/untyped env values, scheduling knobs, labels and annotations |
| `rtc-pod-network-values.yaml` | LiveKit in pod network mode through a LoadBalancer: single `udp_port` and `externalTrafficPolicy: Local` |
| `rtc-values.yaml` | RTC enabled with everything the chart derives left unset: no `well_known` block, no `LIVEKIT_URL` / `LIVEKIT_FULL_ACCESS_HOMESERVERS` / `LIVEKIT_JWT_BIND`, no `livekit.config.keys`, no `networkMode` |
| `scheduled-backup-values.yaml` | Online backups with a per-minute schedule (`* * * * *`), so the runtime job starts the rendered sidecar and lets `crond` fire the job inside its wait window |
| `service-loadbalancer-values.yaml` | The homeserver Service published by a cloud load balancer: `service.type: LoadBalancer` plus `loadBalancerSourceRanges`, which must render without the headless `clusterIP` |
| `storage-and-backup-values.yaml` | S3-backed media storage plus online backups on the default `0 3 * * *` schedule; the runtime job falls back to the crontab's own signal for this one and expects a backup repository under `backup.path` |

Two rules shape a scenario. It must render, and the `runtime` job starts its tuwunel container - which is why `overrides-values.yaml` pins `image.tag: v1.9.2` and the init-container tag: the runtime job starts that exact image. The backup sidecar is the one sidecar the runtime job starts, and only for a scenario whose rendered schedule can fire inside its wait window; nothing in CI installs a Gateway controller or a Gateway: the media routes are rendered and schema-validated, not exercised.

### Schema-rejected fixtures - `charts/tuwunel/ci/invalid/`

| Fixture | Value it must be rejected for |
|---|---|
| `backup-keep-zero.yaml` | `backup.keep: 0` |
| `backup-schedule-bad.yaml` | four-field cron `0 3 * *` in `backup.schedule` |
| `config-quoted-boolean.yaml` | `config.global.allow_federation: "false"` |
| `env-from-secret-without-key.yaml` | `envFromSecret` entry without the `secretName/key` form |
| `extra-env-without-value.yaml` | `extraEnv` entry lacking `value` |
| `image-pull-policy.yaml` | `image.pullPolicy: Sometimes` |
| `ip-source-typo.yaml` | `config.global.ip_source: xforwarded_for` |
| `persistence-access-mode.yaml` | `persistence.data.accessMode: ReadWriteManyy` |
| `resources-limits-null.yaml` | `resources.limits: null` |
| `rtc-enabled-without-domain.yaml` | `rtc.enabled: true` without `rtc.domain` |
| `rtc-network-mode-invalid.yaml` | `rtc.livekit.networkMode: bridge` |
| `service-type-externalname.yaml` | `service.type: ExternalName` - the chart renders no `externalName`, so the type leaves the schema enum |
| `unknown-top-level-key.yaml` | `ingres` (a typo'd top-level key) |

### Template-rejected fixtures - `charts/tuwunel/ci/invalid-render/`

Not every impossible value is a schema question. Rules that span two values belong to a template, and every fixture in this folder declares, in its first comment lines, the substring the refusal has to contain.

| Fixture | `# expect-error:` | Refused by |
|---|---|---|
| `backup-scheduled-without-enabled.yaml` | `backup.enabled` | the statefulset template - the sidecar and its crontab volume are gated on `backup.scheduled`, but the ConfigMap they mount belongs to the backups-enabled render |
| `config-port-mismatch.yaml` | `config.global.port` | the statefulset template - it sets `TUWUNEL_PORT` from `service.port`, so an environment variable would win over the file and the server would listen on a port the values file does not name |
| `gateway-without-parentrefs.yaml` | `gateway.enabled needs gateway.parentRefs` | the gateway HTTPRoute template - the chart renders routes that attach to a Gateway you run, it never creates one |
| `rtc-media-route-without-pod-mode.yaml` | `networkMode=pod` | the udproute template - in hostNetwork mode the media ports are node ports no Service fronts |
| `rtc-pod-udp-range.yaml` | `rtc.livekit.config.rtc.udp_port` | the livekit service template - a Kubernetes Service cannot expose a UDP port range |

### Adding a fixture

```bash
# a scenario: any combination of values that must keep working
# -> charts/tuwunel/ci/<name>-values.yaml

# a shape that values.schema.json must keep rejecting
# -> charts/tuwunel/ci/invalid/<name>.yaml

# a rule that spans two values, enforced by a template fail
# -> charts/tuwunel/ci/invalid-render/<name>.yaml, with the convention:
#
#   # expect-error: <substring the render must report>
```

The `# expect-error:` line is read with `sed -n 's/^# expect-error: //p'`, so it must start at column 1, and the job matches it with `grep -qF` against the combined render output - renaming a value inside a template's `fail` message therefore breaks the fixture loudly instead of silently.

Every check fails closed:

| Situation | Job result |
|---|---|
| A fixture in `ci/invalid-render/` carries no `# expect-error:` line | `::error file=<fixture>::<fixture> has no '# expect-error: <substring>' line naming the value the render must report` |
| Such a fixture renders instead of failing | `::error file=<fixture>::<fixture> rendered, but a template has to refuse it (<expected>)` |
| Such a fixture is refused by the schema instead of by a template | `::error file=<fixture>::<fixture> was rejected by values.schema.json, not by the template that owns the rule (<expected>)` |
| Such a fixture is refused, but the message does not contain the declared substring | `::error file=<fixture>::<fixture> was refused without naming '<expected>'` |
| A fixture in `ci/invalid/` renders successfully | `::error file=<fixture>::<fixture> was accepted, but it must be rejected by charts/tuwunel/values.schema.json` |
| A fixture in `ci/invalid/` fails for a reason that does not mention the schema | `::error file=<fixture>::<fixture> failed for an unexpected reason (not schema validation)` |
| All fixtures are deleted, renamed or moved out of `ci/invalid/` or `ci/invalid-render/` | `::error::no fixtures under charts/tuwunel/ci/invalid/ - this check would pass without validating anything` |

## Local validation

Run these from the repository root. Every one of them is also what CI runs.

| Command | Proves |
|---|---|
| `helm lint --strict charts/tuwunel` | template shape and value validation against `values.schema.json` for the defaults |
| the scenario render loop | every supported scenario still renders |
| `helm template … \| kubeconform -strict -summary …` | rendered manifests are valid against a Kubernetes schema |
| the `ci/invalid/` loop | the schema still refuses these shapes |
| the `ci/invalid-render/` loop | the templates still refuse these combinations |
| `hack/runtime-check.sh charts/tuwunel` | the real image starts per scenario, the rendered probe exits 0, the readiness URL answers 200, and the backup path works where the scenario enables it - through the rendered sidecar when its schedule can fire, otherwise through the crontab's own command |

```console
$ helm lint --strict charts/tuwunel
$ for f in charts/tuwunel/ci/*-values.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null || exit 1; done
$ helm template ci charts/tuwunel --set server_name=matrix.example.org | kubeconform -strict -summary -kubernetes-version 1.31.0
$ for f in charts/tuwunel/ci/invalid/*.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null && echo "unexpectedly accepted: $f"; done
$ for f in charts/tuwunel/ci/invalid-render/*.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null && echo "unexpectedly accepted: $f"; done
$ hack/runtime-check.sh charts/tuwunel
```

Read the output of the two negative loops: they only `echo "unexpectedly accepted: <file>"`, they do not exit non-zero. CI turns the same conditions into a red job. Failures look like this:

| Command | What a failure looks like |
|---|---|
| `helm lint --strict` | non-zero exit with the offending template path or schema violation |
| scenario render loop | `helm template` fails and the loop exits 1 |
| kubeconform | non-zero exit with per-resource errors; CI runs it on both pinned versions (`1.31.0` and `1.37.0`) and additionally asserts the summary reports exactly as many resources as the render has `kind:` lines and that it ends with `Skipped: 0` |
| runtime check | `FAIL <values> <image> -> <assertion>` plus the container's last 30 log lines; the script exits 1 on the first failing scenario |

> **Warning:** `helm lint --strict` can exit 0 on values that `helm install`/`upgrade` refuse. The chart's cross-value guards surface as `level=INFO msg="funcMap fail"` during lint while the exit code stays 0, so verify those changes with `helm template` or `helm install --dry-run`, not with lint alone.

> **Note:** CI pins Helm to the version in the workflow `env:` block (`4.3.0`); a local Helm can be older, and lint output and template error text can differ between versions. The `env:` block is the reference for what the gate actually runs.

> **Warning:** kubeconform ships no schema for `gateway.networking.k8s.io`, and `-strict` turns a missing schema into a failure, so a Gateway scenario needs the same extra schemas the workflow fetches - `httproute_v1.json`, `udproute_v1.json`, `tcproute_v1.json` from the pinned CRDs-catalog commit, passed as a second `-schema-location` next to `default`. The one-liner above renders the defaults, which carry no Gateway resources.

Other useful commands from the same list:

```console
$ helm template release-name charts/tuwunel --include-crds > output.yaml
$ helm dep up charts/tuwunel
$ helm install test-release charts/tuwunel --set server_name=test.example.com --dry-run
$ helm package charts/tuwunel
```

`helm dep up` is a no-op today (`Chart.yaml` declares no dependencies), `output` and `*.tgz` are gitignored, and `helm package` is how you confirm the `ci/` exclusion: the resulting `tuwunel-<version>.tgz` contains `.helmignore`, `Chart.yaml`, `README.md`, `values.yaml`, `values.schema.json` and `templates/*` only.

## The CI jobs

`.github/workflows/ci.yaml` is the only pipeline. It runs on every `pull_request` and on `push` to `main`; job ids double as status-check contexts, and the first three are meant to be required on pull requests.

| Job | Name | Runs | Protects against |
|---|---|---|---|
| `lint` | Lint and validate manifests | `helm lint --strict` for the defaults and every scenario; `helm template` + `kubeconform -strict` for the **default values** and every scenario, on each version in `KUBERNETES_VERSIONS`; two assertions on the renders themselves - `Service types render an applyable clusterIP` (the headless default is kept, a LoadBalancer renders no `clusterIP`) and `Rendered host lists carry no empty entries` (every `spec.tls[].hosts[]`, `spec.rules[].host` and route `spec.hostnames[]` is a non-empty string) | a scenario that stops rendering, a manifest that violates the Kubernetes or Gateway API schemas, and the two combinations no schema can see: `clusterIP: "None"` is legal on a ClusterIP Service only, and kubeconform's Ingress schema accepts an empty host that the API server refuses |
| `schema` | Value schema guardrails | every `ci/invalid/*.yaml` must be refused by the schema; every `ci/invalid-render/*.yaml` must be refused by a template and name its value; every scenario must still render | a weakened `values.schema.json` or a dropped template guard |
| `runtime` | Runtime smoke test against the real image | checkout, the pinned Helm, then `hack/runtime-check.sh "$CHART_DIR"` (`timeout-minutes: 25`) | a config value of the wrong TOML type and a readiness path that answers non-200 - neither is visible to the shape-only jobs; for a schedule that can fire inside the wait window it also starts the rendered backup sidecar, so a sidecar whose job `crond` cannot start fails here |
| `release` | Release chart | chart-releaser, then `gh release edit` with the CHANGELOG section | an unpublished version bump and a release body that stayed the chart description |

Tool pins live in the workflow `env:` block - one pin per tool, no `@latest` anywhere; Dependabot only bumps the actions.

| Pin | Value |
|---|---|
| `HELM_VERSION` | `4.3.0` |
| `KUBECONFORM_VERSION` | `v0.8.0` |
| `KUBECONFORM_SHA256` | `9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883` |
| `CRDS_CATALOG_SHA` | `ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2` |
| `HTTPROUTE_SCHEMA_SHA256` | `e5692e62edd9b8a14bd2527d0a732e174a649131aa4d47159737dc6527c59ca5` |
| `UDPROUTE_SCHEMA_SHA256` | `d624dc44db2eb4dfedcd02a137b7dd1ceabd11d9670335a90727b340b667e5d9` |
| `TCPROUTE_SCHEMA_SHA256` | `91b0188d2b7b0552c462e1fc7dd531b735013e8762d725fdc1e42e49e4bf4418` |
| `CHART_RELEASER_VERSION` | `v1.8.1` |
| `KUBERNETES_VERSIONS` | `1.31.0 1.37.0` |
| `CHART_DIR` | `charts/tuwunel` |
| action pins | `actions/checkout@v7`, `azure/setup-helm@v5`, `helm/chart-releaser-action@v1.7.0` |

Bumping `KUBECONFORM_VERSION` or `CRDS_CATALOG_SHA` without updating the matching checksum fails the job at `sha256sum -c`; those pins travel together.

The `release` job is gated three ways: `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`, `needs: [lint, schema, runtime]`, and `permissions: contents: write` (the workflow default is `contents: read`). Concurrency is one run per workflow and ref, cancelling in progress only for pull requests.

> **Note:** There is deliberately no `paths:` filter on `pull_request`. A job skipped by a path filter never reports a status, so requiring it would block every merge that does not touch those paths - which is also why a docs-only pull request still runs all three quality jobs.

## The runtime check

`hack/runtime-check.sh` is the only gate that starts the real image. Per scenario it:

1. renders the fixture with `helm template` and parses the manifests (`python3` + PyYAML);
2. reads the `tuwunel` container (image, command, args, env, ports, probes), the init container that feeds the rendered `config.toml` through `envsubst`, and the `helm.sh/hook: test` pod;
3. runs that init container as rendered - same image, command, args and env, every `secretKeyRef` faked with a placeholder - so the config the server reads is produced by the chart's own mechanism;
4. starts the image with the rendered env, the substituted config mounted where the manifest reads it, and a tmpfs at the rendered database path;
5. asserts, in order: the container is still running, the *rendered* probe command exits 0, the rendered readiness URL answers 200;
6. for a config that asks for online backups (`database_backup_path` together with `admin_signal_execute`), drives the backup path the render describes: when the rendered schedule can fire inside a 90-second window it starts the *rendered* sidecar — the manifest's own image, command, args, user and capabilities, with the crontab ConfigMap projected into its spool — and lets `crond` fire the job on its own; a schedule that cannot (say `0 3 * * *`) falls back to running the crontab's command once in the server's PID namespace, and prints why. Either path has to leave a `meta/` entry under `backup.path`.

The rule that matters when you change a manifest: it reads images, env names, paths, probes and the readiness URL out of the render, and hardcodes none of them. If the script needs to know something the manifests do not say, that is a bug in the manifests. When the render stops naming something, the script fails with an explicit message instead of guessing:

| Message | Cause |
|---|---|
| `the manifest names no config path (no *_CONFIG env var, no init container output)` | nothing in the render says where the server reads its config |
| `the helm test pod names no http URL to probe` | the `helm.sh/hook: test` pod no longer carries an http(s) URL |
| `cannot tell which config path the rendered init container writes (args: [...])` | the init container's args no longer name both TOML paths |

| Assertion | Failure message |
|---|---|
| container still running | `the container exited on its own (exit code <n>) instead of serving` |
| probe command and readiness URL | whichever deadline expires first: `the readiness path never answered 200 within 180s` while no 200 has been seen, otherwise `the rendered probe command never exited 0 within 180s` |
| backup sidecar start | the rendered sidecar could not be started from `<image>`, or its crontab could not be projected into the spool directory |
| backup signal (fallback path) | `the rendered crontab command (<cmd>) failed in the server's PID namespace` |
| backup repository | `no backup repository (meta/) appeared under <path> within 90s of` the path that was driven - the rendered sidecar's job, or the rendered crontab's signal |

```console
$ hack/runtime-check.sh charts/tuwunel
$ RUNTIME_CHECK_TIMEOUT=300 hack/runtime-check.sh charts/tuwunel
```

Usage is `hack/runtime-check.sh [chart-dir]`, defaulting to `charts/tuwunel`; `RUNTIME_CHECK_TIMEOUT` is the ready budget per fixture and defaults to 180 seconds. The script preflights `docker`, `helm` and `python3` on `PATH`, a reachable Docker daemon, a `python3` with `pyyaml`, and the chart directory - each exits 2. It fails on the first failing scenario (exit 1) and prints the scenario, the image, the failed assertion and the server's last 30 log lines - plus, when the run started the backup sidecar, its state and its last 20 log lines.

Every scenario gets a unique container name and scratch directory derived from `GITHUB_RUN_ID` or the shell PID, world-writable mounts (the pod's uid writes them), and a cleanup trap that removes the container on success, failure and interrupt. An empty scenario glob is a failure of the script itself:

```text
::error::no fixtures matched charts/tuwunel/ci/*-values.yaml - this job would pass without checking anything
```

> **Note:** The init image (`dibi/envsubst:1`, pinned by `initContainer.image`) is published for `linux/amd64` only, so on a non-amd64 daemon the script passes `--platform linux/amd64` to the init container and to nothing else; the tuwunel image is multi-arch and is left to the daemon. Overriding `initContainer.image` to a multi-arch or mirrored equivalent takes the same path.

## Releasing

Only a `Chart.yaml` version bump publishes anything.

1. Bump `version` in `charts/tuwunel/Chart.yaml` and add the matching `## [<version>] - <date>` section to `CHANGELOG.md` **in the same commit**.
2. Merge to `main`. The `release` job runs only there, and only after `lint`, `schema` and `runtime` pass.
3. chart-releaser packages the chart, creates the `tuwunel-<version>` tag and the GitHub release, and updates `index.yaml` on the `gh-pages` branch (which holds `.nojekyll` and `index.yaml` only). `skip_existing: true` means an already-released version is skipped.
4. The next step replaces the release body: it reads `name` and `version` back from each chart in the action's `changed_charts` output, builds `tag=<name>-<version>`, runs `hack/release-notes.sh "$version"` and applies the result with `gh release edit "$tag" --notes-file`.
5. Consumers pick the version up with `helm repo update`.

The notes step exists because chart-releaser cannot carry release notes: `chart-releaser-action@v1.7.0` has no notes input, and `cr upload` reads a notes file only from inside the packaged chart. The action's own `chart_version` output is not usable either - it is the *previous* tag from `git describe --tags --abbrev=0 HEAD~`, which is why the released version is read back from `Chart.yaml`.

`hack/release-notes.sh <version>` prints the `## [<version>]` section of `CHANGELOG.md`, from the heading up to (excluding) the next `## ` heading, plus a best-effort `**Full Changelog**: https://github.com/<repo>/compare/<previous-tag>...<tag>` line when the repository, the `<chart>-<version>` tag and a previous `<chart>-*` tag are all resolvable.

| Invocation | Result |
|---|---|
| `hack/release-notes.sh 2.0.0` | exit 0, the section plus the compare link on stdout |
| `hack/release-notes.sh 9.9.9` | exit 1, nothing on stdout, `no '## [9.9.9]' section in <...>/CHANGELOG.md: add it before releasing 9.9.9, the GitHub release body is taken from it` |
| `hack/release-notes.sh` (no argument) | exit 2, `usage: hack/release-notes.sh <version>   (e.g. 2.0.0)` |
| `CHANGELOG_FILE=<path> hack/release-notes.sh <version>` | reads that file instead of the repository changelog (the documented test hook); a missing file exits 1 with `no changelog file <path>: it holds the release body for <version>` |

The heading match is a literal prefix and requires a space or the end of the line after the closing bracket, so looking for `1.2.0` cannot pick up a `## [1.2.0-rc1]` heading above it. A heading written as `## [2.0.0]-something` matches nothing and fails the release job.

| Failure mode | What happens |
|---|---|
| No `## [<version>]` section for the released version | `hack/release-notes.sh` exits 1, and the release job fails - after chart-releaser has already created the tag, the GitHub release and the `index.yaml` entry; the release body stays the chart `description` |
| `version` unchanged in the merge | nothing is published; the job summary prints `No chart version change detected - nothing was published.` and `Bump \`version\` in \`charts/tuwunel/Chart.yaml\` to publish a release.` |
| A merge that only touches docs or CI | same as above - safe, nothing is published |
| A pre-release | not supported: only stable `version` values are published, there is no pre-release channel |
| A pin and its checksum updated separately | the job fails at `sha256sum -c` before validating anything |

> **Tip:** To see what is actually published, read `origin/gh-pages` (or the chart repository URL) rather than a local `gh-pages` branch - a checkout's local branch can lag the published `index.yaml`.

## Adding or changing a value

Adding a value means touching three places:

| Place | What changes |
|---|---|
| `charts/tuwunel/values.yaml` | the value itself, with a comment and its default |
| `charts/tuwunel/values.schema.json` | the shape rule that keeps impossible values out |
| [`charts/tuwunel/README.md`](../charts/tuwunel/README.md) | the value tables (this file ships inside the packaged chart, so it is the reader's reference) |

Then decide the fixture:

| If the change | Put it |
|---|---|
| is a combination of values worth permanent coverage | a scenario in `charts/tuwunel/ci/<name>-values.yaml` |
| has a shape that must be rejected | a fixture in `charts/tuwunel/ci/invalid/` |
| is a rule that spans two values and belongs to a template | a fixture in `charts/tuwunel/ci/invalid-render/` with the `# expect-error:` line |

The full procedure for a configuration key is: add it to `values.yaml` with a comment and default, reference it in a template, cover it in `values.schema.json`, update the chart README, then test with `helm template` (or add a scenario when the combination deserves permanent coverage).

Two packaging rules apply to everything under `ci/`:

- `charts/tuwunel/.helmignore` excludes `ci/`, so scenarios and negative fixtures never ship in the packaged chart. `helm package charts/tuwunel` is the check.
- That file's last pattern (`ci/`) has no trailing newline. Add a newline before appending a pattern, or the new pattern merges into `ci/` and excludes the wrong path.

If a new value renders a kind that no earlier render produced, the `lint` job fails until that kind's schema is in the pinned set - a rendered resource kubeconform cannot find a schema for is a failure (`kubeconform skipped resources, so a kind has no schema (add it to the pinned set)`), never a silent pass. The Gateway API kinds are handled that way already; see [Configuring the server](./configuration.md) for the value-level reference and [How the chart renders a running server](./internals.md) for what the templates derive.

## Working in this repo

[`AGENTS.md`](../AGENTS.md) carries the conventions a change must follow.

| Area | Rule |
|---|---|
| Whitespace control | `{{-` trims before, `-}}` trims after; wrap optional resources in `{{- if .Values.x.enabled -}}` |
| Indentation | `nindent` for nested blocks, 4 spaces for labels under `labels:` |
| Naming | Templates `chartname.resourcetype` (e.g. `tuwunel.fullname`); component suffixes `-livekit`, `-jwt`, `-configmap`; helper templates live in `_helpers.tpl` with a doc comment |
| Labels | Every resource carries `{{- include "tuwunel.labels" . \| nindent 4 }}` plus `app.kubernetes.io/component: <component>` |
| Security contexts | Pod-level on every workload: `runAsNonRoot: true`, `runAsUser`/`runAsGroup`, `seccompProfile: RuntimeDefault` (LiveKit is the exception - only the seccomp profile); every container adds `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false` and `capabilities.drop: [ALL]` |
| `values.yaml` style | `##` for section headers, `#` for inline comments, `enabled: false` for optional features |
| Env vars | three patterns: plain `{{- range $key, $val := .Values.env }}`, secret form `secretName/key` via `name: {{ (split "/" $val)._0 }}`, and raw sections via `{{- with .Values.envRaw }}{{- toYaml . \| nindent 12 }}{{- end }}` |
| Pins | Nothing uses `@latest`: the workflow `env:` block pins Helm, kubeconform (+ sha256), chart-releaser, the Kubernetes versions and the CRDs-catalog commit; Dependabot bumps the GitHub Actions only |
| Version bump | increment `version` in `charts/tuwunel/Chart.yaml`, update `appVersion` when the application version changes, merge to `main` |
| Documentation | the repository's prose is English - `values.yaml` comments, `charts/tuwunel/README.md`, `CHANGELOG.md`, `ci/` fixture header comments - and every fixture header explains why the fixture exists |

The pull request template asks for what changed, how it was verified, and a six-item checklist: lint passes, every scenario renders, `hack/runtime-check.sh` passes, new or changed values are covered by `values.schema.json` and the chart README tables, nothing under `ci/invalid/` became acceptable to the schema, and `version` was bumped when chart contents changed. `.github/CODEOWNERS` assigns every path to one owner, and Dependabot opens weekly grouped action updates rather than touching the manual tool pins.

Related pages: [Upgrading](./upgrade.md) for what a published version change means to consumers, [Troubleshooting](./troubleshooting.md) for reading the render refusals and runtime failures, and [Installing the chart](./installation.md) for the consumer side of the published chart.
