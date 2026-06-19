output "vm_app_public_ip" {
  description = "Public IP of vm-app"
  value       = azurerm_public_ip.app.ip_address
}

output "vm_app_private_ip" {
  description = "Private IP of vm-app"
  value       = azurerm_network_interface.app.private_ip_address
}

output "vm_backend_public_ip" {
  description = "Public IP of vm-backend"
  value       = azurerm_public_ip.backend.ip_address
}

output "vm_backend_private_ip" {
  description = "Private IP of vm-backend"
  value       = azurerm_network_interface.backend.private_ip_address
}

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.capstone.name
}

output "ssh_vm_app" {
  description = "SSH command to connect to vm-app"
  value       = "ssh labadmin@${azurerm_public_ip.app.ip_address}"
}

output "ssh_vm_backend" {
  description = "SSH command to connect to vm-backend"
  value       = "ssh labadmin@${azurerm_public_ip.backend.ip_address}"
}

output "connectivity_test" {
  description = "Run from vm-app to test ICMP to vm-backend (tests the fault-injection NSG rule)"
  value       = "ping -c 4 10.10.2.10"
}
