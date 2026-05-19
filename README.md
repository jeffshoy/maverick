# Azure Windows Server 2022 VM - Terraform

Deploys a basic Windows Server 2022 VM in Azure with all required networking.

## Resources Created

| Resource | Description |
|---|---|
| Resource Group | Container for all resources |
| Virtual Network | 10.0.0.0/16 address space |
| Subnet | 10.0.1.0/24 |
| Public IP | Static public IP for RDP access |
| Network Security Group | Allows inbound RDP (port 3389) |
| Network Interface | NIC attached to subnet + NSG |
| Windows VM | Windows Server 2022 Datacenter |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in
- An active Azure subscription

## Usage

### 1. Authenticate to Azure
```bash
az login
az account set --subscription "<your-subscription-id>"
```

### 2. Configure your variables
You can use the generic sample or an environment-specific landing zone.

- Use a one-off variables file:
  ```bash
  cp terraform.tfvars.example terraform.tfvars
  ```
  Edit `terraform.tfvars` and set your desired values, especially `admin_password`.

- Or use the landing zone files already provided:
  - `dev.tfvars`
  - `prod.tfvars`

  Edit the `admin_password` values before use.

### 3. Deploy
Initialize once, then plan/apply with the chosen landing zone:
```bash
terraform init
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

For production:
```bash
terraform plan -var-file=prod.tfvars
terraform apply -var-file=prod.tfvars
```

### 4. Connect via RDP
After apply completes, use the output `public_ip_address` to RDP into the VM:
- **Host:** `<public_ip_address>`
- **Username:** value of `admin_username` (default: `azureadmin`)
- **Password:** value you set for `admin_password`

### 5. Destroy when done
```bash
terraform destroy
```

## VM Size Options

| Size | vCPUs | RAM | Notes |
|---|---|---|---|
| Standard_B2s | 2 | 4 GB | Default — low cost dev/test |
| Standard_B4ms | 4 | 16 GB | Light workloads |
| Standard_D4s_v3 | 4 | 16 GB | General purpose production |

Change `vm_size` in `terraform.tfvars` to adjust.

## Security Note

The NSG currently allows RDP from **any IP**. For production use, restrict `source_address_prefix` in `main.tf` to your specific IP:
```hcl
source_address_prefix = "YOUR.IP.ADDRESS/32"
```
