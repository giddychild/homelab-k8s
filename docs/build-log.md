# Build Log — homelab-k8s

A chronological journal of **everything done** to build this platform: decisions,
confirmations, commands run, validations, and gotchas. Organized by phase.

> Reference docs (the "what it is" — architecture, IP plan, naming, ADRs) live
> elsewhere in `docs/`. This file is the "what we did, in order" (the story).
> Updated at every step.

**Environment:** Dell R730XD · dual Xeon E5-2698 v4 (40c/80t) · 512 GB RAM ·
VMware ESXi 7.0 U3 (vSphere **Enterprise Plus**, perpetual) · ESXi host `192.168.216.216`.

---

## Phase 0 — Discovery & Validation  ✅  (2026-05-23 → 24)

Goal: understand the real environment before building anything.

### ESXi findings
| Area | Finding |
|---|---|
| License | **vSphere 7 Enterprise Plus**, never expires, full vSphere API → Terraform can provision VMs (no licensing blocker) |
| Compute | dual E5-2698 v4 (40c/80t), 512 GB RAM — ample headroom |
| Storage | **single `datastore1`**: 2.6 TB VMFS6 on **PERC H730 Mini**, all **HDD (Non-SSD)**, ~1.1 TB free |
| Existing load | **17 VMs already on the host** (~1.5 TB provisioned) incl. an existing k8s set + gitlab — **do not disturb** |
| NICs | 4× Intel 1GbE (`igbn`) on `vSwitch0`; only `vmnic0` up |
| Network | flat, untagged (VLAN 0); ESXi mgmt `vmk0 = 192.168.216.216` |

### Network bottleneck investigation
- **Symptom:** `vmnic0` negotiated at **100 Mbps** (not gigabit).
- **Root cause:** server cabled through a **Netgear ProSafe FS105 (10/100 switch)** before reaching the Orbi mesh. The FS105 caps all traffic at 100 Mbps; cabling/cards are fine.
- **Key insight:** all cluster VMs share one ESXi host, so east-west traffic (etcd, Longhorn, pod-to-pod) stays in the in-RAM vSwitch and is **not** limited by the physical link. The link only throttles egress (image pulls, remote access).
- **Decision:** replace FS105 with an **8-port web-managed gigabit switch** → see `decisions/0001-use-managed-gigabit-switch.md`. Proceeding on 100 Mbps in the meantime.

---

## Phase 1 — Infrastructure Planning  ✅  (2026-05-24)

### Designed
- **Topology:** 3 control-plane + 3 workers + 1 `mgmt-jump`, all VMs on the one host. HA via etcd quorum of 3 + Talos VIP for the API. Right-sized to fit ~1.1 TB free (thin-provisioned).
- **Architecture & rationale:** `docs/architecture.md`
- **IP plan:** `docs/ip-plan.md` — confirmed gateway `192.168.216.1` (Orbi RBR850), mask /24, **current DHCP `.2–.254` must be narrowed to `.100–.200`** before cluster provisioning.
- **Naming conventions:** `docs/naming-conventions.md`
- **Internal networks:** Pod CIDR `10.244.0.0/16`, Service CIDR `10.96.0.0/12`.

### Git repository created & pushed
- Scaffolded the repo tree + docs locally at `C:\Users\admin\homelab-k8s`.
- Initialized git, added `.gitattributes` (force LF for Linux tooling), committed, pushed.
- **Git host decision:** GitHub **public** repo (chosen over self-hosted GitLab for DR-safety + portfolio value; self-hosting via the existing GitLab remains an option later).
- **Repo:** https://github.com/giddychild/homelab-k8s
- **Auth:** classic PAT (`repo` scope, 90-day expiry) via `credential.helper=store`. *Security note: stored plaintext in `~/.git-credentials` — acceptable for homelab; revisit in Phase 9.*

### Scheduled reminder
- Created a one-time remote reminder (fires **2026-05-25 15:08 America/Chicago**) to install the gigabit switch and confirm `vmnic0 = 1000 Mbps`. Routine `trig_01C3HKkWBUBe5zj1WM2YdtaJ`.

---

## Phase 2 — VMware Foundation  ✅ COMPLETE  (2026-05-24)

Building `mgmt-jump` — the single intentionally-manual VM that will host the
toolchain (talosctl/kubectl/helm/terraform/ansible). All later VMs are automated
via Terraform from this host. **Decision:** proceed on the 100 Mbps link for now.

- **Spec:** Ubuntu Server 24.04 LTS · 2 vCPU · 4 GB RAM · 40 GB thin disk · `VM Network` (VMXNET3).
- **Networking plan:** DHCP + an Orbi **address reservation** pinning it to `192.168.216.30` (avoids changing the DHCP pool yet).

