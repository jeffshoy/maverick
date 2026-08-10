# FE Legacy Cognos — Client Deployment Runbook

## Overview

This document covers deploying a Cognos 11.2.4 Linux instance to an FE 1.0 legacy
client from the golden AMI. This is the per-client process that runs after the AMI
build is complete.

**Golden AMIs (owned by PALegacySharedServices - 361362055558):**
- us-west-2: `ami-06dfdbf3cac70c6a7` (v1.4)
- us-east-1: `ami-04a1a6ee507695289` (v1.4)

**KMS Keys (shared services, grant access to all PALegacyFinEnt accounts):**
- us-west-2: `arn:aws:kms:us-west-2:361362055558:key/f17195a0-525f-49be-b625-9fa79e4b0d01`
- us-east-1: `arn:aws:kms:us-east-1:361362055558:key/1167100c-cd4f-4e70-acda-9917a7756cb3`

**Naming Convention:** `{CLIENT}-{ENV}ONSLRP{NUM}` — this is the naming convention for the new
Linux Cognos instances deployed from this AMI.
- Test: `{CLIENT}-TONSLRP001`
- Prod: `{CLIENT}-PONSLRP001`

Note: this is distinct from the existing Windows Cognos naming pattern (e.g. `ISB-PONSRP001`,
no "L"), which refers to the legacy Windows instance being migrated away from, not the new
Linux replacement.

**Prerequisite for every deployment:** a domain admin account must already exist in the
**client's own AD bubble domain** (`{client}.cloud.lcl`) before starting — this is a separate
account per client, not a shared/central credential. Confirm one exists (or get it
provisioned) before launching the instance, since domain join immediately follows.

---

## Automation (Preferred)

Instance launch, hostname, password rotation, and internal DNS records are automated by the
`/fe-cognos-linux-deploy` skill (`.claude/skills/fe-cognos-linux-deploy/SKILL.md`, wrapping
`scripts/fe-cognos-linux/Invoke-FeCognosLinuxDeploy.ps1`):

```
/fe-cognos-linux-deploy ANCO east Test
```

**Inputs:** Client code, Region, Environment — any omitted are prompted for interactively.
VPC/Subnet/Security Group/IAM role are **not** supplied; the skill discovers them from an
existing `{CLIENT}-*ONSRP*` report server (or `{CLIENT}-*ONSJB*` job server fallback) in the
same account.

**Automated:**
1. Launch instance from golden AMI (v1.2 — Tanium and domain-join packages pre-installed)
2. Wait for SSM to come online
3. Set hostname (`{CLIENT}-{ENV}ONSLRP001`)
4. Set passwords (generate unique, store in Parameter Store)
5. Create internal DNS A records (Step 5 below) on the client's domain controller — no
   domain admin credential needed, since the DC's own machine account can update zones it
   hosts. If the DC can't be found or a record fails, the skill warns and continues rather
   than aborting; check the summary for what needs to be done manually.

**Domain join is intentionally NOT automated** — interactive credential prompts don't work
reliably across every surface this skill may run from, so this is always a manual step
performed immediately after the skill finishes. The skill's summary prints the exact
commands (Step 6 below) pre-filled with the instance ID and domain.

**Still manual after running the skill:** domain join (Step 6), moving the computer object
to the client's AD OU (Step 7), proxy (pre-baked into the AMI — no action needed), security
tooling verification (Step 9 — already resolved, no action needed), handing off for Cognos
configuration (Step 10), and validation (Step 11) — see below.

---

## Manual Steps

Use this section end-to-end if Claude/the skill isn't set up, or to complete the steps the
skill doesn't automate (domain join onward, every time).

### Prerequisites

- Client account must be in the AMI share list — if not, see Troubleshooting below
- Domain admin account in the client's own AD bubble domain (see note above)
- VPC ID, subnet ID, security group ID, and IAM instance profile — the skill discovers these
  automatically; doing this manually, see Step 0 below to find them from an existing instance

### Step 0 — Find VPC/Subnet/Security Group/IAM Role from a Reference Instance

The skill discovers these automatically; doing it manually means finding an existing
instance in the same client account/region and copying its network/IAM config. Look for a
report server first, falling back to a job server if none exists — same lookup order the
skill uses:

```powershell
$profile = "PALegacyFinEnt{CLIENT}"
$region = "us-east-1"  # or us-west-2

# First choice: report server ({CLIENT}-*ONSRP*, any environment)
aws ec2 describe-instances --profile $profile --region $region `
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values={CLIENT}-*ONSRP*" `
    --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceId,SubnetId,VpcId,IamInstanceProfile.Arn,join(',', SecurityGroups[].GroupId)]" `
    --output table

