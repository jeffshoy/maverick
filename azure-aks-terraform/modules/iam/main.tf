resource "azurerm_user_assigned_identity" "aks" {
  name                = var.identity_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}
