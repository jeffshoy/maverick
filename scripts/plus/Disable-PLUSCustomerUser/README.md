# Disable-PLUSCustomerUser

Standalone replacement for `PLUS_TerminateCustUser "samid" "CaseNo"` from the deprecated PLUSSysAdmins module.

---

## What it does

1. Validates the samid prefix against `config/PLUSCustomers.csv`
2. Removes the user from all customer databases (PRD04+STG04 for 5.2 customers; PRD01+STG01 for non-5.2 — never both) including SQL login removal
3. Removes the user from the `<CUST>_PLUS` AD group on aspgov.pri
4. Disables the aspgov.pri account: sets `Description`, prepends `Info` field with who/when disabled, clears `AccountExpirationDate`
5. Disables the `c_<samid>` account on centroid.cloud.lcl if it exists
6. Deletes the user's RPT folder tree on prod and train file servers — goes directly to `\\server\share\<cust>\<samid>`, no share-wide enumeration

## What it does NOT do

- Touch FTP virtual directories — do those separately if applicable

---

## Prerequisites

- PowerShell 7 (`pwsh`)
- RSAT ActiveDirectory module
- SqlServer module 21.x (`Install-Module SqlServer -RequiredVersion 21.1.18226`)
- Network access to `aspgov.pri`, `centroid.cloud.lcl`, and PLUS SQL instances

---

## Config and template files

This script uses the shared `config\` folder at `scripts\plus\config\` and the shared `templates\` folder at `scripts\plus\templates\`. Scripts reference both via `$scriptDir\..\config\` and `$scriptDir\..\templates\` - no per-script symlinks needed.

### Required files

| File | Purpose |
|------|---------|
| `config\PLUSCustomers.csv` | Single source of truth - all customers with Version column for 5.2 detection |
| `scripts\plus\templates\Template_SQL_RemoveUserAccess-Simple.txt` | SQL removal template (grab from `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\`) |

---

## Usage

Support staff use menu option 3 via `support\PLUS-UserAdmin.bat`. Direct PowerShell invocation below is for SRE / power users.

```powershell
# Standard termination
.\Disable-PLUSCustomerUser.ps1 -Samid lmpkpeterson -CaseNo 02502101

# Dry run (no changes made)
.\Disable-PLUSCustomerUser.ps1 -Samid lmpkpeterson -CaseNo 02502101 -WhatIf

# Force 5.2 SQL envs regardless of PLUSCustomers.csv Version column
.\Disable-PLUSCustomerUser.ps1 -Samid lmpkpeterson -CaseNo 02502101 -Is52Customer
```

---

## Centroid behavior

| Scenario | Result |
|----------|--------|
| `c_<samid>` exists and is enabled | `DISABLED` |
| `c_<samid>` already disabled | `ALREADY-DISABLED` — no change |
| `c_<samid>` does not exist | `NOT-FOUND` — non-fatal |