# Fallback: job server ({CLIENT}-*ONSJB*) if no report server is found
aws ec2 describe-instances --profile $profile --region $region `
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values={CLIENT}-*ONSJB*" `
    --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceId,SubnetId,VpcId,IamInstanceProfile.Arn,join(',', SecurityGroups[].GroupId)]" `
    --output table
```

If either query returns more than one instance, pick any one — they should share the same
VPC/Subnet/Security Group/IAM role within an account. Use the returned `SubnetId`,
`SecurityGroups` (the GroupId column), and the last segment of `IamInstanceProfile.Arn` (the
profile name) as `$subnet`, `$sg`, and the `--iam-instance-profile Name=...` value in Step 1
below.

### Step 1 — Launch Instance

Tags include a set that's identical across every client (generic), a set that depends on
Prod vs Test (environment), and a set unique to this client (client-specific) — same three
tiers the skill applies automatically. See the Tagging section in
`.claude/skills/fe-cognos-linux-deploy/SKILL.md` for the source of each value.

```powershell
# Replace variables with client-specific values
$profile = "PALegacyFinEnt{CLIENT}"
$region = "us-east-1"  # or us-west-2
$ami = "ami-04a1a6ee507695289"  # east; use ami-06dfdbf3cac70c6a7 for west
$subnet = "subnet-XXXXXXXXX"
$sg = "sg-XXXXXXXXX"
$name = "{CLIENT}-TONSLRP001"  # or PONSLRP001 for prod
$clientCode = "{CLIENT}"       # e.g. ANCO
$envTag = "tst"                # or "prd" for prod
$backupPolicy = "nonprod"      # or "prod" for prod

$tags = "ResourceType=instance,Tags=[" +
    "{Key=Name,Value=$name}," +
    "{Key=cst_name,Value=$name}," +
    "{Key=cst_cost_center,Value=$clientCode}," +
    "{Key=cst_tenant,Value=$($clientCode.ToLower())}," +
    "{Key=cst_environment,Value=$envTag}," +
    "{Key=cst_backup_policy,Value=$backupPolicy}," +
    "{Key=cst_compliance_domain,Value=pci}," +
    "{Key=cst_product_line,Value=pa_financeenterprise}," +
    "{Key=cst_tenancy,Value=single}," +
    "{Key=DataDog,Value=enabled}," +
    "{Key=CloudWatchAgent,Value=enabled}," +
    "{Key=cst_application,Value=report_server}]"

aws ec2 run-instances --profile $profile --region $region --image-id $ami --instance-type r6a.xlarge --subnet-id $subnet --security-group-ids $sg --iam-instance-profile Name=EC2-Default-SSM-AD-Role --block-device-mappings "[{`"DeviceName`":`"/dev/sda1`",`"Ebs`":{`"VolumeSize`":100,`"VolumeType`":`"gp3`",`"Encrypted`":true}}]" --tag-specifications $tags --output json
```

### Step 2 — Connect via SSM

```powershell
aws ssm start-session --profile $profile --region $region --target i-XXXXXXXXX
```

### Step 3 — Set Hostname

```bash
sudo hostnamectl set-hostname {CLIENT}-TONSLRP001
```

### Step 4 — Set Passwords

```bash
echo "ubuntu-admin:{UNIQUE_PASSWORD}" | sudo chpasswd
echo "ubuntu:{UNIQUE_PASSWORD}" | sudo chpasswd
```

Store the password in SSM Parameter Store:

```powershell
aws ssm put-parameter --profile $profile --region $region --name "/tenant/{client}-tst-fe/cognoslx/admin_password" --type SecureString --value "{UNIQUE_PASSWORD}" --description "ubuntu-admin password for {CLIENT} Cognos Linux instance"
```

(Use `{client}-prd-fe` instead of `{client}-tst-fe` for a Prod instance.)

### Step 5 — Create Internal DNS Records

Two A records are created on the client's own domain controller, both pointing at the
instance's private IP. This runs via SSM as SYSTEM directly on the DC — no domain admin
credential needed, since a DC's machine account can already write to zones it hosts (unlike
the AD OU move in Step 7, which is a cross-object permission and does need one).

First, find the client's DC (some clients have more than one — any works, they share zones):

```powershell
aws ec2 describe-instances --profile $profile --region $region `
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values={CLIENT}-*PDC00*" `
    --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceId]" `
    --output table
```

Then get the new instance's private IP:

```powershell
aws ec2 describe-instances --profile $profile --region $region --instance-ids i-XXXXXXXXX `
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text
```

Run against the DC instance ID found above (idempotent — checks for an existing record
before creating, never overwrites):

