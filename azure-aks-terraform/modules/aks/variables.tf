variable "cluster_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "dns_prefix" { type = string }
variable "kubernetes_version" {
  type    = string
  default = null
}
variable "sku_tier" {
  type    = string
  default = "Standard"
}
variable "system_node_pool_name" {
  type    = string
  default = "system"
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
variable "os_disk_size_gb" {
  type    = number
  default = 128
}
variable "availability_zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}
variable "aks_subnet_id" { type = string }
variable "user_assigned_identity_id" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "acr_id" { type = string }
variable "service_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
variable "dns_service_ip" {
  type    = string
  default = "10.20.0.10"
}
variable "tags" { type = map(string) }
