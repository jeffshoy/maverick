resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

module "networking" {
  source              = "../../modules/networking"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  vnet_name           = var.vnet_name
  address_space       = var.address_space
  aks_subnet_name     = var.aks_subnet_name
  aks_subnet_prefixes = var.aks_subnet_prefixes
  nsg_name            = var.nsg_name
  tags                = var.tags
}

module "monitoring" {
  source              = "../../modules/monitoring"
  workspace_name      = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

module "acr" {
  source              = "../../modules/acr"
  acr_name            = var.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku                 = var.acr_sku
  tags                = var.tags
}

module "keyvault" {
  source              = "../../modules/keyvault"
  key_vault_name      = var.key_vault_name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

module "iam" {
  source              = "../../modules/iam"
  identity_name       = var.aks_identity_name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

module "aks" {
  source                     = "../../modules/aks"
  cluster_name               = var.cluster_name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  dns_prefix                 = var.dns_prefix
  kubernetes_version         = var.kubernetes_version
  system_node_vm_size        = var.system_node_vm_size
  system_node_min_count      = var.system_node_min_count
  system_node_max_count      = var.system_node_max_count
  aks_subnet_id              = module.networking.aks_subnet_id
  user_assigned_identity_id  = module.iam.identity_id
  log_analytics_workspace_id = module.monitoring.workspace_id
  acr_id                     = module.acr.acr_id
  service_cidr               = var.service_cidr
  dns_service_ip             = var.dns_service_ip
  tags                       = var.tags
}
