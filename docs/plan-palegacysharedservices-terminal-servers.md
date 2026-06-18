# Plan: PALegacySharedServices Admin Terminal Servers

**Account:** PALegacySharedServices (`361362055558`)  
**Regions:** us-east-1 (primary) · us-west-2 (secondary)  
**Phase:** 1 — cloud.lcl domain users only

---

## Context

PALegacySharedServices is the AWS landing zone for a **datacenter-to-AWS migration** replacing ~50 individual physical workstations with shared Windows Remote Desktop Session Host (RDSH) servers. This also replaces the existing `inf-wss*` machines. Once cloud.lcl users are migrated, the platform will expand to cover ASPGOV and FinEnt environments moving off their current unsupported solutions (Phase 2).

---

## Server Inventory

### DBA SSMS Jump Boxes (1 per region)

Windows Server 2022 + SQL Server Management Studio. Single-admin use — no RDSH role, no CAL/SAL required.

| Name | Region | Subnet |
|---|---|---|
| INF-WSSQL001 | us-east-1 | pri-sub-3-INFWS-az1 (172.30.43.0/28) |
| INF-WSSQL101 | us-west-2 | pri-sub-3-INFWS-az1 (172.29.43.0/28) |

**Instance type:** `t3.large` (2 vCPU / 8 GB)  
**Storage:** 100 GB gp3, encrypted  
**Schedule:** `always-on`

### Admin RDSH Terminal Servers (3 per region)

Windows Remote Desktop Session Host — multi-user shared workstations for ~50 occasional admin users. Split across AZs; one per region always-on for off-hours incident access.

| Name | Region | AZ | Subnet | Schedule |
|---|---|---|---|---|
| INF-WSRDS001 | us-east-1 | az1 | pri-sub-3-INFWS-az1 (172.30.43.0/28) | `office-hours` |
| INF-WSRDS002 | us-east-1 | az2 | pri-sub-3-INFWS-az2 (172.30.43.16/28) | `office-hours` |
| INF-WSRDS003 | us-east-1 | az1 | pri-sub-3-INFWS-az1 (172.30.43.0/28) | `always-on` |
| INF-WSRDS101 | us-west-2 | az1 | pri-sub-3-INFWS-az1 (172.29.43.0/28) | `office-hours` |
| INF-WSRDS102 | us-west-2 | az2 | pri-sub-3-INFWS-az2 (172.29.43.16/28) | `office-hours` |
| INF-WSRDS103 | us-west-2 | az1 | pri-sub-3-INFWS-az1 (172.29.43.0/28) | `always-on` |

**Instance type:** `t3a.xlarge` (4 vCPU / 16 GB, burstable) — start here; upgrade to `m5.xlarge` if burstable credit exhaustion is observed under concurrent load  
**Storage:** 150 GB gp3, encrypted  

Instance count and sizing are fully variable-driven from cloud-foundation-configs tfvars — add or remove servers without touching the Terraform module.

---

## Networking

### Secondary CIDRs and INFWS Subnets

New secondary CIDRs added to the existing PALegacy VPCs for RDSH/SSMS workloads. The instances moved off the original 172.x.249.x /25 subnets onto dedicated /28s.

| Region | Secondary CIDR | az1 Subnet | az2 Subnet |
|---|---|---|---|
| us-east-1 | 172.30.43.0/24 | pri-sub-3-INFWS-az1 (172.30.43.0/28) | pri-sub-3-INFWS-az2 (172.30.43.16/28) |
| us-west-2 | 172.29.43.0/24 | pri-sub-3-INFWS-az1 (172.29.43.0/28) | pri-sub-3-INFWS-az2 (172.29.43.16/28) |

Defined in `cloud-foundation-configs/networking/PALegacySharedServices-use1/primary_networking.tfvars` and `PALegacySharedServices-usw2/primary_networking.tfvars`. Applied via the `cloud-foundation-spoke-networking` pipeline.

### VPC Endpoints

DS interface endpoint (`com.amazonaws.<region>.ds`) is defined in the networking tfvars alongside the other VPC service endpoints. Required for the `AWS-JoinDirectoryServiceDomain` SSM plugin to reach the Directory Service API from private subnets.

---

## Licensing: AWS License Manager User-Based Subscriptions (SALs)

**No RD Licensing Server. No fixed CAL pool.** AWS UBS (SALs) are billed per user per calendar month, only in months where the user authenticates. This fully replaces the grace-period-reset scripts (`scripts/aws/rds-license-reset/`), which violate the Microsoft EULA and must not run against these servers.

