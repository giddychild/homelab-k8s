# Runbook — Apply / verify kube-apiserver audit logging

Enables an explicit, version-controlled API-server audit policy on the control
plane. Policy source: [`talos/patches/controlplane.yaml`](../../talos/patches/controlplane.yaml),
wired into [`scripts/talos-gen.sh`](../../scripts/talos-gen.sh) as a
`--config-patch-control-plane`.

**Run from `mgmt-jump`** (holds `talosctl` + `talosconfig`). Apply **one control-plane
node at a time** and wait for its API server to return healthy before the next, so
etcd quorum and API availability are never lost.

## 1. Regenerate the machine configs

```bash
cd ~/homelab-k8s
git pull
bash scripts/talos-gen.sh          # rebuilds talos/controlplane.yaml with the audit policy
# Sanity-check the policy made it in:
grep -A2 'auditPolicy' talos/controlplane.yaml
```

> **Two gotchas (learned applying this):** `apply-config` needs an explicit
> endpoint `-e <ip>` (read commands auto-resolve it; config-push does not). And
> the live audit log is **`/var/log/audit/kube/kube-apiserver.log`** — the
> `*-<timestamp>.log` siblings are rotated archives.

## 2. Validate before applying (no changes made)

```bash
talosctl -e 192.168.216.201 -n 192.168.216.201 apply-config \
  -f talos/controlplane.yaml \
  --config-patch @talos/patches/nodes/talos-cp-01.yaml \
  --dry-run
```
`--dry-run` prints the diff and validates without touching the node. Expect the
diff to show **only** the new `auditPolicy` rules inserted ahead of the existing
catch-all `- level: Metadata` — no PKI/cert changes.

## 3. Apply, one node at a time

```bash
apply_cp () {                      # $1 = 01 | 02 | 03
  ip=192.168.216.2$1
  echo "=== applying to $ip ==="
  talosctl -e $ip -n $ip apply-config -f talos/controlplane.yaml \
    --config-patch @talos/patches/nodes/talos-cp-$1.yaml --mode=auto
  sleep 10
  until talosctl -e $ip -n $ip get staticpodstatus 2>/dev/null | grep apiserver | grep -q True; do
    echo "  waiting for $ip apiserver..."; sleep 4; done
  echo "  $ip apiserver Ready"
}
apply_cp 01; apply_cp 02; apply_cp 03
kubectl get nodes        # may briefly refuse on the VIP as the last apiserver cycles — retry
```
Audit-policy changes restart the kube-apiserver static pod (**no node reboot**);
`--mode=auto` applies without rebooting. The VIP keeps the other two apiservers
serving while each restarts.

## 4. Verify it's working

```bash
LOG=/var/log/audit/kube/kube-apiserver.log
PROBE=audit-probe-$RANDOM
kubectl create clusterrole $PROBE --verb=get --resource=pods   # RBAC write -> RequestResponse
kubectl -n kube-system get secret >/dev/null                   # secret read -> Metadata, no value
sleep 2

echo "--- RBAC event level (expect RequestResponse) ---"
for ip in 201 202 203; do
  talosctl -e 192.168.216.$ip -n 192.168.216.$ip read $LOG 2>/dev/null \
    | grep "$PROBE" | grep -o '"level":"[^"]*"' | sort -u | sed "s/^/cp-$ip /"
done

echo "--- secret event level (expect Metadata) ---"
for ip in 201 202 203; do
  talosctl -e 192.168.216.$ip -n 192.168.216.$ip read $LOG 2>/dev/null \
    | grep '"objectRef":{"resource":"secrets"' | tail -1 | grep -o '"level":"[^"]*"' | sed "s/^/cp-$ip /"
done

echo "--- secret events leaking a VALUE (responseObject) — MUST be 0 ---"
for ip in 201 202 203; do
  talosctl -e 192.168.216.$ip -n 192.168.216.$ip read $LOG 2>/dev/null \
    | grep '"resource":"secrets"'
done | grep -c responseObject

kubectl delete clusterrole $PROBE
```

Pass criteria: RBAC event logged at `RequestResponse`, secret access at
`Metadata`, and the leak count a genuine `0` (the Metadata check above proves
secret events exist, so `0` means values are absent — not that nothing was read).

## Rollback

```bash
cd ~/homelab-k8s
git revert <commit>      # or remove the --config-patch-control-plane line + delete the patch
bash scripts/talos-gen.sh
# re-apply per node as in step 3 (reverts to Talos's default audit behaviour)
```

## Notes / future

- Logs are per-node files today. To make them queryable in Grafana, ship them to
  Loki — the cleanest path is sending apiserver audit to stdout
  (`cluster.apiServer.extraArgs: { audit-log-path: "-" }`) so Promtail scrapes the
  static-pod logs. **Verify on one node first** — this overrides a Talos-managed
  flag and changes on-disk rotation behaviour.
- Talos also manages `--audit-log-maxage/maxbackup/maxsize`; override via
  `extraArgs` only if the defaults prove insufficient.
