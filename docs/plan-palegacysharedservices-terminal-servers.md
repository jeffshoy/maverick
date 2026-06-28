# Plan: PALegacySharedServices Admin Terminal Servers

**Account:** PALegacySharedServices (`361362055558`)  
**Regions:** us-east-1 (primary) · us-west-2 (secondary)  
**Phase:** 1 — cloud.lcl domain users only

---

## Proposed Timeline (reviewed with Gunjan)

| Phase | Owner | Duration | Description |
|---|---|---|---|
| 1 | Kevin | 2 weeks | Create IaC and automation to build/manage the replacement environment. Initial state is bare minimum necessary to shut down the datacenter. Additional refinement post-migration. |
| 2 | Kevin | 1 week | Deploy final production infrastructure — VPCs, AWS License Manager, RDS License Server, IAM roles, workstations, routes. Provide firewall rule list to network team via PBI. |
| 3 | Network | 1 week | Deploy firewall rules to permit communication with new workstations. |
| 4 | All Staff | 2 weeks | Begin using new workstations while old workstations remain available as backup. |
| 5 | All Staff | 1 week | Shut down old workstations not intended to be migrated. |
| 6 | Shawn / Aarron | +1 week | Migrate necessary workstations from datacenter to AWS. |

---

## Context

PALegacySharedServices is the AWS landing zone for a **datacenter-to-AWS migration** replacing ~50 individual physical workstations with shared Windows Remote Desktop Session Host (RDSH) servers. This also replaces the existing `inf-wss*` machines. Once cloud.lcl users are migrated, the platform will expand to cover ASPGOV and FinEnt environments moving off their current unsupported solutions (Phase 2).

---

## Server Inventory

### DBA SSMS Jump Boxes (1 per region)

Windows Server 2022 + SQL Server Management Studio. Single-admin use — no RDSH role, no CAL/SAL required.

| Name | Region | Subnet |
|---|---|---|
| INF-WSSQL001 | us-east-1 | pri-sub-3-INFWS-az4 (172.30.43.0/28, us-east-1d) |
| INF-WSSQL101 | us-west-2 | pri-sub-3-INFWS-az1 (172.29.43.0/28, us-west-2a) |

**Instance type:** `t3.large` (2 vCPU / 8 GB)  
**Storage:** 100 GB gp3, encrypted  
**Schedule:** `always-on`

### Admin RDSH Terminal Servers (3 per region)

Windows Remote Desktop Session Host — multi-user shared workstations for ~50 occasional admin users. Split across AZs; one per region always-on for off-hours incident access.

| Name | Region | AZ | Subnet | Schedule |
|---|---|---|---|---|
| INF-WSRDS001 | us-east-1 | az4 (us-east-1d) | pri-sub-3-INFWS-az4 (172.30.43.0/28) | `office-hours` |
| INF-WSRDS002 | us-east-1 | az1 (us-east-1b) | pri-sub-3-INFWS-az1 (172.30.43.16/28) | `office-hours` |
| INF-WSRDS003 | us-east-1 | az4 (us-east-1d) | pri-sub-3-INFWS-az4 (172.30.43.0/28) | `always-on` |
| INF-WSRDS101 | us-west-2 | az1 (us-west-2a) | pri-sub-3-INFWS-az1 (172.29.43.0/28) | `office-hours` |
| INF-WSRDS102 | us-west-2 | az2 (us-west-2b) | pri-sub-3-INFWS-az2 (172.29.43.16/28) | `office-hours` |
| INF-WSRDS103 | us-west-2 | az1 (us-west-2a) | pri-sub-3-INFWS-az1 (172.29.43.0/28) | `always-on` |

**Instance type:** `t3a.xlarge` (4 vCPU / 16 GB, burstable) — start here; upgrade to `m5.xlarge` if burstable credit exhaustion is observed under concurrent load  
**Storage:** 150 GB gp3, encrypted  

Instance count and sizing are fully variable-driven from cloud-foundation-configs tfvars — add or remove servers without touching the Terraform module.

---

## Networking

