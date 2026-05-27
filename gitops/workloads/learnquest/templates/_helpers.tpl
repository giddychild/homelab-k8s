{{- define "learnquest.name" -}}
{{- default "learnquest" .Values.nameOverride -}}
{{- end -}}

{{- define "learnquest.labels" -}}
app.kubernetes.io/name: {{ include "learnquest.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
App environment. DATABASE_URL is built from the CNPG-managed app secret
(learnquest-pg-app) via k8s $(VAR) expansion — the robust trick from `money`:
whatever the CNPG secret holds IS the DB password, so we never coordinate it
with Vault. Non-secret config comes from .Values.env; app secrets (JWT keys,
Anthropic key) come from the ESO-materialized secret.
*/}}
{{- define "learnquest.appEnv" -}}
- name: PG_HOST
  value: {{ include "learnquest.name" . }}-pg-rw
- name: PG_USER
  valueFrom:
    secretKeyRef: { name: {{ include "learnquest.name" . }}-pg-app, key: username }
- name: PG_PASS
  valueFrom:
    secretKeyRef: { name: {{ include "learnquest.name" . }}-pg-app, key: password }
- name: PG_DB
  valueFrom:
    secretKeyRef: { name: {{ include "learnquest.name" . }}-pg-app, key: dbname }
- name: DATABASE_URL
  value: "postgresql+asyncpg://$(PG_USER):$(PG_PASS)@$(PG_HOST):5432/$(PG_DB)"
- name: REDIS_URL
  value: "redis://{{ include "learnquest.name" . }}-redis:6379/0"
- name: OLLAMA_URL
  value: {{ .Values.ai.ollamaUrl | quote }}
- name: FACTORY_PROVIDER
  value: {{ .Values.ai.factoryProvider | quote }}
{{- range $k, $v := .Values.env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
- name: JWT_PRIVATE_KEY
  valueFrom: { secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: jwt_private_key } }
- name: JWT_PUBLIC_KEY
  valueFrom: { secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: jwt_public_key } }
- name: ANTHROPIC_API_KEY
  valueFrom: { secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: anthropic_api_key, optional: true } }
- name: DISCORD_WEBHOOK_URL
  valueFrom: { secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: discord_webhook_url, optional: true } }
- name: SIGNUP_INVITE_CODE
  valueFrom: { secretKeyRef: { name: {{ .Values.externalSecret.secretName }}, key: signup_invite_code, optional: true } }
{{- end -}}