### How it works

1. Register the cloud.lcl AD Connector directory with AWS License Manager UBS
2. Subscribe authorized AD users by `samAccountName` — they receive a SAL; unsubscribed users cannot connect once the 120-day grace period expires
3. Each RDSH instance is associated with the `AWS-LicenseManager-UserSubscriptionsHandler` SSM document (Terraform-managed, `lm_ubs_enabled = true`), which reports active sessions back to License Manager for billing

### Access control

**AD group:** `R_AWSCOMM_SSO_cst-comm-infrdsaccess` in `cloud.lcl/Resources/AWSCOMMSSO`  
Added to `Remote Desktop Users` on each RDSH server by the Ansible playbook.

**License Manager sync:** AWS UBS has no native AD group support; users must be subscribed individually. The `inf-rdsh-lm-sync` PowerShell script (TODO — see Open Items) reads the AD group and reconciles against current LM subscriptions. Until it exists, subscriptions are managed manually via the runbook.

### Current status: `lm_ubs_enabled = false`

LM UBS was blocked by the shared Managed AD cross-account limitation — the `AWS-LicenseManager-UserSubscriptionsHandler` SSM document only exists in the directory owner account. The AD Connector (Phase 1 completion item) resolves this: using a connector owned by PALegacySharedServices removes the shared directory restriction. Set `lm_ubs_enabled = true` in tfvars after the connector is deployed and verified.

---

## AD Connector

**Status: Blocked on Aarron Lacey — 10.x VPC CIDRs TBD**

AWS License Manager UBS requires the AD Connector to live in a VPC whose CIDR belongs to `10.0.0.0/8` — AWS automatically assigns connector IP addresses and they must fall within this range. Separate new VPCs are required in both regions.

### What's needed

| Item | Status |
|---|---|
| USE1 VPC CIDR (10.x) | **TBD — Aarron** |
| USE1 Subnet1 CIDR | **TBD — Aarron** |
| USE1 Subnet2 CIDR | **TBD — Aarron** |
| USW2 VPC CIDR (10.x) | **TBD — Aarron** |
| USW2 Subnet1 CIDR | **TBD — Aarron** |
| USW2 Subnet2 CIDR | **TBD — Aarron** |
| AD service account | `awslmsvc` in `OU=Service Accounts,OU=Cloud,DC=cloud,DC=lcl` — password >30 complex characters (from PBI 1531539) |
| Service account password in SSM SecureString | **TBD — create before Terraform apply** |

**Note on service account credential rotation:** Explore automating rotation of the `awslmsvc` password (e.g. AWS Secrets Manager rotation Lambda → updates SSM SecureString + AD password). Not required for initial deployment but desirable long-term.

### Terraform work remaining (once CIDRs confirmed)

- New VPC + subnets in 10.x space (both regions) — in `cloud-foundation-spoke-networking` or as a new module TBD
- `aws_directory_service_connector` resource in `cloud-foundation-palegacysharedservices`
- SSM SecureString parameter for service account password
- Update `ad_directory_id_use1` / `ad_directory_id_usw2` in `palegacysharedservices.tfvars` to the new connector directory IDs
- Populate `ad_dns_ip_use1` / `ad_dns_ip_usw2` with the connector DC IPs
- Add `directoryOU` back to SSM association parameters (cross-account `ds:CreateComputer` limitation goes away with an owned connector)
- Update `security_groups.tf` egress — replace `100.64.0.0/10` CGNAT rules with connector subnet CIDRs; remove CGNAT rules once shared Managed AD is no longer used

---

## Terraform Module

**Location:** `foundaton/cloud-foundation-palegacysharedservices/`  
**PR:** 163174 — open, awaiting review  

Sibling module approach confirmed acceptable. Does not modify any core Foundation module.

### Files

