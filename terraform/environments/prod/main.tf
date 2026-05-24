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
    host       = data.vsphere_host.host.name
  }
}
