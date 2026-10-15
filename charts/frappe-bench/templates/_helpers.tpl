{{/* Common helpers for the frappe-bench chart. */}}

{{- define "frappe-bench.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "frappe-bench.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "frappe-bench.labels" -}}
app.kubernetes.io/name: {{ include "frappe-bench.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: frappe-bench
{{- end -}}

{{/* Common pod-level fields: image pull secrets + ServiceAccount default. */}}
{{- define "frappe-bench.podDefaults" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* The namespace the bench runs in. */}}
{{- define "frappe-bench.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{/*
The otel resource `service.namespace`: explicit value, else the release
namespace (the full canonical name, per repo rule).
*/}}
{{- define "frappe-bench.otelNamespace" -}}
{{- default .Release.Namespace .Values.otel.namespace -}}
{{- end -}}

{{/* deployment.environment: explicit, else the trailing segment of the ns. */}}
{{- define "frappe-bench.otelEnvironment" -}}
{{- if .Values.otel.environment -}}
{{- .Values.otel.environment -}}
{{- else -}}
{{- $parts := splitList "-" .Release.Namespace -}}
{{- last $parts -}}
{{- end -}}
{{- end -}}

{{/* First site hostname (used for probe Host headers). */}}
{{- define "frappe-bench.primaryHost" -}}
{{- (first .Values.sites).name -}}
{{- end -}}

{{/* PVC name for shared sites data. */}}
{{- define "frappe-bench.sitesClaim" -}}
{{- default (printf "%s-sites-data" (include "frappe-bench.fullname" .)) .Values.sitesStorage.existingClaim -}}
{{- end -}}

{{/*
PYTHONPATH: every app dir joined by ':'. Primary app first.
*/}}
{{- define "frappe-bench.pythonPath" -}}
{{- $paths := list -}}
{{- range .Values.apps -}}
{{- $paths = append $paths (printf "/home/frappe/frappe-bench/apps/%s" .name) -}}
{{- end -}}
{{- join ":" $paths -}}
{{- end -}}

{{/*
App code volumes + mounts, driven by .Values.apps. Rendered as two blocks so
callers can place volumes under spec.volumes and mounts in a container.
*/}}
{{- define "frappe-bench.appVolumes" -}}
{{- range .Values.apps }}
- name: apps-{{ .name }}
  image:
    reference: {{ printf "%s:%s" .image.repository .image.tag }}
    pullPolicy: {{ default "IfNotPresent" .image.pullPolicy }}
{{- end }}
{{- end -}}

{{- define "frappe-bench.appVolumeMounts" -}}
{{- range .Values.apps }}
- name: apps-{{ .name }}
  mountPath: /home/frappe/frappe-bench/apps/{{ .name }}
  subPath: opt/frappe/apps/{{ .name }}
  readOnly: true
{{- end }}
{{- end -}}
