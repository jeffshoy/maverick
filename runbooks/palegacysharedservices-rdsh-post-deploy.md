# Runbook: PALegacySharedServices RDSH Post-Deploy

**Account:** PALegacySharedServices (`361362055558`)  
**Servers:** INF-WSRDS001–003 (us-east-1) · INF-WSRDS101–103 (us-west-2) · INF-WSSQL001 (us-east-1) · INF-WSSQL101 (us-west-2)  
**Prerequisite:** `terraform apply` complete in both regions via the `cloud-foundation-palegacysharedservices` pipeline.

---

## Step 1 — Verify Domain Join

Each instance has an SSM Association (`AWS-JoinDirectoryServiceDomain`) that runs automatically on launch.

```powershell
# Check association status for all INF-WS* instances
aws ssm list-associations --profile PALegacySharedServices --region us-east-1 `
    --association-filter-list "key=AssociationName,value=AWS-JoinDirectoryServiceDomain" `
    --query "Associations[*].{Name:Name,Status:Overview.Status,Target:Targets}" | ConvertFrom-Json

aws ssm list-associations --profile PALegacySharedServices --region us-west-2 `
    --association-filter-list "key=AssociationName,value=AWS-JoinDirectoryServiceDomain" `
    --query "Associations[*].{Name:Name,Status:Overview.Status,Target:Targets}" | ConvertFrom-Json
```

Expected `Status`: `Success`. If `Failed`: check SSM Agent is running, instance has outbound 443 to AWS endpoints, and directory ID is correct in the association parameters.

Confirm in ADUC that computer objects appear in the correct OUs:
- `cloud.lcl/Cloud/Servers/AWS/Workstations/PALegacyUSE1`
- `cloud.lcl/Cloud/Servers/AWS/Workstations/PALegacyUSW2`

---

## Step 2 — Install RD Session Host Role (RDSH servers only)

Run the Ansible playbook from an AzDo agent that has AWS credentials for PALegacySharedServices.
The playbook installs the RDSH Windows role, reboots if needed, and adds `R_AWSCOMM_SSO_cst-comm-infrdsaccess`
to `Remote Desktop Users` on all servers tagged `cst_application=inf-admin-rdsh`.

```bash
# us-east-1
ansible-playbook ansible/palegacysharedservices-rdsh-setup.yml \
    -i ansible/inventory/aws_ec2.yml \
    -e "aws_region=us-east-1"

# us-west-2
ansible-playbook ansible/palegacysharedservices-rdsh-setup.yml \
    -i ansible/inventory/aws_ec2.yml \
    -e "aws_region=us-west-2"
```

Playbook: `cloudops/ansible/palegacysharedservices-rdsh-setup.yml`  
Passwords pulled automatically from SSM at `/inf/palegacysharedservices/<instance-name>/admin_password`.

---

## Step 3 — Install SSMS (SSMS jump boxes only)

First, upload the SSMS installer to the media bucket if not already present:

```powershell
aws s3 cp SSMS-Setup-ENU.exe s3://cst-comm-palegacysharedservices-media/installers/ `
    --profile PALegacySharedServices
```

Then run the Ansible playbook against servers tagged `cst_application=inf-admin-ssms`:

```bash
# us-east-1
ansible-playbook ansible/palegacysharedservices-ssms-setup.yml \
    -i ansible/inventory/aws_ec2.yml \
    -e "aws_region=us-east-1"

# us-west-2
ansible-playbook ansible/palegacysharedservices-ssms-setup.yml \
    -i ansible/inventory/aws_ec2.yml \
    -e "aws_region=us-west-2"
```

Playbook: `cloudops/ansible/palegacysharedservices-ssms-setup.yml`

---

## Step 4 — AWS License Manager User-Based Subscriptions (UBS / SALs)

This replaces SPLA and the grace-period-reset scripts. Must be done before any user attempts to RDP to an RDSH server — License Manager blocks connections for unregistered users once the 120-day grace period expires.

### 4a — Register the cloud.lcl directory with License Manager

Do this once per region. Requires the Managed AD directory to be fully active.

```powershell
# us-east-1
aws license-manager-user-subscriptions register-identity-provider `
    --profile PALegacySharedServices `
    --region us-east-1 `
    --identity-provider "ActiveDirectory={DirectoryId=d-906672ebcc}" `
    --product "Remote Desktop Services"

