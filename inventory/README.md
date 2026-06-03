# Inventory

Environment metadata — single source of truth for values that scripts and runbooks reference. AWS account inventory lives in [`aws-configs/cloudops.config`](../aws-configs/cloudops.config), not here.

| File | Contents |
|------|----------|
| `ad-domains.yml` | AD domain FQDNs, NetBIOS names, preferred DCs, user OU base paths |
| `ssm-documents.yml` | Named SSM documents used by team scripts, with purpose and regions |
| `ous.yml` | OU paths for user lifecycle operations |

These files are reference data. Scripts that hard-code these values will migrate here when next rewritten — see [`CLAUDE.md`](../CLAUDE.md) for rewrite standards.
