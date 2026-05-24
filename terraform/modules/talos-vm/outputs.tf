output "id" {
  description = "Managed object ID of the VM."
  value       = vsphere_virtual_machine.this.id
}

output "name" {
  value = vsphere_virtual_machine.this.name
}

output "default_ip" {
  description = "vSphere-reported IP (usually empty for Talos — no guest agent)."
  value       = vsphere_virtual_machine.this.default_ip_address
}
