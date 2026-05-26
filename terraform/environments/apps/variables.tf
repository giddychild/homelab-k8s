# ===========================================================================
# apps-prod cluster — connection + inventory variables.
#
# This environment provisions the SECOND, dedicated "apps" cluster (1 control
# plane + 2 workers) that hosts user-facing applications (first app: "money",
# the finance platform). It is isolated from the homelab-prod learning/chaos
# cluster but shares the same ESXi host + datastore1.
#
# Connection is set in terraform.tfvars (gitignored). The same code works
# whether you point at the ESXi host directly OR at the vCenter at .217 — only
# the values below change. See terraform.tfvars.example.
# ===========================================================================

# ----- Connection (set in terraform.tfvars — gitignored) -----
variable "vsphere_server" {
  type        = string
  description = "vCenter FQDN/IP (e.g. 192.168.216.217) OR the ESXi host IP for a direct connection."
}

variable "vsphere_user" {
  type        = string
  description = "vCenter SSO user (e.g. administrator@vsphere.local) OR ESXi 'root'."
}

variable "vsphere_password" {
  type        = string
  description = "Password for vsphere_user."
  sensitive   = true
}

# ----- Inventory names -----
variable "vsphere_datacenter" {
  type        = string
  description = "Datacenter name. 'ha-datacenter' for a direct ESXi connection; the real vCenter datacenter name when connecting to vCenter."
  default     = "ha-datacenter"
}

variable "vsphere_host_name" {
  type        = string
  description = "ESXi host name as it appears in inventory. Leave \"\" for a direct standalone-ESXi connection (single implicit host); set it (e.g. 'localhost.network.techvitality.com') when connecting via vCenter."
  default     = ""
}

variable "vsphere_datastore" {
  type        = string
  description = "Datastore that backs the VMs (shared with homelab-prod)."
  default     = "datastore1"
}

variable "vsphere_network" {
  type        = string
  description = "Port group VMs attach to (flat LAN, same as homelab-prod)."
  default     = "VM Network"
}

variable "talos_iso_path" {
  type        = string
  description = "Path to the Talos ISO within the datastore (already uploaded for homelab-prod — reused here)."
  default     = "ISOs/talos/metal-amd64.iso"
}
