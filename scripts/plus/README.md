# PLUS Scripts

Standalone scripts replacing legacy PLUSSysAdmins module functions. No VM workstation or PowerShell profile required — run from any domain-joined machine or RDSH terminal server.

| Script | Kiro Task | Audience | Replaces |
|--------|-----------|----------|---------|
| [`New-PLUSCustomerUser/`](New-PLUSCustomerUser/README.md) | `PLUS: New Customer User` | Support / SRE | `PLUS_Create_CustomerUser` |
| [`Enable-PLUSCustomerUser/`](Enable-PLUSCustomerUser/README.md) | `PLUS: Enable Customer User` | Support / SRE | `PLUS_CustomerUsers_QuickSetup -Reenable` |
| [`Disable-PLUSCustomerUser/`](Disable-PLUSCustomerUser/README.md) | `PLUS: Disable Customer User` | Support / SRE | `PLUS_TerminateCustUser` |
| [`PLUS-RefreshDBData/`](PLUS-RefreshDBData/README.md) | `PLUS: DB Refresh` | DBA / SRE | `Invoke-PLUSSqlDBRefresh` + `Update-PLUSDBData` |

## Shared config

All three scripts read from [`config/`](config/) — one canonical copy. Update customer lists here; changes apply to all three scripts automatically.

## Support staff launcher

Non-technical Support staff use [`support/PLUS-UserAdmin.bat`](support/PLUS-UserAdmin.bat) — a menu-driven launcher that prompts for inputs and dispatches to the correct script. On RDSH servers it lives at `C:\PLUS\Scripts\support\PLUS-UserAdmin.bat`.

## Deploying to RDSH servers

After any script update, an SRE runs:

```powershell
pwsh scripts\plus\Sync-PLUSScripts.ps1
```

This copies the entire `scripts/plus/` tree to `C:\PLUS\Scripts\` on all six RDSH servers (`INF-WSRDS001–003`, `INF-WSRDS101–103`) via the `C$` admin share. Use `-WhatIf` to preview. Use `-Servers` to target a subset.

## Prerequisites (on the machine running these scripts)

- PowerShell 7 (`pwsh`)
- RSAT ActiveDirectory module
- SqlServer module 21.x — `Install-Module SqlServer -RequiredVersion 21.1.18226`
- Network access to `aspgov.pri`, `centroid.cloud.lcl`, PLUS SQL instances, and PLUS file servers