| File | Purpose |
|---|---|
| `backend.tf` | Empty S3 partial block — values injected at pipeline runtime |
| `versions.tf` | terraform >= 1.5.0, aws ~> 5.31, random ~> 3.6 |
| `providers.tf` | default + primary (us-east-1) + secondary (us-west-2) providers with assume_role |
| `variables.tf` | All inputs: instance maps, sizing, AD directory IDs, DNS IPs, tags |
| `data.tf` | VPC/subnet by Name tag (`pri-sub-3-INFWS-az1/az2`), Windows 2022 AMI, EBS KMS key, IAM policy |
| `ec2_instances.tf` | RDSH + SSMS instances; count/names/AZ from tfvars variables |
| `iam.tf` | `inf-palegacysharedservices-ec2-role` + instance profile + `ds:CreateComputer` inline policy; primary creates, secondary reads via data source |
| `security_groups.tf` | RFC1918 + 100.64.0.0/10 ingress/egress — update egress when AD Connector replaces shared AD |
| `ssm_associations.tf` | `AWS-JoinDirectoryServiceDomain` (directoryId/directoryName/dnsIpAddresses from variables); `AWS-LicenseManager-UserSubscriptionsHandler` gated on `lm_ubs_enabled` |
| `kms.tf` | S3 KMS keys per region |
| `s3.tf` | `cst-comm-palegacysharedservices-media` media bucket (primary) |
| `s3_replication.tf` | CRR to `cst-comm-palegacysharedservices-media-replica` (us-west-2) |
| `outputs.tf` | Instance ID maps, S3 KMS ARN, media bucket ARN |
| `pipelines/deploy.yaml` | 4-stage AzDo pipeline: validate+plan → apply × 2 regions |
| `pipelines/destroy.yaml` | 4-stage destroy pipeline: secondary first, then primary |
| `templates/winrm_setup.ps1` | EC2 userdata — enables WinRM HTTPS on port 5986 for Ansible; sets per-instance Administrator password |

### Domain join

SSM Association with `AWS-JoinDirectoryServiceDomain`. Directory ID and DNS IPs are pure variables (`ad_directory_id_*`, `ad_dns_ip_*`) — no data source lookup, so destroy works even when the directory is absent.

`directoryOU` is currently omitted — was required to work around `ds:CreateComputer` cross-account failure on shared Managed AD. Once the AD Connector is owned by this account, add `directoryOU` back and computer pre-creation is no longer needed.

**Target OUs:**
- us-east-1: `OU=PALegacyUSE1,OU=Workstations,OU=AWS,OU=Servers,OU=Cloud,DC=cloud,DC=lcl`
- us-west-2: `OU=PALegacyUSW2,OU=Workstations,OU=AWS,OU=Servers,OU=Cloud,DC=cloud,DC=lcl`

**RDP access group:** `R_AWSCOMM_SSO_cst-comm-infrdsaccess` in `cloud.lcl/Resources/AWSCOMMSSO` — added to `Remote Desktop Users` on each RDSH server by the Ansible playbook.

---

## Config (cloud-foundation-configs)

**PR:** 163079 — open, awaiting review

| File | Contains |
|---|---|
| `account/361362055558/palegacysharedservices.tfvars` | Account ID, AD directory IDs, DNS IP placeholders, instance sizing |
| `account/361362055558/primary_palegacysharedservices.tfvars` | us-east-1 region flag, RDSH/SSMS instance map, `lm_ubs_enabled = false` |
| `account/361362055558/secondary_palegacysharedservices.tfvars` | us-west-2 region flag, RDSH/SSMS instance map, `lm_ubs_enabled = false` |
| `networking/PALegacySharedServices-use1/primary_networking.tfvars` | 172.30.43.0/24 secondary CIDR, pri-sub-3-INFWS-az1/az2 /28 subnets |
| `networking/PALegacySharedServices-usw2/primary_networking.tfvars` | 172.29.43.0/24 secondary CIDR, pri-sub-3-INFWS-az1/az2 /28 subnets |
| `networking/PALegacySharedServices-use1/networking.tfvars` | DS VPC interface endpoint |
| `networking/PALegacySharedServices-usw2/networking.tfvars` | DS VPC interface endpoint |

---

## Post-Deploy Runbook & Ansible

**Runbook:** `cloudops/runbooks/palegacysharedservices-rdsh-post-deploy.md`

**Ansible playbooks** (`cloudops/ansible/`):
- `palegacysharedservices-rdsh-setup.yml` — installs RDS-RD-Server role, adds AD access group to Remote Desktop Users
- `palegacysharedservices-ssms-setup.yml` — downloads SSMS installer from S3 media bucket and installs silently

Both playbooks retrieve the Administrator password from SSM Parameter Store (`/inf/palegacysharedservices/<instance>/admin_password`) and connect via WinRM NTLM on port 5986.

### Required application installs (PBI 1531541) — TODO

The following applications must be installed on every RDSH bastion host. These are not yet covered by the Ansible playbooks — to be added after domain join is working.

