---
name: observabilitysetup
description: Onboard a new client into the cloud-observability Terraform repo. Looks up the account ID from accounts.json, discovers VPC subnet/SG from AWS, verifies canary DNS via SSM, creates all tfvars files (shared, fe-alarms, fe-cloudwatch-agent, fe-synthetics, dashboards) plus the slo-dashboards entry in the central obs account (510978032531), commits to a feature branch in cloud-observability, and opens a PR. Use when setting up CloudWatch alarms, dashboards, and synthetics for a new client (e.g. "/observabilitysetup finentlegacy cow", "/observabilitysetup finentlegacy belt").
---

# /observabilitysetup — Onboard a new client into cloud-observability

## Arguments

```
/observabilitysetup <product> <clientcode>
```

- **product**: the product line. Currently supported: `finentlegacy`
- **clientcode**: short client code in any case (e.g. `cow`, `COW`, `BELT`)

If either argument is missing, ask before proceeding.

## Product definitions

### finentlegacy

| Setting | Value |
|---|---|
| Account name pattern | `PALegacyFinEnt<CLIENTCODE>` (uppercase) |
| accounts.json lookup | Match `name` field exactly |
| cst_application | `financeenterprise` |
| cst_product_line | `pa_financeenterprise` |
| cst_cost_center | `<clientcode>` (lowercase) |
| cst_tenant | `<clientcode>` (lowercase) |
| instance_name_prefix | `<CLIENTCODE>-` (uppercase) |
| cst_name (alarms) | `fe-<clientcode>-alarms` (lowercase) |
| stack_name (dashboards) | `fe-<clientcode>` (lowercase) |
| PagerDuty integration key | `6852b45b3dd14d08c06c22148c356f84` (shared, all finentlegacy clients) |
| Canary hostname pattern | `<clientcode>-rpt.<clientcode>cloud.aspgov.com`, `<clientcode>-job.<clientcode>cloud.aspgov.com`, `<clientcode>-app.<clientcode>cloud.aspgov.com` (all lowercase) |
| Canary paths | `/Cognos11`, `/Production`, `/Finance/edge` |
| notification_emails | `CloudSysAdmin@centralsquare.com`, `cloud-pa-observability@centralsquare.com` |

## Steps

### 1. Resolve account

Look up `PALegacyFinEnt<CLIENTCODE>` in `C:\Users\kevin.sloan\.aws\repos\cloudops\aws-configs\accounts.json` (field: `accounts[].name`). Extract `accountId` and `profile`. If no match is found, stop and report the error — do not guess.

### 2. Determine region

Run:
```powershell
aws ec2 describe-availability-zones --profile <profile> --query "AvailabilityZones[0].RegionName" --output text
```
Use the returned region for all subsequent AWS calls and for `aws_region` in `shared.tfvars`.

### 3. Pick subnet and security group for synthetics

Run:
```powershell
aws ec2 describe-subnets --region <region> --profile <profile> `
  --query "Subnets[?Tags[?Key=='Name']].{SubnetId:SubnetId,Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock}" `
  --output json
```

Select the subnet whose Name tag matches `pri-sub-1-servers*`. If multiple match, pick the one with the lowest CIDR. If none match, pick the first private subnet (non-`aws-controltower` preferred) and note the choice.

Run:
```powershell
aws ec2 describe-security-groups --region <region> --profile <profile> `
  --query "SecurityGroups[*].{GroupId:GroupId,Name:GroupName}" --output json
```

Select the SG named `SG-<clientcode>` (case-insensitive). If not found, fall back to the SG named `default` in the main VPC. Note the choice.

### 4. Verify canary DNS via SSM

Find a running instance to use as a DNS probe:
```powershell
aws ec2 describe-instances --region <region> --profile <profile> `
  --filters "Name=instance-state-name,Values=running" `
  --query "Reservations[*].Instances[*].{InstanceId:InstanceId,Name:Tags[?Key=='Name']|[0].Value}" `
  --output json
```

Prefer an app server (`*PONSAP*`) for the probe. Fall back to any running instance.

Send an SSM command to resolve the three canary hostnames:
```powershell
aws ssm send-command --region <region> --profile <profile> `
  --instance-ids "<instance-id>" `
  --document-name "AWS-RunPowerShellScript" `
  --parameters 'commands=["@(\"<rpt-host>\",\"<job-host>\",\"<app-host>\") | ForEach-Object { try { $r=Resolve-DnsName $_ -ErrorAction Stop | Select-Object -First 1; \"$_ => $($r.IPAddress)\" } catch { \"$_ => FAILED\" } }"]' `
  --query "Command.CommandId" --output text
```

Wait for completion (poll with `aws ssm get-command-invocation` until Status is `Success` or `Failed`, max 30s). 

- If all three resolve: use the derived URLs.
- If any fail: report which ones failed, ask the user to supply the correct hostname(s) before continuing.

### 5. Check if account directory already exists

Check whether `C:\Users\kevin.sloan\.aws\repos\cloud-observability\terraform\account\<accountId>\` already exists. If it does, stop and warn — this client may already be onboarded. Ask the user to confirm before overwriting anything.

### 6. Create the branch in cloud-observability

```powershell
cd C:\Users\kevin.sloan\.aws\repos\cloud-observability
git checkout main
git pull
git checkout -b feature/observabilitysetup-<clientcode>
```

### 7. Write tfvars files

Create the directory `terraform/account/<accountId>/` and write these five files using the product definition values and the discovered region, accountId, subnet, SG, and canary URLs.

#### shared.tfvars
```hcl
# Account-level shared variables — AWS account <accountId> (<accountName>)
# ... (standard header)

