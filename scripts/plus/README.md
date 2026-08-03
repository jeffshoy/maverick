# PLUS Scripts

Standalone scripts replacing legacy PLUSSysAdmins module functions. No VM workstation or PowerShell profile required - run from any domain-joined machine or RDSH terminal server.

---

## Quick Start for Support Staff

Double-click `support\PLUS-UserAdmin.bat`.

On an RDSH terminal server: `C:\PLUS\Scripts\support\PLUS-UserAdmin.bat`.

A menu appears. Pick an option. That's it. No PowerShell knowledge needed.

---

## Scripts

| Script | Purpose | Audience | Replaces legacy |
|--------|---------|----------|-----------------|
| [`New-PLUSCustomerUser/`](New-PLUSCustomerUser/README.md) | Create new customer user end-to-end | Support / SRE | `PLUS_Create_CustomerUser` |
| [`Enable-PLUSCustomerUser/`](Enable-PLUSCustomerUser/README.md) | Re-enable a terminated user | Support / SRE | `PLUS_CustomerUsers_QuickSetup -Reenable` |
| [`Disable-PLUSCustomerUser/`](Disable-PLUSCustomerUser/README.md) | Terminate/disable a user | Support / SRE | `PLUS_TerminateCustUser` |
| [`Grant-PLUSUserAccess/`](Grant-PLUSUserAccess/README.md) | Re-grant SQL access after a DB refresh | Support / SRE | `PLUS_GrantUserAccess` |
| [`Get-PLUSUserAccess/`](Get-PLUSUserAccess/README.md) | Read-only access check (AD + SQL) | Support / SRE | `PLUS_CheckUserAccess` |
| [`PLUS-RefreshDBData/`](PLUS-RefreshDBData/README.md) | Post-restore DB data refresh | DBA / SRE | `Invoke-PLUSSqlDBRefresh` |

---

## Shared config

All scripts read from [`config/`](config/) - one canonical copy. Update customer lists here; changes apply to all scripts automatically.

| File | Purpose |
|------|---------|
| `config/PLUSCustomers.csv` | Single source of truth - SiteCode, Name, State, Version, UIDLNFI, CentroidOU |

---

## Shared templates

All SQL templates live in [`templates/`](templates/) - one shared location. Scripts reference this folder directly; there are no per-script `templates\` subfolders.

| File | Used by |
|------|---------|
| `templates\Template_SQL_GrantUserAccess.txt` | New-PLUSCustomerUser, Enable-PLUSCustomerUser, Grant-PLUSUserAccess |
| `templates\Template_SQL_RemoveUserAccess-Simple.txt` | Disable-PLUSCustomerUser |

Template source: `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\`

---

## Support staff launcher

`support\Start-PLUSUserAdmin.ps1` is the primary entry point - a menu-driven TUI launcher that prompts for inputs and dispatches to the correct script. `support\PLUS-UserAdmin.bat` is a thin wrapper that launches it; Support staff double-click the bat file.

Menu options:

| Option | Action |
|--------|--------|
| 1 | New customer user |
| 2 | Re-enable a user |
| 3 | Disable/terminate a user |
| 4 | Re-grant SQL access |
| 5 | Check user access (read-only) |
| Q | Quit |

The launcher handles input validation, presents a WhatIf prompt before making changes, and is the recommended path for non-technical staff.

---

## Deploying to RDSH servers

After any script update, an SRE runs:

```powershell
pwsh scripts\plus\Sync-PLUSScripts.ps1
```

This copies the entire `scripts/plus/` tree to `C:\PLUS\Scripts\` on all six RDSH servers (`INF-WSRDS001-003`, `INF-WSRDS101-103`) via the `C$` admin share. Use `-WhatIf` to preview. Use `-Servers` to target a subset.

---

## Prerequisites (on the machine running these scripts)

- PowerShell 7 (`pwsh`)
- RSAT ActiveDirectory module
- SqlServer module 21.x - `Install-Module SqlServer -RequiredVersion 21.1.18226`
- Network access to `aspgov.pri`, `centroid.cloud.lcl`, PLUS SQL instances, and PLUS file servers

---

## Verify Network Connectivity

Run this before opening a ticket about a script failure - if a required destination doesn't respond, that's the likely root cause, not a bug in the script.

Paste the whole block into a `pwsh` session on the machine you're running `support\PLUS-UserAdmin.bat` (or any individual script) from.

```powershell
# ---- Active Directory ----
# The ActiveDirectory module (Get-ADUser, Set-ADUser, Get-ADDomain, etc.) talks to
# domain controllers over Active Directory Web Services (ADWS) on TCP 9389 by default -
# NOT raw LDAP on port 389 the way ldp.exe or other ADSI tools do. If you're used to
# testing AD connectivity on 389, that check will pass/fail independently of what these
# scripts actually need - test 9389 instead.

# aspgov.pri: the scripts resolve the PDC emulator dynamically via
# (Get-ADDomain aspgov.pri).PDCEmulator, and only fall back to the literal host below
# if that lookup fails. If the domain itself is reachable, the real PDC target is too -
# use inf-svrdc101.aspgov.pri as a stand-in for the connectivity check.
Test-NetConnection inf-svrdc101.aspgov.pri -Port 9389

# centroid.cloud.lcl - hardcoded literal used for the c_<samid> account
Test-NetConnection centroid.cloud.lcl -Port 9389

# ---- SQL (PLUS named instances: \PLUS) ----
# These are SQL Server NAMED instances, so a client normally resolves the actual
# dynamic TCP port via the SQL Browser service on UDP 3090 - Test-NetConnection only
# tests TCP by default, so a "pass" on 3090 below is not proof the UDP browser
# service itself is reachable, just that TCP-something answers there (usually nothing
# should, so an outright refusal/timeout is expected and not meaningful on its own).
# If you know the static TCP port configured for the PLUS instance, test that
# directly instead - contact a DBA if you're not sure whether a static port is set.
Test-NetConnection CLD-PPLSDB001.aspgov.pri -Port 3090   # PRD01
Test-NetConnection CLD-SPLSDB001.aspgov.pri -Port 3090   # STG01
Test-NetConnection CLD-PPLSDB004.aspgov.pri -Port 3090   # PRD04
Test-NetConnection CLD-SPLSDB004.aspgov.pri -Port 3090   # STG04

# ---- File Servers (SMB) ----
Test-NetConnection plus-efp-fs.aspgov.com       -Port 445
Test-NetConnection plus-efp-fs-train.aspgov.com -Port 445

# CLD-PPLSRDS001.aspgov.pri hosts the shared SQL script templates share
# (\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\).
# Only needed if templates/ can't be read locally - less critical for day-to-day support use.
Test-NetConnection CLD-PPLSRDS001.aspgov.pri -Port 445
```

**Not included above (SRE/DBA-only):** the DEV01/DEV04 SQL instances and the RDSH deployment targets (`INF-WSRDS00x`/`INF-WSRDS10x`, used only by `Sync-PLUSScripts.ps1`) are intentionally left out of this support-staff-facing connectivity check - those are SRE/DBA paths, not something a support user running `PLUS-UserAdmin.bat` needs to validate.
