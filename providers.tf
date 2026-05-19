terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "~> 1.3"
    }
  }
  required_version = ">= 1.3.0"
}

provider "azurerm" {
  features {}
}

provider "azuredevops" {
  # Reads AZDO_ORG_SERVICE_URL and AZDO_PERSONAL_ACCESS_TOKEN from environment
}
