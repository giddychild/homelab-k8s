# ===========================================================================
# apps-prod — VM provisioning (reuses the shared ../../modules/talos-vm module).
#
# Topology: 1 control-plane + 2 workers (lean by design — shares one ESXi host
# and one HDD-backed datastore with homelab-prod). Workers carry a second disk
# for Longhorn. All nodes boot the Talos ISO into maintenance mode; machine
# configs are applied in the provisioning runbook (Phase A), not here.
#
#   Sizing:  cp  = 4 vCPU / 8 GB  / 50 GB OS
#            wk  = 6 vCPU / 24 GB / 50 GB OS + 80 GB Longhorn data disk
#
#   IP plan (statics live above the DHCP ceiling .199, between homelab-prod's
#   statics .200-.213 and its LB pool .230-.250):
#            VIP  192.168.216.204
#            cp   192.168.216.205   (apps-cp-01)
#            wk   192.168.216.206-.207 (apps-wk-01, apps-wk-02)
#            LB   192.168.216.221-.229  (apps Cilium pool; ingress pinned .221)
# ===========================================================================

data "vsphere_datacenter" "dc" {
  name = var.vsphere_datacenter
}

data "vsphere_datastore" "ds" {
  name          = var.vsphere_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "net" {
  name          = var.vsphere_network
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Host lookup works for BOTH connection styles:
#   - Direct ESXi  : vsphere_host_name = "" -> name=null -> the single implicit host.
#   - Via vCenter  : vsphere_host_name set  -> the named host in inventory.
# resource_pool_id returns the host's root resource pool in either case.
data "vsphere_host" "host" {
  name          = var.vsphere_host_name != "" ? var.vsphere_host_name : null
  datacenter_id = data.vsphere_datacenter.dc.id
}

output "connectivity_check" {
  description = "If this resolves, Terraform can talk to the endpoint and the names are valid."
  value = {
    datacenter = data.vsphere_datacenter.dc.name
    datastore  = data.vsphere_datastore.ds.name
    network    = data.vsphere_network.net.name
    host_id    = data.vsphere_host.host.id
  }
}

# ---------------------------------------------------------------------------
# Cluster nodes
# ---------------------------------------------------------------------------

module "control_plane" {
  source   = "../../modules/talos-vm"
  for_each = toset(["apps-cp-01"])

  name       = each.key
  num_cpus   = 4
  memory_mb  = 8192 # 8 GB
  os_disk_gb = 50

  datastore_id     = data.vsphere_datastore.ds.id
  resource_pool_id = data.vsphere_host.host.resource_pool_id
  host_system_id   = data.vsphere_host.host.id
  network_id       = data.vsphere_network.net.id
  iso_datastore_id = data.vsphere_datastore.ds.id
  iso_path         = var.talos_iso_path
}

module "workers" {
  source   = "../../modules/talos-vm"
  for_each = toset(["apps-wk-01", "apps-wk-02"])

  name         = each.key
  num_cpus     = 6
  memory_mb    = 24576 # 24 GB
  os_disk_gb   = 50
  data_disk_gb = 80 # second disk for Longhorn replicated storage

  datastore_id     = data.vsphere_datastore.ds.id
  resource_pool_id = data.vsphere_host.host.resource_pool_id
  host_system_id   = data.vsphere_host.host.id
  network_id       = data.vsphere_network.net.id
  iso_datastore_id = data.vsphere_datastore.ds.id
  iso_path         = var.talos_iso_path
}

output "control_plane_vms" {
  description = "Control-plane VM IDs by name."
  value       = { for k, m in module.control_plane : k => m.id }
}

output "worker_vms" {
  description = "Worker VM IDs by name."
  value       = { for k, m in module.workers : k => m.id }
}
