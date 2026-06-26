#Requires -Version 5.1
#Requires -Modules ActiveDirectory

# SqlServer 22.x has an InOutOfProcHelper bug on this server; force 21.x which is also installed
Import-Module SqlServer -RequiredVersion 21.1.18226 -Force

<#
.SYNOPSIS
    Full PLUS database refresh: backup source DB, restore to destination, run post-restore
    data refresh SQL. Any step can be skipped independently.

.DESCRIPTION
    Standalone replacement for the legacy PLUS_RubrikRestoreDB / Invoke-PLUSSqlDBRefresh +
    Update-PLUSDBData workflow. Rubrik is decommissioned; this script uses native SQL
    backup/restore (Backup-SqlDatabase / Restore-SqlDatabase) with .bak files staged via
    \\<server>\T$\transfer\.

    Full flow (default):
      1. Derive destination DB name and SQL instances from source DB name
      2. Back up source DB to \\<srcServer>\T$\transfer\
      3. If cross-cluster, copy .bak to destination server and delete from source
      4. Restore .bak to destination DB (replace if exists, auto-relocate files)
      5. Fix logical file names, set recovery model, delete .bak on success
      6. Import PLUSDBRefreshKit module and execute post-restore data refresh SQL

    Use -SkipRestore when the DB has already been manually restored by a DBA and only
    the post-restore data refresh SQL needs to run.

    Use -SkipDataRefresh for a restore-only run (e.g. before a DB upgrade where the
    data refresh runs as a separate coordinated step).

    Scenarios covered:
      PRD -> TRN  (most common - customer-requested training refresh)
      PRD -> STG  (stage refresh - internal testing; use -DestDB <same name>)
      DEV -> TRN  (dev-to-train; specify -SourceSQLEnv DEV01 or DEV04)
      DEV -> STG  (dev-to-stage; specify -DestDB <same name> and -SourceSQLEnv)

.PARAMETER SourceDB
    Source database name on the production (or dev) SQL instance (e.g. "orofinpro").
    Minimum 4 characters. The 3-character customer prefix is derived from this.
    Not required when -SkipRestore is set (only -DestDB and -DestSQLEnv are needed).

.PARAMETER DestDB
    Destination database name. Defaults to the TRN equivalent of SourceDB
    (inserts "trn" after the 3-char customer prefix, e.g. orofinpro -> orotrnfinpro).
    For a PRD->STG same-name refresh, pass the same value as SourceDB.
    Required when -SkipRestore is set.

.PARAMETER SourceSQLEnv
    Source SQL environment key. Defaults to PRD04 for 5.2 databases (finpro/compro/finplus52),
    PRD01 for all others. Use DEV01 or DEV04 for dev-to-train/stage scenarios.

.PARAMETER DestSQLEnv
    Destination SQL environment key. Defaults to STG04 when source is PRD04/DEV04,
    STG01 otherwise. Required when -SkipRestore is set.

.PARAMETER RestoreDateTime
    Point-in-time restore label stamped into the data refresh SQL.
    Accepts "latest" or any parseable date string (e.g. "2026-06-20"). Default: "latest".

.PARAMETER KeepBackup
    Keep the .bak file after a successful restore. By default it is deleted on success.

.PARAMETER SkipRestore
    Skip the backup and restore steps entirely. Only the post-restore data refresh SQL
    is executed. Requires -DestDB and -DestSQLEnv to be specified explicitly.

.PARAMETER SkipDataRefresh
    Skip the post-restore data refresh SQL. Restore only.

.EXAMPLE
    .\Invoke-PLUSDBRefresh.ps1 -SourceDB orofinpro
    Full PRD04->STG04 refresh: backs up orofinpro, restores as orotrnfinpro, runs data refresh.

.EXAMPLE
    .\Invoke-PLUSDBRefresh.ps1 -SourceDB orofinpro -DestDB orofinpro
    PRD->STG same-name refresh (no trn rename).

.EXAMPLE
    .\Invoke-PLUSDBRefresh.ps1 -SourceDB hfmfinplus -SourceSQLEnv DEV01
    DEV01->STG01 refresh for a 5.1 customer.

.EXAMPLE
    .\Invoke-PLUSDBRefresh.ps1 -SourceDB orofinpro -WhatIf
    Dry run — shows what would happen without making any changes.

.EXAMPLE
    .\Invoke-PLUSDBRefresh.ps1 -DestDB orotrnfinpro -DestSQLEnv STG04 -SkipRestore
    DBA has already manually restored orotrnfinpro. Runs post-restore data refresh SQL only.

.EXAMPLE
    .\Invoke-PLUSDBRefresh.ps1 -SourceDB orofinpro -SkipDataRefresh
    Restore only — useful before a DB upgrade where data refresh runs as a separate step.

