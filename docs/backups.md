# Backups and restore

> How the chart gives tuwunel's built-in online backups their own volume, what its cron sidecar does, and how to trigger, verify and restore a backup.

## Table of Contents

- [How tuwunel backups work](#how-tuwunel-backups-work)
- [Enabling backups](#enabling-backups)
- [The scheduled sidecar](#the-scheduled-sidecar)
- [How the schedule reaches the server](#how-the-schedule-reaches-the-server)
- [Triggering a backup without the sidecar](#triggering-a-backup-without-the-sidecar)
- [Retention](#retention)
- [Verifying backups exist](#verifying-backups-exist)
- [Restore drill](#restore-drill)
- [Limitations](#limitations)

---

## How tuwunel backups work

tuwunel takes **online** database backups itself: no external tooling, no dump-and-upload script, and the server keeps serving while a backup is written. A backup lands in a repository under a configured path, where each entry lives at `<backup.path>/meta/<id>`.

A backup covers the **database only**. It does not contain `media/` or anything in a configured storage provider, so a restore brings the database back without the files it references. Back those up separately — see [Storage and media](./storage-and-media.md).

The chart adds three things around that server-side feature:

| Chart contribution | What it renders |
|---|---|
| A dedicated volume | PVC `<fullname>-backup` (or `backup.existingClaim`) mounted at `backup.path` |
| The config keys that point the server at it | `database_backup_path` and `database_backups_to_keep` in `config.toml`, injected only when you have not set them yourself |
| An optional trigger | `backup.scheduled: true` adds a busybox `crond` sidecar, a crontab ConfigMap and `shareProcessNamespace: true`, whose job is one SIGUSR2 to the server at the scheduled minute — see [The scheduled sidecar](#the-scheduled-sidecar) |

`fullname` is the release name when it already contains `tuwunel`, otherwise `<release>-tuwunel`; `fullnameOverride` replaces both. With release `my-release` the objects are `my-release-tuwunel`, `my-release-tuwunel-data`, `my-release-tuwunel-backup`.

> **Note:** You do not need the sidecar to take a backup. With `backup.enabled: true` and `backup.scheduled: false`, trigger one from the admin room with `!admin server backup-database`. The same group holds `list-backups`, `verify-backup [id]` and `delete-backups <keep>`. See [Triggering a backup without the sidecar](#triggering-a-backup-without-the-sidecar) for the same path from a release that has no sidecar at all.

## Enabling backups

Set the values, then upgrade:

```yaml
backup:
  enabled: true
  size: 20Gi
  scheduled: true   # renders the cron sidecar that fires the job on its schedule
  schedule: "0 3 * * *"
  keep: 14
```

The block and its defaults (the full list, with descriptions, is in the [chart README § Backups and Recovery](../charts/tuwunel/README.md#backups-and-recovery)):

| Value | Default | Effect |
|---|---|---|
| `backup.enabled` | `false` | Creates the PVC, mounts it at `backup.path`, injects the two config keys |
| `backup.existingClaim` | `""` | Use this claim instead of creating `<fullname>-backup` |
| `backup.storageClass` | `""` | Same three-way rule as the data claim: unset/`""` = cluster default, `"-"` = `storageClassName: ""` (bind a pre-created PV), anything else = that class |
| `backup.accessMode` | `ReadWriteOnce` | `ReadWriteOnce`, `ReadOnlyMany`, `ReadWriteMany` or `ReadWriteOncePod` |
| `backup.size` | `5Gi` | Size of the backup claim |
| `backup.path` | `/backups` | Mount path inside the container **and** `database_backup_path` |
| `backup.keep` | `7` | `database_backups_to_keep` |
| `backup.scheduled` | `false` | Adds the cron sidecar, the crontab ConfigMap and `shareProcessNamespace`; needs `backup.enabled: true`, and a render with the schedule alone is refused |
| `backup.schedule` | `0 3 * * *` | Five-field cron expression for the sidecar |
| `backup.command` | `server backup-database` | The admin command a SIGUSR2 runs (`admin_signal_execute`) |
| `backup.sidecar.resources` | `10m`/`32Mi` requests, `100m`/`64Mi` limits | Resources for the sidecar (required by the schema) |

With `backup.enabled: true` the rendered `config.toml` gains the keys — the CI fixture for this feature renders exactly these lines alongside the user's own `[global]` table:

```toml
[global]
  database_backup_path = "/backups"
  database_backups_to_keep = 7
```

The values are `backup.path` and the `int` cast of `backup.keep` (so `7`, not `"7"`). A third key, `admin_signal_execute`, joins them when `backup.scheduled` is also true — see [How the schedule reaches the server](#how-the-schedule-reaches-the-server).

> **Warning:** Setting `config.global.database_backup_path` or `config.global.database_backups_to_keep` yourself disables the injection of that key — the template only writes keys you have not written. `backup.path` still mounts the volume at `/backups`, so your override can point the server at a path with no volume behind it. Leave both keys out of `config.global` unless you know where the repository goes; the injection exists precisely so the mount and the config cannot drift apart. See [Configuring the server](./configuration.md) for the general injection rules.

> **Warning:** Keep `backup.path` off the data volume. A backup that shares a volume with the database does not survive losing that volume, and the only guard is the schema's leading-slash pattern on `backup.path` — there is no cross-value check against `persistence.data`.

The volume is labelled `app.kubernetes.io/component: tuwunel-backup` and picks up `pvcAnnotations`, like the data claim. `backup.enabled: false` (the default) renders no claim and no mount at all.

## The scheduled sidecar

`backup.scheduled: true` — together with `backup.enabled: true` — renders three things that only work as a set:

- a ConfigMap `<fullname>-backup-crontabs` whose single entry is `root`, keyed by user name because busybox `crond` reads one file per user out of its spool directory (`-c /etc/crontabs`);
- a second container named `backup`, image `busybox:1.37` by default, started as `crond -f -l 8 -c /etc/crontabs` (foreground, so the container stays alive), as root with `SETGID`, `SETUID` and `KILL` added;
- `shareProcessNamespace: true` on the pod.

The ConfigMap's whole payload is the rendered schedule followed by the signal. With the default schedule it renders exactly:

```yaml
data:
  root: |
    0 3 * * * pkill -USR2 -x tuwunel
```

The sidecar's only volume mount is that ConfigMap, at `/etc/crontabs` — a ConfigMap volume, so it is read-only. The container therefore has no writable state at all, and it never mounts the backup volume or touches the repository. Its resources come from `backup.sidecar.resources` and the `busybox.image.*` pair is shared with the `helm test` pod, so keep that image multi-arch — a single-arch busybox tag breaks whichever of the two runs on the other architecture.

### Why the sidecar runs as root

The sidecar is the one container in the release that does not run as the pod's uid 2020. Its container-level `securityContext` sets `runAsUser: 0`, `runAsGroup: 0`, `runAsNonRoot: false` and adds exactly three capabilities on top of `drop: [ALL]` — `SETGID`, `SETUID` and `KILL` — while keeping `readOnlyRootFilesystem: true` and `allowPrivilegeEscalation: false` like the server container. The reason is a property of the tool, not a shortcut:

- **`SETGID` and `SETUID`.** busybox `crond` decides which user to run a spool file as from the **name of that file**, and the chart names it `root` (the ConfigMap entry above). Starting the line therefore means switching identity to root, which needs both capabilities — drop either one and crond fails the switch at the minute boundary with `crond: can't set groups: Operation not permitted` and skips the job. Renaming the entry is not an alternative: the name states the identity crond has to become, so any other name just moves the switch to a user the container is not.
- **`KILL`.** The job is `pkill -USR2 -x tuwunel` and the server runs as uid 2020; a root process needs `CAP_KILL` to signal a process of another user.
- **root.** An OCI runtime grants capabilities to a root process only, so a container started as 2020 could not hold the three above even if its security context asked for them.

```console
$ kubectl get pod <fullname>-0 -o jsonpath='{.spec.containers[?(@.name=="backup")].securityContext}'
```

> **Warning:** `backup.scheduled: true` without `backup.enabled: true` is refused at render time. The ConfigMap the sidecar mounts belongs to the enabled render, and the SIGUSR2 the job sends would run nothing because `admin_signal_execute` is injected only with backups on, so the chart fails instead of emitting a pod that cannot start:

```text
Error: execution error at (tuwunel/templates/tuwunnel/statefulset.yaml:37:4): backup.scheduled needs backup.enabled: the sidecar mounts the crontab ConfigMap, which only the backups-enabled render creates
```

> **Warning:** A four-field cron expression is refused by the schema, not silently accepted:

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/backup/schedule': '0 3 * *' does not match pattern '^\\s*\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s*$'
```

## How the schedule reaches the server

The crontab does not run a backup; it sends SIGUSR2 to the server process. The server answers a SIGUSR2 by running the command in `admin_signal_execute`, which the chart injects from `backup.command` as a single-element list:

```toml
admin_signal_execute = ["server backup-database"]
```

That is the same command as `!admin server backup-database`, minus the admin room. So the trigger path is:

1. `crond` fires `pkill -USR2 -x tuwunel` at the scheduled minute — the one job in the release that starts as root, for the reasons under [The scheduled sidecar](#the-scheduled-sidecar); everything below is what the signal sets in motion.
2. `-x` matches **argv\[0\] exactly**, which is why `shareProcessNamespace: true` matters: without a shared PID namespace the sidecar's `pkill` can never see the server process. The value is toggled by the same `backup.scheduled` switch as the sidecar, so the two cannot disagree.
3. The server runs `server backup-database`, writing a new entry under `<backup.path>/meta/<id>`.

Because `-x` compares argv\[0\] verbatim rather than its basename, the command only matches while the server process is named exactly `tuwunel` — which is what the upstream image's `Entrypoint: ["tuwunel"]` provides. A wrapper image whose argv\[0\] is a path (`/usr/local/bin/tuwunel`, a shell script) makes the pattern match nothing; `crond` does not care about the failed command, so the schedule looks armed while no backup is ever written.

> **Warning:** The SIGUSR2 handler is configured only for `backup.enabled` **and** `backup.scheduled`. Turn the schedule off (or send the signal by hand on an install that never enabled it) and `admin_signal_execute` is absent, so a signal runs nothing at all — with no error anywhere.

> **Warning:** `kubectl logs <pod> -c backup` is empty in normal operation and proves nothing either way. busybox `crond` logs through syslog (`-S`), which no daemon in the pod serves, and `-l 8` sets a level rather than a sink; crond writes those lines to stderr only when asked with `-d`, which the chart does not pass. So the sidecar log stays empty at any level whether or not the job ran — look at the server container and the repository instead.

Where to look for real evidence:

- the server container logs the line `Created database backup...` when the signal handler takes a backup (this is the line the chart's own runtime check greps for);
- the restore run logs `Restoring database backup backup_id=...` and then `Restored database backup`;
- the repository itself gets a new directory under `<backup.path>/meta/`.

## Triggering a backup without the sidecar

Two triggers work on an install with `backup.enabled: true`. The first is the server's own admin console, from an admin room — the documented surface, and the one to use normally:

- `!admin server backup-database` — take a backup now;
- `!admin server list-backups` — what the repository holds;
- `!admin server verify-backup [id]` — check one backup (newest when the id is omitted).

The second is to send the signal by hand, running the very command the crontab holds inside the sidecar container instead of leaving it to `crond`:

```console
$ kubectl exec my-release-tuwunel-0 -c backup -- pkill -USR2 -x tuwunel
```

That is the same command the crontab holds, run instead of waiting for the schedule. `kubectl exec` runs the process as the container's user — root, as for `crond` — and the container's `KILL` capability is what lets it signal the server, which runs as uid 2020; `shareProcessNamespace: true` (rendered whenever the sidecar is) puts both in one PID namespace. The container to exec into is the sidecar precisely because it is busybox and therefore ships `pkill`; the `tuwunel` container has no shell and no coreutils to run anything with.

`pkill` prints nothing when it works, and it can also exit `0` without the signal being delivered, so confirm the result from the server's log line or `!admin server list-backups` ([Verifying backups exist](#verifying-backups-exist)) rather than from the exec's silence.

The sidecar exists only under `backup.scheduled: true`, and `admin_signal_execute` is injected only for `backup.enabled` **and** `backup.scheduled` — so this trigger needs that same pair of values. The repo's own runtime check ([hack/runtime-check.sh](../hack/runtime-check.sh)) covers whichever side of the mechanism a fixture exercises: when the rendered schedule can fire inside its 90-second window it starts the *rendered* sidecar — the manifest's own image, command, args, root user and capabilities, with the crontab ConfigMap projected into its spool — and lets `crond` fire the job on its own; for a schedule like `0 3 * * *` it runs this exact command from a container sharing the server's PID namespace, and prints why. Either path has to leave a `meta/` entry under `backup.path`.

Both triggers stay useful next to the schedule: the admin room is the documented way to take an ad-hoc backup, and the exec covers a release whose schedule you do not want to wait for. The scheduled path itself needs nothing further — the sidecar's root user and its `SETGID`/`SETUID`/`KILL` set are what let `crond` start the job at all (see [The scheduled sidecar](#the-scheduled-sidecar)).

## Retention

`database_backups_to_keep` — rendered from `backup.keep`, default `7` — bounds how many backups the repository holds. Pruning is **not** continuous: older backups are dropped *after a new one is taken*. A repository that stops receiving backups therefore also stops being pruned, and `keep` bounds the count, not the total size, so `backup.size` can still fill up.

The schema rejects `keep: 0`, because "prune every backup after taking the next one" means a backup never survives until you need it:

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/backup/keep': minimum: got 0, want 1
```

To prune explicitly, use the admin room rather than the value: `!admin server delete-backups <keep>` — per the chart README, the argument is a **count**, not a backup id, and `0` deletes every managed backup. Treat that command's semantics as README-level documentation only; the chart cannot validate admin-console behavior.

> **Warning:** If you override `config.global.database_backups_to_keep` in your values instead of using `backup.keep`, Helm's values→JSON parse turns your integer into a TOML float (`database_backups_to_keep = 99.0`), while the chart's own injection casts with `int` and stays an integer. Use `backup.keep`.

## Verifying backups exist

The repository is not reachable from inside the server container — the `tuwunel` image has no shell and no coreutils, so `kubectl exec ... -c tuwunel -- ls ...` or `grep ...` cannot run at all. Ask the server, read its log, and inspect the volume from a second pod instead.

Ask the server first; this needs no cluster access at all, just an admin room:

```console
$ !admin server list-backups
```

The server logs one line per backup it takes. `grep` here runs on your machine against the log stream, not inside the container:

```console
$ kubectl logs my-release-tuwunel-0 -c tuwunel | grep 'Created database backup'
```

The backup engine lays the repository out as `<backup.path>/meta/<id>`, one directory per backup, so seeing the volume itself means mounting the claim in a throwaway busybox pod:

```console
$ kubectl get pvc my-release-tuwunel-backup
$ kubectl run backup-inspect --rm -it --restart=Never --image=busybox:1.37 \
    --overrides='{"spec":{"containers":[{"name":"backup-inspect","image":"busybox:1.37","stdin":true,"tty":true,"command":["ls","-l","/backups/meta"],"volumeMounts":[{"name":"backup","mountPath":"/backups"}]}],"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"my-release-tuwunel-backup"}}]}}'
```

Run it in the release's namespace, and with the default `ReadWriteOnce` access mode expect it to need the same node as the server pod — if it stays `Pending`, pin it there with a `nodeName` in the overrides. Use `backup.existingClaim`'s name in place of `my-release-tuwunel-backup` if you did not let the chart create the claim.

The two config keys that decide what you are looking at are `database_backup_path` (where the repository lives — inside the pod this is the mount path `backup.path`, `/backups` by default) and `database_backups_to_keep` (how many entries survive). Confirm they are the values you meant rather than the ones the chart injected behind an override:

```console
$ kubectl get configmap my-release-tuwunel-configmap -o jsonpath='{.data.config\.toml}' | grep database_backup
```

That ConfigMap is the **template** — the unresolved text, `${...}` placeholders and all — that the `config-processor` init container substitutes into `/tmp/config/config.toml` at pod start; the substituted file is what the server reads, handed to it through `TUWUNEL_CONFIG`. The chart's environment variables win where both the file and an env var set the same key, which is the rule from [Day-2 operations](./operations.md).

## Restore drill

A restore is a one-shot run of the server with restore flags instead of its normal startup. The chart passes `args` straight to the image's `tuwunel` entrypoint, and the flags below are documented in `tuwunel --help` (the chart itself validates nothing beyond "non-empty strings"). The sequence below is the chart README's, verified end to end there: the server restores `backup_id=1` into a fresh database path and exits 0.

Find the StatefulSet name first — the commands below use `<fullname>` as `my-release-tuwunel`:

```console
$ kubectl get statefulset -l app.kubernetes.io/instance=my-release
```

> **Danger:** Every step here takes the homeserver down. Step 2 overwrites the live database with the contents of the chosen backup; anything written since that backup is gone. Do this on purpose, and prefer a copy of the volume (a snapshot, or a clone PVC) before you start if the data has any value.

```console
# 1. stop the server
$ kubectl scale statefulset/my-release-tuwunel --replicas=0

# 2. start it once in restore mode: --restore-backup [<id>] picks the newest by default,
#    --maintenance keeps client traffic out, --execute runs one admin command and exits
$ helm upgrade my-release tuwunel/tuwunel -f values.yaml \
    --set 'args={--restore-backup,--maintenance,--execute,server shutdown}'

# 3. watch it
$ kubectl logs -f statefulset/my-release-tuwunel
#    ... "Restoring database backup backup_id=..." then "Restored database backup"

# 4. back to normal: drop args again (the upgrade restores replicas: 1) and confirm the pod is up
$ helm upgrade my-release tuwunel/tuwunel -f values.yaml
$ kubectl scale statefulset/my-release-tuwunel --replicas=1
```

Step by step, with what to watch out for:

1. **Scale to zero.** Clients get connection errors from here on. Note that this step only stops the current pod: the StatefulSet template hardcodes `replicas: 1`, so the next `helm upgrade` brings a pod back — with whatever args are in the release at that moment.
2. **Start in restore mode.** `--set args=...` *replaces* the container's argument list wholesale; a leftover `args` in `values.yaml` will also come back the moment you drop the `--set`, so clean it out first. To restore something other than the newest backup, put the id after `--restore-backup` as its own list element (the documented flag form is `--restore-backup [<id>]`) using an id you saw under `<backup.path>/meta`. The pod runs with the normal probes; the startup probe's budget (`periodSeconds` 10 × `failureThreshold` 180 = 30 minutes) is documented for the one-time database migration, not for a restore.
3. **Watch the log.** `Restoring database backup backup_id=...` starts the work, `Restored database backup` ends it, and the container then exits because of `--execute`.
4. **Return to normal.** Dropping the args and upgrading is what resets the pod template, and the statefulset scale restores the replica. Skipping this step is not cosmetic:

   > **Danger:** While `args` still carries `--restore-backup ... --execute`, the container exits after each run and the StatefulSet keeps the pod alive, so the kubelet restarts it — and it restores again. A forgotten step 4 turns a restore into a restore loop over the live database.

Confirm the homeserver is actually back before declaring victory:

```console
$ kubectl rollout status statefulset/my-release-tuwunel
$ kubectl exec my-release-tuwunel-0 -c tuwunel -- tuwunel --health-check
$ helm test my-release
```

The exec is the same command the chart's readiness probe runs, so success means the server is serving the configuration it was started with. `helm test` adds the one check a schematic render cannot make: a busybox pod that fetches `http://my-release-tuwunel.<namespace>.svc:8080/_tuwunel/server_version` from inside the cluster. See [Day-2 operations](./operations.md) for the surrounding checks, and [Upgrading](./upgrade.md) if the restore is part of a version move — a restore across versions must respect the chart's own image/migration rules.

The restore flags are the server's own, not the chart's. `tuwunel --help` lists the rest of the set that goes with them: `--read-only`, `--maintenance`, `--health-check`, `--restore-backup [<id>]`, `--execute <command>`, `--generate-config` and `--regenerate-config`. The chart passes whatever you put in `args` verbatim to the `tuwunel` entrypoint and validates only that each element is a non-empty string, so a typo reaches the container unmodified.

## Limitations

| Limitation | Consequence | What to add |
|---|---|---|
| The managed backup is database-only | A restore has no `media/` or storage-provider objects, so clients see missing files | Back up media separately — a second volume, restic, or the provider's bucket replication ([Storage and media](./storage-and-media.md)) |
| No off-site copy | The repository lives on one PVC in one cluster; losing the cluster loses the backups with it | Snapshots plus an off-site copy (restic or object storage) |
| No WAL archiving and no point-in-time recovery | The restore unit is a whole backup id: you can only go back to the newest backup, or an older one you name | Snapshot/WAL-based tooling if you need a lower RPO |
| Same default storage class as the data volume | On a single local-path provisioner both claims land on the same node and disk, so the repository is a copy, not a backup | Set `backup.storageClass` to a different class, or provision the claim on other storage |
| Retention prunes count, not size | `database_backups_to_keep` bounds how many backups are kept, never how large they are, and neither the chart nor upstream documents what happens when the claim fills up | Monitor the claim's usage and the server's backup log lines rather than assuming a full volume is reported |

Two habits keep this honest: keep `backup.path` off the data volume, and verify the repository under `<backup.path>/meta` rather than the sidecar's logs — silence there proves nothing either way ([Verifying backups exist](#verifying-backups-exist)). For how the chart wires the volume, the config and the sidecar together, see [How the chart renders a running server](./internals.md).
