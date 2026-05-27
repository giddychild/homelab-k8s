# money — Postgres backups & restore (CloudNativePG + Barman → S3)

The `money` finance data lives in a CloudNativePG cluster on **apps-prod**. Velero
runs on **homelab-prod only**, so it does **not** cover this database. Backups here
are CNPG-native: continuous **WAL archiving** + scheduled **base backups** to S3,
which together give **point-in-time recovery (PITR)**.

The Helm chart pieces are already in place (`gitops/workloads/money`):
`postgres-cluster.yaml` (barmanObjectStore + 30-day retention) and
`postgres-backup.yaml` (S3-creds ExternalSecret + daily `ScheduledBackup` at 03:30).
They are gated by `postgres.backup.enabled`, currently **false**. Enabling is a
one-time set of user-side steps below (AWS + Vault writes are classifier-blocked
from chat, so you run them).

## 1. Create a dedicated S3 bucket + scoped IAM user (AWS, your laptop)

> **Do NOT reuse the Velero bucket** (`…-homelab-k8s-backups`). Velero validates it
> owns the bucket root; a second tool writing a top-level prefix makes Velero's
> BackupStorageLocation go `Unavailable`. Use a separate bucket.

```bash
BUCKET=giddyland-money-pg-backups        # must match values-homelab destinationPath
REGION=us-east-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
# Optional but recommended: enable default encryption + abort-incomplete-multipart
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Least-privilege IAM user limited to this bucket:
aws iam create-user --user-name money-pg-backup
aws iam put-user-policy --user-name money-pg-backup --policy-name money-pg-backup \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"arn:aws:s3:::$BUCKET\"},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\",\"s3:DeleteObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}"
aws iam create-access-key --user-name money-pg-backup
# → note AccessKeyId + SecretAccessKey for step 2
```

> **Do NOT** add an S3 lifecycle expiration rule on this prefix — it would corrupt
> Barman/WAL chains. Retention is handled by CNPG's `retentionPolicy: "30d"`.
> An `abort-incomplete-multipart-upload` rule is safe.

## 2. Store the keys in Vault (so ESO can materialize them)

The apps-prod AppRole policy already allows `secret/data/money/*`, so use that path.
On **mgmt-jump** (`vault` CLI isn't installed there — use the API), or from any host
with the Vault root token:

```bash
export VAULT_ADDR=https://vault.apps.giddyland.net
export VAULT_TOKEN=<root>
curl -sf -X POST "$VAULT_ADDR/v1/secret/data/money/backup-s3" \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{"data":{"access_key_id":"<AccessKeyId>","secret_access_key":"<SecretAccessKey>"}}' \
  -o /dev/null -w 'HTTP %{http_code}\n'   # expect 200
```

## 3. Enable backups

In `gitops/workloads/money/values-homelab.yaml`, set `postgres.backup.enabled: true`
(confirm `destinationPath` matches your `$BUCKET`) and commit to `main`. ArgoCD syncs;
ESO creates `money-pg-backup-s3`; CNPG begins WAL archiving and the daily base backup runs.

## 4. Verify (apps-prod, via mgmt-jump kubeconfig)

```bash
export KUBECONFIG=~/.kube/apps-prod.kubeconfig
kubectl -n money get externalsecret money-pg-backup-s3        # SecretSynced=True
kubectl -n money get scheduledbackup                          # money-pg-daily
# Trigger an immediate base backup instead of waiting for 03:30:
kubectl -n money create -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: money-pg-manual-1, namespace: money }
spec: { cluster: { name: money-pg } }
EOF
# NB: use the FQ resource name — Longhorn also defines a "Backup" kind, so the
# short name "backup" resolves to backups.longhorn.io, not CNPG's.
kubectl -n money get backups.postgresql.cnpg.io money-pg-manual-1 -w   # phase → completed
aws s3 ls s3://giddyland-money-pg-backups/ --recursive | head # base/ + wals/ appear
```

## 5. Restore drill (do this once so it's tested, not hypothetical)

CNPG restores by **bootstrapping a NEW cluster** from the object store (the source
cluster is never overwritten). Recover to the latest WAL or to a point in time.

```yaml
# money-pg-restore.yaml — a throwaway cluster recovered from S3.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: money-pg-restore, namespace: money }
spec:
  instances: 1
  storage: { size: 20Gi, storageClass: longhorn-r2 }
  bootstrap:
    recovery:
      source: money-pg
      # For PITR add: recoveryTarget: { targetTime: "2026-05-26 12:00:00+00" }
  externalClusters:
    - name: money-pg
      barmanObjectStore:
        destinationPath: "s3://giddyland-money-pg-backups/"
        endpointURL: "https://s3.us-east-1.amazonaws.com"
        s3Credentials:
          accessKeyId:     { name: money-pg-backup-s3, key: ACCESS_KEY_ID }
          secretAccessKey: { name: money-pg-backup-s3, key: ACCESS_SECRET_KEY }
```

```bash
kubectl apply -f money-pg-restore.yaml
kubectl -n money get cluster money-pg-restore -w              # → Cluster in healthy state
# Spot-check the data, then tear the drill cluster down:
kubectl -n money exec money-pg-restore-1 -c postgres -- \
  psql -U postgres -d money -c "select count(*) from transaction;"
kubectl -n money delete cluster money-pg-restore
```

**Real recovery:** point the `money` Helm release's Postgres at a recovery bootstrap
(or rename the recovered cluster and repoint `DATABASE_URL`). Keep this runbook with
the DR docs; rehearse after any major Postgres version bump.
