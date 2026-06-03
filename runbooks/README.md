# Runbooks

Operational playbooks for common incidents and routine tasks. Each runbook names the exact Kiro task to run so you can go from alert → runbook → execution without leaving the IDE.

## Index

| Runbook | Kiro Task(s) | When to use |
|---------|--------------|-------------|
| [`aws-sso-setup.md`](aws-sso-setup.md) | `Setup: Sync AWS Config`, `Setup: AWS SSO Login (*)` | First-time setup or after AWS org changes |
| [`ad-user-disable.md`](ad-user-disable.md) | `AD: Disable User (4 Domains)` | Employee offboarding or account lockout |
| [`ad-user-creation.md`](ad-user-creation.md) | `AD: Create *` | New user provisioning |
| [`rds-license-grace-period.md`](rds-license-grace-period.md) | `AWS: Reset RDS License Grace Period` | RDS licensing expired on a client server |
| [`disk-expansion.md`](disk-expansion.md) | `AWS: Expand Disk` | EC2 disk running low |
| [`service-restart.md`](service-restart.md) | `AWS: Restart Service` | Service down alert from LogicMonitor |
| [`site-investigation.md`](site-investigation.md) | `AWS: Investigate Site` | Site outage or IIS issue |
| [`cert-mass-revoke.md`](cert-mass-revoke.md) | `Sectigo: Mass Cert Revoke` | Bulk certificate revocation event |
| [`dns-record-change.md`](dns-record-change.md) | `DNS: Change MS DNS Record` | DNS migration or cutover |

## Template

Every runbook follows this structure:

```markdown
# <Title>

## When to use

## Pre-checks

## Procedure

## Verification

## Rollback

## Related
```