| Application | Notes |
|---|---|
| CarbonBlack | Endpoint security agent |
| Tanium | Endpoint management agent |
| Rapid7 | Vulnerability management agent |
| NPM Client | Network Password Manager client |
| Microsoft RSAT | Required for AD management from bastion |
| SecureCRT | SSH/terminal client |

### Required AD configuration (PBI 1531541) — TODO

Before bastion hosts are handed over to end users:
- Create OU: `OU=BastionHosts,OU=Resources,DC=cloud,DC=lcl`
- Create group: `R_BH_Cloud_Access` — add members from Rich G's team
- Grant `R_BH_Cloud_Access` access to the RDS collection on each bastion host

---

## AMI Strategy

Stock Amazon AMI + post-deploy Ansible configuration. `lifecycle { ignore_changes = [ami] }` prevents instance replacement on new AMI revisions.

**Phase 2:** Packer AMI baking RDSH role + SSMS + baseline hardening — reduces cold-start time significantly. Reference: `fe-aws-infra/ami/packer/fe-windows2022.pkr.hcl`.

---

## Open Items

| # | Item | Owner | Blocking? |
|---|---|---|---|
| 1 | **PR 163079** (cloud-foundation-configs — subnets, endpoints, AD DNS IP vars) | Reviewer | **Yes** — spoke-networking must apply before instances deploy |
| 2 | **PR 163174** (cloud-foundation-palegacysharedservices — full module) | Reviewer | **Yes** — main deploy PR |
| 3 | **Run spoke-networking pipeline** for PALegacySharedServices-use1 and usw2 | CloudOps | **Yes** — creates pri-sub-3-INFWS subnets and DS endpoint |
| 4 | **AD Connector VPC CIDRs** (10.x range, 2 VPCs) | **Aarron Lacey** | **Yes** — blocks connector Terraform and domain join |
| 5 | **AD service account** for connector (`svc-adconnector` or similar) with rights to create computer objects in PALegacy OUs | cloud.lcl AD team | **Yes** — needed before connector deploys |
| 6 | **Write AD Connector Terraform** — new VPCs, connector resource, SSM secret | CloudOps | Blocked on items 4 + 5 |
| 7 | **Update tfvars** with connector directory IDs and DC IPs once connector is deployed | CloudOps | Blocked on item 6 |
| 8 | **Redeploy palegacysharedservices** (deploy pipeline) | CloudOps | Blocked on items 3 + 7 |
| 9 | **Enable LM UBS** — set `lm_ubs_enabled = true`, run `register-identity-provider` CLI step | CloudOps | Blocked on item 8 |
| 10 | **Add `directoryOU` back** to SSM association parameters once connector is owned by this account | CloudOps | Blocked on item 7 |
| 11 | **Update SG egress** — replace `100.64.0.0/10` CGNAT rules with connector subnet CIDRs | CloudOps | Blocked on item 4 |
| 12 | **`inf-rdsh-lm-sync` script** — PowerShell to sync AD group → LM subscriptions | CloudOps | No — manual runbook step covers it initially |
| 13 | **Create `awslmsvc` AD service account** — `OU=Service Accounts,OU=Cloud,DC=cloud,DC=lcl`, password >30 chars, store in SSM SecureString | cloud.lcl AD team + CloudOps | Yes — needed before AD Connector deploys |
| 14 | **Explore `awslmsvc` credential rotation** — Secrets Manager rotation Lambda updating SSM + AD; not required for initial deploy | CloudOps | No |
| 15 | **Ansible: install required apps** on RDSH hosts — CarbonBlack, Tanium, Rapid7, NPM Client, RSAT, SecureCRT (PBI 1531541) | CloudOps | No — after domain join working |
| 16 | **AD: create `OU=BastionHosts,OU=Resources`** and `R_BH_Cloud_Access` group; grant RDS collection access (PBI 1531541) | cloud.lcl AD team | No — after domain join working |

---

## Out of Scope (Phase 2)

- aspgov.pri and FinEnt domains in AWS UBS — requires multi-domain trust testing
- **Instance Scheduler** — enable for this account, set `cst_schedule` tags, implement pre-shutdown notification Lambda (`inf-rdsh-pre-shutdown-notify`) with EventBridge rules and self-service deferral
- Packer AMI bake (RDSH role + SSMS + baseline hardening)
- Security group tightening (broad RFC1918 ingress is intentional for now; FTDv controls access)
- Moving ASPGOV and FinEnt environments off current unsupported solutions
- Grace-period-reset scripts — permanently retired, must not run against any server in this account
