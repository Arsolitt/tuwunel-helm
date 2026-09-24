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

