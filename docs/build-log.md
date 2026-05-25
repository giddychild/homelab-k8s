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
- [x] **Step 2 — app-of-apps live** ✅: bootstrapped once with `kubectl apply -f gitops/bootstrap/root-app.yaml`. `root` + `hello` Applications `Synced/Healthy`; `hello` deployed by ArgoCD (HTTP 200, 2 pods). **Auto-sync demonstrated**: a Git commit scaling `hello` 2→3 replicas reconciles to the cluster with zero `kubectl` (auto-sync + selfHeal + prune enabled).
- [ ] **Step 3 — Migrate/define more apps** as ArgoCD Applications under `gitops/apps/` (done incrementally per phase).

**Phase 6 (GitOps) functional** ✅ — cluster is self-managing from the repo.

---

## Phase 7 — Observability  🟡 IN PROGRESS  (2026-05-25)

Deployed via GitOps — ArgoCD `Application`s committed under `gitops/apps/`.

### Steps
- [x] **Step 1 — kube-prometheus-stack deployed** ✅ (chart `85.3.3`) via ArgoCD (Synced/Healthy).
  All monitoring pods Running (node-exporter on all 6 nodes); PVCs Bound on Longhorn
  (Prometheus 20Gi, Grafana 5Gi, Alertmanager 2Gi). Grafana at `grafana.192.168.216.230.nip.io`
  + CA TLS. `ServerSideApply=true` handled the large operator CRDs. App: `gitops/apps/kube-prometheus-stack.yaml`.
  Login: creds come from a hand-created secret `grafana-admin` (`grafana.admin.existingSecret`) — chart's random-per-sync password caused login failures, so we pinned it via an out-of-band secret + `grafana cli admin reset-admin-password`. (Password kept OUT of the public repo.)
- [x] **Step 2 — Loki + Promtail** ✅: SingleBinary Loki (chart `7.0.0`, filesystem on Longhorn 10Gi, 7-day retention) + Promtail DaemonSet (chart `6.17.1`, all nodes) → ns `monitoring`. Logs flowing — verified in Grafana **Explore** (`{namespace="argocd"}` ~5.65K lines). Loki auto-wired as a Grafana datasource via sidecar ConfigMap. Multi-source Apps `gitops/apps/{loki,promtail}.yaml`.
- [x] **Step 3 — Dashboards & alerts** (inline): kube-prometheus-stack ships dozens of Grafana dashboards + default `PrometheusRule` alert rules + Alertmanager (all running). Alertmanager **notification routing** (email/Slack/Discord) deferred until a channel is chosen — candidate: route alerts through n8n in Phase 8.

**PHASE 7 COMPLETE** ✅ — metrics (Prometheus/Grafana), logs (Loki/Promtail), dashboards & alerting, all GitOps-managed.
- [ ] **Step 5 — Namespaces, RBAC, Pod Security Standards.**

---

## Phase 8 — AI Ops  🟡 IN PROGRESS  (2026-05-25)

Local AI platform, deployed via GitOps into namespace `ai-ops` (PSS `baseline`).
Proceeding on 100 Mbps — deploy the stack now, pull only small models until gigabit.

### Steps
- [x] **Step 1 — Ollama deployed** (chart `1.57.0`, app `0.24.0`): pod Running, CPU inference, models on Longhorn (30Gi). Validate: `kubectl -n ai-ops exec deploy/ollama -- ollama pull llama3.2:1b`. `gitops/apps/ollama.yaml`.
- [x] **Step 2 — Open WebUI deployed** (chart `14.6.0`): pods Running (+ pipelines, redis). Chat at `chat.192.168.216.230.nip.io` + CA TLS, pointed at Ollama. `gitops/apps/open-webui.yaml`.
- [~] **Step 3 — n8n** via manifests (`gitops/workloads/n8n/`, App `gitops/apps/n8n.yaml`): SQLite on Longhorn 5Gi, ingress `n8n.192.168.216.230.nip.io` + CA TLS, `N8N_SECURE_COOKIE=false`. Image `:latest` (pin after first deploy).

  **Resolved:** after the Longhorn fix below, the n8n volume came up healthy and the pod is **Running** at `n8n.192.168.216.230.nip.io`.

  **⚠️ Longhorn capacity gotcha (runbook-worthy):** n8n's volume went `faulted` (0 replicas scheduled) and open-webui's went `degraded`. Root cause was NOT disk-full — workers had ~94 Gi free — but Longhorn reserves ~30% per disk, so the *schedulable* ceiling was ~69 Gi and we'd hit it (8 vols × 3 replicas). Fixes: (1) Ollama models → **1 replica** (re-downloadable) via `kubectl -n longhorn-system patch volume <id> -p '{"spec":{"numberOfReplicas":1}}'`; (2) raised `storageOverProvisioningPercentage` 100→**200** (worker disks are thin VMDKs on the 1.1 TB datastore). Then recreated the faulted PVC (scale deploy to 0 first — a pod reference keeps a `Terminating` PVC alive under GitOps).
