# Upgrading

> How to move an existing release onto a newer chart version: the version numbers you are agreeing to, the values migrations for 2.0.0, the database migration window, and the checks that prove the result.

## Table of Contents

- [The version contract](#the-version-contract)
- [Before you upgrade](#before-you-upgrade)
- [Upgrading from 1.x to 2.0.0](#upgrading-from-1x-to-200)
- [The database migration window](#the-database-migration-window)
- [Upgrade procedure](#upgrade-procedure)
- [After the upgrade](#after-the-upgrade)
- [Rolling back](#rolling-back)
- [Changes that publish nothing](#changes-that-publish-nothing)

---

## The version contract

`charts/tuwunel/Chart.yaml` carries three version numbers, and each one gates something different:

| Field | Value in chart 2.0.1 | What it decides |
| --- | --- | --- |
| `version` | `2.0.1` | The chart release. The git tag and the published index entry are `tuwunel-2.0.1`. |
| `appVersion` | `v1.9.2` | Metadata only: the tuwunel release the defaults target. The image the pod runs comes from `image.tag` (default `v1.9.2`) — no template reads `appVersion`. |
| `kubeVersion` | `>=1.31.0-0` | Enforced by Helm before anything is rendered. A cluster below 1.31 cannot take the chart at all. `kubeVersion` was introduced by 2.0.0. |

Separate from all three is the application floor: **the chart requires tuwunel v1.9.0 or newer**.
That release introduced the `TUWUNEL_*` environment prefix and `tuwunel --health-check`, and the chart
configures and probes the server through exactly those two things. An older image still renders and
starts, but it ignores the chart-managed environment variables and cannot answer the exec probe, so
the pod never becomes Ready. Nothing in `helm lint`, a schema check or a manifest diff catches this.

A packaged version comes from the chart repository, which chart-releaser rewrites on every merge to
`main`: it packages `charts/tuwunel`, creates the `tuwunel-<version>` tag, and updates the `index.yaml`
served from the `gh-pages` branch.

```console
$ helm repo add tuwunel https://arsolitt.github.io/tuwunel-helm
$ helm repo update
$ helm search repo tuwunel/tuwunel -l
NAME           	CHART VERSION	APP VERSION	DESCRIPTION
tuwunel/tuwunel	2.0.0        	v1.9.2     	Helm chart for tuwunel - a Matrix homeserver ba...
tuwunel/tuwunel	1.2.0        	v1.5.1     	Helm chart for tuwunel - a Matrix homeserver ba...
tuwunel/tuwunel	1.1.0        	v1.5.1     	Helm chart for tuwunel - a Matrix homeserver ba...
tuwunel/tuwunel	1.0.3        	v1.5.1     	Helm chart for tuwunel - a Matrix homeserver ba...
tuwunel/tuwunel	1.0.2        	v1.5.1     	Helm chart for tuwunel - a Matrix homeserver ba...
tuwunel/tuwunel	1.0.1        	v1.5.0     	Helm chart for tuwunel - a Matrix homeserver ba...
tuwunel/tuwunel	1.0.0        	v1.5.0     	Helm chart for tuwunel - a Matrix homeserver ba...
```

Read the `APP VERSION` column, not just the chart version: an operator on chart 1.2.0 moving to 2.0.0
takes the application from tuwunel v1.5.1 to v1.9.2 in the same step, which is where the one-time
database migration below comes from. (The list above is what the repository served at the time of
writing; `helm search repo` is always the current answer.)

> **Note:** Read the published set from the chart repository URL — `helm repo update` then
> `helm search repo`, as in the commands above — never from a local checkout: a checkout's
> remote-tracking `origin/gh-pages` ref is only as fresh as your last fetch and can lag behind what
> the repository actually serves, so fetch before reading the branch at all.

The value reference for the version you are moving to ships inside the package, so read it from the
package rather than from a checkout:

```console
$ helm show readme tuwunel/tuwunel
```

That output is `charts/tuwunel/README.md`, including its
[chart README § Upgrading to 2.0.0](../charts/tuwunel/README.md#upgrading-to-200) section. For a
first install instead of an upgrade, see [Installing the chart](./installation.md).

## Before you upgrade

Work through these before you touch the release. Each one either prevents or explains the failures
that the rest of this page deals with.

1. **Take a backup.** The managed backup feature takes the whole database, not media; the chart's own
   backup surface is described in [Backups and restore](./backups.md) and
   [chart README § Backups and Recovery](../charts/tuwunel/README.md#backups-and-recovery). Upstream's
   migration documentation states the caution plainly: "Always back up your database before
   migrating." This repository does not itself instruct you to back up before an upgrade — the advice
   is upstream's, and the chart only provides the mechanism.
2. **Read the target version's notes.** For the 2.0.x line that is the chart README's own upgrade
   section (shipped in the package, readable with `helm show readme` as shown above) plus the release
   body. The repository changelog is [`../CHANGELOG.md`](../CHANGELOG.md).
3. **Check that the released version has a `## [<version>]` section in `CHANGELOG.md`.** The `release`
   job copies that section into the GitHub release body, so a release without one means the release
   notes are missing even though the chart is published — and the job itself goes red after
   publication. The match is literal: `## [<version>]` must be followed by a space or the end of the
   line, so `## [2.0.0]-x` is invisible to the extractor while a `## [1.2.0-rc1]` heading above
   `## [1.2.0]` is not mistaken for it. If you are the maintainer, add the section in the same commit
   as the version bump.
4. **Render your values against the target chart, client-side.** `values.schema.json` runs on every
   `helm lint`, `helm template` and install:

   ```console
   $ helm template my-release tuwunel/tuwunel -f values.yaml > /dev/null
   ```

   Exit 0 means the schema accepted the values and both cross-value template guards passed; anything
   else prints the refusal and nothing has touched the cluster. `helm lint` needs a local chart
   directory (it fails on a repo reference with `stat tuwunel/tuwunel/Chart.yaml: no such file or
   directory`), so pull the chart first if you want lint's full report:
   `helm pull tuwunel/tuwunel --untar`.
5. **Check the cluster against `kubeVersion`.** `>=1.31.0-0` is a hard gate applied before the render,
   and the failure looks like a chart error rather than an unsupported-cluster error.
6. **Audit the overrides that interact with the migration.** A pinned `image.tag` older than v1.9.0, a
   shortened `terminationGracePeriodSeconds`, or a reduced `probes.startup` budget are the three
   values that turn an upgrade into an incident.

> **Tip:** Helm 4 deprecates `helm template --validate` ("Flag --validate has been deprecated, use
> '--dry-run=server' instead"). The client-side render in step 4 catches the schema and cross-value
> refusals; add `--dry-run=server` when you also want the API server to validate the rendered objects.

> **Warning:** The homeserver runs as a single replica with no rolling update: an upgrade deletes and
> recreates the one pod. The installed notes say it directly — "Scaling the StatefulSet will probably
> cause failures and quiet data corruption." There is nothing to fail over to, so plan the downtime
> rather than expecting a rolling upgrade.

## Upgrading from 1.x to 2.0.0

The 2.0.0 section of [`../CHANGELOG.md`](../CHANGELOG.md) is the authoritative list; this is it as a
checklist. Rows in the first table require an edit to your values file.

| Breaking change | Action required | Where it fails |
| --- | --- | --- |
| `env`, `envRaw` and `envFromSecret` live at the **top level**, not under `config.global` (moved in chart 1.0.1) | Move the three keys out of `config.global` to the top level of your values file | Silent: the render succeeds. `config.global` accepts additional properties, so the stray keys land in `config.toml` as an unknown `[global.env]` table (and an unknown `[[global.envRaw]]` array-of-tables) and the chart never sets them as environment variables — nothing fails, the variables simply do not exist |
| Chart-managed environment variables use the `TUWUNEL_` prefix; precedence upstream is `CONDUIT_` < `CONDUWUIT_` < `TUWUNEL_` | Delete legacy `CONDUIT_*`/`CONDUWUIT_*` variables. A leftover `CONDUWUIT_PORT` no longer decides the port — the chart renders `TUWUNEL_PORT` from `service.port` (verified against v1.9.2: the server logs `Listening on ["tcp:[::]:8080"]`, the chart's port) | Silent: the legacy variable loses without an error |
| `config.global.port` must equal `service.port` | Delete `config.global.port` from your values (the chart owns the listener) or set it to the same number as `service.port` | Template guard: `Error: execution error at (tuwunel/templates/tuwunnel/statefulset.yaml:24:4): config.global.port (8008) must equal service.port (8080): the chart sets TUWUNEL_PORT from service.port` |
| `config.global.server_name` must equal `server_name` | Delete `config.global.server_name` or align it with `server_name` | Template guard: `Error: execution error at (tuwunel/templates/tuwunnel/statefulset.yaml:28:4): config.global.server_name (other.example) must equal server_name (matrix.ci.example): the chart sets TUWUNEL_SERVER_NAME from server_name` |
| The published default `registration_token` (`supa-dupa-secret-token`) is gone, and registration is disabled by default (`config.global.allow_registration: false`) | Bring your own token or shared secret: an `envFromSecret` entry (`REGISTRATION_TOKEN: <secret-name>/<key-name>`) plus `registration_token: "${REGISTRATION_TOKEN}"` under `config.global`; see [Secrets and hardening](./security.md) | Closed: `POST https://<server_name>/_matrix/client/v3/register` answers `403 M_FORBIDDEN: Registration has been disabled.` Broken secret: the server refuses to start with `Registration token was specified but is empty ("")` and `There was a problem with the 'registration_token' directive in your configuration` |
| `config.global.blurhashing` and `config.global.antispam` were removed | Delete both keys | Quiet: v1.9.2 starts but logs `Config parameter "blurhashing" is unknown to tuwunel, ignoring.` on every start |
| `rtc.ingress.path` and `rtc.ingress.extraHosts` are rejected instead of ignored | Delete both keys; the RTC ingress always routes the JWT paths and `/` | Schema: `Error: values don't meet the specifications of the schema(s) in the following chart(s): tuwunel: - at '/rtc/ingress': additional properties 'path' not allowed` |
| Image bumps: tuwunel v1.9.2 (was v1.5.1), lk-jwt-service `0.7.0` (was `0.4.1`), LiveKit `v1.13.7` (was `v1.9.12`) | If you pin `image.tag`, raise it to v1.9.0 or newer. If RTC is enabled, review [Matrix RTC with LiveKit](./rtc.md): lk-jwt-service 0.7.0 has a new `/get_token` contract and requires `LIVEKIT_FULL_ACCESS_HOMESERVERS` | Pinned old tag: the pod never becomes Ready. RTC: signalling breaks while the paths still answer |

The second table is behaviour and config shape you have to plan for or check rather than mechanically
edit.

| Change | What it means for the upgrade |
| --- | --- |
| `config.global.log` defaults to `info` (documented as part of the v1.9 config surface in 2.0.0) | The log level is a config key, not an environment variable — tuwunel has no `RUST_LOG` knob, so a `RUST_LOG` entry in `env` never controlled it. Set `config.global.log` to `trace`, `debug`, `info`, `warn` or `error` |
| Array-of-tables keys have to keep the list shape: `identity_provider` and `well_known.rtc_transports` written as a nested mapping render as a single TOML table and stop the server | Check those keys in your values file; the chart cannot catch this for you, because `config` is an unvalidated passthrough. v1.9.2 exits with `invalid type: found string "Authentik", expected struct IdentityProvider for key "global.identity_provider.brand"`. See [Tuwunel Configuration](../charts/tuwunel/README.md#tuwunel-configuration) |
| Every probe is now an exec probe running `tuwunel --health-check`; the readiness probe no longer uses `httpGet /_tuwunel/server_version` | With the defaults there is nothing to do, and the [Probes and database migrations](../charts/tuwunel/README.md#probes-and-database-migrations) budget is in place. Do not disable `probes.startup`: it is the only thing protecting the migration. If external monitoring scraped the old readiness path, point it at `/_tuwunel/server_version` or `/_matrix/client/versions` instead |
| The startup probe allows 30 minutes (10s x 180) and `terminationGracePeriodSeconds` defaults to 1800 | Keep both at least as long as your database needs to migrate; Kubernetes' own grace-period default of 30 seconds would SIGKILL the migration. See the next section |
| `Chart.yaml` declares `kubeVersion: '>=1.31.0-0'` | Clusters below 1.31 cannot take chart 2.0.0 at all — see step 5 above |
| Editing `config` or any `env`/`envRaw`/`envFromSecret` value now rolls the pod (`checksum/config` covers the rendered ConfigMap plus the environment) | Any values edit is a full server restart, and a restart is when the migration runs. Remember that rotating a Secret's *contents* does not roll the pod — only the reference is hashed |
| The CPU limit derives `TOKIO_WORKER_THREADS` and `TUWUNEL_ROCKSDB_PARALLELISM_THREADS` | On a node with many cores, upstream's `db_pool_max_workers` default of 2048 can exceed the pod's task limit and fail startup with `EAGAIN`; setting `config.global.db_pool_max_workers` to roughly the CPU limit (for example `64`) removes that failure mode |

If your values file predates 1.2.0 rather than 1.1.0, these older changes are still in your path:

| Carried over from 1.x | Action |
| --- | --- |
| `values.schema.json` exists since chart 1.1.0: unknown top-level keys and impossible values are rejected (a typo like `ingres:` no longer passes silently) | Expect render failures you did not see before; the error names the offending path |
| `service.port` defaults to `8080`, not `80`, since 1.0.2 | Drop stale port assumptions from values and probes |
| `config.global.address` defaults to `::` (one dual-stack socket) since 1.2.0 | On a pod network without a usable IPv6 stack set it to `0.0.0.0` |
| Quoted booleans in `config` are rejected since 1.2.0, and values files that still carry them have to be fixed before upgrading | The quoted form is refused by the schema at render time; if such a value reaches the server it exits with `invalid type: found string "false", expected a boolean for key "global.allow_federation"` |
| The readiness path changed from `/_matrix/federation/v1/version` to `/_tuwunel/server_version` in 1.2.0, and to the exec probe in 2.0.0 | Do not keep a federation path as a health check: it answers 403 as soon as federation is disabled, which is the chart default |

## The database migration window

The first start after a homeserver upgrade runs a **one-time blocking database migration before the
server listens**. `tuwunel --health-check` exits non-zero while the server is still migrating or
already unhealthy, so the pod reports `Running` with `0/1` Ready for the whole migration and
`kubectl describe pod` shows the startup probe failing.

Two settings exist so the migration can finish, and they are one mechanism split in two:

| Setting | Default | What it protects |
| --- | --- | --- |
| `probes.startup` | `enabled: true`, `periodSeconds: 10`, `failureThreshold: 180` (= 30 minutes) | The migration budget. The startup probe is the only probe counted until the server answers; the readiness probe stays out of the way so a slow first start is not read as a broken server |
| `probes.readiness` / `probes.liveness` | `enabled: true`, `periodSeconds: 10`, `failureThreshold: 3` | Take over once the server is up; not the probes that report a migration |
| `terminationGracePeriodSeconds` | `1800` | Bounds SIGTERM to SIGKILL on shutdown. A SIGKILL in the middle of the migration leaves the database half-migrated, not merely slow to start, which is why the default is 60x Kubernetes' own |

What interrupting it costs:

| Interruption | Cost |
| --- | --- |
| `kubectl delete pod --force`, an eviction, a node drain, an OOM kill, or a shortened `terminationGracePeriodSeconds` | The migration dies mid-flight; the database is left half-migrated rather than unchanged |
| The startup probe exhausting its 180 failures | The kubelet kills the container and the migration resumes from the last recorded step — a stop is honoured between steps, and every step that finished is recorded, so it does not start over. `terminationGracePeriodSeconds` bounds the SIGTERM-to-SIGKILL wait only; it does not extend the probe budget, so raise `probes.startup.periodSeconds` or `failureThreshold` if you know a database needs more than 30 minutes |

> **Warning:** The repository states the budget, not the recovery: nothing in it documents what to do
> if a migration legitimately exceeds the 30-minute startup budget, and there is no stated migration
> time limit or measurement guidance. Treat the budget as the line you must plan around, and keep the
> backup from [Before you upgrade](#before-you-upgrade) as the way out.

> **Note:** The chart's `db_pool_max_workers` advice applies at exactly this moment, because the pool
> is opened during startup: on a many-core node set `config.global.db_pool_max_workers` to roughly the
> CPU limit to avoid a startup failure with `EAGAIN` that looks like a migration fault.

## Upgrade procedure

The chart ships no upgrade script, and the repository's only `helm upgrade` examples are the restore
recipe; this is the standard sequence in the order that matters.

1. **Back up** ([Backups and restore](./backups.md)). Nothing later in this list undoes a migration.
2. **See what the repository serves** and re-check the target version's notes:

   ```console
   $ helm repo update
   $ helm search repo tuwunel/tuwunel -l
   ```

3. **Pre-flight the render** with your own values, so a schema or cross-value refusal happens here
   instead of in the middle of the rollout:

   ```console
   $ helm template my-release tuwunel/tuwunel -f values.yaml > /dev/null
   ```

4. **Upgrade the release.** The release name and values file are the only inputs the chart needs:

   ```console
   $ helm upgrade my-release tuwunel/tuwunel -f values.yaml
   ```

   > **Tip:** If you add `--wait`, remember that Helm then waits for the pod to become Ready — which
   > happens only after the migration. A Helm timeout shorter than the migration budget reports a
   > failed release while the pod is still migrating; the pod itself is unaffected.

5. **Watch the init container first, then the server.** The init container (`config-processor`) only
   substitutes `${VAR}` placeholders into the config template:

   ```console
   $ kubectl get pods -l app.kubernetes.io/name=tuwunel -w
   $ kubectl logs -f my-release-tuwunel-0 -c config-processor
   $ kubectl logs -f statefulset/my-release-tuwunel
   ```

6. **Wait for Ready.** One replica is recreated, and readiness only arrives when the migration has
   finished and the server accepted its configuration:

   ```console
   $ kubectl rollout status statefulset/my-release-tuwunel --timeout=35m
   ```

7. **Run the chart's own smoke test.** The `helm test` hook proves the Service answers where the chart
   rendered it, from inside the cluster:

   ```console
   $ helm test my-release --logs
   ```

   The hook pod runs `wget -q --spider http://my-release-tuwunel.<namespace>.svc:8080/_tuwunel/server_version`
   (8080 is the default `service.port`) and exits non-zero on any non-2xx answer, so a failure is a
   real one. It is left behind (`helm.sh/hook-delete-policy: before-hook-creation`), which is why
   `--logs` and `kubectl logs` both work.

Lines worth recognising in the output:

| Line | Meaning |
| --- | --- |
| `Listening on ["tcp:[::]:8080"]` | The migration finished and the server bound its listener; the address comes from `config.global.address` and the port from `service.port` (the chart README records this line for v1.9.2) |
| `Config parameter "blurhashing" is unknown to tuwunel, ignoring.` | A removed key is still in your values; delete it (the same applies to `antispam`) |
| `Registration token was specified but is empty ("")` followed by `There was a problem with the 'registration_token' directive in your configuration` | An enabled registration token resolved to an empty string — the pod will not start. Fix the secret reference; this message is the loud failure, not an open server |
| `ip_source is set to RightmostXForwardedFor, a header-based source. Ensure a trusted reverse proxy populates this header for every request; otherwise clients can spoof their IP address.` | Only if you set `config.global.ip_source`; the warning is about proxy configuration, not about the upgrade |

> **Note:** The migration does announce itself in the log: `tuwunel_service::migrations` lines — the
> schema version, the injectivity scan — appear ahead of `Listening on [...]`, so a pod that keeps
> printing migration lines is working rather than hung, and a stop is honoured between steps with
> every finished step recorded, so a restarted migration resumes from the last recorded step rather
> than from the beginning. The pod's `0/1` Ready state and the failing startup probe are the other
> signal, not the only one: the server binds its listener only once the migration returns. See
> [Day-2 operations](./operations.md#the-migration-budget) for a reproduced log.

## After the upgrade

| Check | Command | What it proves |
| --- | --- | --- |
| The pod is Ready | `kubectl get pods -l app.kubernetes.io/name=tuwunel` | The readiness probe is the exec `tuwunel --health-check`: Ready means the running server accepted *this* configuration, not merely that a port is open |
| The Service answers on the rendered port | `helm test my-release --logs` | The in-cluster fetch of `/_tuwunel/server_version` succeeded against the Service the chart rendered |
| The version endpoint from outside | `curl https://<server_name>/_tuwunel/server_version` | Upstream's own health check for a deployment. The path needs no client IP, so it also answers while a header-based `ip_source` is misconfigured |
| The image actually running | `kubectl get pod -l app.kubernetes.io/name=tuwunel -o jsonpath='{.items[0].spec.containers[0].image}'` | The whole contract depends on a v1.9.0-or-newer image; this shows the tag in use rather than the one you meant to set |
| Registration state | `POST https://<server_name>/_matrix/client/v3/register` | `403 M_FORBIDDEN: Registration has been disabled.` is the expected answer while registration is closed; an enabled token flow answers `401` with `m.login.registration_token` and no token supplied |
| Probe and log noise | `kubectl logs statefulset/my-release-tuwunel` | Unknown-parameter warnings tell you a removed key survived the migration |
| Exposure | your existing Ingress or Gateway routes | The upgrade re-renders them from your values. Gateway API exposure is opt-in since 2.0.0 (`gateway.enabled` is `false` by default), so an Ingress install is not moved onto a Gateway by upgrading — see [Exposing the homeserver with Gateway API](./gateway-api.md) |
| RTC, if enabled | `curl https://<server_name>/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` and `kubectl logs -l app.kubernetes.io/component=rtc-jwt` | An empty `rtc_transports` list means `config.global.well_known.livekit_url` is missing from the rendered config, not that LiveKit is down |
| Backups, if enabled | `!admin server list-backups`, or an ad-hoc signal - `kubectl exec my-release-tuwunel-0 -c backup -- pkill -USR2 -x tuwunel` | The evidence is the server's `Created database backup...` line and the repository under the backup path; the sidecar's own log stays empty either way, because crond logs to a syslog the pod does not run - see [Backups and restore](./backups.md#the-scheduled-sidecar) |

## Rolling back

The repository contains no rollback or downgrade procedure: no `helm rollback` recipe, no downgrade
notes, and no statement that an older chart may be pointed at a database the new version has already
migrated. Upstream's position is the only guidance there is (tuwunel README, "Upgrading & Downgrading
Tuwunel"):

> We strive to make moving between versions of Tuwunel safe and easy. Downgrading Tuwunel is always
> safe but often prevented by a guard. An error will indicate the downgrade is not possible and a
> newer version which does not error must be sought.

Three consequences for an upgrade that has gone wrong:

- **A chart downgrade is not a data rollback.** Rolling the release back re-renders the earlier
  templates and image tag; it does not undo the schema migration the new server performed.
- **The two halves have to move together, one chart version excepted.** A chart *older than 1.2.0*
  probes `/_matrix/federation/v1/version` with `httpGet`, and that path answers
  `403 M_FORBIDDEN` as soon as federation is disabled — the chart default — so under that default it
  never reports Ready, whatever image runs beneath it. Under chart 2.0.0 the reverse holds with the
  two other values: an image older than v1.9.0 ignores the `TUWUNEL_*` environment and never answers
  the exec probe. A rollback to **chart 1.2.0** with the v1.9.2 image is the case that does work: it
  probes `/_tuwunel/server_version` and configures the server through the legacy `CONDUWUIT_*` names,
  which v1.9.2 still accepts (precedence `CONDUIT_` < `CONDUWUIT_` < `TUWUNEL_`). It still points at a
  database v1.9.2 has already migrated, which the first bullet governs.
- **The forward direction is the supported one.** When the guard refuses a downgrade, upstream's
  instruction is to seek a newer version that does not error rather than to force an older one.

If you need the previous state of the database, restore it instead of downgrading: the restore is a
forward operation driven through the release's `args`
(`--restore-backup`, `--maintenance`, `--execute`), and
[Backups and restore](./backups.md) has the procedure.

> **Warning:** A restore replaces the RocksDB files in `database_path`; anything written after the
> newest backup is gone, media is not part of the managed backup, and the restore must be taken back
> out of the release when it finishes. The container exits after `--execute` and the pod template sets
> no `restartPolicy` of its own, so leaving the restore `args` in place turns the one-shot restore into
> a restore loop on every pod restart — and the next unrelated `helm upgrade` re-asserts
> `replicas: 1` and can resurrect it.

## Changes that publish nothing

Only a `Chart.yaml` version bump creates a release. `chart-releaser` runs with `skip_existing: true`,
so a merge that leaves `version` alone publishes nothing — documentation, CI, and even a template fix
that shipped without a bump. The workflow summary says so in as many words:

```text
No chart version change detected - nothing was published.
Bump `version` in `charts/tuwunel/Chart.yaml` to publish a release.
```

What that means while you wait for a fix:

- The `release` job only runs on a push to `main`, and only after `lint`, `schema` and `runtime` pass.
  A pull request publishes nothing regardless of what it changes.
- Only stable versions are published; there is no pre-release channel, so nothing in the index needs
  `--devel` to become visible.
- A merged fix with no version bump produces no tag and no index entry. Check what the repository
  actually serves before assuming an upgrade is available:

  ```console
  $ helm repo update
  $ helm search repo tuwunel/tuwunel -l
  ```

> **Note:** Publication and release notes are two steps: chart-releaser creates the tag, the GitHub
> release and the index entry first, and the notes step runs afterwards. A released version with no
> `## [<version>]` section in [`../CHANGELOG.md`](../CHANGELOG.md) therefore fails the job *after* the
> chart is already published, leaving a release whose body is still the chart description.

See [Development and releases](./development.md) for the pipeline itself, and
[Day-2 operations](./operations.md) for the ongoing checks after the upgrade settles.
