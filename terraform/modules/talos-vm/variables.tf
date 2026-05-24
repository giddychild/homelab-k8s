# ----- Identity & sizing -----
variable "name" {
  type        = string
  description = "VM name (e.g. talos-cp-01)."
}

variable "num_cpus" {
  type        = number
  description = "Number of vCPUs."
}

variable "memory_mb" {
  type        = number
  description = "Memory in MB."
}

variable "os_disk_gb" {
  type        = number
  description = "Size of the OS/system disk in GB."
  default     = 60
}

variable "data_disk_gb" {
  type        = number
  description = "Optional second disk in GB (e.g. Longhorn on workers). 0 = none."
  default     = 0
}

# ----- Placement (IDs passed in from the root module's data sources) -----
variable "datastore_id" { type = string }
variable "resource_pool_id" { type = string }
variable "host_system_id" { type = string }
variable "network_id" { type = string }

# ----- Boot media (Talos ISO) -----
variable "iso_datastore_id" {
  type        = string
  description = "Datastore ID holding the Talos ISO."
}

variable "iso_path" {
  type        = string
  description = "Path to the Talos ISO within the datastore (e.g. ISOs/linux/talos/metal-amd64.iso)."
}

# ----- Advanced (sensible defaults for Talos) -----
variable "guest_id" {
  type        = string
  description = "vSphere guest OS id. Talos isn't a recognized OS, so we use a generic 64-bit Linux id."
  default     = "otherLinux64Guest"
}

variable "firmware" {
  type        = string
  description = "BIOS or EFI. Talos supports both; EFI is the modern default."
  default     = "efi"
}