### Steps
- [x] **Step 1 — ISO uploaded:** `[datastore1] ISOs/linux/ubuntu/ubuntu-24.04.4-live-server-amd64.iso` (3.17 GB).
- [x] **Step 2 — VM created:** `mgmt-jump` created with the spec above; powered on to the Ubuntu installer.
- [x] **Step 3 — Ubuntu installed:** hostname `mgmt-jump`, user `seyi`, OpenSSH server enabled. NIC `ens160` (VMXNET3), MAC `00:0c:29:7b:49:ed`, DHCP IP `192.168.216.112` (to be reserved as `.30`).
- [x] **Step 4 — Network + access:** reserved `.30` in Orbi (MAC `00:0c:29:7b:49:ed`); SSH from Windows works (`ssh seyi@192.168.216.30`).
- [x] **Step 5 — Toolchain installed** via `scripts/bootstrap-mgmt.sh`: kubectl `v1.36.1`, talosctl `v1.13.2`, helm `v3.21.0`, terraform `v1.15.4`, ansible `core 2.16.3`.

---

## Phase 3 — Automation Foundation (Terraform)  ✅ COMPLETE  (2026-05-24)

Goal: provision cluster VMs as code via the Terraform **vSphere provider** (unlocked
by the Enterprise Plus license). We connect **directly to the standalone ESXi host**
(no vCenter), so the implicit datacenter is `ha-datacenter`.

Layout: `terraform/environments/prod/` is the root config; a reusable
`terraform/modules/talos-vm/` will define a single VM (added next).

> 🔒 Fixed a `.gitignore` bug first: inline comments had broken the `*.tfvars`
> rule, so credential files were not actually being ignored. Rewritten with
> comments on their own lines; `terraform.tfvars` is now properly excluded.

### Steps
- [x] **Step 1 — Connectivity validation:** `terraform init/plan` confirmed auth to ESXi and resolved `ha-datacenter` / `datastore1` / `VM Network` (+ the host). 0 resources. (First plan failed on the placeholder password — expected; fixed by editing `terraform.tfvars`.)
- [x] **Step 2 — `talos-vm` module:** written at `terraform/modules/talos-vm/` — pvscsi + vmxnet3, optional Longhorn data disk, ISO boot, `wait_for_guest_*_timeout = 0` (Talos has no guest agent). Root reads the ESXi host (`id=ha-host`; display name is null on standalone ESXi — cosmetic).
- [x] **Step 3 — Nodes created:** `terraform apply` → `6 added, 0 changed, 0 destroyed`. All 6 VMs (3 cp 4vCPU/16GB/60GB + 3 wk 8vCPU/48GB/60GB+100GB Longhorn) powered on and booting the Talos ISO into maintenance mode. VM IDs in `terraform output` / state.

---

## Phase 4 — Talos Kubernetes Deployment  ✅ COMPLETE  (2026-05-24)

Proceeding on the 100 Mbps link (image pulls just slower). Control-plane **VIP
`192.168.216.200`**; static IPs cp `.201–.203`, wk `.211–.213`. CNI disabled (Cilium
comes in Phase 5) and kube-proxy disabled (Cilium replaces it with eBPF).

### Steps
- [x] **Step 1 — Capped Orbi DHCP at `.199`** so the `.200+` static block is free.
- [~] **Step 2 — Configs:** secret-free patches committed to `talos/patches/` —
  `all.yaml` (install disk `/dev/sda`, CNI none, proxy off, pod/service CIDRs, DNS) and
  `nodes/talos-*.yaml` (static IP + hostname; control planes also carry VIP `.200`).
  Generate with `talosctl gen secrets` + `talosctl gen config homelab-prod https://192.168.216.200:6443`
  → `controlplane.yaml`/`worker.yaml`/`talosconfig`/`secrets.yaml` (all **gitignored** — secrets).
- [ ] **Step 3 — Collect each node's maintenance-mode IP** (ESXi console or Orbi attached devices).
- [ ] **Step 4 — `apply-config`** per node (base config + its per-node patch) → node installs Talos, reboots onto its static IP.
- [x] **Step 5 — Bootstrapped:** set `talosctl` endpoints/node, `talosctl bootstrap` on cp-01 (once). etcd healthy across 3 CPs; VIP `.200` serving the API; `talosctl kubeconfig` fetched. `kubectl get nodes` → all **6 nodes** with correct hostnames, **k8s v1.36.0**, all `NotReady` (no CNI yet — expected). **HA cluster live.**

