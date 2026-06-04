{{- define "brainblocks.name" -}}
{{- default "brainblocks" .Values.nameOverride -}}
{{- end -}}

{{- define "brainblocks.labels" -}}
app.kubernetes.io/name: {{ include "brainblocks.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
DB-only env. DATABASE_URL is built from the CNPG-managed app secret
(brainblocks-pg-app) via k8s $(VAR) expansion — same trick as learnquest/money:
whatever the CNPG secret holds IS the DB password, so we never coordinate it with
Vault. Used on its own by the migrate Job so migrations DON'T depend on the
ESO-materialized app secret (which delayed the first deploy).
*/}}
{{- define "brainblocks.dbEnv" -}}
- name: PG_HOST
  value: {{ include "brainblocks.name" . }}-pg-rw
- name: PG_USER
  valueFrom:
    secretKeyRef: { name: {{ include "brainblocks.name" . }}-pg-app, key: username }
- name: PG_PASS
  valueFrom:
    secretKeyRef: { name: {{ include "brainblocks.name" . }}-pg-app, key: password }
- name: PG_DB
  valueFrom:
    secretKeyRef: { name: {{ include "brainblocks.name" . }}-pg-app, key: dbname }
- name: DATABASE_URL
  value: "postgresql://$(PG_USER):$(PG_PASS)@$(PG_HOST):5432/$(PG_DB)?schema=public"
{{- end -}}

{{/*
Backend (API) environment = DB env + app config. The JWT secret comes from the
ESO-materialized brainblocks-secrets.
*/}}
{{- define "brainblocks.appEnv" -}}
- name: NODE_ENV
  value: {{ .Values.env.NODE_ENV | default "production" | quote }}
- name: PORT
  value: {{ .Values.backend.port | quote }}
- name: APP_VERSION
  value: {{ .Values.image.tag | quote }}
{{ include "brainblocks.dbEnv" . }}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: jwt_secret }
- name: JWT_EXPIRES_IN
  value: {{ .Values.backend.jwtExpiresIn | quote }}
- name: CORS_ORIGIN
  value: {{ .Values.backend.corsOrigin | quote }}
{{- if .Values.inviteCode.enabled }}
- name: SIGNUP_INVITE_CODE
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: signup_invite_code }
{{- end }}
{{- if .Values.loginAlerts.enabled }}
- name: DISCORD_WEBHOOK_URL
  valueFrom:
    secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: discord_webhook_url }
{{- if .Values.loginAlerts.mention }}
- name: DISCORD_MENTION
  value: {{ .Values.loginAlerts.mention | quote }}
{{- end }}
{{- end }}
{{- end -}}
