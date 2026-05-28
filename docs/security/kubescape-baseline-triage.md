# Kubescape baseline triage — 2026-05-28

First Kubescape scan against the homelab cluster after the security
hardening pass. Frameworks scanned: NSA, MITRE, ArmoBest, cis-v1.12.0.

## Headline

| Metric | Value |
|---|---|
| Total resources scanned | 441 |
| Total failed | 137 |
| **Compliance score** | **50.10%** |
| Frameworks | NSA · MITRE · ArmoBest · cis-v1.12.0 |
| Action Required (need Kubescape operator) | 14 controls |

This is the **baseline** — no prior CIS scanning had been done. The 50.10%
is in line with stock Talos + Kubernetes + a workload mix without any
prior hardening pass. The big movers, in expected order of fix:

## Triage — Critical + High

| Control | Failed | Total | % | Fix | Status |
|---|---|---|---|---|---|
| Immutable container filesystem (`readOnlyRootFilesystem`) | 27 | 47 | 43% | Add `securityContext.readOnlyRootFilesystem: true` + emptyDir for /tmp where needed | TODO |
| Nginx Ingress Controller End of Life | 1 | 33 | 97% | Confirm ingress-nginx chart version; upgrade if EOL'd | TODO — investigate |
| Validate admission controller (validating) | 6 | 6 | 0% | Add Kyverno or OPA Gatekeeper for ValidatingAdmissionWebhook | TODO — needs design |
| Network mapping (no NetworkPolicy) | 9 | 13 | 31% | Covered by `network-policy-rollout.md` — applies after rollout | IN PROGRESS |
| PSP enabled | 1 | 1 | 0% | False positive — we use PSS labels (PodSecurityStandards). Document acceptance. | ACCEPT |
| Kubernetes CronJob (workload-specific check) | 2 | 2 | 0% | Investigate — likely false positive on resource-digest + kubescape-scan themselves | INVESTIGATE |

## Triage — Medium (CIS-1.2.x kube-apiserver flags)

These are Talos config patches on `talos/patches/controlplane.yaml`. Same
pattern as the audit-policy work in Phase 9.

| CIS ID | Title | Failed | Fix |
|---|---|---|---|
| CIS-1.2.3 | DenyServiceExternalIPs admission plugin | 1/1 (0%) | Add `DenyServiceExternalIPs` to `--enable-admission-plugins` |
| CIS-1.2.29 | API Server only uses individual SA credentials | 0/1 (100%) | ✅ pass |
| CIS-1.2.30 | --service-account-extend-token-expiration | 1/1 (0%) | Add `--service-account-extend-token-expiration=false` |

## Triage — Medium (CIS-5.1.x RBAC)

These are RBAC bindings that grant broad access. Most pass; the failures
are specific role/clusterrolebinding overreaches.

| CIS ID | Title | Failed | Total | % | Action |
|---|---|---|---|---|---|
| CIS-5.1.9 | Minimize access to create PVs | 3 | 103 | 97% | Review the 3 SAs with `persistentvolumes/create` — likely cert-manager / longhorn / cnpg system controllers. Document if expected. |
| CIS-5.1.10 | Minimize access to proxy sub-resource | 3 | 103 | 97% | Same — likely Cilium / kube-controller-manager |
| CIS-5.1.11 | Minimize access to approval sub-resource | 2 | 103 | 98% | cert-manager controller likely; expected |
| CIS-5.1.12 | Minimize access to webhook config | 5 | 103 | 95% | cert-manager + Trivy + ESO operators; expected |
| CIS-5.1.13 | Minimize access to SA token sub-resource | 4 | 103 | 96% | kube-controller-manager + others; expected |

For all five: list the actual subjects via:
```sh
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name as $r |
    ($r == "system:controller:persistent-volume-binder") or
    ($r | test("admin|edit"))
  ) | "\(.metadata.name): \(.subjects // [] | map(.kind + "/" + .namespace + "/" + .name) | join(", "))"
'
```
Document expected operators in `kubescape-acceptances.md`.

## Triage — "Action Required" (need Kubescape operator)

These 14 controls (CIS-3.1.x, CIS-4.2.5/6/7/8/13, several others) need the
Kubescape operator running inside the cluster to evaluate host/kubelet
config that the CLI can't reach. Two paths:

**(a) Install the Kubescape operator** (~1 ArgoCD app) — gives us
continuous evaluation of these controls + the cluster-info CRDs Kubescape
queries (`ControlPlaneInfo`, `APIServerInfo`).

**(b) Document them as N/A on Talos** — Talos's read-only root + API-only
management makes most of the kubelet-flag checks tautologically correct
(you can't drift). Verify each via `talosctl get kubeletconfigs` and
document acceptance.

Recommendation: **(a)** for completeness. The operator is one small chart.

## Triage — Low (mostly informational)

Most pass at 100%. Notable failures:
- **Pods in default namespace** — 0/47 fail = 100% pass ✅
- **Access Kubernetes dashboard** — 100% pass ✅ (we don't run it)
- **SSH server running inside container** — 100% pass ✅ (Talos disallows)
- **Immutable filesystem** — already in the Critical section, repeats here

## Next commit's scope

1. **RBAC fix on Kubescape ClusterRole** — add `apiregistration`,
   `coordination`, `discovery` so future runs don't show the 5 warnings.
   ✅ included in this commit.
2. **`readOnlyRootFilesystem` audit** — list the 27 workloads, add to chart
   values one-by-one (separate PR, requires per-app smoke testing).
3. **Talos patch for CIS-1.2.3 + CIS-1.2.30** — append to
   `talos/patches/controlplane.yaml`, regen, apply per
   `talos-kubernetes-upgrades.md`.
4. **Kubescape operator install** — adds the Action-Required controls.

## What's NOT in scope

- **CIS-aks / cis-eks frameworks** — we're vanilla k8s on Talos; AKS/EKS
  controls are managed by those clouds, not applicable here.
- **SOC2 framework** — homelab; no compliance requirement. Add only if a
  consulting use case requires the report.
