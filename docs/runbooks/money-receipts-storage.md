# Money — receipt photo storage (in-cluster MinIO)

Project-expense receipts (photos, PDFs) live in an in-cluster MinIO instance
deployed by the money Helm chart, backed by a Longhorn PVC. No data leaves the
homelab.

## What gets created

- **MinIO** Deployment + Service + 20 Gi Longhorn PVC, namespace `money`.
- A bucket named `money-receipts` (auto-created by the API on first boot).
- API container env: `STORAGE_*` settings wired through ESO.

## One-time setup

### 1. Generate access/secret keys

Two opaque random strings. Run locally — never reuse a real cloud key.

```bash
openssl rand -hex 16              # storage_access_key (32 hex chars)
openssl rand -base64 32 | tr -d '=/+'   # storage_secret_key (~43 chars)
```

### 2. Write them to Vault

The money AppRole policy already allows `secret/data/money/*` read. Add the
two keys to the existing `secret/money/app` blob (alongside `database_url`,
`jwt_*`, etc.) — PATCH, **not POST**, so other keys aren't overwritten:

```bash
vault kv patch secret/money/app \
  storage_access_key='<HEX-FROM-STEP-1>' \
  storage_secret_key='<BASE64-FROM-STEP-1>'
```

### 3. Enable in `values-homelab.yaml`

```yaml
externalSecrets:
  storage: true

minio:
  enabled: true
storage:
  enabled: true
  endpointUrl: "http://money-minio.money.svc.cluster.local:9000"
  bucket: "money-receipts"
```

Commit + push; ArgoCD syncs. Order of events on the cluster:

1. ESO refreshes `money-secrets` with the two new keys.
2. MinIO Deployment + PVC come up; pod becomes Ready.
3. API restarts (Deployment hash changes via the new env vars), reads the keys,
   `ensure_bucket()` creates `money-receipts` on first boot.

### 4. Verify

```bash
kubectl -n money get pods -l app.kubernetes.io/component=minio
kubectl -n money logs deploy/money-minio --tail=20 | grep -i 'API'   # listening on :9000
kubectl -n money exec deploy/money-api -- python - <<'PY'
import asyncio
from app.core.storage import storage_enabled, ensure_bucket
print("enabled:", storage_enabled())
asyncio.run(ensure_bucket())
PY
```

End-to-end: upload a receipt from the UI (Projects → open a project → click
the 📎 icon on any expense → "Add receipt"). The image should appear inline.

## Operational notes

- **Backups**: receipts are *not* in the CNPG Postgres backup. If you need
  off-site copies, configure `mc mirror` on a schedule from MinIO to S3
  (separate runbook — currently the PVC is the only copy, snapshotted by
  Longhorn).
- **Rotating the keys**: write the new values to Vault, then `kubectl -n money
  rollout restart deploy/money-minio deploy/money-api`. MinIO re-reads the
  root creds on start.
- **Disk usage**: receipts are tiny (a few MB each). 20 Gi is several thousand
  receipts; bump `minio.storage.size` in `values-homelab.yaml` to grow it
  (Longhorn expands the volume in place).
- **Upload limit**: 10 MB per file, capped at the API edge
  (`STORAGE_MAX_UPLOAD_BYTES`). Adjust via `storage.maxUploadBytes` in values.
