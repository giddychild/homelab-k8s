terraform {
  required_providers {
    vsphere = {
      source = "hashicorp/vsphere"
    }
  }
}

resource "vsphere_virtual_machine" "this" {
  name             = var.name
  resource_pool_id = var.resource_pool_id
  host_system_id   = var.host_system_id
  datastore_id     = var.datastore_id

  num_cpus = var.num_cpus
  memory   = var.memory_mb
  guest_id = var.guest_id
  firmware = var.firmware

  # Talos ships no VMware guest agent by default, so it never reports an IP to
  # vSphere. Without these set to 0, `terraform apply` would block waiting for a
  # guest IP and then fail. (Common Talos+Terraform gotcha.)
  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout  = 0

  enable_disk_uuid = true     # exposes stable /dev/disk/by-id (helps Longhorn)
  scsi_type        = "pvscsi" # VMware paravirtual SCSI — fast, low CPU

  network_interface {
    network_id   = var.network_id
    adapter_type = "vmxnet3"
  }

  # OS / system disk (Talos installs itself here on first boot)
  disk {
    label            = "disk0"
    size             = var.os_disk_gb
    thin_provisioned = true
    unit_number      = 0
  }

  # Optional second disk — used by workers for Longhorn replicated storage
  dynamic "disk" {
    for_each = var.data_disk_gb > 0 ? [1] : []
    content {
      label            = "disk1"
      size             = var.data_disk_gb
      thin_provisioned = true
      unit_number      = 1
    }
  }

  # Boot from the Talos ISO → node comes up in maintenance mode awaiting config.
  cdrom {
    datastore_id = var.iso_datastore_id
    path         = var.iso_path
  }

  lifecycle {
    # Talos rewrites the disk on install; don't let vSphere fight over CD/guest state.
    ignore_changes = [disk[0].thin_provisioned, cdrom]
  }
}
