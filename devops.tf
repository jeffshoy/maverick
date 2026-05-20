resource "azuredevops_project" "project" {
  name               = var.devops_project_name
  description        = "Azure VM infrastructure managed by Terraform"
  visibility         = "private"
  version_control    = "Git"
  work_item_template = "Agile"

  features = {
    boards       = "enabled"
    repositories = "enabled"
    pipelines    = "enabled"
    artifacts    = "disabled"
  }
}

resource "azuredevops_variable_group" "terraform_vars" {
  project_id   = azuredevops_project.project.id
  name         = "terraform-vars"
  description  = "Terraform pipeline variables"
  allow_access = true

  variable {
    name  = "ARM_CLIENT_ID"
    value = var.devops_service_principal_id
  }

  variable {
    name         = "ARM_CLIENT_SECRET"
    secret_value = var.devops_service_principal_key
    is_secret    = true
  }

  variable {
    name  = "ARM_SUBSCRIPTION_ID"
    value = var.azure_subscription_id
  }

  variable {
    name  = "ARM_TENANT_ID"
    value = var.azure_tenant_id
  }

  variable {
    name  = "AZDO_ORG_SERVICE_URL"
    value = "https://dev.azure.com/jazurehoy"
  }

  variable {
    name         = "AZDO_PERSONAL_ACCESS_TOKEN"
    secret_value = var.devops_pat
    is_secret    = true
  }
}

resource "azuredevops_serviceendpoint_azurerm" "azure_svc" {
  project_id            = azuredevops_project.project.id
  service_endpoint_name = "Azure-Service-Connection"
  description           = "Terraform deployment service connection"

  credentials {
    serviceprincipalid  = var.devops_service_principal_id
    serviceprincipalkey = var.devops_service_principal_key
  }

  azurerm_spn_tenantid      = var.azure_tenant_id
  azurerm_subscription_id   = var.azure_subscription_id
  azurerm_subscription_name = var.azure_subscription_name
}
