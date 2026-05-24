# Module: talos-vm

Creates one Talos Linux VM on a standalone ESXi host, booting from the Talos ISO
into maintenance mode (ready for `talosctl apply-config` in Phase 4).

## Why it's built this way
- **`pvscsi` + `vmxnet3`** — VMware's paravirtual controller/NIC: faster, lower CPU.
- **`enable_disk_uuid = true`** — gives stable `/dev/disk/by-id` paths (Longhorn likes this).
- **`wait_for_guest_*_timeout = 0`** — Talos has no VMware guest agent by default, so
  Terraform must not wait for a guest IP (it would hang, then error).
- **Optional `data_disk_gb`** — workers get a second disk for Longhorn; control planes don't.

## Example
```hcl
module "cp" {
  source = "../../modules/talos-vm"

  name      = "talos-cp-01"
  num_cpus  = 4
  memory_mb = 16384
  os_disk_gb = 60

  datastore_id     = data.vsphere_datastore.ds.id
  resource_pool_id = data.vsphere_host.host.resource_pool_id
  host_system_id   = data.vsphere_host.host.id
  network_id       = data.vsphere_network.net.id
  iso_datastore_id = data.vsphere_datastore.ds.id
  iso_path         = "ISOs/linux/talos/metal-amd64.iso"
}
```

## Inputs (summary)
`name`, `num_cpus`, `memory_mb`, `os_disk_gb` (def 60), `data_disk_gb` (def 0),
`datastore_id`, `resource_pool_id`, `host_system_id`, `network_id`,
`iso_datastore_id`, `iso_path`, `guest_id` (def `otherLinux64Guest`), `firmware` (def `efi`).