### Secondary CIDRs and INFWS Subnets

New secondary CIDRs added to the existing PALegacy VPCs for RDSH/SSMS workloads. The instances moved off the original 172.x.249.x /25 subnets onto dedicated /28s.

| Region | Secondary CIDR | First Subnet | Second Subnet |
|---|---|---|---|
| us-east-1 | 172.30.43.0/24 | pri-sub-3-INFWS-az4 (172.30.43.0/28, us-east-1d) | pri-sub-3-INFWS-az1 (172.30.43.16/28, us-east-1b) |
| us-west-2 | 172.29.43.0/24 | pri-sub-3-INFWS-az1 (172.29.43.0/28, us-west-2a) | pri-sub-3-INFWS-az2 (172.29.43.16/28, us-west-2b) |

Defined in `cloud-foundation-configs/networking/PALegacySharedServices-use1/primary_networking.tfvars` and `PALegacySharedServices-usw2/primary_networking.tfvars`. **Applied via `cloud-foundation-spoke-networking` pipeline — complete as of 2026-06-25.**

### VPC Endpoints

DS interface endpoint (`com.amazonaws.<region>.ds`) is defined in the networking tfvars alongside the other VPC service endpoints. Required for the `AWS-JoinDirectoryServiceDomain` SSM plugin to reach the Directory Service API from private subnets. **Deployed in both regions as of 2026-06-25** (use1: `vpce-0f91ea393e3089055`, usw2: `vpce-0f91ea393e3089055` — see apply logs).

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

**CIDRs confirmed by Aarron Lacey (06/18/2026).** AWS License Manager UBS requires the AD Connector VPC CIDR to belong to `10.0.0.0/8`. AWS does not permit 10.x secondary CIDRs on a VPC whose primary CIDR is in the 172.x range — attempting to add a 10.x secondary CIDR to the existing PALegacy VPCs returns `InvalidVpc.Range`. **Separate VPCs are required** for the MSAD connector subnets.

Two new VPCs (`PALegacySharedServicesAlternate-USE1` and `PALegacySharedServicesAlternate-USW2`) were created via the `cloud-foundation-spoke-networking` pipeline and are live in AWS as of 2026-06-25.

### Deployed CIDRs and Resources

| Item | Value |
|---|---|
| USE1 VPC | `vpc-03ad69aad26522702` (PALegacySharedServicesAlternate-USE1, **new**) |
| USE1 CIDR | `10.0.15.0/24` |
| USE1 Subnet1 | `MSADConnectors-use1az4` — `10.0.15.0/28` — use1-az4 (us-east-1d) — `subnet-076d1828a602da486` |
| USE1 Subnet2 | `MSADConnectors-use1az1` — `10.0.15.16/28` — use1-az1 (us-east-1b) — `subnet-0999ef9a27b42b73d` |
| USE1 TGW attachment | `tgw-attach-037b90a827469c808` → `TGW-PALegacy-US-East-1-CldSvcs` |
| USW2 VPC | `vpc-0f7fcace897bad052` (PALegacySharedServicesAlternate-USW2, **new**) |
| USW2 CIDR | `10.1.15.0/24` |
| USW2 Subnet1 | `MSADConnectors-usw2az1` — `10.1.15.0/28` — usw2-az1 (us-west-2a) — `subnet-0a5378dfb0720e4a4` |
| USW2 Subnet2 | `MSADConnectors-usw2az2` — `10.1.15.16/28` — usw2-az2 (us-west-2b) — `subnet-0ee342a4ffaa765e6` |
| USW2 TGW attachment | `tgw-attach-0bb0550d4c4908755` → `TGW-PALegacy-US-West-2-CldSvcs` |
| AD service account | `awslmsvc` in `OU=Service Accounts,OU=Cloud,DC=cloud,DC=lcl` — password >30 complex characters (from PBI 1531539) |
| Service account password in SSM SecureString | **TBD — create before AD Connector Terraform apply** |

