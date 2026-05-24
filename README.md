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
| Ingress / TLS | Ingress controller + cert-manager | 5 |
| GitOps | ArgoCD (app-of-apps) | 6 |
| Observability | Prometheus, Grafana, Loki, Alertmanager | 7 |
| AI ops | Ollama, Open WebUI, n8n | 8 |
| Remote access | Tailscale | 9 |
| Secrets | SOPS + age (encrypted in git) | 9 |

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

Phase 1 (Infrastructure Planning) — in progress. See `docs/`.

## Conventions

- `main` is the deployed state. Changes land via pull request.
- Secrets are **never** committed in plaintext. See `.sops.yaml` and `.gitignore`.