```powershell
$dcInstanceId = "i-XXXXXXXXX"  # the client's DC, from the lookup above
$privateIp = "10.X.X.X"        # from the lookup above
$computerName = "{CLIENT}-TONSLRP001"  # or PONSLRP001 for prod
$aspgovRecordName = "{client}-rptlnx-tst"  # or "{client}-rptlnx" for prod

$dnsCommands = @(
    "Import-Module DnsServer",
    "if (-not (Get-DnsServerResourceRecord -ZoneName '{client}.cloud.lcl' -ComputerName 'localhost' -Name '$computerName' -ErrorAction SilentlyContinue)) { Add-DnsServerResourceRecordA -ZoneName '{client}.cloud.lcl' -ComputerName 'localhost' -Name '$computerName' -IPv4Address '$privateIp'; Write-Output 'A_RECORD_CREATED' } else { Write-Output 'A_RECORD_EXISTS' }",
    "if (-not (Get-DnsServerResourceRecord -ZoneName '{client}cloud.aspgov.com' -ComputerName 'localhost' -Name '$aspgovRecordName' -ErrorAction SilentlyContinue)) { Add-DnsServerResourceRecordA -ZoneName '{client}cloud.aspgov.com' -ComputerName 'localhost' -Name '$aspgovRecordName' -IPv4Address '$privateIp'; Write-Output 'A_RECORD_CREATED' } else { Write-Output 'A_RECORD_EXISTS' }"
)
$paramsJson = ConvertTo-Json @{ commands = $dnsCommands } -Compress

aws ssm send-command --profile $profile --region $region --instance-ids $dcInstanceId `
    --document-name AWS-RunPowerShellScript --parameters $paramsJson `
    --comment "Create DNS A records for $computerName" --output json
```

**Naming convention for the second zone** (`{client}cloud.aspgov.com`): the record name is
`{client}-rptlnx` for Prod / `{client}-rptlnx-tst` for Test — confirmed for ANCO (2026-08-06)
as the standard going forward, distinct from the existing Windows report-server naming
(`anco-rpt` / `anco-rpt-tst`).

Verify both records on the DC:

```powershell
$verifyCommands = @("Get-DnsServerResourceRecord -ZoneName '{client}.cloud.lcl' -Name '$computerName'")
$verifyParamsJson = ConvertTo-Json @{ commands = $verifyCommands } -Compress

aws ssm send-command --profile $profile --region $region --instance-ids $dcInstanceId `
    --document-name AWS-RunPowerShellScript --parameters $verifyParamsJson --output json
```

### Step 6 — Domain Join (always manual, even when using the skill)

`realmd`, `sssd`, `sssd-tools`, `adcli`, and `packagekit` are pre-installed on the golden
AMI (v1.1+) — no package install needed per client. Requires the domain admin account
prerequisite noted at the top of this document — confirm you have valid credentials for
`{client}.cloud.lcl` specifically before starting.

```bash
sudo realm discover {client}.cloud.lcl
sudo realm join {client}.cloud.lcl -U {domain-admin-user}
```

Verify:

```bash
realm list
id {your-user}@{client}.cloud.lcl
```

### Step 7 — Move Computer Object in AD

Domain join places the computer object in the default `Computers` container. Move it to the
client's dedicated OU structure.

**Example (ANCO):** joins into `anco.cloud.lcl/Computers/ANCO-PONSLRP001`, needs to move to
`anco.cloud.lcl/ANCO/Servers/Prod` (or `.../Servers/Test` for a test instance).

Run from a machine with the RSAT ActiveDirectory module and line-of-sight to
`{client}.cloud.lcl` (e.g. a domain controller):

```powershell
$ComputerName = "{CLIENT}-{ENV}ONSLRP001"
$TargetOu = "OU={Prod|Test},OU=Servers,OU={CLIENT},DC={client},DC=cloud,DC=lcl"

Get-ADComputer -Identity $ComputerName | Move-ADObject -TargetPath $TargetOu
```

Verify:

```powershell
Get-ADComputer -Identity $ComputerName -Properties DistinguishedName |
    Select-Object DistinguishedName
```

**Note:** confirm the `OU={CLIENT}` container already exists under `Servers` before moving —
this runbook does not cover creating client OU structure. The exact OU path may vary by
client; confirm against an existing server in the same client domain if unsure.

### Step 8 — Configure Proxy (if needed) - AMI has proxy set by default

Check if internet access works:

```bash
apt-get update
```

If it fails, configure proxy. Check existing Windows instance in the account for the
correct proxy IP. Common pattern:
- East: `172.30.20.55:8080`
- West: `172.29.20.55:8080`

```bash
sudo tee /etc/environment << 'EOF'
http_proxy=http://{PROXY_IP}:{PORT}
https_proxy=http://{PROXY_IP}:{PORT}
no_proxy=localhost,127.0.0.1,169.254.169.254,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,.cloud.lcl,.amazonaws.com
HTTP_PROXY=http://{PROXY_IP}:{PORT}
HTTPS_PROXY=http://{PROXY_IP}:{PORT}
NO_PROXY=localhost,127.0.0.1,169.254.169.254,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,.cloud.lcl,.amazonaws.com
EOF

