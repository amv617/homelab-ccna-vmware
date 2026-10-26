output "vm_ip_addresses" {
  description = "IP address of each VM, as reported by VMware Tools"
  value       = { for name, vm in vsphere_virtual_machine.vm : name => vm.default_ip_address }
}
