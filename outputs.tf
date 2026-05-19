output "public_ip_address" {
  description = "Public IP address of the virtual machine"
  value       = azurerm_public_ip.public_ip.ip_address
}

output "vm_name" {
  description = "Name of the virtual machine"
  value       = azurerm_windows_virtual_machine.vm.name
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  description = "Name of the diagnostics storage account"
  value       = azurerm_storage_account.diag.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID"
  value       = azurerm_log_analytics_workspace.law.id
}

output "devops_project_url" {
  description = "URL of the Azure DevOps project"
  value       = "https://dev.azure.com/${urlencode(split("/", var.devops_org_url)[length(split("/", var.devops_org_url)) - 1])}/${urlencode(azuredevops_project.project.name)}"
}
