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

resource "azuredevops_git_repository" "repo" {
  project_id = azuredevops_project.project.id
  name       = "azure-vm-terraform"

  initialization {
    init_type = "Clean"
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

resource "azuredevops_git_repository_file" "pipeline" {
  repository_id       = azuredevops_git_repository.repo.id
  file                = "azure-pipelines.yml"
  content             = file("${path.module}/azure-pipelines.yml")
  branch              = "refs/heads/main"
  commit_message      = "Add CI/CD pipeline"
  overwrite_on_create = false
}

resource "azuredevops_build_definition" "pipeline" {
  project_id = azuredevops_project.project.id
  name       = "terraform-vm-pipeline"
  path       = "\\"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.repo.id
    branch_name = "refs/heads/main"
    yml_path    = "azure-pipelines.yml"
  }

  depends_on = [azuredevops_git_repository_file.pipeline]
}