aws_region  = "<region>"
account_id  = "<accountId>"
environment = "prod"

cst_application       = "financeenterprise"
cst_cost_center       = "<clientcode_lower>"
cst_compliance_domain = "none"
cst_environment       = "prd"
cst_product_line      = "pa_financeenterprise"
cst_tenancy           = "single"
cst_tenant            = "<clientcode_lower>"
cst_repo              = "cloud-observability-repo"
cst_backup_policy     = "prod"
```

#### fe-alarms.tfvars
Mirror `terraform/account/880961130429/fe-alarms.tfvars` exactly, substituting:
- `cst_name` → `fe-<clientcode_lower>-alarms`
- `instance_name_prefix` → `<CLIENTCODE_UPPER>-`
- `critical_notification_https_endpoints` → PagerDuty key from product definition

#### fe-iam-roles.tfvars
Create as an empty file. The `fe/iam-roles` module sources all values from `shared.tfvars` — no module-specific variables are required. The file must exist for the pipeline to run the module.

#### fe-cloudwatch-agent.tfvars
Copy verbatim from `terraform/account/880961130429/fe-cloudwatch-agent.tfvars` — the server roles and log paths are identical across all finentlegacy clients.

#### fe-synthetics.tfvars
Mirror `terraform/account/880961130429/fe-synthetics.tfvars`, substituting:
- `vpc_subnet_ids` → discovered subnet
- `vpc_security_group_ids` → discovered SG
- `canary_endpoints` → derived and DNS-verified URLs
- Add a comment noting the DNS verification date and instance used

#### dashboards.tfvars
Mirror `terraform/account/880961130429/dashboards.tfvars`, substituting:
- `stack_name` → `fe-<clientcode_lower>`
- `tenant` → `<clientcode_lower>`

### 8. Add slo-dashboards entry in central obs account

Edit `terraform/account/510978032531/slo-dashboards.tfvars` and add a new entry to the `dashboards` map immediately before the closing `}`. Mirror the COSM entry (key `"880961130429"`) substituting:
- Map key → `"<accountId>"`
- `tenant` → `<clientcode_lower>`
- `cst_name` → `fe-<clientcode_lower>-slo-dashboard-<accountId>`
- `cst_cost_center` / `cst_tenant` → `<clientcode_lower>`
- Canary keys → `<clientcode_lower>-fe-fe-app`, `<clientcode_lower>-fe-fe-job`, `<clientcode_lower>-fe-cognos`
- `baseline_only_roles` → `["job_server"]`

### 9. Commit

```
git add terraform/account/<accountId>/
git add terraform/account/510978032531/slo-dashboards.tfvars
git commit -m "feat(fe-account): deploy FinanceEnterprise observability to <accountName> (<accountId>)"
```

### 10. Push and create PR

```powershell
git push -u origin feature/observabilitysetup-<clientcode>
```

Then create the PR using the cloudops wrapper:
```powershell
# Write description to temp file, then:
& 'C:\Users\kevin.sloan\.aws\repos\cloudops\scripts\azdo\New-PR.ps1' `
    -Title "feat(fe-account): deploy FinanceEnterprise observability to <accountName>" `
    -DescriptionFile "C:\Temp\pr-observabilitysetup-<clientcode>.md" `
```

Pass these flags explicitly to `az repos pr create` (the wrapper auto-detects repo from git context, but cloud-observability uses SSH remotes so pass explicitly):
- `--repository cloud-observability`
- `--org https://dev.azure.com/psgov`
- `--project "Cloud Foundation"`

PR description template:
```markdown
## Summary
- Deploy full FinanceEnterprise observability stack for <accountName> (<accountId>)
- Includes: shared tags, fe-alarms (PagerDuty critical), fe-cloudwatch-agent, fe-synthetics (canaries DNS-verified via SSM), and dashboards
- Mirrors PALegacyFinEntCOSM (880961130429) account structure

## Test plan
- [ ] `terraform plan` for all five modules against account <accountId> — confirm clean plan with expected resource counts
- [ ] After apply: confirm SNS topics created, canaries healthy, dashboards visible in CloudWatch console
- [ ] After apply: confirm PagerDuty receives test alarm trigger and OK resolution on the critical SNS topic

## Blast radius
- Net-new account deployment — no existing resources modified
- Canary DNS verified via SSM on <probe-instance> (<date>)
```

### 11. Report

Print a summary:
- Account: `<accountName>` (`<accountId>`)
- Region: `<region>`
- Files created: list all five
- Subnet: `<subnetId>` (`<subnetName>`)
- Security group: `<sgId>` (`<sgName>`)
- Canary DNS: all three hostnames → IP
- Branch: `feature/observabilitysetup-<clientcode>`
- PR URL

## Examples

```
/observabilitysetup finentlegacy cow
/observabilitysetup finentlegacy belt
/observabilitysetup finentlegacy cosm   ← will stop at step 5 (already exists)
```

## Error cases

| Condition | Action |
|---|---|
| Account not found in accounts.json | Stop, report. Ask user to verify the client code. |
| Account directory already exists | Stop, warn. Ask user to confirm overwrite. |
| Canary DNS resolution fails | Report which hostnames failed. Ask user to supply correct values. |
| Subnet `pri-sub-1-servers*` not found | Use best fallback, note the choice prominently in output. |
| SG `SG-<clientcode>` not found | Use `default` SG fallback, note prominently. |
| SSM command times out | Report timeout. Ask user to supply canary IPs manually or retry. |
