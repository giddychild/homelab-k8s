{{- define "vantage.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vantage.fullname" -}}
{{- include "vantage.name" . -}}
{{- end -}}

{{- define "vantage.labels" -}}
app.kubernetes.io/name: {{ include "vantage.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "vantage.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vantage.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
