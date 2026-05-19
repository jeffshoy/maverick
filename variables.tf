variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
  default     = "rg-windows-vm"
}

variable "location" {
  description = "Azure region to deploy resources"
  type        = string
  default     = "East US"
}

variable "vm_name" {
  description = "Name of the virtual machine"
  type        = string
  default     = "vm-win2022"
}

variable "vm_size" {
  description = "Size/SKU of the virtual machine"
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Administrator username for the VM"
  type        = string
  default     = "azureadmin"
}

variable "admin_password" {
  description = "Administrator password for the VM"
  type        = string
  sensitive   = true
}

variable "storage_account_name" {
  description = "Globally unique storage account name (3-24 chars, lowercase alphanumeric only)"
  type        = string
}

variable "alert_email" {
  description = "Email address for Azure Monitor alert notifications"
  type        = string
}

variable "devops_project_name" {
  description = "Name of the Azure DevOps project to create"
  type        = string
}

variable "devops_service_principal_id" {
  description = "Service principal App ID used for the ADO Azure service connection"
  type        = string
}

variable "devops_service_principal_key" {
  description = "Service principal client secret used for the ADO Azure service connection"
  type        = string
  sensitive   = true
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "azure_subscription_name" {
  description = "Azure subscription display name"
  type        = string
}

variable "azure_tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
}
