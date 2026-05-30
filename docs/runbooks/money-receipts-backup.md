# Money — off-site mirror of the receipts bucket

Receipts (project-expense photos / PDFs) live in the in-cluster MinIO bucket
`money-receipts`. Longhorn snapshots are the only local safety net; this
runbook adds a nightly **off-site mirror** to an S3-compatible bucket so the
attachments survive a full Longhorn loss. The pattern mirrors the existing
CNPG → AWS S3 backup.

## What gets created

- A nightly Kubernetes **CronJob** (`money-minio-backup`) that runs `mc mirror`
  from the in-cluster MinIO to an AWS S3 bucket. `--remove` keeps the remote
  exactly in step with the source (deletes propagate).
- An **ExternalSecret** that pulls the destination IAM user's
  access_key_id / secret_access_key from Vault.

## Prerequisites

- MinIO is already enabled (`minio.enabled: true`, see
  [money-receipts-storage.md](money-receipts-storage.md)).
- An AWS account you control (or any S3-compatible endpoint).

## One-time setup

### 1. Create the destination bucket + IAM user

Use a **dedicated bucket** (don't reuse `giddyland-money-pg-backups` — sharing
the root breaks Velero's BackupStorageLocation pattern):

```bash
aws s3api create-bucket \
  --bucket giddyland-money-receipts-backup \
  --region us-east-1

# (Recommended) versioning + lifecycle so deletes are recoverable for a while.
aws s3api put-bucket-versioning \
  --bucket giddyland-money-receipts-backup \
  --versioning-configuration Status=Enabled
```

Create an IAM user scoped to just this bucket and capture its access keys.
Minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ],
    "Resource": [
      "arn:aws:s3:::giddyland-money-receipts-backup",
      "arn:aws:s3:::giddyland-money-receipts-backup/*"
    ]
  }]
}
```

### 2. Store the credentials in Vault

The chart expects them at `secret/money/receipts-backup-s3` (separate from
`money/app` so revoking these doesn't touch the app's other secrets):

```bash
vault kv put secret/money/receipts-backup-s3 \
  access_key_id='AKIA…' \
  secret_access_key='…'
```

### 3. Enable in `values-homelab.yaml`

```yaml
minio:
  enabled: true            # (already true if receipts are live)
  backup:
    enabled: true
    bucket: giddyland-money-receipts-backup
    # endpointUrl + vaultPath + schedule default to AWS S3, secret/money/receipts-backup-s3, 03:15.
```

Commit + push. ArgoCD syncs the ExternalSecret + CronJob.

### 4. Verify

```bash
# Trigger a one-off run (don't wait for the schedule).
kubectl -n money create job --from=cronjob/money-minio-backup money-minio-backup-manual

# Tail the log; expect "added 0/N files".
kubectl -n money logs job/money-minio-backup-manual -f

# Confirm in S3.
aws s3 ls s3://giddyland-money-receipts-backup/ --recursive
```

## Restore

Pre-merger or full Longhorn loss:

```bash
# Mirror the OTHER direction. Run as a one-off Job, NOT from the CronJob.
kubectl -n money run mc-restore --rm -it --restart=Never \
  --image=minio/mc:RELEASE.2026-05-01T00-00-00Z \
  --env=AWS_ACCESS_KEY_ID=... \
  --env=AWS_SECRET_ACCESS_KEY=... \
  --env=SRC_ACCESS=$(kubectl -n money get secret money-secrets -o jsonpath='{.data.storage_access_key}' | base64 -d) \
  --env=SRC_SECRET=$(kubectl -n money get secret money-secrets -o jsonpath='{.data.storage_secret_key}' | base64 -d) \
  -- sh -c '
    mc alias set dst http://money-minio.money.svc.cluster.local:9000 "$SRC_ACCESS" "$SRC_SECRET"
    mc alias set src https://s3.us-east-1.amazonaws.com AWS_KEYS_HERE
    mc mirror src/giddyland-money-receipts-backup dst/money-receipts
  '
```

## Operational notes

- The job uses `--remove`, so if a receipt is deleted in the app it disappears
  from S3 on the next run. Versioning on the bucket (step 1) is your undo if
  someone deletes by mistake.
- `mc mirror` is incremental — only new/changed objects are uploaded; nightly
  bandwidth ≈ size of new receipts since yesterday.
- AWS cost: receipts are tiny (a few MB each); a few hundred receipts/year is
  ~pennies/month in storage + GET/PUT requests.
- The CronJob runs at 03:15 by default; CNPG's nightly base backup runs at
  03:30 (`postgres.backup.schedule`) — staggered to spread I/O.
