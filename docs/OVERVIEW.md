# Homelab Kubernetes Platform — Overview

A **production-style, fully GitOps-managed Kubernetes platform** built from scratch on a
single Dell R730XD server — entirely as Infrastructure-as-Code. Every layer, from VM
provisioning to a self-hosted AI operations assistant, is version-controlled in this repo
and continuously reconciled by ArgoCD. Nothing is clicked together by hand and forgotten;
the repo *is* the system.

## Hardware & foundation
- **Server:** Dell R730XD — dual Xeon E5-2698 v4 (40 cores / 80 threads), 512 GB RAM
- **Hypervisor:** VMware ESXi 7.0 U3 (vSphere Enterprise Plus)
- **VMs (7):** 1 management/jump host + a **highly-available Kubernetes cluster** of
  3 control-plane nodes (etcd quorum) and 3 worker nodes

## End-to-end tool stack (and what each does)

| Layer | Tool | What it does |
|---|---|---|
| **Virtualization** | VMware ESXi | Runs all the VMs on the physical server |
| **VM provisioning** | **Terraform** (vSphere provider) | Creates all cluster VMs from code (a reusable module stamps out each node) |
| **Config/automation** | Ansible + a `mgmt-jump` host | A dedicated Linux "command center" VM holding the toolchain (talosctl, kubectl, helm, terraform) |
| **Operating system / K8s** | **Talos Linux** | A minimal, immutable, API-driven OS purpose-built for Kubernetes — no SSH, no shell, fully declarative |
| **Cluster networking** | **Cilium** (eBPF) | The CNI — pod networking, network policy, and a built-in load balancer; *replaces* kube-proxy for speed |
| **Persistent storage** | **Longhorn** | Replicated block storage across the worker nodes for stateful apps |
| **Ingress / TLS** | **ingress-nginx + cert-manager** | HTTP routing into the cluster with automatic TLS certificates (issued by an internal CA) |
| **GitOps engine** | **ArgoCD** | Watches this Git repo and makes the cluster match it; every change is a commit, rollbacks are `git revert` |
| **Metrics** | **Prometheus + Grafana** | Cluster/node/app metrics, dozens of dashboards, and alerting rules |
| **Logs** | **Loki + Promtail** | Centralized log aggregation, queryable alongside metrics in Grafana |
| **Alerting** | **Alertmanager** | Routes firing alerts (to the AI summarizer below) |
| **Local AI runtime** | **Ollama** | Runs open LLMs locally on the server (no cloud) |
| **AI chat UI** | **Open WebUI** | A ChatGPT-style interface wired to the local models |
| **Automation / agents** | **n8n** | Workflow automation — hosts the AI ops agents |
| **Secrets management** | **HashiCorp Vault + External Secrets Operator** | Central, audited secret storage; secrets are *referenced* (not stored) in Git and synced into the cluster |
| **Remote access** *(in progress)* | **Tailscale** | Private, zero-trust access to cluster services from anywhere |

## How it was built (the process)

1. **Planning** — designed the architecture, IP plan, naming conventions, and a Git repo structure; recorded decisions as ADRs.
2. **VMware foundation** — validated the ESXi host, then built the `mgmt-jump` control host and installed the toolchain.
3. **Provisioning (Terraform)** — wrote a reusable VM module and stood up all 6 cluster VMs from code.
4. **Kubernetes (Talos)** — generated machine configs, bootstrapped an **HA control plane** (3-node etcd) behind a floating virtual IP, and joined the workers.
5. **Platform services** — installed Cilium (networking + load balancing), Longhorn (storage), ingress-nginx, and cert-manager (an internal Certificate Authority for TLS).
6. **GitOps (ArgoCD)** — adopted the *app-of-apps* pattern so the cluster now deploys and self-heals everything from the repo.
7. **Observability** — Prometheus, Grafana, Loki, and Alertmanager, all GitOps-managed.
8. **AI Ops** — deployed Ollama + Open WebUI + n8n, and built an **AI incident summarizer**: a real cluster alert flows Prometheus → Alertmanager → n8n → a local LLM that writes a plain-English summary with likely cause and next steps.
9. **Security** — Vault + External Secrets Operator for secrets, Cilium network policies, Trivy vulnerability scanning, **RBAC least-privilege identities**, an **internal CA trusted on client devices**, **explicit API-server audit logging**, and the **Tailscale operator** for zero-trust remote access (API-server proxy over the tailnet).
10. **Production readiness** *(next)* — backup/DR, upgrade & chaos testing, runbooks.

## Key decisions & configurations

- **Server access / operations:**
  - A dedicated **`mgmt-jump`** Ubuntu VM is the single control/jump host; all admin happens from there over SSH.
  - It holds the cluster credentials (`talosctl` for the OS, `kubectl` for Kubernetes), pinned to a stable IP via a router DHCP reservation.
  - Apps are reached through ingress over HTTPS (e.g. `grafana.…`, `argocd.…`, `chat.…`, `n8n.…`, `vault.…`), with certs from the internal CA.
- **Networking:** diagnosed a real bottleneck — the server was cabled through an old **10/100 switch** capping it at 100 Mbps (gigabit switch being installed). Single flat subnet; cluster uses **static IPs above the DHCP range** plus a dedicated load-balancer IP pool that Cilium advertises on the LAN.
- **Storage tuning:** Longhorn runs on dedicated disks; learned and fixed real capacity/over-provisioning behavior on spinning disks (the single HDD is the platform's main constraint — an SSD is a planned upgrade).
- **Security-first:** Pod Security Standards enforced per namespace, TLS everywhere via the internal CA (root trusted on client devices), kube-proxy replaced by eBPF, secrets centralized in Vault, and least-privilege RBAC identities (e.g. a read-only `cluster-viewer` bound to the built-in `view` role) for scoped teammate/CI access.
- **Everything as code:** the entire platform lives in a public GitHub repo with a detailed, step-by-step build log — reproducible from scratch.

## Current status
**Phases 1–9 complete** (planning → HA cluster → platform services → GitOps → observability → AI ops → security). **Phase 10 (production readiness)** — backup/DR, upgrade & chaos testing, runbooks — is next.
