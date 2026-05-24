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

## Phase 2 — VMware Foundation  🟡 IN PROGRESS  (2026-05-24)

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
- [ ] **Step 5 — Toolchain:** run `scripts/bootstrap-mgmt.sh` on mgmt-jump → installs kubectl/helm/talosctl/terraform/ansible + base utils.

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
- [ ] Narrow Orbi DHCP `.2–.254` → `.100–.200` (do before cluster provisioning).
- [x] Reserved `192.168.216.30` for `mgmt-jump` in Orbi (MAC `00:0c:29:7b:49:ed`).
- [ ] (Optional, future) Consider an SSD for etcd; managed-switch enables a future pfSense/OPNsense VLAN router.
- [ ] (Security, Phase 9) Replace plaintext PAT storage with SSH keys / short-lived creds.
```
