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
| `aliases.json` | Hand-maintained nickname + application aliases, merged into `accounts.json` on regeneration. |
| `tools/Sync-AwsConfig.ps1` | Merges `cloudops.config` into `~/.aws/config`, preserving personal profiles. |
| `tools/generate_aws_config.py` | Regenerates `cloudops.config` and `accounts.json` by querying both SSO instances. |

---

## Account aliases — nicknames vs applications

Scripts that accept an account name (`Connect-RDP.ps1`, `connect-instance.ps1`, all Python AWS tools) resolve it through a 6-tier matcher. The interesting middle tiers come from `aliases.json`:

- **Tier 3 — nicknames** are environment-specific 1:1 aliases. `pac-prd` resolves to one and only one account; if you typed it, you meant that one. The validator enforces strict 1:1.
- **Tier 4 — applications** are 1:many app names that may legitimately span prod/staging/dev. `finance` matches every account that runs finance workloads; the resolver returns all of them and prompts you to pick the environment.

**Schema** — `aws-configs/aliases.json`:

```json
{
  "PROD-PA-Pro":    { "nicknames": ["pac-prd", "pac prd"], "applications": ["comdev", "finance"] },
  "Pa-pro-staging": { "nicknames": ["pac-stg", "pac stg"], "applications": ["comdev", "finance"] },
  "Pa-pro-dev":     { "nicknames": ["pac-dev", "pac dev"], "applications": ["comdev", "finance"] },
  "PALegacySharedServices": { "nicknames": ["shared", "ss"] }
}
```

Either field may be omitted; an account without aliases gets `[]` for both in `accounts.json`.

**When to use which:**
- **Nickname** — there's exactly one account this shorthand could mean. `pac-prd`, `shared`, `ss`.
- **Application** — the same app exists in multiple environments and you want a prompt to pick. `finance`, `comdev`, `eam`.

**Add an alias:**

1. Edit `aws-configs/aliases.json`. Keys must match the exact AWS account name.
2. Regenerate: `python aws-configs/tools/generate_aws_config.py`
3. Commit `aliases.json` and `accounts.json` together in a PR.

**Normalization:** matching is case-insensitive and ignores spaces, hyphens, and underscores. `"pac-prd"` also matches `pac prd`, `PAC_PRD`, and `PacPrd`. Same rule applies to applications.

**Validation:** the generator fails loudly if:
- A key in `aliases.json` doesn't match a real AWS account name.
- The same normalized **nickname** appears under two different accounts (1:1 enforced).
- The same normalized string appears as both a nickname and an application (a name is one or the other, never both).

Application names ARE allowed to repeat across accounts — that's the whole point.

---

## How `Sync-AwsConfig.ps1` works

- If `~/.aws/config` does not exist: copies `cloudops.config` directly.
- If it does exist: replaces all blocks owned by the `foundation` or `legacy` SSO sessions with the contents of `cloudops.config`. Any personal profiles (other sessions) are preserved.
- Writes a timestamped backup (`~/.aws/config.backup-<timestamp>`) before overwriting.
- Run with `-WhatIf` to preview changes without applying them.
