# AWS Configs

Team-wide AWS CLI configuration. `cloudops.config` is the source of truth for `~/.aws/config` — it covers all 300+ accounts across both SSO sessions and is version-controlled so every teammate stays in sync.

---

## First-time setup

Run these two Kiro tasks in order (Ctrl+Shift+P → Tasks: Run Task):

1. **`Setup: Sync AWS Config`** — merges `cloudops.config` into your `~/.aws/config`, preserving any personal profiles you have.
2. **`Setup: AWS SSO Login (foundation)`** — opens a browser window to authenticate the foundation session.
3. **`Setup: AWS SSO Login (legacy)`** — opens a browser window to authenticate the legacy session.

Verify both sessions are active:
```
aws sts get-caller-identity --profile PALegacySharedServices
aws sts get-caller-identity --profile legacy-<any-legacy-account>
```

---

## Two SSO sessions (during migration)

| Session | Start URL | Role | Profile prefix |
|---------|-----------|------|----------------|
| `foundation` | `https://d-9067f93f22.awsapps.com/start` | `cst-comm-cloudadmin` | *(no prefix)* |
| `legacy` | `https://centralsquare.awsapps.com/start` | `Cloud-Administrator` | `legacy-` |

When an account migrates from legacy → foundation, its profile drops the `legacy-` prefix in the next config regeneration. The count of `legacy-` profiles in `cloudops.config` is the migration scoreboard.

---

## When new accounts are added

1. A teammate with SSO admin access runs:
   ```
   python aws-configs/tools/generate_aws_config.py
   ```
   This re-enumerates all accounts from both SSO instances and regenerates `cloudops.config`.
2. Submit a PR with the updated `cloudops.config`.
3. After merge, teammates pull and run **`Setup: Sync AWS Config`** again.

**Recommended cadence:** monthly, or on-demand when a teammate hits a missing-account error.

---

## Files

| File | Purpose |
|------|---------|
| `cloudops.config` | Committed AWS config — both SSO sessions + all profiles. Do not edit by hand. |
| `accounts.json` | Generated account registry used by the resolvers in `scripts/aws/`. |
| `nicknames.json` | Hand-maintained nickname aliases, merged into `accounts.json` on regeneration. |
| `tools/Sync-AwsConfig.ps1` | Merges `cloudops.config` into `~/.aws/config`, preserving personal profiles. |
| `tools/generate_aws_config.py` | Regenerates `cloudops.config` and `accounts.json` by querying both SSO instances. |

---

## Account nicknames

Scripts that accept an account name (`Connect-RDP.ps1`, `Find-Instance.ps1`, all Python AWS tools) resolve it through a 5-tier matcher. **Tier 3** checks curated nicknames before falling back to substring/token-overlap on the real name.

**Add a nickname:**

1. Edit `aws-configs/nicknames.json` — keys are exact AWS account names, values are arrays of aliases:
   ```json
   {
     "PROD-PA-Pro": ["pac-prd", "pac prd", "comdev", "commdev"],
     "PALegacySharedServices": ["shared", "ss"]
   }
   ```
2. Regenerate: `python aws-configs/tools/generate_aws_config.py`
3. Commit `nicknames.json` and `accounts.json` together in a PR.

**Normalization:** matching is case-insensitive and ignores spaces, hyphens, and underscores. The entry `"pac-prd"` also matches `pac prd`, `PAC_PRD`, and `PacPrd`.

**Validation:** the generator fails loudly if:
- A key in `nicknames.json` doesn't match a real AWS account name.
- The same normalized nickname appears under two different accounts (prevents ambiguous routing).

---

## How `Sync-AwsConfig.ps1` works

- If `~/.aws/config` does not exist: copies `cloudops.config` directly.
- If it does exist: replaces all blocks owned by the `foundation` or `legacy` SSO sessions with the contents of `cloudops.config`. Any personal profiles (other sessions) are preserved.
- Writes a timestamped backup (`~/.aws/config.backup-<timestamp>`) before overwriting.
- Run with `-WhatIf` to preview changes without applying them.
