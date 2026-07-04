location            = "eastus"
resource_group_name = "rg-dev-eastus-aks"

vnet_name           = "vnet-dev-eastus-aks"
address_space       = ["10.10.0.0/16"]
aks_subnet_name     = "snet-dev-eastus-aks"
aks_subnet_prefixes = ["10.10.1.0/24"]
nsg_name            = "nsg-dev-eastus-aks"

log_analytics_workspace_name = "law-dev-eastus-aks"
log_retention_days           = 30

# Must be globally unique and only lowercase letters/numbers.
acr_name       = "acrdeveastusaks001"
acr_sku        = "Standard"
key_vault_name = "kv-dev-eastus-aks001"

aks_identity_name = "id-dev-eastus-aks"
cluster_name      = "aks-dev-eastus-core"
dns_prefix        = "aks-dev-eastus-core"

system_node_vm_size   = "Standard_D4s_v5"
system_node_min_count = 3
system_node_max_count = 10

service_cidr   = "10.20.0.0/16"
dns_service_ip = "10.20.0.10"

tags = {
  environment = "dev"
  platform    = "aks"
  owner       = "cloud-engineering"
  managed_by  = "terraform"
}
