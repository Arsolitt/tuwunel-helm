# Storage and media

> What the chart persists, where the database and uploaded media live, and how to put either of them on other storage.

## Table of Contents

- [The data volume](#the-data-volume)
- [PVC options](#pvc-options)
- [Bringing your own volume](#bringing-your-own-volume)
- [Local media](#local-media)
- [S3-compatible media storage](#s3-compatible-media-storage)
- [Extra volumes and mounts](#extra-volumes-and-mounts)
- [Capacity and growth](#capacity-and-growth)

---

## The data volume

The chart creates one claim for the server's state — `<fullname>-data` — and mounts it on the
tuwunel container at `/data` with `subPath: data`:

```yaml
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-release-tuwunel-data
```

```yaml
volumeMounts:
  - mountPath: /data
    name: data
    subPath: data
  - mountPath: /tmp/config
    name: config
  - mountPath: /tmp
    name: tmp
```

Four things follow from that layout:

| Fact | Consequence |
| --- | --- |
| `TUWUNEL_DATABASE_PATH` is rendered from `config.global.database_path`, default `/data/db` | The server's database directory is `/data/db` unless you set that key |
| `/data` is the claim's `data/` subdirectory, not the claim root | RocksDB lives at `<pvc-root>/data/db` on the volume |
| Media has no configured provider by default | Uploads land under `<database_path>/media`, i.e. `/data/db/media` — on the same volume as the database |
| The container runs with `readOnlyRootFilesystem: true` | Only `/data`, `/tmp` and `/tmp/config` are writable; the latter two are `emptyDir`s recreated on every pod start, so nothing outside `/data` survives a restart |

> **Warning:** a `database_path` that resolves outside the mounted volume is not caught at render
> time. Setting `config.global.database_path: /var/lib/tuwunel` renders
> `TUWUNEL_DATABASE_PATH=/var/lib/tuwunel` with no volume behind it; the read-only root filesystem
> then leaves the server unable to create the directory, so the homeserver fails at startup with a
> symptom that looks like a disk problem but is a config/mount mismatch. Unlike `port` and
> `server_name`, the chart does not validate this key.

The StatefulSet runs a single replica (`replicas` is hardcoded to `1`, not a value) with a RocksDB
store on a `ReadWriteOnce` volume; scaling it up is not supported. Everything else the pod mounts —
the rendered `config.toml` under `/tmp/config` and `/tmp` — is ephemeral (see
[How the chart renders a running server](./internals.md)).

List the claims the release owns:

```console
$ kubectl get pvc -l app.kubernetes.io/instance=my-release
```

## PVC options

| Value | Default | What the template does |
| --- | --- | --- |
| `persistence.data.enabled` | `true` | `true`: the pod uses `persistentVolumeClaim.claimName` and, unless `existingClaim` is set, a PVC named `<fullname>-data` is rendered. `false`: the `data` volume becomes `emptyDir: {}` and no PVC object is rendered |
| `persistence.data.size` | `4Gi` | Quoted into `spec.resources.requests.storage`; validated as a Kubernetes quantity (numeric with an optional unit suffix) |
| `persistence.data.storageClass` | `""` | Three-way switch, see below |
| `persistence.data.accessMode` | `ReadWriteOnce` | The single entry in `spec.accessModes`, quoted. Validated against `ReadWriteOnce`, `ReadOnlyMany`, `ReadWriteMany`, `ReadWriteOncePod` |
| `persistence.data.existingClaim` | `""` | When set, the claim template renders nothing and the pod is wired to this claim name |
| `pvcAnnotations` | `{}` | Rendered under `metadata.annotations` of **every** PVC the chart creates (data and backup) |

`persistence` accepts no key other than `data` (the schema sets `additionalProperties: false`), and
the data claim carries only `accessModes` and `resources.requests.storage` — no `volumeMode`,
`selector` or `dataSource`.

`storageClass` is a three-way switch, and the three spellings look alike in a values file:

| Setting | Rendered | Effect |
| --- | --- | --- |
| unset or `""` | no `storageClassName` key at all | the cluster's default provisioner decides |
| `"-"` | `storageClassName: ""` | bind a pre-created PersistentVolume by hand; on a cluster with a default class the claim stays `Pending` forever and the pod unschedulable (see [Troubleshooting](./troubleshooting.md)) |
| any other value | `storageClassName: "fast-ssd"` | that class, quoted |

The rendered claim for the default case looks like this:

```yaml
spec:
  accessModes:
    - "ReadWriteOnce"
  resources:
    requests:
      storage: "4Gi"
```

A typo in `accessMode` fails the render before any manifest is produced:

```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
tuwunel:
- at '/persistence/data/accessMode': value must be one of 'ReadWriteOnce', 'ReadOnlyMany', 'ReadWriteMany', 'ReadWriteOncePod'
```

> **Danger:** `persistence.data.enabled: false` is a supported mode (the CI fixtures install that
> way), but it makes the data volume an `emptyDir` without any warning in the install — the
> container mount stays at `/data`, the claim template renders nothing, and the volume block
> shrinks to:
>
> ```yaml
> volumes:
>   - name: data
>     emptyDir: {}
> ```
>
> The database and, by default, all media then disappear whenever the pod is recreated — and a
> backup claim, if you enabled one, would outlive the data it describes. The diff against a real
> install is a single value.

See [Persistence Configuration](../charts/tuwunel/README.md#persistence-configuration) for the
same table in the canonical value reference.

## Bringing your own volume

Point `persistence.data.existingClaim` at a claim that already exists — created by another release,
a GitOps-managed object, or `kubectl apply`:

```yaml
persistence:
  data:
    existingClaim: matrix-data
```

The pod is then wired straight to that name:

```yaml
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: matrix-data
```

> **Warning:** in this mode the chart renders **no** PVC object — the claim is entirely yours. That
> means `pvcAnnotations`, `size`, `storageClass` and `accessMode` under `persistence.data` are
> inert, the chart cannot annotate or resize the storage, and helm will not touch or delete it. You
> can confirm the absence in a render:
>
> ```console
> $ helm template my-release charts/tuwunel -f values.yaml | grep -c "kind: PersistentVolumeClaim"
> 0
> ```

Keep the layout in mind when you hand over a claim: the mount uses `subPath: data`, so the server
reads `<claim-root>/data/db`. A claim whose data sits directly in its root (or anywhere next to a
`data/` directory) will look populated while the server starts with an empty database.

## Local media

With no provider configured, the server stores uploads in a `media/` subdirectory of the database
path — `/data/db/media` on the data volume. The chart does not render anything for media in that
case; it only renders `TUWUNEL_DATABASE_PATH`, and the server creates the directory itself. There
is no chart value for a media directory, no size estimate in the repo, and no compaction or
garbage-collection knob: the only RocksDB setting the chart exposes is
`config.global.db_pool_max_workers` (upstream default 2048; the chart also passes
`TUWUNEL_ROCKSDB_PARALLELISM_THREADS`, derived from the CPU limit), and its own note warns that
2048 can exceed the pod's task limit on a many-core node — failing startup with `EAGAIN`, which a
value around the CPU limit avoids.

Because media shares the database directory, two moves matter:

- **Moving media to object storage later** — do it without downtime: list both providers, point
  `store_media_on_providers` at the new one, then copy the old uploads with the admin-room command
  `!admin query storage sync <src> <dst>` (see the next section).
- **Changing `database_path`** — this re-homes the database *and* media, because media is defined
  relative to it. The chart only renders the env var: nothing is copied for you, and the new path
  has to stay inside the mounted `/data` (see the warning in [The data volume](#the-data-volume)).

> **Note:** media is not part of the managed backup — the backup repository covers the database
> only. See [Backups and restore](./backups.md).

## S3-compatible media storage

Media providers are pure configuration passthrough: you write them under `config.global`, the chart
renders them into `config.toml` verbatim, and credentials stay in a Secret through the
`${VAR}`/envsubst mechanism described in
[Using Secrets for Configuration](../charts/tuwunel/README.md#using-secrets-for-configuration) and
[Secrets and hardening](./security.md).

```yaml
envFromSecret:
  S3_ACCESS_KEY: tuwunel-secrets/S3_ACCESS_KEY
  S3_SECRET_KEY: tuwunel-secrets/S3_SECRET_KEY

config:
  global:
    ## Name the provider here or it is never used
    media_storage_providers: ["media", "media_on_s3"]
    ## Where new media is written while old media is still read from "media"
    store_media_on_providers: ["media_on_s3"]
    storage_provider:
      media_on_s3:
        s3:
          url: "s3://tuwunel-media/matrix"          # or bucket/region/base_path separately
          endpoint: "https://s3.example.com"        # self-hosted / non-AWS endpoints
          region: "us-east-1"
          key: "${S3_ACCESS_KEY}"
          secret: "${S3_SECRET_KEY}"
          # startup_check: false
```

That renders — excerpt, keys sorted by `toToml`, so the rendered order is not the order you wrote —
as:

```toml
[global]
  media_storage_providers = ["media", "media_on_s3"]
  store_media_on_providers = ["media_on_s3"]
  # ... the chart's other [global] keys ...
  [global.storage_provider]
    [global.storage_provider.media_on_s3]
      [global.storage_provider.media_on_s3.s3]
        endpoint = "https://s3.example.com"
        key = "${S3_ACCESS_KEY}"
        region = "us-east-1"
        secret = "${S3_SECRET_KEY}"
        url = "s3://tuwunel-media/matrix"
```

The shape rules the renderer follows:

| You write | Rendered TOML |
| --- | --- |
| A list of provider names (`media_storage_providers`, `store_media_on_providers`) | A TOML array of strings |
| A nested mapping (`storage_provider.media_on_s3.s3`) | One table per level: `[global.storage_provider.media_on_s3.s3]`, **not** an array of tables |
| A YAML list under a key upstream defines as a list of tables (`identity_provider`, `well_known.rtc_transports`) | The array-of-tables form `[[global.<key>]]` |

Semantics worth knowing before you edit the block:

- `media_storage_providers` is what makes a provider exist; `store_media_on_providers` decides which
  of the listed providers receives **new** media. Keeping `"media"` in the list keeps existing local
  uploads reachable while new ones go to S3.
- `key` and `secret` are placeholders, not values. The init container runs
  `envsubst < /tmp/config-template/config.toml > /tmp/config/config.toml`, and its environment comes
  from the same `env`/`envRaw`/`envFromSecret` mapping the server container uses — so the bucket
  keys never have to be written into a values file, and the same variables are available to the
  server at runtime.
- `startup_check` (upstream default `true`) pings the bucket while the server starts and aborts the
  start when it is unreachable. It is only switchable through this passthrough block — the chart has
  no dedicated value for it.
- Other provider keys from `tuwunel --generate-config` work through the same passthrough:
  `base_path`, `use_vhost_request`, `token`, `kms`, `use_bucket_key`.

> **Warning:** the chart validates none of this. `config` and `config.global` are
> `additionalProperties: true`, so a misspelled provider name, a provider that is configured but
> absent from `store_media_on_providers`, or a wrong TOML shape all render successfully and surface
> instead as a startup failure inside the server — a nested mapping where upstream expects an array
> of tables exits with `invalid type: found string, expected struct ...`. A missing env var is worse
> than a typo: envsubst expands `${S3_ACCESS_KEY}` to the empty string, the render still succeeds,
> and with `startup_check` on the homeserver refuses to start; with it off the failure moves to the
> first upload.

The repository contains no copy of the upstream storage-provider schema, so treat the keys listed
above (plus what `tuwunel --generate-config` prints) as the documented set rather than an
exhaustive one. The chart also never creates buckets, checks their contents, or synchronises
anything.

## Extra volumes and mounts

`extraVolumes` is appended to the pod's volume list after every chart volume; `extraVolumeMounts`
is appended after the chart's mounts on the tuwunel container only. Each mount entry needs `name`
and a `mountPath` starting with `/`.

```yaml
extraVolumes:
  - name: media-cache
    emptyDir: {}
extraVolumeMounts:
  - name: media-cache
    mountPath: /var/cache/media
```

Renders as:

```yaml
volumeMounts:
  # ... /data, /tmp/config, /tmp ...
  - mountPath: /var/cache/media
    name: media-cache
```

```yaml
volumes:
  # ... data, config-template, config, tmp ...
  - emptyDir: {}
    name: media-cache
```

A mount `name` has to match either an `extraVolumes` entry or one of the chart's own volumes:
`data`, `config-template`, `config`, `tmp`, `backup`.

> **Warning:** extra mounts cannot replace the chart's mounts. Reusing `data` in
> `extraVolumeMounts` adds a second mount of the same volume — the chart's own `/data` entry
> remains, and the server keeps using it. Relocating the database directory is a `database_path`
> question, not a mount question.

See [Pod Configuration](../charts/tuwunel/README.md#pod-configuration) for the neighbouring pod
values.

## Capacity and growth

Three things consume space, and only the first two are on the data claim:

| Grows | Where | Notes |
| --- | --- | --- |
| RocksDB store | `<pvc-root>/data/db` | the database itself |
| Uploaded media | `<pvc-root>/data/db/media` | only while no S3 provider takes new uploads |
| Backup repository | its own claim at `backup.path` (default `/backups`) | only with `backup.enabled: true` — see [Backups and restore](./backups.md) |

The chart gives you no usage signal: `size` is a PVC request, not a quota or a monitor. There is no
metrics endpoint, `ServiceMonitor`, `PodMonitor` or PVC-usage surface anywhere in the chart, and no
resize helper or `allowVolumeExpansion` guidance — growing a claim is your storage class's
behaviour, and watching it is cluster-level tooling's job (see [Day-2 operations](./operations.md)).

> **Warning:** `kubectl exec` into the server container cannot measure the volume. The image ships
> no shell and no coreutils — `du` is not in it — so `kubectl exec … -- du -sh /data/db` fails with
> a not-found error (`exec: "du": executable file not found in $PATH`, the failure
> `docker run --entrypoint du ghcr.io/matrix-construct/tuwunel:v1.9.2` reports against the same
> image, whose entrypoint is the `tuwunel` binary).

Measure the volume from a throwaway pod instead, mounting the claim the way the chart does:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: data-usage
spec:
  restartPolicy: Never
  nodeName: <node-running-the-server>
  containers:
    - name: du
      image: busybox:1.37
      command: ["du", "-sh", "/data/db", "/data/db/media"]
      volumeMounts:
        - name: data
          mountPath: /data
          subPath: data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: my-release-tuwunel-data
```

The claim is `ReadWriteOnce`, so the pod has to land on the node that already runs the server:

```console
$ kubectl get pod -l app.kubernetes.io/instance=my-release \
    -o jsonpath='{.items[0].spec.nodeName}'
```

Plan capacity before the volume is full: filling the data volume (RocksDB plus local `media/`) is
silent until a write fails, and the chart raises nothing. With `replicas` fixed at one and the
store on a `ReadWriteOnce` volume you cannot spread the load across pods, so capacity work means
resizing the claim or moving to a fresh, larger install.
