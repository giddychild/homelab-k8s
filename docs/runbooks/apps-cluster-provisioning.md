# Runbook — Provisioning the `apps-prod` cluster (Phase A)

Stands up the second, dedicated **apps-prod** cluster (1 control-plane + 2 workers)
that hosts user-facing applications, isolated from the `homelab-prod`
learning/chaos cluster but sharing the same ESXi host + `datastore1`.

> **Cadence:** one step at a time. Stop and verify at each ✅ gate. Nothing here
> is destructive to `homelab-prod` or the 11 existing VMs, but `terraform apply`
> **creates** 3 new VMs — review the plan before applying.

## Facts

| Item | Value |
|---|---|
| Cluster name | `apps-prod` |
| Nodes | apps-cp-01 (4c/8G/50G), apps-wk-01 & -02 (6c/24G/50G + 80G Longhorn) |
| VIP (API) | `192.168.216.204:6443` |
| Node IPs | cp `.205`, wk `.206`, `.207` |
| Cilium LB pool | `192.168.216.221-.229` (distinct from homelab `.230-.250`) |
| Ingress IP | `192.168.216.221` |
| App host | `money.apps.giddyland.net` → `.221` (DNS-only A record) |
| Run from | `mgmt-jump` (`192.168.216.30`) — has talosctl/terraform/helm/kubectl |
| Datastore free | 1.89 TB (ample) |

IaC authored in this repo:
- `terraform/environments/apps/` — VM provisioning (reuses `modules/talos-vm`)
- `talos-apps/` — patches, schematic, (generated) configs
- `scripts/talos-gen-apps.sh` — config generation
- `kubernetes/bootstrap-apps/` — Cilium LB pool (+ platform values added per step)

---

## Step 0 — Decide the vSphere connection, fill tfvars

Pick **vCenter (.217, recommended)** or **direct ESXi**. Copy the template and fill:

```bash
cd ~/homelab-k8s/terraform/environments/apps
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # gitignored
```

For **vCenter**, verify the real datacenter + host names in the vSphere Client
(Hosts and Clusters) — `vsphere_datacenter` and `vsphere_host_name` must match
inventory exactly.

✅ Gate: `terraform.tfvars` filled, creds correct, not committed (`git status` clean of it).

## Step 1 — Terraform init + plan (READ-ONLY)

```bash
terraform init
terraform plan
```

Expect: data sources resolve (datacenter/datastore/network/host) and **3 VMs to add**
(1 control_plane + 2 workers), 0 to change/destroy.

✅ Gate: plan shows exactly 3 to add, connectivity_check resolves. **Review before apply.**

## Step 2 — Terraform apply (creates the VMs)

```bash
terraform apply        # confirm 'yes' after reviewing
```

VMs power on and boot the Talos ISO into **maintenance mode** on temporary DHCP
leases (DHCP is capped at .199, so leases come from the home pool — fine).

✅ Gate: 3 VMs created & powered on in vSphere; consoles show Talos maintenance mode.

## Step 3 — Collect maintenance IPs

From the ESXi/vCenter console or the Orbi DHCP table, note each node's temporary IP.
Verify the install disk on one node:

```bash
talosctl get disks --insecure -n <maintenance-ip>   # expect /dev/sda (OS) + /dev/sdb (workers)
```

✅ Gate: maintenance IPs recorded for apps-cp-01, apps-wk-01, apps-wk-02; disks as expected.

## Step 4 — Generate machine configs

```bash
cd ~/homelab-k8s
bash scripts/talos-gen-apps.sh
```

Produces `talos-apps/{controlplane,worker,talosconfig}.yaml` and (first run)
`talos-apps/secrets.yaml`. All gitignored.

✅ Gate: files generated; `talos-apps/controlplane.yaml` has no `auto: stable` under HostnameConfig.

## Step 5 — Apply config per node (`-e`/`-n` are required)

```bash
# Control plane
talosctl apply-config --insecure -n <cp-maint-ip> \
  --file talos-apps/controlplane.yaml \
  --config-patch @talos-apps/patches/nodes/apps-cp-01.yaml

# Workers
talosctl apply-config --insecure -n <wk1-maint-ip> \
  --file talos-apps/worker.yaml \
  --config-patch @talos-apps/patches/nodes/apps-wk-01.yaml
talosctl apply-config --insecure -n <wk2-maint-ip> \
  --file talos-apps/worker.yaml \
  --config-patch @talos-apps/patches/nodes/apps-wk-02.yaml
```

Nodes reboot, install to `/dev/sda` (workers pull the Image Factory installer with
iscsi-tools), and come up on their **static** IPs (.205/.206/.207).

✅ Gate: nodes reachable at static IPs; `talosctl -n .205 version` responds.

## Step 6 — Bootstrap etcd + get kubeconfig

```bash
export TALOSCONFIG=~/homelab-k8s/talos-apps/talosconfig
talosctl config endpoint 192.168.216.204
talosctl config node 192.168.216.205

talosctl bootstrap -n 192.168.216.205      # ONCE, on the single control plane
talosctl kubeconfig ~/.kube/apps-prod.kubeconfig
# Merge / name the context 'apps-prod' (keep homelab-prod context intact)
```

