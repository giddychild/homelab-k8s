{{/* Common naming + label helpers. */}}

{{- define "money.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "money.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s" (include "money.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "money.labels" -}}
app.kubernetes.io/name: {{ include "money.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Per-component selector labels. Usage: include "money.selectorLabels" (dict "ctx" . "component" "api") */}}
{{- define "money.selectorLabels" -}}
app.kubernetes.io/name: {{ include "money.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "money.api.fullname" -}}{{ printf "%s-api" (include "money.fullname" .) }}{{- end -}}
{{- define "money.web.fullname" -}}{{ printf "%s-web" (include "money.fullname" .) }}{{- end -}}
{{- define "money.worker.fullname" -}}{{ printf "%s-worker" (include "money.fullname" .) }}{{- end -}}
{{- define "money.redis.fullname" -}}{{ printf "%s-redis" (include "money.fullname" .) }}{{- end -}}
{{- define "money.pg.fullname" -}}{{ printf "%s-pg" (include "money.fullname" .) }}{{- end -}}

{{/* Shared API/worker env (secrets + AI config). */}}
{{- define "money.appEnv" -}}
# DATABASE_URL is assembled from the CloudNativePG-managed app secret so it
# always matches the live DB password (k8s $(VAR) env expansion). This avoids
# coordinating the generated Postgres password with Vault.
- name: PG_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "money.pg.fullname" . }}-app
      key: username
- name: PG_PASS
  valueFrom:
    secretKeyRef:
      name: {{ include "money.pg.fullname" . }}-app
      key: password
- name: DATABASE_URL
  value: "postgresql+asyncpg://$(PG_USER):$(PG_PASS)@{{ include "money.pg.fullname" . }}-rw.{{ .Release.Namespace }}.svc.cluster.local:5432/{{ .Values.postgres.database }}"
- name: REDIS_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalSecrets.targetSecretName }}
      key: redis_url
- name: JWT_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalSecrets.targetSecretName }}
      key: jwt_private_key
- name: JWT_PUBLIC_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalSecrets.targetSecretName }}
      key: jwt_public_key
# Optional: present only once credential_key is provisioned in Vault and
# externalSecrets.credentialKey is enabled. optional=true so pods start without it.
- name: CREDENTIAL_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalSecrets.targetSecretName }}
      key: credential_key
      optional: true
- name: OLLAMA_URL
  value: {{ .Values.ai.ollamaUrl | quote }}
- name: EXTERNAL_AI_ENABLED
  value: {{ .Values.ai.externalAiEnabled | quote }}
- name: BASE_CURRENCY
  value: "USD"
- name: DEMO_SEED_ENABLED
  value: {{ .Values.demo.seedEnabled | default false | quote }}
- name: REGISTRATION_OPEN
  value: {{ .Values.registrationOpen | default false | quote }}
{{- end -}}
