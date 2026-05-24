# ----- Connection (set these in terraform.tfvars — gitignored) -----
variable "vsphere_server" {
  type        = string
  description = "ESXi host IP or FQDN (we connect directly; no vCenter)."
}

variable "vsphere_user" {
  type        = string
  description = "ESXi username (e.g. root, or a dedicated terraform user)."
}

variable "vsphere_password" {
  type        = string
  description = "ESXi password."
  sensitive   = true
}

# ----- Inventory names (defaults match this environment) -----
variable "vsphere_datacenter" {
  type        = string
  description = "Implicit datacenter name when connecting directly to a standalone ESXi host."
  default     = "ha-datacenter"
}

variable "vsphere_datastore" {
  type        = string
  description = "Datastore that backs the VMs."
  default     = "datastore1"
}

variable "vsphere_network" {
  type        = string
  description = "Port group VMs attach to."
  default     = "VM Network"
}

variable "talos_iso_path" {
  type        = string
  description = "Path to the Talos ISO within the datastore."
  default     = "ISOs/talos/metal-amd64.iso"
}
