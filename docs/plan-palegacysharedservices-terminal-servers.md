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
| INF-WSSQL001 | us-east-1 | pri-sub-1-INF-az1 (172.30.249.0/25) |
| INF-WSSQL101 | us-west-2 | pri-sub-1-INF-az1 (172.29.249.0/25) |

**Instance type:** `t3.large` (2 vCPU / 8 GB)  
**Storage:** 100 GB gp3, encrypted  
**Schedule:** `always-on`

### Admin RDSH Terminal Servers (3 per region)

Windows Remote Desktop Session Host — multi-user shared workstations for ~50 occasional admin users. Split across AZs; one per region always-on for off-hours incident access.

| Name | Region | AZ | Subnet | Schedule |
|---|---|---|---|---|
| INF-WSRDS001 | us-east-1 | az1 | pri-sub-1-INF-az1 (172.30.249.0/25) | `office-hours` |
| INF-WSRDS002 | us-east-1 | az2 | pri-sub-1-INF-az2 (172.30.249.128/25) | `office-hours` |
| INF-WSRDS003 | us-east-1 | az1 | pri-sub-1-INF-az1 (172.30.249.0/25) | `always-on` |
| INF-WSRDS101 | us-west-2 | az1 | pri-sub-1-INF-az1 (172.29.249.0/25) | `office-hours` |
| INF-WSRDS102 | us-west-2 | az2 | pri-sub-1-INF-az2 (172.29.249.128/25) | `office-hours` |
| INF-WSRDS103 | us-west-2 | az1 | pri-sub-1-INF-az1 (172.29.249.0/25) | `always-on` |

**Instance type:** `t3a.xlarge` (4 vCPU / 16 GB, burstable) — start here; upgrade to `m5.xlarge` if burstable credit exhaustion is observed under concurrent load  
**Storage:** 150 GB gp3, encrypted  

Instance count and sizing are fully variable-driven from cloud-foundation-configs tfvars — add or remove servers without touching the Terraform module.

---

## Licensing: AWS License Manager User-Based Subscriptions (SALs)

**No RD Licensing Server. No fixed CAL pool.** AWS UBS (SALs) are billed per user per calendar month, only in months where the user authenticates. This fully replaces the grace-period-reset scripts (`scripts/aws/rds-license-reset/`), which violate the Microsoft EULA and must not run against these servers.

### How it works

1. Register the cloud.lcl Managed AD directory with AWS License Manager UBS
2. Subscribe authorized AD users by `samAccountName` — they receive a SAL; unsubscribed users cannot connect once the 120-day grace period expires
3. Each RDSH instance is associated with the `AWS-LicenseManager-UserSubscriptionsHandler` SSM document (Terraform-managed), which reports active sessions back to License Manager for billing

### Access control

**AD group:** `R_AWSCOMM_SSO_cst-comm-infrdsaccess` in `cloud.lcl/Resources/AWSCOMMSSO`  
Added to `Remote Desktop Users` on each RDSH server by the Ansible playbook.

**License Manager sync:** AWS UBS has no native AD group support; users must be subscribed individually. The `inf-rdsh-lm-sync` PowerShell script (TODO — see Open Items) reads the AD group and reconciles against current LM subscriptions. Until it exists, subscriptions are managed manually via the runbook.

### Phase 1 scope: cloud.lcl only

aspgov.pri and FinEnt domains are Phase 2. Multi-domain UBS behavior with one-way trusts needs testing before expanding. A two-way trust between cloud.lcl and subdomains must NOT be established for security reasons. Each domain will likely require its own set of registered users in License Manager; testing is required to confirm the exact model.

---

## Terraform Module

**Location:** `foundaton/cloud-foundation-palegacysharedservices/`  
**Status:** Complete. Awaiting AzDo git repo creation.

Sibling module approach confirmed acceptable. Does not modify any core Foundation module.

### Files

| File | Purpose |
|---|---|
| `backend.tf` | Empty S3 partial block — values injected at pipeline runtime |
| `versions.tf` | terraform >= 1.5.0, aws ~> 5.31, random ~> 3.6 |
| `providers.tf` | default + primary (us-east-1) + secondary (us-west-2) providers with assume_role |
| `variables.tf` | All inputs: instance maps, sizing, AD directory IDs, tags |
| `data.tf` | VPC/subnet by Name tag, Windows 2022 AMI, EBS KMS key, IAM policy, Managed AD directory |
| `ec2_instances.tf` | RDSH + SSMS instances; count/names/AZ/schedule from tfvars variables |
| `iam.tf` | `inf-palegacysharedservices-ec2-role` + instance profile; primary creates, secondary reads via data source |
| `security_groups.tf` | RFC1918 ingress, HTTPS/LDAP egress — FTDv controls access; SGs tightened in future phase |
| `ssm_associations.tf` | `AWS-JoinDirectoryServiceDomain` for all instances; `AWS-LicenseManager-UserSubscriptionsHandler` for RDSH only |
| `kms.tf` | S3 KMS keys per region |
| `s3.tf` | `cst-comm-palegacysharedservices-media` media bucket (primary) |
| `s3_replication.tf` | CRR to `cst-comm-palegacysharedservices-media-replica` (us-west-2) |
| `outputs.tf` | Instance ID maps, S3 KMS ARN, media bucket ARN |
| `pipelines/deploy.yaml` | 4-stage AzDo pipeline: validate+plan → apply × 2 regions |
| `templates/winrm_setup.ps1` | EC2 userdata — enables WinRM HTTPS on port 5986 for Ansible; sets per-instance Administrator password |

