{{- define "certprep.name" -}}
{{- default "certprep" .Values.nameOverride -}}
{{- end -}}

{{- define "certprep.labels" -}}
app.kubernetes.io/name: {{ include "certprep.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
API environment.

Postgres credentials come from the CNPG-managed app secret rather than Vault —
whatever CNPG generated IS the password, so there is nothing to keep in sync.
The application's own secret (session signing key, tunnel token) comes from
Vault via ESO.
*/}}
{{- define "certprep.apiEnv" -}}
- name: POSTGRES_HOST
  value: {{ include "certprep.name" . }}-pg-rw
- name: POSTGRES_PORT
  value: "5432"
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef: { name: {{ include "certprep.name" . }}-pg-app, key: username }
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ include "certprep.name" . }}-pg-app, key: password }
- name: POSTGRES_DB
  valueFrom:
    secretKeyRef: { name: {{ include "certprep.name" . }}-pg-app, key: dbname }
- name: REDIS_URL
  value: "redis://{{ include "certprep.name" . }}-redis:6379/0"
- name: ENVIRONMENT
  value: "production"
- name: MEDIA_ROOT
  value: /data/media
- name: SOURCE_ROOT
  value: /app/data/source
- name: DEFAULT_EXAM_QUESTIONS
  value: {{ .Values.exam.questions | quote }}
- name: DEFAULT_EXAM_MINUTES
  value: {{ .Values.exam.minutes | quote }}
{{- range $k, $v := .Values.env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
- name: SECRET_KEY
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: secret_key }
- name: AI_API_KEY
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: ai_api_key, optional: true }
{{- end -}}

{{/* Pod-level hardening applied to every workload in this chart. */}}
{{- define "certprep.podSecurity" -}}
runAsNonRoot: true
runAsUser: 1001
runAsGroup: 1001
seccompProfile: { type: RuntimeDefault }
{{- end -}}

{{- define "certprep.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities: { drop: ["ALL"] }
{{- end -}}
