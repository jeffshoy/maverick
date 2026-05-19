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
