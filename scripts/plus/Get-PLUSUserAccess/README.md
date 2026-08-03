# Get-PLUSUserAccess

Read-only diagnostic that shows the full access picture for a PLUS customer user across
Active Directory (aspgov.pri), Centroid (centroid.cloud.lcl), and SQL.

**This script makes no changes to any system.** Use it to audit a user's current state before
running `Enable/Disable/Grant-PLUS*` scripts, to confirm access was applied correctly after
onboarding, or to troubleshoot a login issue.

---

## What it does

1. Looks up the user on **aspgov.pri** and displays account health, key attributes, and PLUS group membership
2. Checks for a matching `c_<samid>` account on **centroid.cloud.lcl** and reports its enabled status
3. Queries the appropriate PLUS SQL instance(s) to verify the crosswalk record, `sectb_user` record, SQL login, and database user

## What it does NOT do

- Make any changes to AD, SQL, file servers, or any other system
- Support `-WhatIf` (unnecessary - the script is read-only)
- Check FTP virtual directories
- Check rpt folder existence on the file servers - use `Grant-PLUSUserAccess.ps1 -WhatIf` for that

---

## Prerequisites

- PowerShell 7 (`pwsh`)
- RSAT ActiveDirectory module
- SqlServer module 21.x (`Install-Module SqlServer -RequiredVersion 21.1.18226`)
- Network access to `aspgov.pri`, `centroid.cloud.lcl`, and the PLUS SQL instance(s)

---

## Config files

This script uses the shared `config\` folder - no template file is required.

| File | Purpose |
|------|---------|
| `config/PLUSCustomers.csv` | Single source of truth - all customers with Version column for 5.2 detection |

The `config\` folder is shared across all PLUS scripts at `scripts\plus\config\`. Scripts reference it via `$scriptDir\..\config\` - no per-script symlink or junction needed. This script does not use any template file.

---

## Usage

Support staff use menu option 5 via `support\PLUS-UserAdmin.bat` to run this interactively. The direct PowerShell invocation below is for SRE / power users.

By default the customer site code is derived from the first 3 characters of `-Samid`. Pass
`-CustCode` to override that derivation - this is needed for internal/support user accounts whose
samid doesn't start with the customer's site code (the TUI launcher's `Invoke-CheckAccess` function
passes this through automatically when it knows the customer context). The value must be a valid
site code from `config/PLUSCustomers.csv`.

If `-SqlEnv` is omitted, the script no longer auto-selects an environment silently - it prompts with
an interactive Production/Train/Stage menu (see [SQL environment selection](#sql-environment-selection)
below).

```powershell
# Basic - prompts interactively for which SQL environment(s) to check (Production/Train/Stage)
.\Get-PLUSUserAccess.ps1 -Samid sjcjsmith

# Override the SQL environment (e.g. check staging instead of production) - skips the prompt
.\Get-PLUSUserAccess.ps1 -Samid sjcjsmith -SqlEnv STG04

# Verbose - shows PDC resolution, selected SQL env, and per-database detail
.\Get-PLUSUserAccess.ps1 -Samid sjcjsmith -Verbose

# Internal-user override - force a specific customer's config/SQL context regardless of samid prefix
.\Get-PLUSUserAccess.ps1 -Samid someinternaluser -CustCode sjc
```

---

## SQL environment selection

When `-SqlEnv` is not specified, the script derives the customer's Production and Stage SQL instances
from `config/PLUSCustomers.csv` (using `PRD04`/`STG04` for `5.2` customers, `PRD01`/`STG01` for all
others) and then prompts with an interactive menu:

```
  Customer: <Name> (<CODE>)
  1) Production  (<prod-server>)
  2) Train       (<stage-server>)
  3) Stage       (<stage-server>)

  Select environments [1/2/3 or combination e.g. 1,2]:
```

The user can select any single option or a comma-separated combination (e.g. `1,2` or `1,2,3`). This
script is read-only and has no `FilterMode`-based query split (unlike `Grant-PLUSUserAccess.ps1`), so
**Train (2) and Stage (3) both resolve to the same underlying STG SQL instance** for a given customer.
The script dedupes the resulting environment list by instance, so selecting both `2` and `3` only
queries that STG instance once - it does not run the same database checks twice.

Use `-SqlEnv PRD01`, `-SqlEnv STG01`, `-SqlEnv PRD04`, or `-SqlEnv STG04` to skip the prompt entirely
and target a specific instance non-interactively.

---

## Output

The script prints three sections separated by divider lines:

| Section | What is shown |
|---------|--------------|
| **STEP 1 - AD (aspgov.pri)** | SamAccountName, DisplayName, GivenName, Surname, EmailAddress, EmployeeID, Enabled, LockedOut, PasswordExpired, PasswordLastSet, AccountExpirationDate, Description, Info, msDS-cloudExtensionAttribute18, PLUS group membership |
| **STEP 2 - Centroid** | Whether `c_<samid>` exists on centroid.cloud.lcl, Enabled status, and DistinguishedName |
| **STEP 3 - SQL** | For each customer database: crosswalk record, sectb_user row, SQL login entry, and database user entry - plus a green HAS ACCESS or red NO ACCESS summary line per database |

### Color key

| Color | Meaning |
|-------|---------|
| Cyan | Section headers and instance labels |
| Green | Enabled account, HAS ACCESS, PLUS group found |
| Yellow | Warning - non-fatal (disabled Centroid account, database not found, SQL query failed) |
| Red | Error - account disabled, locked out, NO ACCESS, user not found |

---

## Notes

- The script exits with code `1` if the samid prefix is not a valid customer code, or if the aspgov.pri user is not found. All SQL and Centroid failures are non-fatal warnings.
- SQL queries use a 30-second timeout. On a slow or unreachable instance the script prints a yellow warning and continues to the next environment.
- `sectb_crosswalk` is queried by `winuser = '<samidL>'` (lowercase). If the crosswalk was populated with a different casing the lookup may return no results even though the user has access - check the raw crosswalk directly if results look wrong.
