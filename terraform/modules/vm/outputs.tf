output "vm_path" {
  description = "Filesystem path of the running VM's .vmx."
  value       = "${var.vm_output_dir}/${var.vm_name}.vmx"
}

output "mac_address" {
  description = "MAC pinned on the VM's single NIC."
  value       = var.mac_address
}

output "vm_name" {
  description = "The name passed to `vmrun clone -cloneName`."
  value       = var.vm_name
}
