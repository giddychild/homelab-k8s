{{- define "careledger.name" -}}
{{- default "careledger" .Values.nameOverride -}}
{{- end -}}

{{- define "careledger.labels" -}}
app.kubernetes.io/name: {{ include "careledger.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Application environment. Plain config inline; the three secrets (AUTH_SECRET,
VAULT_KEY, JOIN_CODE) come from the ESO-materialized careledger-secrets. The
container entrypoint runs `prisma migrate deploy` against the SQLite file on the
mounted volume before starting the server.
*/}}
{{- define "careledger.env" -}}
- name: NODE_ENV
  value: "production"
- name: PORT
  value: {{ .Values.app.port | quote }}
- name: HOSTNAME
  value: "0.0.0.0"
- name: DATABASE_URL
  value: "file:{{ .Values.persistence.mountPath }}/app.db"
- name: AUTH_TRUST_HOST
  value: "true"
- name: NEXTAUTH_URL
  value: {{ .Values.app.publicUrl | quote }}
- name: STORAGE_DRIVER
  value: "local"
- name: STORAGE_LOCAL_DIR
  value: "{{ .Values.persistence.mountPath }}/uploads"
- name: MAX_UPLOAD_MB
  value: {{ .Values.app.maxUploadMb | quote }}
- name: AUTH_SECRET
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: auth_secret }
- name: VAULT_KEY
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: vault_key }
- name: JOIN_CODE
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: join_code }
{{- if .Values.loginAlerts.enabled }}
- name: DISCORD_WEBHOOK_URL
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: discord_webhook_url }
{{- end }}
{{- end -}}