.NOTES
    Author: CloudOps SRE — CentralSquare Technologies
    Replaces: Invoke-PLUSSqlDBRefresh + Update-PLUSDBData (PLUSSysAdmins.psm1)
    No Rubrik dependency. Uses native SQL backup/restore via T:\transfer\.

    Prerequisites:
      - SqlServer module 21.x (Install-Module SqlServer -RequiredVersion 21.1.18226)
      - Read/write access to \\<server>\T$\transfer\ on source and destination SQL servers
      - The CUSTOMERINFO database must exist on the destination SQL instance
        (both refresh templates query [CUSTOMERINFO].efpcustomerinfo.dbo.CustomerProfile)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()][ValidateLength(4, 128)][string]$SourceDB,
    [Parameter()][string]$DestDB,
    [Parameter()][ValidateSet('PRD01','PRD04','STG01','STG04','DEV01','DEV04')][string]$SourceSQLEnv,
    [Parameter()][ValidateSet('PRD01','PRD04','STG01','STG04','DEV01','DEV04')][string]$DestSQLEnv,
    [Parameter()][string]$RestoreDateTime = 'latest',
    [Parameter()][switch]$KeepBackup,
    [Parameter()][switch]$SkipRestore,
    [Parameter()][switch]$SkipDataRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- constants ---------------------------------------------------------

$sqlInstances = @{
    PRD01 = 'CLD-PPLSDB001.aspgov.pri\PLUS'
    STG01 = 'CLD-SPLSDB001.aspgov.pri\PLUS'
    PRD04 = 'CLD-PPLSDB004.aspgov.pri\PLUS'
    STG04 = 'CLD-SPLSDB004.aspgov.pri\PLUS'
    DEV01 = 'CLD-DPLSDB001.aspgov.pri\PLUS'
    DEV04 = 'CLD-DPLSDB004.aspgov.pri\PLUS'
}

# Maps a SQL instance hostname to the UNC transfer share root
function Get-TransferShare { param([string]$SqlEnvKey)
    $host = $sqlInstances[$SqlEnvKey] -replace '\\.*', ''
    return "\\$host\T$\transfer"
}

#endregion

#region --- helpers -----------------------------------------------------------

function Test-Is52DB {
    param([string]$DbName)
    $n = $DbName.ToLower()
    return ($n -match 'finpro' -or $n -match 'finplus52' -or $n -match 'compro')
}

function Get-DefaultDestDB {
    param([string]$SourceDB)
    # Insert 'trn' after the 3-char customer prefix: orofinpro -> orotrnfinpro
    $prefix = $SourceDB.Substring(0, 3).ToLower()
    $rest   = $SourceDB.Substring(3).ToLower()
    # If it already starts with 'trn', don't double-insert
    if ($rest.StartsWith('trn')) { return $SourceDB.ToLower() }
    return "$prefix`trn$rest"
}

function Get-DefaultSourceSQLEnv {
    param([string]$DbName)
    return if (Test-Is52DB $DbName) { 'PRD04' } else { 'PRD01' }
}

function Get-DefaultDestSQLEnv {
    param([string]$SourceSQLEnv)
    return switch ($SourceSQLEnv) {
        'PRD04' { 'STG04' }
        'DEV04' { 'STG04' }
        default { 'STG01' }
    }
}

function Get-SqlServerHostname {
    param([string]$SqlEnvKey)
    return ($sqlInstances[$SqlEnvKey] -replace '\\.*', '').ToLower()
}

function Invoke-RestoreLogicalFileRename {
    <#
    After restore, if the logical file names don't match the destination DB name,
    renames them to <DestDB> (MDF) and <DestDB>_log (LDF).
    #>
    param([string]$DestDB, [string]$Instance)

    $query = @"
USE [master];
DECLARE @mdf sysname, @ldf sysname;
SELECT @mdf = name FROM sys.master_files WHERE database_id = DB_ID(N'$DestDB') AND type = 0;
SELECT @ldf = name FROM sys.master_files WHERE database_id = DB_ID(N'$DestDB') AND type = 1;
IF @mdf IS NOT NULL AND @mdf <> N'$DestDB'
    ALTER DATABASE [$DestDB] MODIFY FILE (NAME = [$($DestDB -replace "'","''")], NEWNAME = [$DestDB]);
IF @ldf IS NOT NULL AND @ldf <> N'${DestDB}_log'
    ALTER DATABASE [$DestDB] MODIFY FILE (NAME = [$($DestDB -replace "'","''")], NEWNAME = [${DestDB}_log]);
"@

    Invoke-Sqlcmd -ServerInstance $Instance -Query $query -QueryTimeout 60 -ErrorAction Stop
}

#endregion

#region --- main script -------------------------------------------------------

# ---- Step 0: Input validation -----------------------------------------------

