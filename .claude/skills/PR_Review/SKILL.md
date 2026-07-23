---
name: PR_Review
description: Review the current branch diff for correctness bugs AND compliance with the PSJ Cloud Platform Engineering Spec (v0.2.0). Checks tagging, observability, networking, FinOps guardrails, Terraform standards, and deployment standards. Use /PR_Review when you want spec compliance checked alongside code quality; use /review for code-quality-only reviews.
---

You are performing a combined **code quality + spec compliance** review of the current branch diff.

## Step 1 — Get the diff

Run `git diff main...HEAD` (or `git diff origin/main...HEAD` if needed) to get the full diff for this branch. If the branch has no commits ahead of main, tell the user and stop.

## Step 2 — Code quality review

Review the diff for the same categories as the built-in `/review` skill:
- **Correctness bugs** — logic errors, off-by-ones, null dereferences, race conditions, wrong comparisons
- **Simplification** — duplicated logic that could reuse an existing helper, over-engineered abstractions
- **Efficiency** — unnecessary allocations, N+1 queries, repeated expensive calls
- **Security** — hardcoded secrets, overly permissive IAM, missing input validation, command injection

## Step 3 — Spec compliance review

Check the diff against the PSJ Cloud Platform Engineering Spec at `~/.aws/repos/cloud-foundation-platform-engineering-spec`. The spec version is v0.2.0. Review each domain that is touched by the diff:

### Tagging (05-tagging-standards.md)
Required `cst_*` tags on every AWS resource:
- `cst_name`, `cst_application`, `cst_cost_center`, `cst_compliance_domain`, `cst_environment`, `cst_product_line`, `cst_tenancy`, `cst_tenant`, `cst_repo`, `cst_backup_policy`
- Valid `cst_environment` values: `csi`, `demo`, `dev`, `pdmo`, `prd`, `qa`, `qaa`, `sbox`, `sdmo`, `stg`, `trn`, `tst`, `uat`
- Valid `cst_compliance_domain`: `canada`, `cjis`, `hipaa`, `pci`, `none`
- Valid `cst_tenancy`: `single`, `multiple`, `none`
- Valid `cst_backup_policy`: `prod`, `nonprod`, `dev`, `none`
- Tags should be applied via `merge(local.common_tags, {...})` pattern

### Observability (02-observability-requirements.md)
- CloudWatch Log Groups must have `retention_in_days` and `kms_key_id` set
- Log group names follow `/aws/{service}/{stack_name}/{component}` pattern
- Lambda functions must have `tracing_config { mode = "Active" }`
- EC2 instances need CloudWatch Agent config
- Retention: prod=90d, non-prod=30d, dev=7d

### Terraform standards (01-terraform-standards.md)
- Use approved modules from `cloud-foundation-*` repositories
- File structure: `backends.tf`, `data.tf`, `locals.tf`, `main.tf`, `outputs.tf`, `providers.tf`, `variables.tf`, `versions.tf`
- Resource naming: `{stack_name}-{resource_type}-{descriptor}`, lowercase/hyphens, max 64 chars
- Terraform version `>= 1.5.0`, AWS provider `~> 5.0`
- Modules pinned to specific versions/tags
- No hardcoded AMI IDs — use data sources
- Shell provisioners (`local-exec`/`remote-exec`): **never** redirect stderr to `/dev/null` or use `|| true`; capture output and match on specific error strings

### Networking (03-networking-constraints.md)
- EKS clusters: `endpoint_public_access = false`
- Security group rules: least privilege, specific ports/sources, descriptions required
- No rules with `cidr_blocks = ["0.0.0.0/0"]` on non-80/443 ports without justification
- VPC Flow Logs must be enabled on new VPCs

### FinOps (04-finops-guardrails.md)
- EBS volumes must use `type = "gp3"`, not `gp2`
- Non-prod EC2 instances should have `AutoShutdown = "true"` tag
- Budget alerts required for new stacks
- IMDSv2 required: `metadata_options { http_tokens = "required" }`

### Deployment/Pipeline (06-deployment-standards.md)
- Pipeline scripts: no `2>/dev/null` stderr suppression, no `|| true` without validation
- Multi-line pipeline scripts should use `set -euo pipefail`
- Unexpected errors must propagate with original exit code

### Platform compliance (00-platform-standards.md)
- No HIGH/CRITICAL security findings may be merged
- Infrastructure that doesn't meet standards MUST NOT be merged to main
- Exceptions require written justification, approval, remediation plan, and time-bound period

## Step 4 — Output format

Report findings grouped into two sections:

### Code Quality
List each finding as:
- **[SEVERITY]** `file:line` — description

### Spec Compliance
List each violation as:
- **[SPEC-SECTION]** `file:line` — what's missing or wrong, and what the spec requires

Use severity levels: **BLOCKER** (must fix before merge), **WARNING** (should fix), **INFO** (suggestion).

If there are no findings in a section, say "No issues found."

End with a one-line summary: `PASS` (no blockers), `NEEDS WORK` (warnings only), or `BLOCKED` (one or more blockers).

> Spec reference: `~/.aws/repos/cloud-foundation-platform-engineering-spec` (v0.2.0, 2026-05-29)