- [~] **Step 4 — AI ops agents**:
  - [x] **Incident summarizer** built in n8n & **verified**: Webhook (`POST /webhook/alertmanager`, respond immediately) → HTTP Request `POST http://ollama.ai-ops.svc.cluster.local:11434/api/generate`. Body via **"Using Fields Below"** (`model`, `stream`={{false}}, `prompt`=text+`{{ JSON.stringify($json.body.alerts) }}`) — the JS-object expression form failed with "missing request body"; field-based (or `JSON.stringify(...)`) works. A sample alert returns a plain-English SRE summary from `llama3.2:1b`. Published/active.
  - [x] **Alertmanager → n8n wired & verified**: a synthetic alert auto-triggered n8n executions (LLM summaries) with zero manual input — the full Prometheus→Alertmanager→n8n→Ollama pipeline works. Refined to route **only `severity: critical`** to the summarizer (CPU inference is slow; warnings/info stay visible in Alertmanager/Grafana but don't hammer Ollama).
  - [ ] Further agents (optional): troubleshooting (Loki query → LLM), remediation workflows.

**Phase 8 core complete** ✅ — self-hosted AI ops: Ollama + Open WebUI + n8n, with a live AI incident-summarizer pipeline.

---

## Phase 9 — Security  🟡 IN PROGRESS  (2026-05-25)

Production-grade, job-market-relevant tooling (user's explicit goal).

### Steps
- [x] **Step 1 — Secrets: Vault + ESO** ✅ **verified**.
  - Vault chart `0.32.0` (app `1.21.2`), standalone + file storage on Longhorn (2Gi),
    UI at `vault.192.168.216.230.nip.io`, injector off, ns `vault` (PSS `privileged` for mlock).
    `gitops/apps/vault.yaml`. Init'd (1 share / 1 threshold) + unsealed; **unseal needed after restarts** (keys saved out-of-band).
  - Vault config: KV v2 at `secret`, Kubernetes auth method, `eso` policy (read `secret/data/*`) + role bound to SA `external-secrets/external-secrets`.
  - ESO chart `2.5.0` (API `external-secrets.io/v1`). `ClusterSecretStore vault-backend` → **Valid**; `ExternalSecret grafana-admin` (`gitops/workloads/eso-config/`) → **SecretSynced**.
  - **Result:** `grafana-admin` Secret now sourced from Vault (`secret/grafana`), referenced not stored in Git. The production secrets pattern is live.
- [ ] **Step 2 — Tailscale** secure remote access.
- [~] **Step 3 — Network policies** (Cilium-enforced): demonstrate default-deny + explicit allows on the `demo` namespace (DNS egress + ingress from ingress-nginx). Production approach = observe flows via Hubble, then extend per-namespace incrementally. Policies in `gitops/workloads/hello/`.
- [x] **Step 4 — Trivy Operator deployed** ✅ (chart `0.32.1`, app `0.30.1`, ns `trivy-system`). `VulnerabilityReport` + `ConfigAuditReport` populated cluster-wide (CVE counts per image; config audit mostly clean for our workloads, expected highs on privileged infra like Cilium/Longhorn). Metrics → Prometheus. `ignoreUnfixed: true`, `scanJobsConcurrentLimit: 3`. `gitops/apps/trivy-operator.yaml`.
- [ ] **Step 5 — Hardening**: audit logging, RBAC least-privilege, trust `homelab-ca`.

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
