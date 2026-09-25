{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "tuwunel.name" -}}
  {{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "tuwunel.fullname" -}}
  {{- if .Values.fullnameOverride -}}
    {{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
  {{- else -}}
    {{- $name := default .Chart.Name .Values.nameOverride -}}
    {{- if contains $name .Release.Name -}}
      {{- .Release.Name | trunc 63 | trimSuffix "-" -}}
    {{- else -}}
      {{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "tuwunel.chart" -}}
  {{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Generate all the labels for chart-deployed resources
*/}}
{{- define "tuwunel.labels" -}}
app.kubernetes.io/name: {{ template "tuwunel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ template "tuwunel.chart" . }}
{{ with .Values.extraLabels }}{{ toYaml . }}{{ end }}
{{- end -}}

{{/*
The labels that decide which pod a workload or a Service owns.

This set has to stay identical for the whole life of a release, so it is
deliberately smaller than `tuwunel.labels`: nothing here may come from the chart
version or from the release metadata. `spec.selector` is immutable on a
StatefulSet and on a Deployment, so `helm.sh/chart` in it - it carries the chart
version - turns the next `helm upgrade` into

    Deployment.apps "..." is invalid: spec.selector: Invalid value: ...: field is immutable

and a Service that selects on the chart version loses every endpoint between
the moment the new selector is applied and the moment its first new pod is
Ready. `extraLabels` is metadata as well and stays out, or changing it would
break the selector it was never meant to touch.

Metadata labels, pod template labels and every other label site keep using
`tuwunel.labels`, which is a superset of this (a pod template must carry at
least its own selector).

Usage: {{ include "tuwunel.selectorLabels" . }}, plus the component label the
resource belongs to.
*/}}
{{- define "tuwunel.selectorLabels" -}}
app.kubernetes.io/name: {{ template "tuwunel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Render a value as a Kubernetes host field.

The values the chart builds host fields from are Matrix names, and a Matrix
server name may carry a port (`matrix.example.com:8448`) - but the fields that
consume it are not Matrix fields: `Ingress.spec.rules[].host`,
`Ingress.spec.tls[].hosts[]` and `HTTPRoute.spec.hostnames[]` take a bare
hostname, the API server refuses a port, and a port would end up in the
certificate's SNI name as well. So the port is dropped here, once, for every
host field the chart renders (the delegated domain used to be normalised in the
templates themselves).

A scheme is never part of a host field, and unlike a port there is nothing to
strip to turn one into a name: guessing which host the user meant behind
`https://` would put a name in the manifest that appears nowhere in the values,
and it would disagree with `TUWUNEL_SERVER_NAME`/`config.toml`, which keep the
configured value. So the render fails instead, naming the label and the value.

Usage: {{ include "tuwunel.host" (dict "value" .Values.server_name "label" "server_name") }}
*/}}
{{- define "tuwunel.host" -}}
  {{- $value := .value | toString -}}
  {{- if contains "://" (lower $value) -}}
    {{- fail (printf "%s must be a bare hostname, not a URL: %q" .label $value) -}}
  {{- end -}}
  {{- mustRegexReplaceAll ":[0-9]+$" $value "" -}}
{{- end -}}

{{/*
Refuse the upgrade the API server would refuse, with the commands that fix it.

Charts at 2.0.1 and below selected pods with the full `tuwunel.labels` set, so
`spec.selector.matchLabels` of the live StatefulSet and of the two RTC
Deployments carries `helm.sh/chart: tuwunel-<chart version>`. That value changes
on every chart release and a workload's selector is immutable, so the first
upgrade of such a release fails at the API server with

    spec.selector: Invalid value: ...: field is immutable

which names neither the cause nor a way out. The state that produces it is
readable from the cluster before anything is applied, so the render reads it and
fails here instead, printing the one-time commands.

`lookup` returns an empty map whenever there is no cluster to ask (`helm
template` and `helm lint`, which is what CI runs, and `helm install`, where the
objects do not exist yet), so this only ever fires on an upgrade of a release
that still carries the old selector. Once the commands have run, the recreated
objects carry the new selector and the check stays silent for good.

Usage (rendered from a template that always renders, see statefulset.yaml):
{{ include "tuwunel.assert-selector-migration" . }}
*/}}
{{- define "tuwunel.assert-selector-migration" -}}
  {{- $fullname := include "tuwunel.fullname" . -}}
  {{- $candidates := list (dict "kind" "StatefulSet" "name" $fullname) -}}
  {{- if .Values.rtc.enabled -}}
    {{- $candidates = append $candidates (dict "kind" "Deployment" "name" (printf "%s-jwt" $fullname)) -}}
    {{- $candidates = append $candidates (dict "kind" "Deployment" "name" (printf "%s-livekit" $fullname)) -}}
  {{- end -}}
  {{- $commands := list -}}
  {{- range $candidate := $candidates -}}
    {{- $live := lookup "apps/v1" $candidate.kind $.Release.Namespace $candidate.name -}}
    {{- if hasKey (dig "spec" "selector" "matchLabels" (dict) $live) "helm.sh/chart" -}}
      {{- if eq $candidate.kind "StatefulSet" -}}
        {{- $commands = append $commands (printf "kubectl -n %s delete statefulset %s --cascade=orphan" $.Release.Namespace $candidate.name) -}}
      {{- else -}}
        {{- $commands = append $commands (printf "kubectl -n %s delete deployment %s" $.Release.Namespace $candidate.name) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if $commands -}}
    {{- fail (printf "the live release still selects its pods with the chart version in spec.selector.matchLabels, which chart 2.0.1 and older rendered from helm.sh/chart. A workload's selector is immutable, so the API server refuses this upgrade (\"spec.selector: Invalid value: ...: field is immutable\"). Run the commands below once and start the upgrade again.\n\n  %s\n\nThe StatefulSet keeps its pod: --cascade=orphan leaves it running under the same name and the recreated StatefulSet adopts it, so the database on the PersistentVolumeClaim is never touched. Deleting the Deployments recreates their pods, which is a couple of seconds without RTC media forwarding." (join "\n  " $commands)) -}}
  {{- end -}}
{{- end -}}

