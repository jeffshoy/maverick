variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vnet_name" { type = string }
variable "address_space" { type = list(string) }
variable "aks_subnet_name" { type = string }
variable "aks_subnet_prefixes" { type = list(string) }
variable "nsg_name" { type = string }
variable "log_analytics_workspace_name" { type = string }
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "acr_name" { type = string }
variable "acr_sku" {
  type    = string
  default = "Standard"
}
variable "key_vault_name" { type = string }
variable "aks_identity_name" { type = string }
variable "cluster_name" { type = string }
variable "dns_prefix" { type = string }
variable "kubernetes_version" {
  type    = string
  default = null
}
variable "system_node_vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}
variable "system_node_min_count" {
  type    = number
  default = 3
}
variable "system_node_max_count" {
  type    = number
  default = 10
}
variable "service_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
variable "dns_service_ip" {
  type    = string
  default = "10.20.0.10"
}
variable "tags" { type = map(string) }
