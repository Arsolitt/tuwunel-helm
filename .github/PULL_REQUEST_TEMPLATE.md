# What changed

<!-- Describe the change and why it is needed. Link issues with "Fixes #123". -->

## How it was verified

<!-- Commands you ran, clusters you installed into, values you tried. -->

## Checklist

- [ ] `helm lint --strict charts/tuwunel` passes
- [ ] Every scenario still renders:
      `for f in charts/tuwunel/ci/*-values.yaml; do helm template ci charts/tuwunel -f "$f" > /dev/null || exit 1; done`
- [ ] `hack/runtime-check.sh` passes (starts the real image for every scenario
      and probes the readiness path - needs docker)
- [ ] New or changed values are covered by `charts/tuwunel/values.schema.json`
      (and the value tables in `charts/tuwunel/README.md` were updated)
- [ ] Nothing under `charts/tuwunel/ci/invalid/` became acceptable to the schema
- [ ] `CHANGELOG.md` carries the section for the version this change ships
      in - a release publishes the section its tag names
