# AWS WorkSpaces VDI — Terraform

Two-layer design, same principle you already use for EC2 remediation: separate
things that change rarely (network, directory, security posture) from things
that churn constantly (individual user WorkSpaces), so drift and blast radius
stay contained.

```
vdi-terraform/
├── platform/     # VPC, subnets, NAT, Directory Service, IP groups, monitoring
│                 # -> deploy once, changes rarely, tightly reviewed
└── fleet/        # Individual aws_workspaces_workspace resources per user
                  # -> changes constantly (onboarding/offboarding)
```

## Deploy order

### 1. Platform layer

```bash
cd platform
cp terraform.tfvars.example terraform.tfvars   # not included above — build your own from variables.tf
terraform init
terraform plan
terraform apply
```

Required before you can apply:
- A Secrets Manager secret containing the directory admin (Managed AD) or
  AD Connector service-account password. Pass its ARN via
  `directory_admin_password_secret_arn`.
- If `directory_type = "ad_connector"`: `onprem_dns_ips` and
  `connect_ad_service_account_username`, plus a working VPN/Direct Connect
  path to your on-prem AD (the `onprem_ad_cidr` route in `networking.tf` has
  a placeholder `gateway_id` you must replace with your real VGW/TGW
  attachment).
- `allowed_client_cidrs` — your office and VPN egress IP ranges. Nothing
  outside this list can reach a WorkSpace, regardless of AD credentials.

Capture the outputs — the fleet layer needs `workspaces_directory_id`.

### 2. Bundle / golden image (outside Terraform)

Either use an AWS-managed bundle ID directly, or build a custom one:
1. Launch an EC2 instance (or existing WorkSpace) as your build base.
2. Install baseline apps, AV/EDR agent, SSM agent, any org-standard tooling.
3. Capture as a WorkSpaces bundle via the console or
   `aws workspaces create-workspace-image` / `create-workspace-bundle`.
4. Feed the resulting `wsb-xxxxxxxxx` ID into the fleet layer's
   `bundle_id` variable.

This is the piece worth automating next with EC2 Image Builder if you're
doing it more than a couple of times a year.

### 3. Fleet layer

```bash
cd ../fleet
cp terraform.tfvars.example terraform.tfvars
# fill in workspaces_directory_id (from platform output), bundle_id, and users{}
terraform init
terraform plan
terraform apply
```

## Notes / things to adapt before production

- **Egress**: `networking.tf` provisions a plain NAT Gateway per AZ. If
  CentralSquare routes egress through an existing inspected
  proxy/firewall appliance, swap the NAT route for a route to that
  appliance instead — don't run two separate egress paths.
- **State backend**: both layers have a commented `backend "s3"` block —
  point these at your existing S3/DynamoDB state bucket (same pattern as
  your EC2 remediation Terraform) rather than local state.
- **High-churn onboarding**: the `fleet/main.tf` `for_each` over `var.users`
  works fine for a stable population, but past a few hundred users, wire
  create/delete to a Lambda triggered by your HR/ITSM system instead —
  Terraform state reconciliation gets slow and risky at that scale for
  resources that change daily.
- **MFA**: not shown here — configure via IAM Identity Center federation or
  RADIUS on the directory (`aws_workspaces_directory` supports a
  `saml_properties` / `certificate_based_auth_properties` block if you go
  the SAML/cert route — add once you've decided the auth path).
- **Group Policy for drive/clipboard/printer redirection**: applied via
  WorkSpaces ADMX templates on the AD side, not something Terraform manages
  — track as a manual/GPO-tooling step, common audit finding if skipped.
