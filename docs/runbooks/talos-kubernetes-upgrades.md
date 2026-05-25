# Runbook — Talos & Kubernetes upgrades

Current: **Talos v1.13.2**, **Kubernetes v1.36.0** (both latest as of 2026-05; this
runbook is for future releases). Nodes: control-plane `192.168.216.201-203`
(`talos-cp-01..03`), workers `192.168.216.211-213` (`talos-wk-01..03`). Run from
`mgmt-jump`. Version lives in the **installer image**, not the machine config — upgrades
do **not** go through `scripts/talos-gen.sh`.

> ⚠ **CRITICAL — worker extensions.** Workers run Image Factory **system extensions**
> (`iscsi-tools`, `util-linux-tools`) that Longhorn needs. Their upgrade installer image
> MUST use the matching **schematic** — the vanilla installer silently drops the
> extensions and breaks Longhorn (volumes fail to attach). Control-plane nodes have no
> extensions and use the vanilla installer.

## 0. Pre-flight (do every time)
- **Compatibility:** upgrade **one minor at a time** (patch versions can be skipped, minors
  cannot). Confirm the target Talos release supports the target Kubernetes minor (Talos
  release notes / compatibility matrix).
- **Health + backups:**
  ```bash
  talosctl health --wait-timeout 5m      # etcd healthy, all nodes ready
  kubectl get nodes                      # all Ready
  ```
  Take fresh backups first (see `disaster-recovery.md`): run the etcd-snapshot CronJob and a
  Velero backup, confirm both succeed. OS upgrades are A/B with auto-rollback, but take the
  etcd snapshot anyway — etcd changes are one-way.

## 1. Talos OS upgrade — rolling, ONE node at a time
Schematic source: `talos/schematic.yaml`; ID `613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245`
(deterministic from the file — recompute/verify with
`curl -X POST --data-binary @talos/schematic.yaml https://factory.talos.dev/schematics`).

```bash
T=v1.14.0     # <-- target Talos version (example; one minor up)
SCHEMATIC=613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245

# Control-plane (vanilla installer, no extensions) — one at a time, wait for health between:
for ip in 201 202 203; do
  talosctl -e 192.168.216.$ip -n 192.168.216.$ip upgrade --image ghcr.io/siderolabs/installer:$T
  talosctl health --wait-timeout 10m
done

# Workers (SCHEMATIC installer — keeps iscsi-tools) — one at a time:
for ip in 211 212 213; do
  talosctl -e 192.168.216.$ip -n 192.168.216.$ip upgrade --image factory.talos.dev/installer/$SCHEMATIC:$T
  kubectl wait --for=condition=Ready node/talos-wk-0${ip#21} --timeout=10m
done
```
Each node reboots into the new image; Talos auto-reverts (A/B) if it fails to boot. Talos
coordinates etcd on control-plane nodes and preserves the data partition across the upgrade.
After workers: `talosctl -n 192.168.216.211 get extensions` — confirm iscsi-tools is still there.

## 2. Kubernetes upgrade — orchestrated, single command
Talos upgrades apiserver / controller-manager / scheduler / kubelet across all nodes, in order.

```bash
talosctl -e 192.168.216.201 -n 192.168.216.201 upgrade-k8s --to 1.37.0   # one minor up
kubectl get nodes        # VERSION column reflects the new k8s on each node
```
Then align local tools: install matching `kubectl` (and `talosctl` to the cluster's Talos version).

## 3. Verify
```bash
talosctl health --wait-timeout 5m
kubectl get nodes -o wide                  # all Ready, new VERSION
kubectl get pods -A | grep -vE 'Running|Completed'   # nothing stuck
```
Spot-check: a Longhorn volume mounts (proves worker extensions intact) and an app loads over ingress.

## Rollback
- **Talos OS:** a failed boot auto-reverts to the previous A/B image. To undo a *successful*
  upgrade, `talosctl upgrade` back to the prior version's image.
- **Kubernetes:** `talosctl upgrade-k8s --to <previous-minor>` (within Talos's supported
  range), or restore the etcd snapshot (`disaster-recovery.md`, Scenario C).

## Gotchas
- Workers ⇒ **schematic** installer image, never the vanilla one.
- `talosctl upgrade` / `upgrade-k8s` need explicit `-e`/`-n`.
- One minor per step — don't jump minor versions.
- Don't run config regen (`talos-gen.sh`) for a version bump; it's unrelated to the installer image.
