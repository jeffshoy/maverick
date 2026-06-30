# PLUS-RefreshDBData

Runs the PLUS post-restore data refresh SQL against a destination database. Renders the complete T-SQL from bundled templates and either executes it remotely or copies it to the clipboard for manual SSMS execution.

The backup and restore steps are **not** performed by this script — the DBA or Rubrik handles restoring the database first.

---

## Usage

```powershell
# Remote execution — runs SQL directly against the destination instance
.\PLUS-RefreshDBData.ps1 -DestDB orotrnfinpro -DestSQLEnv STG04

# Copy to clipboard — DBA pastes into SSMS and runs manually
.\PLUS-RefreshDBData.ps1 -DestDB orotrnfinpro -CopyToClipboard

# Dry run — renders SQL and prints it; nothing executes or copies
.\PLUS-RefreshDBData.ps1 -DestDB orotrnfinpro -DestSQLEnv STG04 -WhatIf

# Pre-DB-upgrade (remote) — data refresh + pre-upgrade scripts
.\PLUS-RefreshDBData.ps1 -DestDB orofinpro -DestSQLEnv PRD04 -PreDBUpgrade

# Pre-DB-upgrade (clipboard) — includes PASP-to-ASP block for matching customer
.\PLUS-RefreshDBData.ps1 -DestDB orofinpro -CopyToClipboard -PreDBUpgrade -FromAWSCustomerCodes 'oro'

# Post-DB-upgrade (clipboard)
.\PLUS-RefreshDBData.ps1 -DestDB orofinpro -CopyToClipboard -PostDBUpgrade
```

---

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-DestDB` | Required | Destination DB name (e.g. `orotrnfinpro`). Min 4 chars. |
| `-DestSQLEnv` | Required* | SQL environment key: `PRD01`, `PRD04`, `STG01`, `STG04`, `DEV01`, `DEV04`. *Not required when `-CopyToClipboard` is used. |
| `-SourceDB` | Auto-derived | Label stamped into the rendered SQL header for traceability. Defaults to `DestDB` with `trn` removed. Does not affect SQL execution. |
| `-RestoreDateTime` | `latest` | Restore-point label stamped into `menutb_cfg.customer`. `latest` = today's date as `MM-dd-yy`. |
| `-CopyToClipboard` | off | Renders SQL and copies to clipboard. DBA pastes into SSMS. No SQL connection made; `-DestSQLEnv` not required. |
| `-PreDBUpgrade` | off | Append SRE-managed pre-DB-upgrade scripts from `$SqlScriptsRoot`. Cannot be used with `-PostDBUpgrade`. |
| `-PostDBUpgrade` | off | Append SRE-managed post-DB-upgrade scripts from `$SqlScriptsRoot`. Cannot be used with `-PreDBUpgrade`. |
| `-FromAWSCustomerCodes` | `@()` | 3-char customer prefixes migrating from AWS (PASP-to-ASP). Used with `-PreDBUpgrade` to include the PASP-to-ASP block when the customer matches. |
| `-SqlScriptsRoot` | `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PLUS SQL Scripts` | Root UNC path for SRE-managed upgrade SQL files. Override for testing. |
| `-WhatIf` | — | Dry run. Renders and prints the SQL; nothing executes or copies. |

---

## Modes

| Mode | Command |
|---|---|
| Remote execution | `.\PLUS-RefreshDBData.ps1 -DestDB <db> -DestSQLEnv STG04` |
| Clipboard for SSMS | `.\PLUS-RefreshDBData.ps1 -DestDB <db> -CopyToClipboard` |
| Remote + pre-upgrade | `.\PLUS-RefreshDBData.ps1 -DestDB <db> -DestSQLEnv PRD04 -PreDBUpgrade` |
| Clipboard + pre-upgrade | `.\PLUS-RefreshDBData.ps1 -DestDB <db> -CopyToClipboard -PreDBUpgrade` |
| Clipboard + post-upgrade | `.\PLUS-RefreshDBData.ps1 -DestDB <db> -CopyToClipboard -PostDBUpgrade` |

> **Note:** `-PreDBUpgrade` and `-PostDBUpgrade` are mutually exclusive. Run them as separate steps.

---

## Pre-upgrade scripts included (when `-PreDBUpgrade`)

| Script | Condition |
|---|---|
| `02 Database Principals, Permissions.sql` | Always |
| `03-PROCEDURE-spi_sp_grantdbaccess.sql` | Always |
| `PLUS_DB-Onboarding_52.sql` | Always |
| `5.2\PASP-to-ASP\PLUS_52_PASP-to-ASP_DBchanges.sql` | Only if customer prefix is in `-FromAWSCustomerCodes` |
| `PerDB_addPLUSCloudGrps.sql` | FinPro non-attach DBs only |
| `02 DEV ONLY Database Principals, Permissions for Installers.sql` | DEV environments only |

Missing files are skipped with a warning — they are not fatal.

## Post-upgrade scripts included (when `-PostDBUpgrade`)

| Script | Condition |
|---|---|
| `PLUS_DB-Onboarding_52.sql` | Always |
| `autoRefresh\5.2\finpro\proc_header.sql` | FinPro non-attach DBs only |

---

## Prerequisites

- PowerShell 7 (`pwsh`)
- **Remote execution only:** SqlServer module 21.x — `Install-Module SqlServer -RequiredVersion 21.1.18226`
- **Remote execution only:** The `CUSTOMERINFO` database must exist on the destination SQL instance
- **`-PreDBUpgrade` / `-PostDBUpgrade`:** Read access to `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PLUS SQL Scripts`

---

## SQL instance map

| Key | Instance |
|---|---|
| PRD01 | `CLD-PPLSDB001.aspgov.pri\PLUS` |
| STG01 | `CLD-SPLSDB001.aspgov.pri\PLUS` |
| PRD04 | `CLD-PPLSDB004.aspgov.pri\PLUS` |
| STG04 | `CLD-SPLSDB004.aspgov.pri\PLUS` |
| DEV01 | `CLD-DPLSDB001.aspgov.pri\PLUS` |
| DEV04 | `CLD-DPLSDB004.aspgov.pri\PLUS` |
