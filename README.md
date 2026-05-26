# homelab-k8s

Production-style homelab Kubernetes platform — Infrastructure-as-Code source of truth.

Runs on a single **Dell R730XD** (dual Xeon E5-2698 v4, 512 GB RAM) under **VMware ESXi 7.0 U3**
(vSphere Enterprise Plus). The whole platform is declarative: this repo can rebuild it from scratch.

## Stack

| Layer | Tech | Phase |
|---|---|---|
| Hypervisor | VMware ESXi 7.0 U3 | 2 |
| VM provisioning | Terraform (vSphere provider) | 2–3 |
| Config bootstrap | Ansible | 3 |
| Kubernetes distro | Talos Linux (HA, 3 control plane + 3 workers) | 4 |
| CNI / networking | Cilium (eBPF, kube-proxy replacement) | 5 |
| Storage | Longhorn (replicated block storage) | 5 |
| Ingress / TLS | ingress-nginx + cert-manager (Let's Encrypt via Cloudflare DNS-01, + internal CA) | 5 |
| GitOps | ArgoCD (app-of-apps) | 6 |
| Observability | Prometheus, Grafana, Loki, Alertmanager (→ Discord) | 7 |
| AI ops | Ollama, Open WebUI, n8n | 8 |
| Remote access | Tailscale (operator + API-server proxy) | 9 |
| Secrets | HashiCorp Vault + External Secrets Operator | 9 |
| Security | RBAC least-privilege, Pod Security Standards, Cilium NetworkPolicies, Trivy, audit logging | 9 |
| Backup / DR | Velero + Talos etcd snapshots → AWS S3 (tested restore) | 10 |

## Repository layout

```
docs/         Living documentation: architecture, IP plan, naming, ADRs, runbooks
terraform/    Creates the ESXi VMs (reusable module + prod environment)
ansible/      Bootstraps the mgmt host and helper automation
talos/        Talos machine configs + patches (secrets encrypted/ignored)
kubernetes/   Bootstrap manifests applied BEFORE ArgoCD (Cilium, ArgoCD itself)
gitops/       ArgoCD watches this = the cluster's desired state
scripts/      Helper scripts
```

## Status

**All 10 phases complete** — planning → HA cluster → platform services → GitOps → observability → AI ops → security → production readiness. Disaster recovery is **tested** (Velero + Talos etcd snapshots to AWS S3; restore drill passed). Every service has publicly-trusted HTTPS (Let's Encrypt via Cloudflare DNS-01). See [`docs/OVERVIEW.md`](docs/OVERVIEW.md) for the tour and [`docs/build-log.md`](docs/build-log.md) for the full step-by-step build, key facts, and runbooks.

## Conventions

- `main` is the deployed state; GitOps (ArgoCD) reconciles the cluster to it.
- Secrets are **never** committed in plaintext — they live in **HashiCorp Vault** and are delivered to the cluster by the **External Secrets Operator**. See `.gitignore`.