> **Gotcha (Talos 1.13):** the hostname must be set via a `HostnameConfig` document
> (`apiVersion: v1alpha1`, `kind: HostnameConfig`, `hostname: <name>`), **not** via
> `machine.network.hostname`. Setting both errors with *"static hostname is already set
> in v1alpha1 config"*. Per-node patches updated: IP/VIP in v1alpha1 `interfaces` +
> hostname in a separate `HostnameConfig` doc. Also: regenerate with `--with-secrets`
> (keep cluster identity) and `--force` (overwrite); `--with-examples=false` does NOT
> remove `HostnameConfig` (it's a core doc, not an example).
>
> **Full resolution:** merging a hostname into the base `HostnameConfig` leaves
> `auto: stable` set too → *"'auto' and 'hostname' cannot be set at the same time"*.
> And patches can't strip `auto`: config patches are decoded as typed docs, so the
> strategic-merge directive `$patch: replace` is rejected (*"unknown keys: $patch"*).
> Fix → **`scripts/talos-gen.sh`**: regenerates configs and `sed`-removes the
> `auto: stable` line, so the per-node `HostnameConfig` patch (plain `hostname:`) merges
> cleanly. Regenerate via that script from now on (not raw `talosctl gen config`).
- `talosctl gen config` → patches (VIP, install disk `/dev/sda`, static IPs, allow
  scheduling? no) → `apply-config` to each node's maintenance IP → `talosctl bootstrap`
  (etcd, once) → fetch kubeconfig → validate nodes (they'll be `NotReady` until Cilium).

---

## Phase 5 — Kubernetes Platform Services  🟡 IN PROGRESS  (2026-05-24)

Cluster is up (k8s **v1.36.0**, 6 nodes `NotReady` — no CNI). Bringing it online and
layering on platform services.

### Steps
- [x] **Step 1 — Cilium `v1.19.4` installed** ✅ — Helm into `kube-system` with `kubernetes/bootstrap/cilium/values.yaml`. DaemonSet rolled out 6/6 (cilium + cilium-envoy per node) + operator + Hubble relay/UI. **All 6 nodes `Ready`** — cluster fully functional.
  > Observed: Pod Security Admission is active (Talos default) — a plain `nginx` pod triggers `restricted` *warnings*. Privileged components (e.g. Longhorn) will need their namespace labeled `pod-security.kubernetes.io/enforce: privileged`.
- [~] **Step 2 — Longhorn** replicated storage (workers' `/dev/sdb`):
  - [x] **2a** — `iscsi-tools` v0.2.0 + `util-linux-tools` 2.41.4 added to all 3 workers via Image Factory (`talos/schematic.yaml`, id `613e1592b2da...961245`) + rolling `talosctl upgrade --image factory.talos.dev/installer/<id>:v1.13.2`.
  - [x] **2b** — `/dev/sdb` mounted at `/var/lib/longhorn` (xfs) on all 3 workers via `machine.disks`.
  - [x] **2c** — Longhorn deployed via Helm into `longhorn-system` (PSS `privileged`). All pods Running (manager/CSI/instance-manager on the 3 workers), `longhorn` is the **default StorageClass**, 3 worker storage nodes schedulable. Manifests in `kubernetes/bootstrap/longhorn/`.

  **Step 2 (Longhorn) complete** ✅ — replicated block storage on the workers' dedicated disks.
- [x] **Step 3 — Cilium LB-IPAM + L2** ✅ — Cilium upgraded with `l2announcements.enabled` (+ raised `k8sClientRateLimit`); `CiliumLoadBalancerIPPool homelab-pool` (`.230–.250`, 21 IPs) + `CiliumL2AnnouncementPolicy homelab-l2` (workers). Verified: test `LoadBalancer` Service got `192.168.216.230` and returned `HTTP 200` over the LAN. CRD versions: pool `cilium.io/v2`, policy `cilium.io/v2alpha1`.
- [~] **Step 4 — Ingress (ingress-nginx) + cert-manager**:
  - [x] 4a — `ingress-nginx` installed via Helm (2 replicas), controller Service pinned to `192.168.216.230` (annotation `io.cilium/lb-ipam-ips`). Verified EXTERNAL-IP `.230`, `curl` → `HTTP 404` (healthy default backend). Manifests `kubernetes/bootstrap/ingress-nginx/`.
  - [x] 4b — cert-manager installed (controller/webhook/cainjector Running) + CA chain applied: `selfsigned` & `homelab-ca-issuer` ClusterIssuers `Ready`, root `homelab-ca` cert `Ready` (secret `homelab-ca-key-pair`). ACME DNS-01 deferred to Phase 9.

  **Step 4 complete** ✅ — ingress-nginx on `192.168.216.230` + internal CA for automatic TLS.

- [x] **Step 5 — Governance** (handled inline): Pod Security applied per namespace (`privileged` for longhorn-system/ingress-nginx, `restricted` for demo); namespaces created per-need; RBAC stays at secure k8s defaults and will be extended declaratively via GitOps.

### Capstone validation ✅
- [x] Demo app (`kubernetes/examples/hello-ingress-tls.yaml`): PSS-`restricted` nginx (unprivileged image) → Service → Ingress with TLS auto-issued by `homelab-ca-issuer`, hostname via `nip.io`. **Verified:** HTTPS page loads, validates against `homelab-ca.crt` (no `-k`), `issuer: CN=homelab-ca`. CNI + ingress + cert-manager + DNS proven end-to-end.

**PHASE 5 COMPLETE** ✅ — full platform services layer up.

---

## Phase 6 — GitOps (ArgoCD)  🟡 IN PROGRESS  (2026-05-25)

ArgoCD watches the repo's `gitops/` tree and reconciles the cluster to match it
(app-of-apps pattern). Bootstrap components (Cilium, Longhorn, ingress, cert-manager)
stay Helm-installed; ArgoCD manages everything layered on top.

### Steps
- [x] **Step 1 — ArgoCD installed** via Helm into `argocd` (7 pods Running), server `insecure` behind ingress at `argocd.192.168.216.230.nip.io` with CA-issued TLS. `/healthz` → HTTP 200. Values: `kubernetes/bootstrap/argocd/values.yaml`. Admin password in secret `argocd-initial-admin-secret`.
- [~] **Step 2 — app-of-apps**: `gitops/bootstrap/root-app.yaml` (root Application watches `gitops/apps/` recursively) → child `gitops/apps/hello.yaml` → deploys `gitops/workloads/hello/` (the demo, now GitOps-managed). Bootstrap once with `kubectl apply -f gitops/bootstrap/root-app.yaml`.
- [ ] **Step 3 — Migrate/define more apps** (monitoring, etc.) as ArgoCD Applications under `gitops/apps/`.
- [ ] **Step 5 — Namespaces, RBAC, Pod Security Standards.**

---

## Appendix A — Commands run (chronological)

```powershell
# Phase 1 — repo init & first commit (Windows, C:\Users\admin\homelab-k8s)
git init -b main
git add -A
git commit -m "chore: scaffold homelab-k8s platform repository" ...

# Line-ending normalization
# (added .gitattributes: * text=auto eol=lf)
git add .gitattributes
git add --renormalize .
git commit -m "chore: normalize line endings to LF via .gitattributes" ...

# GitHub push
git remote add origin https://github.com/giddychild/homelab-k8s.git
git config credential.helper store        # local to repo
git push -u origin main                   # interactive: username giddychild + PAT

# Phase 2 Step 5 — toolchain (on mgmt-jump, user seyi)
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/giddychild/homelab-k8s.git
cd homelab-k8s && ./scripts/bootstrap-mgmt.sh

# Phase 3 Step 1 — Terraform connectivity validation (on mgmt-jump)
cd ~/homelab-k8s/terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars && chmod 600 terraform.tfvars
# (edit terraform.tfvars: set vsphere_password)
terraform init
terraform plan
terraform apply   # typed 'yes' -> 6 Talos VMs created
```

---

## Appendix B — Key facts & endpoints

| Thing | Value |
|---|---|
| ESXi host | `192.168.216.216` |
| Gateway (Orbi RBR850) | `192.168.216.1` |
| Subnet | `192.168.216.0/24` |
| Datastore | `datastore1` (2.6 TB HDD, ~1.1 TB free) |
| Ubuntu ISO | `[datastore1] ISOs/linux/ubuntu/ubuntu-24.04.4-live-server-amd64.iso` |
| Talos ISO | `[datastore1] ISOs/talos/metal-amd64.iso` (Talos v1.13.2, 318 MB) |
| Git repo | https://github.com/giddychild/homelab-k8s |
| `mgmt-jump` IP | `192.168.216.30` (Orbi reservation, MAC `00:0c:29:7b:49:ed`) |
| `mgmt-jump` MAC / NIC / user | `00:0c:29:7b:49:ed` / `ens160` (VMXNET3) / `seyi` |
| Talos API VIP (planned) | `192.168.216.40` |
| Control plane (planned) | `192.168.216.41–43` |
| Workers (planned) | `192.168.216.51–53` |
| LB pool (planned) | `192.168.216.201–220` |

---

## Appendix C — Pending / deferred items

- [ ] Install gigabit switch + confirm `vmnic0 = 1000 Mbps` (reminder set for 2026-05-25).
- [x] Uploaded Talos `metal-amd64.iso` to `[datastore1] ISOs/talos/` (318 MB).
- [ ] Cap Orbi DHCP at `.199` (END `.254 → .199`) so cluster statics `.200+` are free.
- [x] Reserved `192.168.216.30` for `mgmt-jump` in Orbi (MAC `00:0c:29:7b:49:ed`).
- [ ] (Optional, future) Consider an SSD for etcd; managed-switch enables a future pfSense/OPNsense VLAN router.
- [ ] (Security, Phase 9) Replace plaintext PAT storage with SSH keys / short-lived creds.
```