✅ Gate: `kubectl --kubeconfig ~/.kube/apps-prod.kubeconfig get nodes` shows 3 nodes
(NotReady — no CNI yet, expected). VIP .204 serving the API.

## Step 7 — Cilium (→ nodes Ready) + LB pool

Reuse the homelab Cilium values (Talos-specific, cluster-agnostic), then apply the
**apps** LB pool/L2 policy:

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm install cilium cilium/cilium --version 1.19.4 -n kube-system \
  --values kubernetes/bootstrap/cilium/values.yaml
kubectl apply -f kubernetes/bootstrap-apps/cilium/loadbalancer.yaml
```

✅ Gate: cilium pods Running; all 3 nodes **Ready**. (Verify a test LoadBalancer
svc gets `.221`–`.229` and answers ARP on the LAN.)

## Step 8 — Longhorn

Reuse `kubernetes/bootstrap/longhorn/` (namespace + values). Workers already mount
`/var/lib/longhorn` on `/dev/sdb`. Taint the control plane so Longhorn stays on workers.

✅ Gate: Longhorn pods Running on both workers; `longhorn` is default StorageClass.
**Create the per-replica StorageClasses for `money`:** `longhorn-r1` (1 replica,
re-creatable: Redis), `longhorn-r2` (2 replicas, Postgres).

## Step 9 — ingress-nginx (pinned .221) + cert-manager + LE issuers

> **To create at this step:** `kubernetes/bootstrap-apps/ingress-nginx/values.yaml`
> (copy of homelab's, but pin the controller Service to `.221` via
> `io.cilium/lb-ipam-ips` annotation). Reuse cert-manager + the existing
> `letsencrypt-staging`/`letsencrypt-prod` ClusterIssuers (they use the Cloudflare
> token via ESO — see Step 10).

✅ Gate: ingress on `.221` (HTTP 404 healthy); cert-manager Ready.

## Step 10 — ESO → reach the homelab Vault (CROSS-CLUSTER — the tricky bit)

The apps cluster's ESO must read secrets from the **homelab-prod** Vault. The
homelab Vault's Kubernetes auth is bound to the *homelab* cluster's SA issuer, so
it will **not** validate apps-prod service-account tokens out of the box. Options:

- **(a) AppRole auth (recommended for cross-cluster):** enable AppRole in Vault,
  create a role scoped to `secret/money/*` + `secret/cloudflare-dns`, store the
  role_id/secret_id as a bootstrap K8s secret in apps-prod, point a
  `ClusterSecretStore` at `https://vault.apps.giddyland.net` via AppRole.
- **(b) Second Kubernetes auth backend:** `vault auth enable -path=k8s-apps kubernetes`
  configured with apps-prod's JWKS/issuer + a reviewer SA token; ClusterSecretStore
  uses `path: k8s-apps`.

Vault is reachable from apps-prod over the LAN at its ingress host. Decide (a) vs (b)
when we get here; **(a) is simpler and avoids exposing apps-prod's API to Vault.**

✅ Gate: a test `ExternalSecret` in apps-prod materializes a value from Vault.

## Step 11 — CloudNativePG operator

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
```

(Or as an ArgoCD app once the hub manages this cluster — see Step 12.)

✅ Gate: CNPG operator Running; CRDs present (`kubectl get crd | grep postgresql`).

## Step 12 — Register apps-prod in the homelab ArgoCD (hub-and-spoke)

From `mgmt-jump` with the homelab-prod context active, add apps-prod as a managed
cluster:

```bash
argocd cluster add apps-prod --kubeconfig ~/.kube/apps-prod.kubeconfig
# (or declaratively: an argocd cluster Secret with the apps-prod API server + token)
```

The homelab ArgoCD now deploys to apps-prod by setting the `money` Application's
`destination.server` to the apps-prod API URL (`https://192.168.216.204:6443`).

✅ Gate: apps-prod shows green in ArgoCD's cluster list; a no-op test Application
syncs to it.

## Step 13 — DNS

Add a **DNS-only (grey-cloud)** A record in Cloudflare:
`money.apps.giddyland.net → 192.168.216.221`. (Overrides the homelab wildcard
`*.apps.giddyland.net → .230` for this specific name.)

✅ Gate: `dig money.apps.giddyland.net` → `.221`.

---

## Done = ready for the app

At this point `apps-prod` is a functioning GitOps-managed cluster with storage,
ingress, TLS, secrets, and Postgres operator — ready to receive the `money` Helm
release (Phases P0→). Update the project memory and tick Phase A complete.

## Rollback / teardown

`cd terraform/environments/apps && terraform destroy` removes the 3 VMs (does **not**
touch homelab-prod). Talos secrets in `talos-apps/secrets.yaml` can be kept to
re-provision with the same PKI, or deleted for a clean slate.
