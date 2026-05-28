# CIS Kubernetes Benchmark on Talos

## Why kube-bench doesn't work

We tried `aquasec/kube-bench:v0.12.0` as a Job on the homelab cluster. Every
pod failed with:

```
Error: failed to generate container ... failed to apply OCI options:
failed to mkdir "/etc/systemd": read-only file system
```

This is fundamental: Talos's root filesystem is **read-only by design**
(immutability is one of Talos's three pillars). kube-bench's image runs
`mkdir /etc/systemd` as part of its init even though we only mount it
read-only — the kernel refuses the mkdir and the container never starts.

There's no flag to disable this in kube-bench. The tool was built for
mutable distributions (Ubuntu, RHEL, etc.). Talos goes the other direction
on purpose.

## What we use instead

**Kubescape** (`quay.io/kubescape/kubescape-cli:v3.0.43`) runs as a normal
non-root pod, talks to the kube API, and covers the same CIS controls plus
NSA-CISA, MITRE ATT&CK, and ArmoBest frameworks. No host paths, no
read-only-fs gymnastics. Manifest:
`gitops/workloads/security-scans/kubescape-cronjob.yaml`.

## OS-layer CIS controls (the half kubescape can't see)

CIS Kubernetes Benchmark splits into:

1. **Control plane components** (kube-apiserver, kube-controller-manager,
   kube-scheduler, etcd, kubelet) — file permissions, flag values, audit
   policy. Kubescape covers the *API-visible* portion (audit policy, RBAC,
   PSS); the *on-disk file* portion needs OS-level visibility.

2. **Worker components** (kubelet config + binaries) — same story.

3. **Policies** (RBAC, NetworkPolicy, PSS, namespace labels) — Kubescape
   covers this fully.

For categories 1 and 2 on Talos, **the controls are enforced by Talos
itself, not by us**. Talos publishes a CIS mapping at
https://www.talos.dev/v1.13/learn-more/talos-secure/ that documents which
CIS controls are met out-of-the-box. The short answer: **most of them**,
because:

- Talos uses an immutable filesystem (controls 1.1.x about file permissions
  are met by construction — there's no way for a permission to drift).
- Talos's API is the ONLY way to change config (no SSH, no shell, no
  `kubectl edit` of static pod manifests).
- The kubelet, apiserver, etcd, etc. ship with Talos-curated flag values
  that match CIS recommendations.

**Verification** for the OS layer on Talos:

```sh
# Audit policy is set (we did this in Phase 9):
talosctl -n 192.168.216.201 read /etc/kubernetes/audit/policy.yaml

# Kubelet config (CIS 4.2.x):
talosctl -n 192.168.216.201 get kubeletconfigs -o yaml

# etcd config (CIS 2.1.x):
talosctl -n 192.168.216.201 get etcdconfigs -o yaml

# Control-plane static-pod flags (CIS 1.2.x, 1.3.x, 1.4.x):
talosctl -n 192.168.216.201 get staticpods -o yaml | grep -E '(--anonymous-auth|--authorization-mode|--admission-control|--audit|--enable-admission|--profiling|--tls-)' | sort -u
```

If a flag value disagrees with CIS, the fix is a Talos patch
(`talos/patches/controlplane.yaml`) + regenerate + apply — not editing
files on the node (you can't).

## Workflow

| Step | Tool | Cadence | Where |
|------|------|---------|-------|
| Cluster-resource controls (RBAC, PSS, NetworkPolicy, etc.) | Kubescape | Weekly (Mon 04:00 CT) | `kubectl logs -n security-scans -l job-name=kubescape-scan` |
| OS / control-plane controls | `talosctl` + Talos CIS mapping | Quarterly review | mgmt-jump CLI |
| Container image CVEs | Trivy operator | Continuous | See `trivy-monthly-review.md` |

## First-run command

```sh
kubectl apply -f gitops/workloads/security-scans/kubescape-cronjob.yaml
# The included `kubescape-baseline` Job runs immediately:
kubectl wait --for=condition=complete --timeout=600s job/kubescape-baseline -n security-scans
kubectl logs -n security-scans -l job-name=kubescape-baseline --tail=-1 | tee /tmp/kubescape-baseline.txt

# Headline: count failed controls per framework:
grep -E '(Failed resources|FAILED:|TOTAL:|Compliance score)' /tmp/kubescape-baseline.txt
```

The CronJob then takes over weekly.

## What to do with the findings

For each FAIL:

1. **Read the control text** in the Kubescape output — it includes the CIS
   ID + the fix.
2. **If the fix is a Talos config flag** — add it to
   `talos/patches/controlplane.yaml`, regen, apply per
   `talos-kubernetes-upgrades.md`.
3. **If it's a workload spec issue** (e.g. `runAsRoot` on some pod) — fix
   in the chart values or template.
4. **If it's a false positive on our setup** (e.g. "missing NetworkPolicy"
   on a namespace we deliberately leave open) — file in
   `docs/security/kubescape-acceptances.md` with the reason + expiry.

The Trivy review pattern (`docs/runbooks/trivy-monthly-review.md`) applies
verbatim — same three-bucket triage (patch / schedule / accept).
