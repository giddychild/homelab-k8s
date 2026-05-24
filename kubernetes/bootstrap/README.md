# kubernetes/bootstrap/

The minimal set installed by hand BEFORE ArgoCD takes over:

```
cilium/    The CNI — must exist before pods can get networking (Talos ships
           without a CNI on purpose so you choose). Installed with kube-proxy
           replacement enabled.
argocd/    ArgoCD itself — once running, it manages everything in /gitops.
```

Built in Phase 5–6. This is the only place we apply manifests manually; after
ArgoCD is up, all further changes go through git (`/gitops`).
