terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-core"
    storage_account_name = "sttfstatemaverick"
    container_name       = "tfstate"
    key                  = "aks/dev/terraform.tfstate"
  }
}
