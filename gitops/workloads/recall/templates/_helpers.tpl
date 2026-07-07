{{- define "recall.name" -}}
{{- default "recall" .Values.nameOverride -}}
{{- end -}}

{{- define "recall.labels" -}}
app.kubernetes.io/name: {{ include "recall.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "recall.apiImage" -}}
{{ .Values.image.registry }}/{{ .Values.image.api.repository }}:{{ .Values.image.api.tag }}
{{- end -}}

{{- define "recall.webImage" -}}
{{ .Values.image.registry }}/{{ .Values.image.web.repository }}:{{ .Values.image.web.tag }}
{{- end -}}

{{/*
Shared app env. DATABASE_URL is assembled from the CNPG-generated recall-pg-app secret via
$(VAR) expansion, so we never have to coordinate the DB password with Vault — whatever
recall-pg-app holds IS the password.
*/}}
{{- define "recall.appEnv" -}}
- name: ENVIRONMENT
  value: {{ .Values.config.environment | quote }}
- name: PUBLIC_BASE_URL
  value: {{ .Values.config.publicBaseUrl | quote }}
- name: CORS_ORIGINS
  value: {{ .Values.config.corsOrigins | quote }}
- name: REDIS_URL
  value: "redis://recall-redis:6379/0"
- name: PG_USER
  valueFrom:
    secretKeyRef: { name: recall-pg-app, key: username }
- name: PG_PASS
  valueFrom:
    secretKeyRef: { name: recall-pg-app, key: password }
- name: DATABASE_URL
  value: "postgresql+asyncpg://$(PG_USER):$(PG_PASS)@recall-pg-rw:5432/recall"
- name: REGISTRATION_MODE
  value: {{ .Values.config.registrationMode | quote }}
- name: ADMIN_EMAILS
  value: {{ .Values.config.adminEmails | quote }}
- name: AI_PROVIDER
  value: {{ .Values.config.aiProvider | quote }}
- name: EMBEDDING_PROVIDER
  value: {{ .Values.config.embeddingProvider | quote }}
- name: TRANSCRIPTION_PROVIDER
  value: {{ .Values.config.transcriptionProvider | quote }}
- name: BLOB_STORE
  value: {{ .Values.config.blobStore | quote }}
- name: S3_REGION
  value: {{ .Values.config.s3Region | quote }}
- name: S3_BUCKET_AUDIO
  value: {{ .Values.config.s3BucketAudio | quote }}
- name: S3_ENDPOINT_URL
  value: {{ .Values.config.s3EndpointUrl | quote }}
- name: OLLAMA_URL
  value: {{ .Values.config.ollamaUrl | quote }}
- name: ANTHROPIC_MODEL
  value: {{ .Values.config.anthropicModel | quote }}
- name: GROQ_MODEL
  value: {{ .Values.config.groqModel | quote }}
- name: EMBEDDING_MODEL
  value: {{ .Values.config.embeddingModel | quote }}
- name: JWT_PRIVATE_KEY_PATH
  value: /run/secrets/jwt_private_key
- name: JWT_PUBLIC_KEY_PATH
  value: /run/secrets/jwt_public_key
{{- if .Values.externalSecrets.enabled }}
- name: CREDENTIAL_KEY
  valueFrom:
    secretKeyRef: { name: recall-secrets, key: credential_key, optional: true }
- name: S3_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef: { name: recall-secrets, key: s3_access_key_id, optional: true }
- name: S3_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef: { name: recall-secrets, key: s3_secret_access_key, optional: true }
- name: ANTHROPIC_API_KEY
  valueFrom:
    secretKeyRef: { name: recall-secrets, key: anthropic_api_key, optional: true }
- name: GROQ_API_KEY
  valueFrom:
    secretKeyRef: { name: recall-secrets, key: groq_api_key, optional: true }
{{- end }}
{{- end -}}

{{/* Mount the RS256 keys (from recall-secrets) as files. */}}
{{- define "recall.secretVolumes" -}}
- name: jwt-keys
  secret:
    secretName: recall-secrets
    items:
      - { key: jwt_private_key, path: jwt_private_key }
      - { key: jwt_public_key, path: jwt_public_key }
{{- end -}}

{{- define "recall.secretVolumeMounts" -}}
- name: jwt-keys
  mountPath: /run/secrets
  readOnly: true
{{- end -}}
