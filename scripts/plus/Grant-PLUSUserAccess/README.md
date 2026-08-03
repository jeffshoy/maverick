# Grant-PLUSUserAccess

Standalone replacement for `PLUS_GrantUserAccess` from the deprecated PLUSSysAdmins module.

Use this when SQL access needs to be (re-)applied independently — e.g. after a DB refresh that
dropped user permissions, or when a step was skipped during `New-PLUSCustomerUser` or
`Enable-PLUSCustomerUser`.

---

## What it does

1. Looks up the user on aspgov.pri and verifies they are enabled
2. (Re-)adds the user to the `<CUST>_PLUS` AD group
3. Creates/verifies rpt report folders on the production and training file servers
4. Grants SQL access via an interactive Production/Train/Stage selection menu (or a specific
   instance if `-SqlEnv` is supplied) — see [SQL environment selection](#sql-environment-selection) below.
   If the grant fails because the account hasn't replicated to the DC the SQL instance resolves
   logins against yet (e.g. run immediately after `New-PLUSCustomerUser`), it automatically retries
   with backoff — see [SQL access retry behavior](#sql-access-retry-behavior) below

## What it does NOT do

- Create or modify the AD user account — use `New-PLUSCustomerUser` for new users
- Reset passwords or manage account lifecycle — use `Enable-PLUSCustomerUser` for re-enables
- Create or modify the `centroid.cloud.lcl` account

---

## Prerequisites

- PowerShell 7 (`pwsh`)
- RSAT ActiveDirectory module
- SqlServer module 21.x (`Install-Module SqlServer -RequiredVersion 21.1.18226`)
- Network access to `aspgov.pri`, the PLUS file servers, and PLUS SQL instances

---

## Config and template files

### Required files

| File | Purpose |
|------|---------|
| `config\PLUSCustomers.csv` | Single source of truth - all customers with Version column for 5.2 detection |
| `scripts\plus\templates\Template_SQL_GrantUserAccess.txt` | SQL grant template (grab from `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\`) |

The `config\` folder is shared across all PLUS scripts at `scripts\plus\config\`. Scripts reference it via `$scriptDir\..\config\` - no per-script symlink needed.

---

## Usage

Support staff use menu option 4 via `support\PLUS-UserAdmin.bat`. Direct PowerShell invocation below is for SRE / power users.

```powershell
# Grant access using the customer code derived from the samid's first 3 chars
.\Grant-PLUSUserAccess.ps1 -Samid opakalvarado

# Dry run (no changes made)
.\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -WhatIf

# Override DBA flag (grant User_DBA='Y' in the database)
.\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -IsUserDBA

# Skip the interactive SQL env menu and target a specific instance
.\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -SqlEnv PRD01

# Internal user - override the customer code derived from the samid's first 3 chars
.\Grant-PLUSUserAccess.ps1 -Samid someinternaluser -CustCode sjc
```

### Parameters

| Parameter | Required | Purpose |
|---|---|---|
| `-Samid` | Yes | aspgov.pri samAccountName of the user |
| `-SqlEnv` | No | Advanced override: skip the interactive menu and target a single SQL environment (`PRD01`, `STG01`, `PRD04`, `STG04`) |
| `-CustCode` | No | Overrides the customer site code that would otherwise be derived from the samid's first 3 characters. Used by the TUI launcher (`support\PLUS-UserAdmin.bat`) for internal users whose samid doesn't start with a customer code |
| `-IsUserDBA` | No | Grants PLUS Admin backend permissions. Defaults to reading `msDS-cloudExtensionAttribute18` on the AD account if not passed |

---

## SQL environment selection

When `-SqlEnv` is not specified, the script prompts with an interactive menu instead of picking
an environment automatically:

```
Customer: <name> (<CUST>)
1) Production  (<prod-server>)
2) Train       (<stage-server>)
3) Stage       (<stage-server>)

Select environments [1/2/3 or combination e.g. 1,2]:
```

| Selection | Maps to |
|---|---|
| `1` | Production instance (`PRD04` for 5.2 customers, `PRD01` for non-5.2) |
| `2` | Train filter on the stage instance (`STG04`/`STG01`) |
| `3` | Stage filter on the stage instance (`STG04`/`STG01`) |

Combinations are accepted (e.g. `1,2` or `1,2,3`) — the script grants access on each selected
environment in turn and reports a status line per environment. The prompt re-asks until a valid
selection is entered.

Passing `-SqlEnv PRD01|STG01|PRD04|STG04` skips this prompt entirely and grants access on that
single instance only — use this for non-interactive/scripted invocations.

---

## SQL access retry behavior

`CREATE LOGIN [ASPGOV\<samid>] FROM WINDOWS` requires the SQL Server instance to resolve the
Windows account against a domain controller. If the account was just created and hasn't
replicated to that DC yet, this fails with a `Windows NT user or group ... not found` error, which
aborts the entire generated SQL script (including every downstream per-database grant) - this is
the most common reason a fresh `New-PLUSCustomerUser` run appears to fail on the SQL step.

When the SQL grant step hits specifically that error, it automatically retries the whole
generate-and-execute cycle with backoff: 30s, 60s, then 120s per attempt, up to 6 retries (~9.5
minutes total worst case). You'll see a `WARNING: ASPGOV\<samid> not yet visible to <instance>
(AD replication lag) - attempt N of 7, retrying in Ns...` message on each retry - this is expected
and the script is not hung. Any other SQL error (bad template, permissions, connectivity) fails
immediately with no retry, exactly as before.

---

## Output

The script reports status for each step:

| Status | Meaning |
|--------|---------|
| `ADDED` | Added to `<CUST>_PLUS` AD group |
| `ALREADY-MEMBER` | Already in the group — no change |
| `CREATED` | rpt folder created |
| `ALREADY-EXISTS` | rpt folder already present |
| `SKIP-no-cust-share` | Customer share doesn't exist on that server — non-fatal |
| `OK` | SQL grant completed |
| `WHATIF` | `-WhatIf` was passed — no changes made |

Generated SQL scripts are saved to `%TEMP%\GrantUserAccess_<samid>_<cust>_<env>_<ts>.sql` for audit.
