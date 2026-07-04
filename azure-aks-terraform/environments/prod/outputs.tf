output "resource_group_name" { value = azurerm_resource_group.this.name }
output "aks_cluster_name" { value = module.aks.cluster_name }
output "acr_login_server" { value = module.acr.acr_login_server }
output "key_vault_uri" { value = module.keyvault.key_vault_uri }
output "aks_oidc_issuer_url" { value = module.aks.oidc_issuer_url }
