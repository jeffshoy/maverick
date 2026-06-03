# Inventory

Environment reference data — canonical values that scripts and runbooks link to instead of hard-coding. AWS account inventory lives in [`aws-configs/accounts.json`](../aws-configs/accounts.json), not here.

| File | Contents |
|------|----------|
| [`ad-domains.yml`](ad-domains.yml) | The four AD domains targeted by user-management scripts — FQDNs, DCs, and OU paths |
| [`ssm-documents.yml`](ssm-documents.yml) | Named SSM documents used by team scripts, with purpose and parameter reference |
| [`ous.yml`](ous.yml) | OU distinguished names used in user lifecycle operations |

These files are reference data. When a script hard-codes a value that belongs here (domain name, OU path, SSM document name), migrate it on next rewrite — see [`CLAUDE.md`](../CLAUDE.md) for rewrite standards.