if ($SkipRestore) {
    if (-not $DestDB) {
        throw "ERROR: -DestDB is required when -SkipRestore is set (no source DB to derive it from)."
    }
    if (-not $DestSQLEnv) {
        throw "ERROR: -DestSQLEnv is required when -SkipRestore is set. Specify the SQL environment key where the DB was restored (e.g. STG01, STG04)."
    }
    # SourceDB not required for SkipRestore, but use DestDB as the "source" for data refresh token
    if (-not $SourceDB) { $SourceDB = $DestDB -replace 'trn', '' }
} else {
    if (-not $SourceDB) {
        throw "ERROR: -SourceDB is required."
    }
}

$sourceDBL = $SourceDB.ToLower()
$destDBL   = if ($DestDB) { $DestDB.ToLower() } else { Get-DefaultDestDB $sourceDBL }
$srcEnv    = if ($SourceSQLEnv) { $SourceSQLEnv.ToUpper() } else { Get-DefaultSourceSQLEnv $sourceDBL }
$dstEnv    = if ($DestSQLEnv) { $DestSQLEnv.ToUpper() } else { Get-DefaultDestSQLEnv $srcEnv }

$srcInstance = $sqlInstances[$srcEnv]
$dstInstance = $sqlInstances[$dstEnv]
$srcHost     = Get-SqlServerHostname $srcEnv
$dstHost     = Get-SqlServerHostname $dstEnv
$isCrossCluster = ($srcHost -ne $dstHost)

Write-Host ''
Write-Host "=== PLUS DB Refresh ===" -ForegroundColor Cyan
if (-not $SkipRestore) {
    Write-Host ("  Source   : {0} on {1} ({2})" -f $sourceDBL, $srcInstance, $srcEnv) -ForegroundColor Cyan
}
Write-Host ("  Dest     : {0} on {1} ({2})" -f $destDBL, $dstInstance, $dstEnv) -ForegroundColor Cyan
Write-Host ("  Restore  : {0}" -f $(if ($SkipRestore) { 'SKIPPED (manual restore assumed)' } else { 'YES' })) -ForegroundColor Cyan
Write-Host ("  DataRefresh: {0}" -f $(if ($SkipDataRefresh) { 'SKIPPED' } else { 'YES' })) -ForegroundColor Cyan
Write-Host ''

# ---- Step 1: Backup ---------------------------------------------------------

$bakFile = $null

