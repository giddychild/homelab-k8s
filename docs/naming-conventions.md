# Naming conventions

Consistent names make automation (Terraform loops, Ansible inventory, Grafana
dashboards) predictable. Always lowercase + hyphens (Kubernetes and DNS dislike
uppercase and underscores).

| Thing | Convention | Examples |
|---|---|---|
| ESXi VM / hostname | `talos-<role>-<NN>` | `talos-cp-01`, `talos-wk-02`, `mgmt-jump` |
| ESXi VM folder | `k8s-prod` | groups our VMs separately from the 17 existing ones |
| Kubernetes cluster | `<env>` | `homelab-prod` |
| Kubernetes namespaces | by function | `longhorn-system`, `argocd`, `cert-manager`, `ingress`, `monitoring`, `logging`, `ai-ops`, `tailscale` |
| Git branches | trunk-based | `main` (= live state), `feat/<thing>` via PR |
| Terraform resources | `<role>` indexed | `talos_cp[0]`, `talos_wk[1]` |
| Kubernetes labels | upstream standard | `app.kubernetes.io/name`, `app.kubernetes.io/part-of` |
| DNS (future, TLS) | `<svc>.<domain>` | e.g. `grafana.k8s.example.com` — domain TBD |

## Roles

| Code | Role |
|---|---|
| `cp` | control plane |
| `wk` | worker |
| `mgmt` | management / tooling |