# us-west-2 — run after the cloud.lcl directory share is extended to us-west-2
# aws license-manager-user-subscriptions register-identity-provider `
#     --profile PALegacySharedServices `
#     --region us-west-2 `
#     --identity-provider "ActiveDirectory={DirectoryId=<usw2-directory-id>}" `
#     --product "Remote Desktop Services"
```

### 4b — Create the AD access group

In cloud.lcl ADUC, create a security group: `R_AWSCOMM_SSO_cst-comm-infrdsaccess`  
Location: `cloud.lcl/Resources/AWSCOMMSSO`  
Add all users who need RDSH access to this group.

> The Ansible playbook in Step 2 already adds this group to `Remote Desktop Users` on each RDSH server. No manual SSM command is needed here.

### 4c — Subscribe users to License Manager

Subscribe each user individually. The `inf-rdsh-lm-sync` script (TODO: write this script) automates this by syncing `R_AWSCOMM_SSO_cst-comm-infrdsaccess` group membership against current subscriptions. Until the script exists, run manually:

```powershell
$users = Get-ADGroupMember -Identity "R_AWSCOMM_SSO_cst-comm-infrdsaccess" -Recursive | Select-Object -ExpandProperty SamAccountName

foreach ($user in $users) {
    aws license-manager-user-subscriptions start-product-subscription `
        --profile PALegacySharedServices `
        --region us-east-1 `
        --identity-provider "ActiveDirectory={DirectoryId=d-906672ebcc}" `
        --product "Remote Desktop Services" `
        --username $user `
        --domain "cloud.lcl"
    Write-Host "Subscribed: $user"
}
```

### 4d — Verify LM UBS SSM Association

The `AWS-LicenseManager-UserSubscriptionsHandler` SSM Association (created by Terraform) must show `Success` on each RDSH instance. This association configures the instance to report active sessions back to License Manager for billing.

```powershell
aws ssm list-associations --profile PALegacySharedServices --region us-east-1 `
    --association-filter-list "key=AssociationName,value=AWS-LicenseManager-UserSubscriptionsHandler" `
    --query "Associations[*].{Name:Name,Status:Overview.Status}" | ConvertFrom-Json
```

---

## Step 5 — Verify RDP Access

Use the `/rdp` skill to test access to each server:
```
/rdp INF-WSRDS001 <your-cloud-lcl-account>
/rdp INF-WSSQL001 <your-cloud-lcl-account>
```

Confirm:
- [ ] Domain join succeeded (server name resolves as `INF-WSRDS001.cloud.lcl`)
- [ ] RDP session establishes without license warnings
- [ ] License Manager console shows the user as subscribed after login

---

## Step 6 — Verify us-west-2 Directory Share

The cloud.lcl Managed AD directory (`d-906672ebcc`, prdcomm.cloud.lcl) is confirmed active in both us-east-1 and us-west-2 with cross-region enabled. No action required before the secondary apply.

```powershell
# Verification only — should show d-906672ebcc Active in both regions
aws ds describe-directories --profile PALegacySharedServices --region us-east-1 --query "DirectoryDescriptions[*].{ID:DirectoryId,Name:Name,Stage:Stage}"
aws ds describe-directories --profile PALegacySharedServices --region us-west-2 --query "DirectoryDescriptions[*].{ID:DirectoryId,Name:Name,Stage:Stage}"
```

---

## Ongoing: User Access Management

Add/remove users from `R_AWSCOMM_SSO_cst-comm-infrdsaccess` in cloud.lcl ADUC.

Until the `inf-rdsh-lm-sync` script is running on a schedule, also manually sync to License Manager using the Step 4c command whenever the group changes. Users not subscribed in License Manager will be blocked from RDSH sessions once the grace period expires.