if (-not $SkipRestore) {
    $srcTransfer = Get-TransferShare $srcEnv
    $ts          = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bakFileName = "${sourceDBL}_${ts}.bak"
    $bakFile     = "$srcTransfer\$bakFileName"

    Write-Host "Step 1: Backing up $sourceDBL to $bakFile ..." -ForegroundColor Cyan

    # Verify source DB exists before attempting backup
    $dbExists = Invoke-Sqlcmd -ServerInstance $srcInstance `
        -Query "SELECT name FROM sys.databases WHERE name = '$sourceDBL'" `
        -QueryTimeout 30 -ErrorAction Stop
    if (-not $dbExists) {
        throw "ERROR: Database '$sourceDBL' not found on $srcInstance."
    }

    if ($PSCmdlet.ShouldProcess($srcInstance, "Backup-SqlDatabase '$sourceDBL' to $bakFile")) {
        try {
            Backup-SqlDatabase `
                -ServerInstance $srcInstance `
                -Database       $sourceDBL `
                -BackupFile     $bakFile `
                -CopyOnly `
                -CompressionOption On `
                -Checksum `
                -ConnectionTimeout 120 `
                -ErrorAction    Stop
            Write-Host "  OK: Backup complete — $bakFile" -ForegroundColor Green
        } catch {
            throw "ERROR: Backup failed for '$sourceDBL' on $srcInstance. Error: $_"
        }
    }

    # ---- Step 2: Cross-cluster .bak copy ------------------------------------

    $dstTransfer = Get-TransferShare $dstEnv

    if ($isCrossCluster) {
        $dstBakFile = "$dstTransfer\$bakFileName"
        Write-Host "Step 2: Cross-cluster copy — $bakFile -> $dstBakFile ..." -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($dstBakFile, "Copy-Item .bak to destination server")) {
            try {
                Copy-Item -Path $bakFile -Destination $dstBakFile -Force -ErrorAction Stop
                Write-Host "  OK: Copied to $dstBakFile" -ForegroundColor Green
            } catch {
                throw "ERROR: Failed to copy .bak to destination server. Aborting before restore. Error: $_"
            }

            # Delete from source after successful copy
            try {
                Remove-Item -Path $bakFile -Force -ErrorAction Stop
                Write-Verbose "  Deleted source .bak: $bakFile"
            } catch {
                Write-Warning "  Could not delete source .bak after copy — clean up manually: $bakFile"
            }

            $bakFile = $dstBakFile
        }
    } else {
        Write-Verbose "Step 2: Same cluster — no .bak copy needed."
        $bakFile = "$dstTransfer\$bakFileName"
    }

    # ---- Step 3: Restore ----------------------------------------------------

    Write-Host "Step 3: Restoring $bakFile -> $destDBL on $dstInstance ..." -ForegroundColor Cyan

    if ($PSCmdlet.ShouldProcess($dstInstance, "Restore-SqlDatabase '$destDBL' from $bakFile")) {
        try {
            # Convert UNC to local path for restore (SQL Server needs a local path or UNC the instance can reach)
            Restore-SqlDatabase `
                -ServerInstance  $dstInstance `
                -Database        $destDBL `
                -BackupFile      $bakFile `
                -ReplaceDatabase `
                -AutoRelocateFile `
                -ConnectionTimeout 120 `
                -QueryTimeout    3600 `
                -ErrorAction     Stop
            Write-Host "  OK: Restore complete." -ForegroundColor Green
        } catch {
            throw "ERROR: Restore failed for '$destDBL' on $dstInstance. The source .bak is at $bakFile. Error: $_"
        }
    }

    # ---- Step 4: Post-restore fixups ----------------------------------------

    Write-Host "Step 4: Post-restore fixups (logical file names, recovery model) ..." -ForegroundColor Cyan

    if ($PSCmdlet.ShouldProcess($dstInstance, "Fix logical file names for '$destDBL'")) {
        try {
            Invoke-RestoreLogicalFileRename -DestDB $destDBL -Instance $dstInstance
            Write-Verbose "  Logical file names verified/fixed."
        } catch {
            Write-Warning "  Could not fix logical file names — non-fatal. Error: $_"
        }
    }

    # Set SIMPLE recovery on non-prod destinations
    $isProdDest = $dstEnv -like 'PRD*'
    if (-not $isProdDest) {
        if ($PSCmdlet.ShouldProcess($dstInstance, "Set SIMPLE recovery model on '$destDBL'")) {
            try {
                Invoke-Sqlcmd -ServerInstance $dstInstance `
                    -Query "ALTER DATABASE [$destDBL] SET RECOVERY SIMPLE WITH NO_WAIT" `
                    -QueryTimeout 30 -ErrorAction Stop
                Write-Verbose "  Recovery model set to SIMPLE."
            } catch {
                Write-Warning "  Could not set recovery model — non-fatal. Error: $_"
            }
        }
    }

    # ---- Step 5: Delete .bak -------------------------------------------------

    if (-not $KeepBackup -and $bakFile) {
        if ($PSCmdlet.ShouldProcess($bakFile, "Remove-Item .bak file")) {
            try {
                Remove-Item -Path $bakFile -Force -ErrorAction Stop
                Write-Verbose "  Deleted .bak: $bakFile"
            } catch {
                Write-Warning "  Could not delete .bak — clean up manually: $bakFile"
            }
        }
    } elseif ($KeepBackup) {
        Write-Host ("  .bak retained at: $bakFile") -ForegroundColor Yellow
    }
}

# ---- Step 6: Post-restore data refresh SQL -----------------------------------

if (-not $SkipDataRefresh) {
    Write-Host "Step 6: Running post-restore data refresh SQL on $destDBL ($dstInstance) ..." -ForegroundColor Cyan

    $modulePath = Join-Path $PSScriptRoot 'PLUSDBRefreshKit.psm1'
    if (-not (Test-Path $modulePath)) {
        throw "ERROR: PLUSDBRefreshKit.psm1 not found at $modulePath. Ensure the module ships alongside this script."
    }

    Import-Module $modulePath -Force -ErrorAction Stop

    $refreshSql = New-PLUSDBRefreshScript `
        -DestDB          $destDBL `
        -SrcDB           $sourceDBL `
        -RestoreDateTime $RestoreDateTime `
        -NoFile `
        -PassThru

    if ($PSCmdlet.ShouldProcess($dstInstance, "Invoke-Sqlcmd data refresh on '$destDBL'")) {
        try {
            Invoke-Sqlcmd `
                -ServerInstance $dstInstance `
                -Database       $destDBL `
                -Query          $refreshSql `
                -QueryTimeout   120 `
                -ErrorAction    Stop
            Write-Host "  OK: Data refresh complete." -ForegroundColor Green
        } catch {
            throw "ERROR: Post-restore data refresh SQL failed on '$destDBL' at $dstInstance. The database has been restored but may be in an inconsistent state. Run the data refresh manually via -SkipRestore. Error: $_"
        }
    }
}

# ---- Done -------------------------------------------------------------------

Write-Host ''
Write-Host ("DONE: {0} -> {1} at {2}" -f $sourceDBL, $destDBL, (Get-Date)) -ForegroundColor Green

#endregion
