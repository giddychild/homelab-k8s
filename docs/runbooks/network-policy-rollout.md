# NetworkPolicy rollout — cluster hardening

Closes the cluster-wide gap where east-west traffic was wide open in every
namespace except `demo`.  After rollout every namespace (vault, monitoring,
argocd, ai-ops, money, learnquest) runs default-deny with explicit allows.

## Why this is staged, not "kubectl apply -f netpol-baseline/"

A wrong allow rule = the namespace goes dark.  Recovery is fast (`kubectl
delete cnp -n <ns> --all`) but only if you notice the breakage.  So we apply
per namespace, wait, verify, then move on.  Order = lowest-risk-first.

## Order

| Step | Namespace      | File                                             | Risk | Watch for                                    |
|------|----------------|--------------------------------------------------|------|----------------------------------------------|
| 1    | `vault`        | `netpol-baseline/vault.yaml`                     | low  | ESO sync errors in `external-secrets` ns     |
| 2    | `ai-ops`       | `netpol-baseline/ai-ops.yaml`                    | low  | `kubectl logs -n money -l ...component=worker` for Ollama timeouts |
| 3    | `monitoring`   | `netpol-baseline/monitoring.yaml`                | med  | Grafana login from LAN; Alertmanager Discord test |
| 4    | `argocd`       | `netpol-baseline/argocd.yaml`                    | med  | New sync from a repo URL; UI login           |
| 5    | `money`        | flip `values-homelab.yaml networkPolicy.enabled=true` | high | `money.apps.giddyland.net` end-to-end + Cloudflare Tunnel path |
| 6    | `learnquest`   | same flip in its `values-homelab.yaml`           | high | `learn.giddyland.net` end-to-end             |

## Per-step procedure

```sh
# 1. Apply
kubectl apply -f gitops/workloads/netpol-baseline/vault.yaml

# 2. Verify policies installed
kubectl get cnp -n vault

# 3. Smoke test from inside the namespace
#    (run a throwaway pod, confirm ALLOWED edge works, BLOCKED edge fails)
kubectl run -n external-secrets test --rm -it --image=alpine -- \
  sh -c 'wget -qO- --timeout=3 http://vault.vault.svc.cluster.local:8200/v1/sys/health || echo BLOCKED'
# expected: a JSON response, not BLOCKED

kubectl run -n default test --rm -it --image=alpine -- \
  sh -c 'wget -qO- --timeout=3 http://vault.vault.svc.cluster.local:8200/v1/sys/health || echo BLOCKED'
# expected: BLOCKED  (default-deny working)

# 4. Wait 30 min, check for ESO sync errors:
kubectl get externalsecret -A -o wide | grep -v SecretSynced

# 5. If green, move to step 2 (ai-ops).  If red, rollback:
kubectl delete -f gitops/workloads/netpol-baseline/vault.yaml
```

## Money + LearnQuest rollout (steps 5 + 6)

The chart templates are ready (rewritten in this hardening pass).  To activate:

```sh
# Edit:
gitops/workloads/money/values-homelab.yaml
  networkPolicy:
    enabled: true   # was false

gitops/workloads/learnquest/values-homelab.yaml
  networkPolicy:
    enabled: true   # was false

git add -A && git commit -m "money + learnquest: enable network policies"
git push
# ArgoCD syncs; CNPs appear within ~60s.
```

**Smoke test after each app:**
```sh
# money:
curl -I https://money.apps.giddyland.net    # 200/302 expected
# learnquest (public path through Cloudflare):
curl -I https://learn.giddyland.net          # 200/302 expected
# Postgres reachable from api/worker?  Watch CNPG operator + pod logs:
kubectl logs -n money -l cnpg.io/cluster=money-pg --tail=20
kubectl logs -n learnquest -l cnpg.io/cluster=learnquest-pg --tail=20
```

## Rollback (any step)

```sh
# Per-namespace baseline:
kubectl delete -f gitops/workloads/netpol-baseline/<ns>.yaml

# Per-app (money/learnquest):
# Flip values-homelab.yaml back to networkPolicy.enabled: false, push.
# OR (instant):
kubectl delete cnp -n money --all
kubectl delete cnp -n learnquest --all
```

## What this does NOT cover

- `kube-system`, `cnpg-system`, `external-secrets`, `cert-manager`,
  `ingress-nginx`, `longhorn-system`, `velero`, `tailscale`, `trivy-system` —
  left untouched.  These are infra components whose own policies (or lack of
  them) are the responsibility of their charts.  Adding a default-deny here
  is high-risk and low-reward; the apps that matter (vault, money, learnquest,
  ai-ops) are now locked down.
- L7 (HTTP method/path) filtering — Cilium can do it; we don't yet.
- Tailscale operator's per-Connector policies — those use Tailscale ACLs not
  k8s NetworkPolicy.