### Domain join

SSM Association with `AWS-JoinDirectoryServiceDomain`. OU paths confirmed:
- us-east-1: `OU=PALegacyUSE1,OU=Workstations,OU=AWS,OU=Servers,OU=Cloud,DC=cloud,DC=lcl`
- us-west-2: `OU=PALegacyUSW2,OU=Workstations,OU=AWS,OU=Servers,OU=Cloud,DC=cloud,DC=lcl`

---

## Config (cloud-foundation-configs account/361362055558)

**Status:** Complete. PR 162935 open for review.

| File | Contains |
|---|---|
| `palegacysharedservices.tfvars` | Account ID, AD directory IDs, instance sizing (type/volume) |
| `primary_palegacysharedservices.tfvars` | us-east-1 region flag + full RDSH/SSMS instance map with subnet AZ and schedule |
| `secondary_palegacysharedservices.tfvars` | us-west-2 region flag + same structure |

To add, remove, or resize servers: edit the instance maps or sizing values in these files — no module changes required.

---

## Post-Deploy Runbook & Ansible

**Status:** Complete. PR 162934 open for review.

**Runbook:** `cloudops/runbooks/palegacysharedservices-rdsh-post-deploy.md`  
7-step runbook covering domain join verification, Ansible playbook execution, SSMS install, License Manager UBS registration, RDP access verification, Instance Scheduler schedule name confirmation, and us-west-2 directory share prerequisite.

**Ansible playbooks** (`cloudops/ansible/`):
- `palegacysharedservices-rdsh-setup.yml` — targets `tag_cst_application_inf_admin_rdsh`; installs RDS-RD-Server role, reboots if needed, adds AD access group to Remote Desktop Users
- `palegacysharedservices-ssms-setup.yml` — targets `tag_cst_application_inf_admin_ssms`; downloads SSMS installer from S3 media bucket and installs silently

Both playbooks retrieve the Administrator password from SSM Parameter Store (`/inf/palegacysharedservices/<instance>/admin_password`) and connect via WinRM NTLM on port 5986.

---

## Instance Scheduler

All instances run always-on in Phase 1 — no `cst_schedule` tag is set. The Instance Scheduler is not yet configured for this account. Scheduling is deferred to Phase 2 (see Out of Scope).

---

## AMI Strategy

Stock Amazon AMI + post-deploy Ansible configuration. `lifecycle { ignore_changes = [ami] }` prevents instance replacement on new AMI revisions.

**Phase 2:** Packer AMI baking RDSH role + SSMS + baseline hardening — reduces cold-start time significantly. Reference: `fe-aws-infra/ami/packer/fe-windows2022.pkr.hcl`.

---

## Open Items

| # | Item | Owner | Blocking? |
|---|---|---|---|
| 1 | ~~**AzDo git repo creation** for `cloud-foundation-palegacysharedservices`~~ | ~~C3 team~~ | **Resolved** |
| 2 | ~~**us-west-2 cloud.lcl directory share**~~ | ~~SharedServices AD team~~ | **Resolved** — `d-906672ebcc` (prdcomm.cloud.lcl) confirmed in both regions with cross-region enabled 2026-06-18 |
| 3 | ~~**Instance Scheduler**~~ | ~~CloudOps~~ | **Deferred to Phase 2** — all instances always-on, no cst_schedule tag |
| 4 | **`inf-rdsh-lm-sync` script** — PowerShell to sync `R_AWSCOMM_SSO_cst-comm-infrdsaccess` AD group membership → License Manager subscriptions | CloudOps | No — manual runbook step covers it initially |
| 5 | **PR 162934** (cloudops — runbook + Ansible) | Reviewer | No — ready |
| 6 | **PR 162935** (cloud-foundation-configs — tfvars) | Reviewer | No — ready |

---

## Out of Scope (Phase 2)

- aspgov.pri and FinEnt domains in AWS UBS — requires multi-domain trust testing
- **Instance Scheduler** — enable for this account, set `cst_schedule` tags, implement pre-shutdown notification Lambda (`inf-rdsh-pre-shutdown-notify`) with EventBridge rules and self-service deferral
- **LM UBS for us-west-2** — AWS LM UBS cannot register a cross-region replicated Managed AD directory from a consumer account; the us-west-2 RDSH servers run on the 120-day grace period until resolved. Options: open AWS support case, or create a dedicated Managed AD in PALegacySharedServices for us-west-2. Set `lm_ubs_enabled = true` in `secondary_palegacysharedservices.tfvars` once resolved.
- Packer AMI bake (RDSH role + SSMS + baseline hardening)
- Security group tightening (broad RFC1918 ingress is intentional for now; FTDv controls access)
- Moving ASPGOV and FinEnt environments off current unsupported solutions
- Grace-period-reset scripts — permanently retired, must not run against any server in this account
