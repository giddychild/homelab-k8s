provider "vsphere" {
  vsphere_server = var.vsphere_server
  user           = var.vsphere_user
  password       = var.vsphere_password

  # ESXi presents a self-signed certificate; skip TLS verification.
  # (For a hardened setup we'd trust the host cert instead — revisit in Phase 9.)
  allow_unverified_ssl = true
}
