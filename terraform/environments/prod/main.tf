# Phase 3, Step 1 — CONNECTIVITY VALIDATION ONLY.
#
# These are read-only data sources. Running `terraform plan` reads them from the
# ESXi host, which proves: (a) our credentials work, and (b) the datastore and
# network names are correct. NO resources are created at this step.
#
# Once this validates, the next step adds the reusable talos-vm module and the
# actual VM resources.

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

# Standalone ESXi has exactly one host, so `name` can be omitted — the data
# source returns that host. We use it to place VMs (resource pool + host id).
data "vsphere_host" "host" {
  datacenter_id = data.vsphere_datacenter.dc.id
}

output "connectivity_check" {
  description = "If this resolves, Terraform can talk to ESXi and the names are valid."
  value = {
    datacenter = data.vsphere_datacenter.dc.name
    datastore  = data.vsphere_datastore.ds.name
    network    = data.vsphere_network.net.name
    host_id    = data.vsphere_host.host.id
  }
}

# ---------------------------------------------------------------------------
# Cluster nodes (Phase 3, Step 3) — created via the reusable talos-vm module.
# Each VM boots the Talos ISO into maintenance mode; configs come in Phase 4.
# ---------------------------------------------------------------------------

module "control_plane" {
  source   = "../../modules/talos-vm"
  for_each = toset(["talos-cp-01", "talos-cp-02", "talos-cp-03"])

  name       = each.key
  num_cpus   = 4
  memory_mb  = 16384 # 16 GB
  os_disk_gb = 60

  datastore_id     = data.vsphere_datastore.ds.id
  resource_pool_id = data.vsphere_host.host.resource_pool_id
  host_system_id   = data.vsphere_host.host.id
  network_id       = data.vsphere_network.net.id
  iso_datastore_id = data.vsphere_datastore.ds.id
  iso_path         = var.talos_iso_path
}

module "workers" {
  source   = "../../modules/talos-vm"
  for_each = toset(["talos-wk-01", "talos-wk-02", "talos-wk-03"])

  name         = each.key
  num_cpus     = 8
  memory_mb    = 49152 # 48 GB
  os_disk_gb   = 60
  data_disk_gb = 100 # second disk for Longhorn replicated storage

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
