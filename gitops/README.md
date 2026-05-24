# gitops/

ArgoCD's source of truth. Once ArgoCD is bootstrapped, **anything committed here
is automatically reconciled onto the cluster** — git becomes the control panel.

```
bootstrap/root-app.yaml   The "app-of-apps": one Application that points ArgoCD
                          at the folders below, so adding an app = adding a file.
infrastructure/           longhorn, cert-manager, ingress controller, external-dns
monitoring/               kube-prometheus-stack, loki, grafana, alertmanager
security/                 tailscale, network policies, image/vuln scanners
ai-ops/                   ollama, open-webui, n8n
```

Built from Phase 6 onward. Pattern: declarative desired state + automated sync,
with git history giving you instant rollback.
