# Trivy operator — monthly CVE review

Trivy operator is already running (`gitops/apps/trivy-operator.yaml`).  It
continuously scans every workload image + the cluster's manifests, writing
findings into `VulnerabilityReport` and `ConfigAuditReport` CRDs.

The gap: **no human ever reads them.**  This runbook is the monthly cadence
to triage + remediate.

## Cadence

First Monday of each month, 30-min slot.  Recurring calendar event.

## Triage steps

### 1. Sweep the headline numbers

```sh
# Critical + High CVEs cluster-wide:
kubectl get vulnerabilityreport -A \
  -o custom-columns=NS:.metadata.namespace,POD:.metadata.labels.trivy-operator\\.resource\\.name,IMG:.report.artifact.repository,CRIT:.report.summary.criticalCount,HIGH:.report.summary.highCount \
  | awk 'NR==1 || $4>0 || $5>0'

# Misconfig (PSS, RBAC, NetworkPolicy gaps):
kubectl get configauditreport -A \
  -o custom-columns=NS:.metadata.namespace,KIND:.report.scope.kind,NAME:.report.scope.name,CRIT:.report.summary.criticalCount,HIGH:.report.summary.highCount \
  | awk 'NR==1 || $4>0 || $5>0'
```

### 2. For each Critical CVE

Decide one of:

| Action          | When                                                                   |
|-----------------|------------------------------------------------------------------------|
| **Patch now**   | A newer image tag exists + your chart accepts it. Bump tag, push, sync.|
| **Schedule**    | Upstream patch exists but breaking change. File a ticket with deadline.|
| **Accept risk** | False positive or non-exploitable in your config. Document in `docs/security/trivy-acceptances.md` with: CVE, image, reason, owner, expiry. |
| **Replace**     | Image is abandoned / no upstream fix. Migrate to an alternative.       |

### 3. For each High Misconfig

Common patterns + fixes:
- **"runAsRoot"** on a workload → add `securityContext.runAsNonRoot: true`
  + a non-zero uid.
- **"NoCpuLimit" / "NoMemoryLimit"** → add `resources.limits` to the
  container spec.
- **"MissingNetworkPolicy"** → covered by the `network-policy-rollout.md`
  hardening pass.

### 4. Record outcomes

Append to `docs/security/trivy-review-log.md` with date + the headline numbers
+ what you fixed.  Trend over months tells you if hygiene is improving.

## Helpful queries

```sh
# All Critical CVEs grouped by image:
kubectl get vulnerabilityreport -A -o json | jq -r '
  .items[] | select(.report.summary.criticalCount > 0)
  | "\(.report.artifact.repository):\(.report.artifact.tag) — \(.report.summary.criticalCount) crit"
' | sort -u

# Misconfigs that are PSS violations (most actionable):
kubectl get configauditreport -A -o json | jq -r '
  .items[] | .report.checks[] | select(.severity == "CRITICAL" or .severity == "HIGH")
  | "\(.checkID): \(.title)"
' | sort | uniq -c | sort -rn | head -20

# What's exposed (Service type=LoadBalancer or NodePort):
kubectl get svc -A -o json | jq -r '
  .items[] | select(.spec.type == "LoadBalancer" or .spec.type == "NodePort")
  | "\(.metadata.namespace)/\(.metadata.name): \(.spec.type) \(.spec.clusterIP) -> \(.status.loadBalancer.ingress // [])"
'
```

## When to escalate beyond monthly

- A Critical CVE with public exploit code (check the CVE description) →
  patch the same day.
- A Critical CVE in a workload that talks to the internet (cloudflared, api,
  worker images) → patch within 72h.
- A Critical CVE in a workload behind only LAN (longhorn-manager, cnpg-
  controller) → next monthly review is fine.

## Out of scope for this runbook

- Operating-system CVEs on the Talos nodes → those come with Talos image
  upgrades (see `talos-kubernetes-upgrades.md`).
- ESXi / iDRAC / firmware CVEs → VMware Security Advisories, separate cadence.
