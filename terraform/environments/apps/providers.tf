provider "vsphere" {
  vsphere_server = var.vsphere_server
  user           = var.vsphere_user
  password       = var.vsphere_password

  # Both ESXi (self-signed) and a homelab vCenter typically present untrusted
  # certs; skip TLS verification here. (Harden by trusting the cert in Phase 9.)
  allow_unverified_ssl = true
}
