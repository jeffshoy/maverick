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
4. Grants SQL access (PRD04+STG04 for 5.2 customers; PRD01+STG01 for non-5.2 — never both)

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
| `config/PLUSCustomers.csv` | Single source of truth — all customers with Platform column for 5.2 detection |
| `templates/Template_SQL_GrantUserAccess.txt` | SQL grant template (grab from `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\`) |

The `config/` folder is shared with `New-PLUSCustomerUser`. The simplest setup is a symlink:

```powershell
New-Item -ItemType SymbolicLink `
    -Path   ".\config" `
    -Target "..\New-PLUSCustomerUser\config"
```

---

## Usage

```powershell
# Grant access using the customer code derived from the samid's first 3 chars
.\Grant-PLUSUserAccess.ps1 -Samid opakalvarado

# Dry run (no changes made)
.\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -WhatIf

# Force 5.2 SQL envs (PRD04/STG04) regardless of PLUSCustomers.csv Platform column
.\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -Is52Customer

# Override DBA flag (grant User_DBA='Y' in the database)
.\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -IsUserDBA
```

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
