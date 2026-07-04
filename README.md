# Azure AKS Terraform Starter Repo

This repository builds a production-style Azure AKS foundation using Terraform modules and environment-specific folders.

## What it creates

- Resource Group
- Virtual Network and AKS subnet
- Azure Container Registry
- Log Analytics Workspace
- Azure Key Vault
- User Assigned Managed Identity
- AKS cluster with autoscaling node pool
- Azure CNI networking
- Azure Monitor integration
- Role assignment for AKS to pull from ACR

## Folder Structure

```text
aks-azure-terraform/
├── environments/
│   ├── dev/
│   └── prod/
├── modules/
│   ├── networking/
│   ├── aks/
│   ├── acr/
│   ├── monitoring/
│   ├── keyvault/
│   └── iam/
└── scripts/
```

## Deploy

```bash
cd environments/dev
terraform init
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

## Connect to AKS

```bash
../../scripts/get-credentials.sh rg-dev-eastus-aks aks-dev-eastus-core
kubectl get nodes
```

## Configure cluster after Terraform

```bash
../../scripts/create-namespaces.sh
../../scripts/install-nginx-ingress.sh
../../scripts/deploy-sample-app.sh
```

## Notes

Update `terraform.tfvars` values before deploying. Resource names must be globally unique where required, especially Azure Container Registry names and Key Vault names.
