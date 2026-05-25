# Runbook — Disaster recovery

Three independent recovery layers. Pick the one that matches the failure.

| Layer | Covers | Source of truth | Tool |
|---|---|---|---|
| **Config / apps** | All Kubernetes manifests (Deployments, Services, Ingress, CRs…) | this Git repo | ArgoCD (re-sync) |
| **Volume + resource data** | PV contents (Vault, n8n, Grafana, Loki…) + live resources | S3 `…/velero/` | Velero (kopia FSB) |
| **Cluster state** | etcd (the whole API state) | S3 `…/etcd-snapshots/` | Talos `etcd snapshot` |

Bucket: `s3://155125294186-homelab-k8s-backups` (us-east-1). Velero is scoped to the
`velero/` prefix; etcd snapshots live under `etcd-snapshots/`. All commands run from
`mgmt-jump` (or the laptop) with `kubectl`/`talosctl`.

---

## Scenario A — a namespace / app got deleted or corrupted

Restore just that namespace from the latest Velero backup.

```bash
kubectl get backups -n velero                      # find a recent Completed backup
# restore one namespace from it:
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata: { name: restore-$(date +%s), namespace: velero }
spec:
  backupName: <BACKUP_NAME>
  includedNamespaces: [<NAMESPACE>]
EOF
kubectl get restore -n velero -w                   # wait for phase=Completed
```
PV data is rehydrated by the `restore-wait` initContainer (kopia) before app pods start.
**Note:** for GitOps-managed namespaces, ArgoCD will also try to re-create resources from
Git — that's fine for manifests, but only Velero restores *volume data*.

**Verified 2026-05-25:** destroyed a namespace (pod+PVC+volume) and restored it; the
volume's sentinel file returned byte-identical. The restore procedure works.

## Scenario B — full cluster lost, nodes intact (rebuild + restore)

1. Re-provision Talos config if needed (`scripts/talos-gen.sh`) and `talosctl bootstrap`.
2. Bootstrap Cilium + ArgoCD (see Phase 5/6 of the build log), then apply the
   app-of-apps root — ArgoCD reconciles the entire platform from Git.
3. Restore volume data with Velero:
   ```bash
   velero restore create --from-backup <BACKUP_NAME>     # or the Restore CR above with no includedNamespaces
   ```

## Scenario C — etcd corruption / control-plane loss (fast state recovery)

Restore etcd from a snapshot rather than rebuilding from scratch.

```bash
# 1. Pull the desired snapshot from S3 (any S3 client with the velero creds)
aws s3 ls s3://155125294186-homelab-k8s-backups/etcd-snapshots/
aws s3 cp s3://155125294186-homelab-k8s-backups/etcd-snapshots/etcd-<TS>.snapshot ./etcd.snapshot

# 2. Recover etcd on a control-plane node from the snapshot
#    (Talos rebuilds the single-member etcd from the snapshot, then re-scales)
talosctl -n 192.168.216.201 bootstrap --recover-from=./etcd.snapshot
```
See the Talos "Disaster Recovery" guide for the exact reset/recover sequence for your
version before running this in anger — it wipes and rebuilds etcd from the snapshot.

---

## Backup schedules (what runs automatically)

- **Velero** — `velero-daily` Schedule, 03:00, all namespaces, FS backup, **ttl 72h** (3-day retention; Velero also runs kopia maintenance to reclaim blobs).
- **etcd** — `talos-etcd-snapshot` CronJob, 02:00 → `etcd-snapshots/`.

## Operational notes / gotchas

- **Do not** put an S3 object-expiration lifecycle rule on the `velero/` prefix — it
  shares a deduplicated kopia repo and expiring blobs corrupts it. Retention = Velero `ttl`.
  A prefix-scoped expiration on `etcd-snapshots/` (standalone files) IS safe.
- `talosctl etcd snapshot` / `config new` / `apply-config` need explicit `-e`/`-n` endpoints.
- BSL `Unavailable: invalid top-level directories` → another tool wrote to Velero's
  bucket root; Velero must use a `prefix`.