**Note on service account credential rotation:** Explore automating rotation of the `awslmsvc` password (e.g. AWS Secrets Manager rotation Lambda → updates SSM SecureString + AD password). Not required for initial deployment but desirable long-term.

### Terraform work remaining

- ~~New VPC + subnets in 10.x space (both regions)~~ — **Done** (PALegacySharedServicesAlternate-USE1/USW2 applied 2026-06-25)
- `aws_directory_service_connector` resource in `cloud-foundation-palegacysharedservices`
- SSM SecureString parameter for service account password (`/inf/palegacysharedservices/awslmsvc/password` — both regions)
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
| 1 | ~~**PR 163079** (cloud-foundation-configs — subnets, endpoints, AD DNS IP vars)~~ | ~~Reviewer~~ | **Done** — merged as PR 163895 (fix/palegacy-subnet-az-mapping → main) 2026-06-25 |
| 2 | ~~**PR 163174** (cloud-foundation-palegacysharedservices — full module)~~ | ~~Reviewer~~ | **Done** — merged |
| 3 | ~~**Run spoke-networking pipeline** for PALegacySharedServices-use1, usw2, Alternate-USE1, Alternate-USW2~~ | ~~CloudOps~~ | **Done** — all four stacks applied 2026-06-25. vpc-endpoints → main merged as PR 164063 |
| 4 | ~~**AD Connector CIDRs confirmed**~~ | ~~Aarron Lacey~~ | **Done** — confirmed 06/18/2026; separate VPCs required and deployed |
| 5 | ~~**AD service account**~~ | ~~cloud.lcl AD team~~ | **Done** — `awsadssvc` created and delegated `Create Computer Objects` on `OU=PALegacyUSE1` and `OU=PALegacyUSW2`. Note: `awslmsvc` was deleted. |
| 6 | ~~**AD Connector Terraform**~~ — connector resource, SSM secret | ~~CloudOps~~ | **Done** — `aws_directory_service_directory` (ADConnector) deployed in USE1 as `d-9066755bec` (Active). Connector uses dedicated Alternate VPCs with 10.x CIDRs. |
| 7 | ~~**Populate SSM SecureString** `/inf/palegacysharedservices/awsadssvc/password` in us-east-1 and us-west-2~~ | ~~CloudOps~~ | **Done** — parameter created in both regions. **Rotate password** — was briefly exposed in session history. |
| 8 | ~~**Update tfvars** with connector DC IPs and service account~~ | ~~CloudOps~~ | **Done** — `ad_connector_dns_ips_use1/usw2`, `ad_connector_username`, `ad_connector_password_ssm_path` set in `palegacysharedservices.tfvars` |
| 9 | ~~**Deploy palegacysharedservices USE1**~~ (deploy pipeline) | ~~CloudOps~~ | **Done** — pipeline applied 2026-06-28. INF-WSRDS001/002/003 and INF-WSSQL001 deployed and domain-joined to `OU=PALegacyUSE1`. |
| 9a | **Deploy palegacysharedservices USW2** | CloudOps | **Blocked** — see networking blocker #1 below. |
| 10 | **Enable LM UBS** — set `lm_ubs_enabled = true`, run `register-identity-provider` CLI step | CloudOps | Blocked on item 9a (USW2 must be deployed first) |
| 11 | ~~**Add `directoryOU` back** to SSM association parameters~~ | ~~CloudOps~~ | **Done** — `directoryOU` added to `AWS-JoinDirectoryServiceDomain` parameters. All USE1 instances joined to correct OUs. |
| 12 | **Update SG egress** — replace `100.64.0.0/10` CGNAT rules with connector subnet CIDRs | CloudOps | No — deferred; FTDv controls access |
| 13 | **`inf-rdsh-lm-sync` script** — PowerShell to sync AD group → LM subscriptions | CloudOps | No — manual runbook step covers it initially |
| 14 | **Rotate `awsadssvc` password** — update SSM parameter in both regions, run `aws ds update-directory-setup` | CloudOps | **Yes** — password was exposed in session history |
| 15 | **Ansible: add `R_AWSCOMM_SSO_cst-comm-infrdsaccess`** to Remote Desktop Users on all instances | CloudOps | Blocked on networking blocker #2 (domain connectivity needed for domain group resolution) |
| 16 | **Ansible: install required apps** on RDSH hosts — CarbonBlack, Tanium, Rapid7, NPM Client, RSAT, SecureCRT (PBI 1531541) | CloudOps | No — after domain join working |
| 17 | **AD: create `OU=BastionHosts,OU=Resources`** and `R_BH_Cloud_Access` group; grant RDS collection access (PBI 1531541) | cloud.lcl AD team | No — after domain join working |
| 18 | **Networking: codify TGW attachment second-AZ subnets** — both regions modified manually today; networking Terraform stack needs to match | Networking | No — cosmetic until next networking stack apply |

