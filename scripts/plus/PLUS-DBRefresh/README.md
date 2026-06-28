# PLUSDBRefreshKit

Full PLUS database refresh pipeline: backup source DB → restore to destination → run post-restore data refresh SQL. Any step can be skipped independently.

Replaces the legacy `Invoke-PLUSSqlDBRefresh` + `Update-PLUSDBData` workflow. Rubrik is decommissioned — this uses native SQL backup/restore via `T:\transfer\`.

---

## What it does

1. Backs up the source DB (PRD/DEV) to `\\<srcServer>\T$\transfer\`
2. Copies the `.bak` to the destination server if they're on different clusters
3. Restores the `.bak` to the destination DB (replaces if exists, auto-relocates files)
4. Fixes logical file names, sets SIMPLE recovery on non-prod
5. Deletes the `.bak` on success (use `-KeepBackup` to retain it)
6. Runs the post-restore data refresh SQL via `PLUSDBRefreshKit.psm1` (executed in-memory, no `.sql` file written)

---

## Usage

```powershell
# PRD04 -> STG04 TRN refresh (most common)
.\Invoke-PLUSDBRefresh.ps1 -SourceDB orofinpro

# PRD -> STG same-name refresh (internal testing)
.\Invoke-PLUSDBRefresh.ps1 -SourceDB orofinpro -DestDB orofinpro

# DEV01 -> STG01 refresh
.\Invoke-PLUSDBRefresh.ps1 -SourceDB hfmfinplus -SourceSQLEnv DEV01

# Dry run — see what would happen, nothing executes
.\Invoke-PLUSDBRefresh.ps1 -SourceDB orofinpro -WhatIf

# DBA already manually restored — run data refresh SQL only
.\Invoke-PLUSDBRefresh.ps1 -DestDB orotrnfinpro -DestSQLEnv STG04 -SkipRestore

# Restore only, skip data refresh (e.g. before a DB upgrade)
.\Invoke-PLUSDBRefresh.ps1 -SourceDB orofinpro -SkipDataRefresh
```

---

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-SourceDB` | Required | Source DB name (e.g. `orofinpro`). Min 4 chars. Not required with `-SkipRestore`. |
| `-DestDB` | Auto-derived | TRN equivalent (inserts `trn` after 3-char prefix). For PRD→STG, pass the same name as `-SourceDB`. Required with `-SkipRestore`. |
| `-SourceSQLEnv` | Auto-detected | `PRD04` for 5.2 DBs (finpro/compro/finplus52), `PRD01` for others. Use `DEV01`/`DEV04` for dev scenarios. |
| `-DestSQLEnv` | Auto-detected | `STG04` when source is `PRD04`/`DEV04`, `STG01` otherwise. Required with `-SkipRestore`. |
| `-RestoreDateTime` | `latest` | Point-in-time label stamped into the data refresh SQL. |
| `-KeepBackup` | off | Keep the `.bak` file after a successful restore. |
| `-SkipRestore` | off | Skip backup + restore. Run data refresh SQL only (DBA already restored manually). Requires `-DestDB` and `-DestSQLEnv`. |
| `-SkipDataRefresh` | off | Skip the post-restore SQL. Restore only. |
| `-WhatIf` | — | Dry run. Shows what would happen without making any changes. |

---

## Scenarios

| Scenario | Command |
|---|---|
| PRD → TRN (customer refresh) | `.\Invoke-PLUSDBRefresh.ps1 -SourceDB <db>` |
| PRD → STG (same-name, internal) | `.\Invoke-PLUSDBRefresh.ps1 -SourceDB <db> -DestDB <db>` |
| DEV → TRN | `.\Invoke-PLUSDBRefresh.ps1 -SourceDB <db> -SourceSQLEnv DEV01` |
| DEV → STG | `.\Invoke-PLUSDBRefresh.ps1 -SourceDB <db> -DestDB <db> -SourceSQLEnv DEV01` |
| DBA already restored, data refresh only | `.\Invoke-PLUSDBRefresh.ps1 -DestDB <destdb> -DestSQLEnv STG04 -SkipRestore` |
| Restore only (pre-upgrade) | `.\Invoke-PLUSDBRefresh.ps1 -SourceDB <db> -SkipDataRefresh` |

---

## Prerequisites

- PowerShell 7 (`pwsh`)
- SqlServer module 21.x — `Install-Module SqlServer -RequiredVersion 21.1.18226`
- Read/write access to `\\<server>\T$\transfer\` on both source and destination SQL servers
- The `CUSTOMERINFO` database must exist on the destination SQL instance — both refresh templates query `[CUSTOMERINFO].efpcustomerinfo.dbo.CustomerProfile`

---

## Module: PLUSDBRefreshKit

`PLUSDBRefreshKit.psm1` is the engine that generates the post-restore data refresh SQL. `Invoke-PLUSDBRefresh.ps1` imports and calls it automatically. You can also use the module directly:

```powershell
Import-Module .\PLUSDBRefreshKit.psm1
# Generate and inspect the SQL without executing it
New-PLUSDBRefreshScript -DestDB orotrnfinpro -NoFile -PassThru | Select-Object -First 40
```

See `Examples\Render-Examples.ps1` for more usage examples and `Tests\Test-RenderOutput.ps1` to validate the module output.

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