sudo tee /etc/apt/apt.conf.d/95proxy << 'EOF'
Acquire::http::Proxy "http://{PROXY_IP}:{PORT}";
Acquire::https::Proxy "http://{PROXY_IP}:{PORT}";
EOF

source /etc/environment
export http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
```

**Important:** Always include `.amazonaws.com` in no_proxy so SSM agent connects directly.

### Step 9 — Security Software (No Action Needed)

**Resolved — Tanium is baked into the golden AMI (v1.2), not installed per-client.**

Security team provided the Linux Tanium client bundle directly; it was installed once
during the AMI build (see `fe-legacy-cognos-ami-build.md`, Phase 8b) and is present on every
instance launched from `ami-06dfdbf3cac70c6a7` (west) / `ami-04a1a6ee507695289` (east).
Per security team guidance, the Tanium agent periodically re-pulls host information
(hostname, etc.), so no per-instance identity reset or re-registration step is required here.

This matches fleet evidence from an existing FE 2.0 Linux client, which also only has
Tanium installed — no Rapid7 or Carbon Black package, service, or directory present. Tanium
is the confirmed Linux security tooling requirement; Rapid7/Carbon Black were not provided
by security for this build.

Optional sanity check after launch:
```bash
systemctl status taniumclient --no-pager | grep "Active:"
```

### Step 10 — Hand Off to GlobalLogic for Cognos Configuration

The GlobalLogic team RDPs into the instance and configures Cognos:

```powershell
# RDP via SSM port forwarding
aws ssm start-session --profile $profile --region $region --target i-XXXXXXXXX --document-name AWS-StartPortForwardingSession --parameters "portNumber=3389,localPortNumber=33389"
# Then RDP to localhost:33389, user: ubuntu-admin
```

They open a terminal and run:
```bash
/opt/ibm/cognos/analytics/bin64/cogconfig.sh
```

Configures:
- Content store database connection (host, port, DB name, credentials)
- Gateway URI (client hostname)
- Authentication namespace (LDAP/OIDC)
- SMTP settings (if applicable)
- Saves and starts Cognos

### Step 11 — Validate

```bash
# Check Cognos is running
sudo systemctl status cognos.service

# Check Cognos URL responds
curl -s -o /dev/null -w "%{http_code}" http://localhost:9300/bi
# Expected: 200 or 302

# Check Apache
curl -s http://localhost/healthcheck.html
```

---

## Troubleshooting: AMI Not Shared With the Client Account

The golden AMI and its KMS key are shared from `PALegacySharedServices` (361362055558) to
specific `PALegacyFinEnt{CLIENT}` account IDs. If Step 1 (`run-instances`, or the skill's
launch step) fails with an AMI/snapshot permission error, the new client's account ID hasn't
been added to the share list yet.

**1. Share the AMI + snapshot (both regions):**

```powershell
# West
aws ec2 modify-image-attribute --profile PALegacySharedServices --region us-west-2 --image-id ami-06dfdbf3cac70c6a7 --launch-permission "Add=[{UserId=NEW_ACCOUNT_ID}]"
aws ec2 modify-snapshot-attribute --profile PALegacySharedServices --region us-west-2 --snapshot-id snap-0644c82a28e817cfc --attribute createVolumePermission --operation-type add --user-ids NEW_ACCOUNT_ID

# East
aws ec2 modify-image-attribute --profile PALegacySharedServices --region us-east-1 --image-id ami-04a1a6ee507695289 --launch-permission "Add=[{UserId=NEW_ACCOUNT_ID}]"
aws ec2 modify-snapshot-attribute --profile PALegacySharedServices --region us-east-1 --snapshot-id snap-0e1c15b2b8248c640 --attribute createVolumePermission --operation-type add --user-ids NEW_ACCOUNT_ID
```

**2. Add the new account to the KMS key policy** (the AMI's root volume is encrypted with a
shared KMS key — sharing the AMI alone isn't enough). Add
`"arn:aws:iam::NEW_ACCOUNT_ID:root"` to both `scripts/kms-policy-west.json` and
`scripts/kms-policy-east.json`, then apply:

```powershell
aws kms put-key-policy --profile PALegacySharedServices --region us-west-2 --key-id f17195a0-525f-49be-b625-9fa79e4b0d01 --policy-name default --policy file://scripts/kms-policy-west.json
aws kms put-key-policy --profile PALegacySharedServices --region us-east-1 --key-id 1167100c-cd4f-4e70-acda-9917a7756cb3 --policy-name default --policy file://scripts/kms-policy-east.json
```

Retry Step 1 (or re-run the skill) once both steps complete — no other changes needed.
