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

## 2. Validate before applying (no changes made)

```bash
for ip in 201 202 203; do
  echo "== cp-$ip =="
  talosctl -n 192.168.216.$ip apply-config \
    -f talos/controlplane.yaml \
    --config-patch @talos/patches/nodes/talos-cp-${ip#20}.yaml \
    --dry-run
done
```
`--dry-run` prints the diff and validates the config without touching the node.
Expect the diff to show only the new `auditPolicy` (and its `--audit-*` apiserver flags).

## 3. Apply, one node at a time

```bash
apply_cp () {   # $1 = last octet (201/202/203), $2 = node file suffix (01/02/03)
  talosctl -n 192.168.216.$1 apply-config \
    -f talos/controlplane.yaml \
    --config-patch @talos/patches/nodes/talos-cp-$2.yaml \
    --mode=auto
}
apply_cp 201 01
# wait until the API server on this node is back before continuing:
until talosctl -n 192.168.216.201 service kubelet | grep -q 'Running'; do sleep 3; done
kubectl get --raw='/readyz?verbose' >/dev/null && echo "apiserver OK"
apply_cp 202 02
until talosctl -n 192.168.216.202 service kubelet | grep -q 'Running'; do sleep 3; done
apply_cp 203 03
```
Audit-policy changes restart the kube-apiserver static pod (no node reboot);
`--mode=auto` applies without rebooting when possible.

## 4. Verify it's working

```bash
# a) the audit log file exists and is growing on each CP node
talosctl -n 192.168.216.201 ls /var/log/audit/kube/
talosctl -n 192.168.216.201 read /var/log/audit/kube/kube-apiserver-audit.log | tail -3

# b) generate a high-signal RBAC event, then confirm it was captured at RequestResponse
kubectl create clusterrole audit-probe --verb=get --resource=pods --dry-run=server -o yaml >/dev/null
kubectl create clusterrole audit-probe --verb=get --resource=pods
talosctl -n 192.168.216.201 read /var/log/audit/kube/kube-apiserver-audit.log \
  | grep audit-probe | tail -1 | python3 -m json.tool | grep -E '"level"|"verb"|"resource"'
kubectl delete clusterrole audit-probe

# c) CRITICAL — confirm Secret VALUES are NOT logged (must be Metadata, no responseObject)
kubectl -n kube-system get secret >/dev/null
talosctl -n 192.168.216.201 read /var/log/audit/kube/kube-apiserver-audit.log \
  | grep '"resource":"secrets"' | tail -1 | grep -c responseObject   # expect 0
```

`level` should read `RequestResponse` for the RBAC event and `Metadata` for the
Secret access, and step (c) must print `0` — proof secret contents never reach the log.

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
