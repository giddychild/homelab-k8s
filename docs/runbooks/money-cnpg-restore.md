# money — Restore the Postgres cluster from S3 (CNPG `bootstrap.recovery`)

If the `money-pg` Cluster, its PVCs, or the entire `money` namespace are lost
(accidental delete, node-pool wipe, etc.), the database can be rebuilt from
the S3 archive that [money-db-backups.md](money-db-backups.md) produces. The
chart already has `bootstrap.recovery` wired behind `postgres.recover.enabled`
— this runbook is the procedure for *using* it end-to-end, including the
gotchas that aren't obvious from the Helm values alone.

Read this whole page before starting. Recovery has five ordering hazards that
each look like a bug the first time you hit them.

## Prerequisites

- A base backup exists under `s3://giddyland-money-pg-backups/money-pg/base/<ts>/`
  and recent WALs under `…/money-pg/wals/`. Verify before starting:

  ```bash
  aws s3 ls s3://giddyland-money-pg-backups/money-pg/base/ | tail -5
  aws s3 ls s3://giddyland-money-pg-backups/money-pg/wals/ | tail -5
  ```

  No base backup → recovery is impossible; restore from a different source.
- The Vault entries `secret/money/backup-s3` (S3 IAM creds) and `secret/money/app`
  (database_url, redis_url, jwt keys) still exist. Vault wasn't part of the
  cascade-delete, so these survive normal incidents.
- `kubectl config use-context admin@apps-prod` (recovery happens on the apps cluster).

## Step 1 — Choose a new `backup.serverName`

Critical, and the easiest to miss. CNPG runs a `barman-cloud-check-wal-archive`
sanity check at cluster start that **refuses to boot if the destination prefix
is non-empty**, to prevent two clusters silently corrupting each other's WALs.

If the new cluster writes WALs to the same prefix it just restored *from*
(both default to `metadata.name = money-pg`), it crash-loops with:

```
ERROR: WAL archive check failed for server money-pg: Expected empty archive
```

So:

- `postgres.recover.serverName` = the OLD cluster's prefix (where the backup
  to restore from lives — usually `money-pg`).
- `postgres.backup.serverName` = a NEW prefix the new cluster will write its
  WALs/backups to going forward (e.g. `money-pg-v2`, `money-pg-v3`).

The old prefix becomes historical (read-only) after restore.

## Step 2 — Edit `values-homelab.yaml`

```yaml
postgres:
  backup:
    enabled: true
    destinationPath: "s3://giddyland-money-pg-backups/"
    endpointURL: "https://s3.us-east-1.amazonaws.com"
    s3CredentialsVaultPath: "money/backup-s3"
    serverName: "money-pg-v2"    # NEW prefix — must differ from recover.serverName

  recover:
    enabled: true
    serverName: "money-pg"        # source prefix in S3
    # targetTime: ""              # optional PITR target; empty = replay every WAL
```

Open a PR, merge to main. ArgoCD auto-syncs the chart but **won't** create
the Cluster until the namespace is intact (see step 3).

## Step 3 — Make sure the namespace and sync-wave -5 resources can come up cleanly

If the namespace was cascade-deleted, ArgoCD recreates it on next sync. Three
chart resources at sync-wave **-5** must all reach Healthy before the wave-5
migrate Job will fire:

| Resource | Wave | Why |
|---|---|---|
| `ExternalSecret/money-secrets` | -5 | app DATABASE_URL, JWT keys, etc. |
| `ExternalSecret/money-pg-backup-s3` | -5 | S3 creds CNPG uses to read the source archive — **without this the recovery pod crash-loops with `secrets "money-pg-backup-s3" not found`** |
| `Cluster/money-pg` | -5 | the CNPG cluster CR that triggers restore |

These already carry the right annotations in the chart; you don't have to
change anything. But if a previous botched sync left stale leftovers, clean
them out so CNPG starts fresh:

```bash
kubectl -n money delete cluster money-pg --wait=false
kubectl -n money delete pvc -l cnpg.io/cluster=money-pg --ignore-not-found
kubectl -n money delete job -l cnpg.io/cluster=money-pg --ignore-not-found
kubectl -n money delete pods -l job-name=money-pg-1-full-recovery --force --grace-period=0 --ignore-not-found
kubectl -n money delete secret money-pg-app money-pg-ca money-pg-replication money-pg-server --ignore-not-found
# Don't delete money-pg-backup-s3 or money-secrets — ESO will refresh them on next sync.
```

## Step 4 — Trigger ArgoCD to apply the recovery

From the homelab-prod ArgoCD context:

```bash
kubectl config use-context admin@homelab-prod
kubectl -n argocd patch application money --type merge -p '{"operation":null}'
kubectl -n argocd annotate application money --overwrite argocd.argoproj.io/refresh=hard
sleep 8
kubectl -n argocd patch application money --type merge -p \
  '{"operation":{"sync":{"revision":"HEAD","syncOptions":["ServerSideApply=true","Replace=true"]}}}'
```

## Step 5 — Watch the recovery

Back on apps-prod:

```bash
kubectl config use-context admin@apps-prod
kubectl -n money get cluster money-pg -w
```

Expected progression (5–10 min for a small DB; longer for many WALs):

1. `Setting up primary` — `barman-cloud-restore` downloading the base backup
2. `Waiting for the instances to become active` — postgres replaying WALs
3. `Creating a new replica` — money-pg-2 streaming from the new primary
4. `Cluster in healthy state` — done

If the recovery pod errors early, get its logs:

```bash
POD=$(kubectl -n money get pods -l job-name=money-pg-1-full-recovery -o name | head -1)
kubectl -n money logs "$POD" -c full-recovery
```

## Step 6 — Apply the post-recovery permission fix (REQUIRED)

CNPG's `bootstrap.recovery` skips initdb, and as a side effect **ignores
`bootstrap.initdb.owner`**. It always creates the app user with its canonical
default name `app` (not `money`), stored in `money-pg-app`. But the restored
data still has all its tables owned by `money` (from the original cluster) —
so the live connection lands as `app` with **no grants**, and every query
fails with `permission denied for table …`.

Fix with one set of GRANTs, run as the `postgres` superuser on the primary:

```bash
kubectl -n money exec money-pg-1 -- psql -U postgres -d money -c "
GRANT CONNECT ON DATABASE money TO app;
GRANT USAGE, CREATE ON SCHEMA public TO app;
GRANT ALL ON ALL TABLES IN SCHEMA public TO app;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO app;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO app;
"
```

Then bounce the failed migrate Job + app pods so they reconnect:

```bash
kubectl -n money delete job money-migrate --ignore-not-found
kubectl -n money rollout restart deploy/money-api deploy/money-worker
```

Sanity check — `SET ROLE app` should now succeed:

```bash
kubectl -n money exec money-pg-1 -- psql -U postgres -d money -c \
  "SET ROLE app; SELECT version_num FROM alembic_version; RESET ROLE;"
```

Expected: one row with the current Alembic revision.

## Step 7 — Flip `recover.enabled` back to false

Once the cluster is Healthy with restored data and the app is logged in:

```yaml
postgres:
  recover:
    enabled: false
    serverName: ""
```

CNPG only honors `bootstrap` on initial cluster creation, so leaving
`enabled: true` is harmless, but flipping it back keeps intent clear and
prevents accidental re-bootstrap if someone deletes the Cluster CR later.

`backup.serverName` stays on the **new** prefix (`money-pg-v2`) permanently
— that's where ongoing backups now land. Don't reset it to empty.

## Step 8 — Clean up the historical S3 prefix (after ≥2 weeks)

The old `s3://giddyland-money-pg-backups/money-pg/` tree is your rollback
parachute. Keep it untouched until you're confident the new cluster is
healthy and you have at least one fresh base backup under `money-pg-v2/`.

After that:

```bash
aws s3 rm --recursive s3://giddyland-money-pg-backups/money-pg/
```

## Why this is multi-step (vs. "just set recover.enabled=true and sync")

Five gotchas, each invisible from the values alone, each fixed by a specific
step above. They surfaced in production during the 2026-05-30 incident and
are now baked into the chart + this runbook:

1. **PreSync hook deadlock** — old behavior: `migrate-job` had `argocd.argoproj.io/hook: PreSync`, which runs *before* the Sync phase that creates `money-secrets`. On a fresh-namespace sync the migrate pod hit `CreateContainerConfigError` and Job backoff doesn't retry kubelet errors → deadlock. **Fix already in chart**: migrate runs at sync-wave 5, ExternalSecrets + Cluster at wave -5.

2. **Backup-S3 ExternalSecret at wrong wave** — recovery needs `money-pg-backup-s3` to authenticate against S3 *before* it can start downloading. The secret's ExternalSecret must be at wave -5 too (it is, in `postgres-backup.yaml`).

3. **Same `serverName` for source and destination** — the WAL archive check refuses to start. Use a different `backup.serverName` (step 1).

4. **Recovery skips initdb → app user permissions missing** — step 6's GRANTs.

5. **Vault DATABASE_URL drifts after recovery** — the URL in Vault uses `user=money,password=<old>`. The new live cluster's working credentials are in CNPG's auto-managed `money-pg-app` (user=`app`, fresh password). The chart's `appEnv` helper sources from `money-pg-app` directly, so apps work — but Vault's URL is now stale and should be updated or removed. Lower priority than steps 1–7.