---

## Networking Blockers

### Blocker 1 — USW2 AD Connector: FTD firewall rule missing

**Action required: Networking team**

All AD ports are blocked from the USW2 connector subnets to the USW2 domain controllers.
ICMP (ping) succeeds from both AZs confirming TGW routing is in place; TCP/UDP is blocked at the FTD.
Confirmed via port scan 2026-06-28 from probe instances `i-0549fab81b7482a59` (us-west-2a, `10.1.15.14`) and `i-03cc057867fd4c552` (us-west-2b, `10.1.15.27`) — both stopped, available for re-testing.

| Source | Destination | Required Ports |
|---|---|---|
| `10.1.15.0/24` (MSADConnectors-usw2az1/az2) | `172.29.20.20` (inf-svrdc011) | TCP/UDP 53, 88, 135, 389, 445, 636, 3268, 49152-65535 |
| `10.1.15.0/24` (MSADConnectors-usw2az1/az2) | `172.29.20.21` (inf-svrdc012) | TCP/UDP 53, 88, 135, 389, 445, 636, 3268, 49152-65535 |

### Blocker 2 — USE1 instances: no DC connectivity from instance subnets

**Action required: Networking team**

RDSH and WSSQL instances in `172.30.43.x` cannot reach the USE1 domain controllers directly.
Domain join succeeded (runs from AWS DS service plane), but live AD lookups, GP, Kerberos, and domain user logins all fail from the instances.
This blocks domain user RDP access and Ansible domain-level configuration.

The equivalent rule will be needed in USW2 for `172.29.43.x` once that pipeline runs.

| Source | Destination | Required Ports |
|---|---|---|
| `172.30.43.0/24` (pri-sub-3-INFWS-az4/az1, USE1) | `172.30.20.20` (inf-svrdc001) | TCP/UDP 53, 88, 135, 389, 445, 636, 3268, 49152-65535 |
| `172.30.43.0/24` (pri-sub-3-INFWS-az4/az1, USE1) | `172.30.20.21` (inf-svrdc002) | TCP/UDP 53, 88, 135, 389, 445, 636, 3268, 49152-65535 |
| `172.29.43.0/24` (pri-sub-3-INFWS-az1/az2, USW2) | `172.29.20.20` (inf-svrdc011) | TCP/UDP 53, 88, 135, 389, 445, 636, 3268, 49152-65535 |
| `172.29.43.0/24` (pri-sub-3-INFWS-az1/az2, USW2) | `172.29.20.21` (inf-svrdc012) | TCP/UDP 53, 88, 135, 389, 445, 636, 3268, 49152-65535 |

---

## Out of Scope (Phase 2)

- aspgov.pri and FinEnt domains in AWS UBS — requires multi-domain trust testing
- **Instance Scheduler** — enable for this account, set `cst_schedule` tags, implement pre-shutdown notification Lambda (`inf-rdsh-pre-shutdown-notify`) with EventBridge rules and self-service deferral
- Packer AMI bake (RDSH role + SSMS + baseline hardening)
- Security group tightening (broad RFC1918 ingress is intentional for now; FTDv controls access)
- Moving ASPGOV and FinEnt environments off current unsupported solutions
- Grace-period-reset scripts — permanently retired, must not run against any server in this account
