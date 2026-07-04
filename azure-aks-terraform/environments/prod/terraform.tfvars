location            = "eastus"
resource_group_name = "rg-prod-eastus-aks"

vnet_name           = "vnet-prod-eastus-aks"
address_space       = ["10.30.0.0/16"]
aks_subnet_name     = "snet-prod-eastus-aks"
aks_subnet_prefixes = ["10.30.1.0/23"]
nsg_name            = "nsg-prod-eastus-aks"

log_analytics_workspace_name = "law-prod-eastus-aks"
log_retention_days           = 90

# Must be globally unique and only lowercase letters/numbers.
acr_name       = "acrprodeastusaks001"
acr_sku        = "Premium"
key_vault_name = "kv-prod-eastus-aks001"

aks_identity_name = "id-prod-eastus-aks"
cluster_name      = "aks-prod-eastus-core"
dns_prefix        = "aks-prod-eastus-core"

system_node_vm_size   = "Standard_D4s_v5"
system_node_min_count = 3
system_node_max_count = 10

service_cidr   = "10.40.0.0/16"
dns_service_ip = "10.40.0.10"

tags = {
  environment = "prod"
  platform    = "aks"
  owner       = "cloud-engineering"
  managed_by  = "terraform"
}
