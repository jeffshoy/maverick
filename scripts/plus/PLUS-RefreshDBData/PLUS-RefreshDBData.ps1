#Requires -Version 5.1

<#
.SYNOPSIS
    Run the PLUS post-restore data refresh SQL against a destination database.

.DESCRIPTION
    Renders the complete PLUS data-refresh T-SQL from bundled templates and either
    executes it remotely via Invoke-Sqlcmd or copies it to the clipboard for a DBA
    to paste into SSMS.

    The backup and restore steps are NOT performed by this script — the DBA or
    Rubrik is responsible for restoring the database before this script runs.

    Default behavior (no switches):
      Renders the data-refresh SQL and executes it remotely against the destination
      SQL instance via Invoke-Sqlcmd.

    With -CopyToClipboard:
      Renders the SQL and copies it to the clipboard. No SQL connection is made.
      The DBA pastes the script into SSMS and runs it manually.

    With -PreDBUpgrade OR -PostDBUpgrade (mutually exclusive):
      Reads SRE-managed upgrade .sql files from the PLUS SQL Scripts network share
      and appends them to the rendered output, in either remote-execution or
      clipboard mode.

.PARAMETER DestDB
    Destination database name (e.g. "orotrnfinpro"). Required. Min 4 characters.

.PARAMETER DestSQLEnv
    Destination SQL environment key — which SQL instance to target.
    Valid values: PRD01, PRD04, STG01, STG04, DEV01, DEV04.
    Required unless -CopyToClipboard is used.

.PARAMETER SourceDB
    Source database name. Used as a metadata label stamped into the rendered SQL
    for traceability. Defaults to DestDB with 'trn' removed. Does not affect
    what SQL runs against the database.

.PARAMETER RestoreDateTime
    Point-in-time restore label stamped into menutb_cfg.customer.
    Accepts "latest" (default = today's date as MM-dd-yy) or any parseable date.

.PARAMETER CopyToClipboard
    Skip remote SQL execution. Render the script and copy it to the clipboard.
    When this switch is set, -DestSQLEnv is optional (no SQL connection is made).

.PARAMETER PreDBUpgrade
    Append SRE-managed pre-DB-upgrade scripts to the rendered output.
    Reads files from $SqlScriptsRoot. Cannot be combined with -PostDBUpgrade.
    Mirrors the $preDBUpgrade branch in the original Update-PLUSDBData function.

.PARAMETER PostDBUpgrade
    Append SRE-managed post-DB-upgrade scripts to the rendered output.
    Reads files from $SqlScriptsRoot. Cannot be combined with -PreDBUpgrade.
    Mirrors the $postDBUpgrade branch in the original Update-PLUSDBData function.

.PARAMETER FromAWSCustomerCodes
    List of 3-char customer prefixes migrating from AWS (PASP-to-ASP).
    When -PreDBUpgrade is set and the destination DB's customer prefix is in
    this list, the PLUS_52_PASP-to-ASP_DBchanges.sql block is included.

.PARAMETER SqlScriptsRoot
    Root UNC path to the SRE-managed pre/post-upgrade SQL files.
    Defaults to \\CLD-PPLSRDS001.aspgov.pri\PLUS$\PLUS SQL Scripts.

.EXAMPLE
    .\PLUS-RefreshDBData.ps1 -DestDB orotrnfinpro -DestSQLEnv STG04
    Renders and executes the data-refresh SQL against STG04\orotrnfinpro.

.EXAMPLE
    .\PLUS-RefreshDBData.ps1 -DestDB orotrnfinpro -CopyToClipboard
    Copies the rendered data-refresh SQL to clipboard for the DBA to paste into SSMS.

.EXAMPLE
    .\PLUS-RefreshDBData.ps1 -DestDB orotrnfinpro -DestSQLEnv STG04 -WhatIf
    Dry run — renders the SQL and prints it; no execution or clipboard copy.

.EXAMPLE
    .\PLUS-RefreshDBData.ps1 -DestDB orofinpro -DestSQLEnv PRD04 -PreDBUpgrade
    Executes data-refresh SQL then runs pre-DB-upgrade scripts against PRD04.

.EXAMPLE
    .\PLUS-RefreshDBData.ps1 -DestDB orofinpro -CopyToClipboard -PreDBUpgrade -FromAWSCustomerCodes 'oro'
    Copies full data-refresh + pre-upgrade SQL (including PASP-to-ASP block) to clipboard.

.EXAMPLE
    .\PLUS-RefreshDBData.ps1 -DestDB orofinpro -CopyToClipboard -PostDBUpgrade
    Copies data-refresh + post-DB-upgrade SQL to clipboard.

.NOTES
    Author: CloudOps SRE — CentralSquare Technologies
    Standalone script — no external module dependency.

    Prerequisites:
      - SqlServer module 21.x (Install-Module SqlServer -RequiredVersion 21.1.18226)
        Required for remote execution mode; not needed for -CopyToClipboard.
      - The CUSTOMERINFO database must exist on the destination SQL instance
        (both refresh templates query [CUSTOMERINFO].efpcustomerinfo.dbo.CustomerProfile).
      - Read access to $SqlScriptsRoot when using -PreDBUpgrade or -PostDBUpgrade.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateLength(4, 128)]
    [string]$DestDB,

    [Parameter()]
    [ValidateSet('PRD01','PRD04','STG01','STG04','DEV01','DEV04')]
    [string]$DestSQLEnv,

    [Parameter()]
    [string]$SourceDB,

    [Parameter()]
    [string]$RestoreDateTime = 'latest',

    [Parameter()]
    [switch]$CopyToClipboard,

    [Parameter()]
    [switch]$PreDBUpgrade,

    [Parameter()]
    [switch]$PostDBUpgrade,

    [Parameter()]
    [string[]]$FromAWSCustomerCodes = @(),

    [Parameter()]
    [string]$SqlScriptsRoot = '\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PLUS SQL Scripts'
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

$DefaultTemplate51 = Join-Path $PSScriptRoot 'Templates\Template_SQL_DBDataRefresh.txt'
$DefaultTemplate52 = Join-Path $PSScriptRoot 'Templates\Template_SQL_DBDataRefresh_52.txt'
$DefaultChangeUid  = 'clouddba'
$ScriptVersion     = '2.1.0'

#endregion

#region --- input validation --------------------------------------------------

if ($PreDBUpgrade -and $PostDBUpgrade) {
    throw "ERROR: -PreDBUpgrade and -PostDBUpgrade cannot be used together. Run pre-upgrade or post-upgrade separately."
}

if (-not $CopyToClipboard -and -not $DestSQLEnv) {
    throw "ERROR: -DestSQLEnv is required for remote execution. Specify the SQL environment key (e.g. STG01, STG04), or use -CopyToClipboard to skip SQL execution."
}

$destDBL  = $DestDB.ToLower()
$custl    = $destDBL.Substring(0, 3)
$custu    = $custl.ToUpper()

if (-not $SourceDB) {
    $SourceDB = if ($destDBL -match 'trn') { $destDBL -replace 'trn', '' } else { $destDBL }
}
$sourceDBL = $SourceDB.ToLower()

#endregion

#region --- private helpers ---------------------------------------------------

function Get-PLUSDBProductInfo {
    param([Parameter(Mandatory)][string]$DBName)

    $isAttach = $false
    $is52     = $false
    $useTpl52 = $false
    $prodVer  = $null

    switch -Wildcard ($DBName.ToLower()) {
        '*pro*attach*'  { $isAttach = $true ; $prodVer = '5.2' ; $useTpl52 = $true ; break }
        '*plus*attach*' { $isAttach = $true ; $prodVer = '5.1' ; break }
    }

    if (-not $prodVer) {
        switch -Wildcard ($DBName.ToLower()) {
            '*finpro*'    { $prodVer = '5.2' ; $is52 = $true ; $useTpl52 = $true ; break }
            '*finplus52*' { $prodVer = '5.2' ; $is52 = $true ; $useTpl52 = $true ; break }
            '*finplus51'  { $prodVer = '5.1' ; break }
            '*finplus'    { $prodVer = '5.0' ; break }
            '*compro*'    { $prodVer = '9.1' ; $useTpl52 = $true ; break }
            '*complus91'  { $prodVer = '9.1' ; break }
            '*complus'    { $prodVer = '9.0' ; break }
            default       { $prodVer = 'unknown' }
        }
    }

    [pscustomobject]@{
        ProdVer  = $prodVer
        Is52     = $is52
        IsAttach = $isAttach
        UseTpl52 = $useTpl52
        IsFinPro = ($DBName -match '(?i)finpro') -and (-not $isAttach)
        IsComPro = ($DBName -match '(?i)compro') -and (-not $isAttach)
        IsFin    = ($DBName -match '(?i)fin')    -and (-not $isAttach)
    }
}

function Get-PLUSCustSpecialDBStr {
    param([Parameter(Mandatory)][string]$DBName)
    $s = $DBName.Substring(3).
        Replace('finpro','').Replace('compro','').
        Replace('finplus51','').Replace('finplus','').
        Replace('complus51','').Replace('complus','').
        Replace('trn','')
    if ($s) { '_' + $s.ToUpper() } else { '' }
}

function Get-PLUSProductLogins {
    param(
        [Parameter(Mandatory)][string]$ProdVer,
        [Parameter(Mandatory)][string]$CustomerLower
    )
    $logins = New-Object System.Collections.Generic.List[string]
    if ($ProdVer -eq '5.2') {
        [void]$logins.Add('webuser_52')
    } elseif ($ProdVer -match '\.0$' -or $ProdVer -match '\.1$') {
        [void]$logins.Add('webuser')
    }
    [void]$logins.Add('crnuser')
    [void]$logins.Add(($CustomerLower + '_webuser'))
    [void]$logins.Add(($CustomerLower + '_crnuser'))
    , $logins.ToArray()
}

function Format-PLUSRestoreDate {
    param([string]$Value)
    if (-not $Value -or $Value -ieq 'latest') { return (Get-Date).ToString('MM-dd-yy') }
    try { return ([datetime]$Value).ToString('MM-dd-yy') }
    catch { throw "Could not parse RestoreDateTime '$Value'. Use a parseable date or 'latest'." }
}

function ConvertTo-TSqlSafeLiteral {
    param([string]$s)
    if ($null -eq $s) { return '' }
    return $s.Replace("'", "''")
}

function Get-RenderHeader {
    param($DestDB,$SrcDB,$Info,$ChangeUid,$RestorePoint,$TemplateName,$IncludesUpgrade)
    $utc         = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    $upgradeLine = if ($IncludesUpgrade) { "   Includes:          $IncludesUpgrade`n" } else { '' }
@"
/* ======================================================================
   PLUS DB Data Refresh - Generated Script
   ----------------------------------------------------------------------
   Generated UTC:     $utc
   Generator:         PLUS-RefreshDBData v$ScriptVersion
   ----------------------------------------------------------------------
   Destination DB:    $DestDB
   Source DB:         $SrcDB
   Restore Point:     $RestorePoint
   Product Version:   $($Info.ProdVer)
   Is Attach DB:      $($Info.IsAttach)
   Template:          $TemplateName
   Stamped change_uid: $ChangeUid
$upgradeLine   ----------------------------------------------------------------------
   IMPORTANT BEFORE RUNNING:
   1. Connect SSMS to the DESTINATION SQL instance.
   2. Confirm the destination database is the freshly-restored copy.
   3. Review the script. You can run it section-by-section if you prefer.
   ====================================================================== */

"@
}

function Get-UserRepairBlock {
    param($DestDB,$ProductLogins)
    $literals = ($ProductLogins | ForEach-Object {
        "    (N'" + (ConvertTo-TSqlSafeLiteral $_) + "')"
    }) -join ",`r`n"
@"
-- ============================================================
-- STEP 1 - Login / DB-user reconciliation (5.0/5.1/9.0/9.1 prelude)
-- ============================================================
USE [$DestDB] ;
GO
DECLARE @logins TABLE (name SYSNAME) ;
INSERT INTO @logins (name) VALUES
$literals ;

DECLARE @login SYSNAME, @sqlcmd NVARCHAR(MAX) ;
DECLARE login_cur CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @logins ;
OPEN login_cur ;
FETCH NEXT FROM login_cur INTO @login ;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE LOWER(name) = LOWER(@login))
    BEGIN
        SET @sqlcmd = N'ALTER USER [' + @login + N'] WITH LOGIN = [' + @login + N']' ;
        EXEC (@sqlcmd) ;
    END
    ELSE
    BEGIN
        SET @sqlcmd = N'EXEC sp_adduser ''' + @login + N''',''' + @login + N'''' ;
        EXEC (@sqlcmd) ;
    END
    FETCH NEXT FROM login_cur INTO @login ;
END
CLOSE login_cur ; DEALLOCATE login_cur ;
GO
"@
}

function Get-SpiFixBlock {
    param($DestDB)
@"
-- ============================================================
-- STEP 3 - SPI_INTEGRATION_DET URL fix (5.2 FinPro non-attach)
-- ============================================================
USE [$DestDB] ;
GO
DECLARE @ENV varchar(10), @ENVUrlfx varchar(10), @APserver varchar(40),
        @CUST nvarchar(3) = LEFT(DB_NAME(),3),
        @ThisInstanceName nvarchar(100) = CONVERT(nvarchar,(SELECT SERVERPROPERTY('ServerName'))) ;
IF (@ThisInstanceName LIKE '%DPLS%') SET @ENV = 'DEV' ;
IF (@ThisInstanceName LIKE '%PPLS%') SET @ENV = 'LIVE' ;
IF (@ThisInstanceName LIKE '%SPLS%') SET @ENV = 'STAGE' ;
IF (@ThisInstanceName LIKE '%TPLS%') SET @ENV = 'TEST' ;
IF (DB_NAME() LIKE '%demo%') SET @ENV = 'Demo' ;
IF (@ENV = 'LIVE') SET @ENVUrlfx = '' ELSE SET @ENVUrlfx = '-' + LOWER(@ENV) ;
IF (DB_NAME() LIKE '%trn%' OR DB_NAME() LIKE '%ye%') SET @ENVUrlfx = '-train' ;
SET @APserver = 'plus-' + LOWER(@CUST) + @ENVUrlfx + '.aspgov.com' ;

IF OBJECT_ID('dbo.SPI_INTEGRATION_DET','U') IS NOT NULL
BEGIN
    SELECT db_name() AS [DBNAME], 'SPI_INTEGRATION_DET (before)' AS [TABLENM], * FROM dbo.SPI_INTEGRATION_DET ;
    UPDATE dbo.SPI_INTEGRATION_DET
       SET OPTION_VALUE = 'https://' + @APserver + RIGHT(OPTION_VALUE, LEN(OPTION_VALUE) - CHARINDEX('.com', OPTION_VALUE) - 3)
     WHERE OPTION_VALUE LIKE 'https://%' AND OPTION_NAME IN ('APP_SERVICES_URL','LINK_LOGIN_URL','POD_URL') ;
    SELECT db_name() AS [DBNAME], 'SPI_INTEGRATION_DET (after)' AS [TABLENM], * FROM dbo.SPI_INTEGRATION_DET ;
END
ELSE PRINT 'SKIP: dbo.SPI_INTEGRATION_DET does not exist on ' + DB_NAME() ;
GO
"@
}

function Get-ReapplyUserAccessBlock {
    param($DestDB)
@"
-- ============================================================
-- STEP 4 - Reapply DB User Access (FinPro / ComPro non-attach)
-- ============================================================
USE [$DestDB] ;
GO
DECLARE @cust NVARCHAR(3) = LEFT(DB_NAME(),3), @dbuser SYSNAME, @login SYSNAME, @sql NVARCHAR(MAX) = N'' ;
DECLARE orphan_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name FROM sys.database_principals d
    LEFT JOIN sys.server_principals s ON d.sid = s.sid
    WHERE d.type = 'S' AND d.default_schema_name NOT IN ('dbo','guest')
      AND d.name NOT LIKE '%user%' AND s.name IS NULL ;
OPEN orphan_cur ; FETCH NEXT FROM orphan_cur INTO @dbuser ;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @login = @cust + LTRIM(RTRIM(@dbuser)) + N'sql' ;
    IF EXISTS (SELECT 1 FROM master.sys.server_principals WHERE name = @login)
        SET @sql = @sql + N'ALTER USER [' + @dbuser + N'] WITH LOGIN = [' + @login + N'] ; ' ;
    FETCH NEXT FROM orphan_cur INTO @dbuser ;
END
CLOSE orphan_cur ; DEALLOCATE orphan_cur ;
IF LEN(@sql) > 0 BEGIN PRINT 'Re-attaching orphaned DB users:' ; PRINT @sql ; EXEC sp_executesql @sql ; END
ELSE PRINT 'No orphaned DB users found in ' + DB_NAME() + '.' ;
GO
"@
}

function Get-VerificationBlock {
    param($DestDB,$Info)
    $finproOnly = $Info.IsFinPro
    $finOnly    = $Info.IsFin
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(@"
-- ============================================================
-- STEP 5 - POST-REFRESH VERIFICATION (read-only)
-- ============================================================
USE [$DestDB] ;
GO
PRINT '--- menutb_cfg ---' ;
IF OBJECT_ID('dbo.menutb_cfg','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], 'menutb_cfg' AS [TABLE], * FROM dbo.menutb_cfg ;
ELSE PRINT 'SKIP: menutb_cfg not present.' ;
PRINT '--- crn_cfg ---' ;
IF OBJECT_ID('dbo.crn_cfg','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], 'crn_cfg' AS [TABLE], * FROM dbo.crn_cfg ;
ELSE PRINT 'SKIP: crn_cfg not present.' ;
PRINT '--- DB users / logins ---' ;
SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], d.name AS [USER],
       s.name AS [LOGIN], s.type_desc AS [LOGIN_TYPE], s.is_disabled
  FROM sys.database_principals d
  LEFT JOIN sys.server_principals s ON d.sid = s.sid
 WHERE d.type IN ('R','S') AND d.name LIKE '%user%' ORDER BY d.name ;
"@)
    if ($finOnly) {
        [void]$sb.AppendLine(@"

PRINT '--- workflow_config ---' ;
IF OBJECT_ID('dbo.workflow_config','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], row_id,
           LTRIM(RTRIM(setting_key)) AS setting_key, LTRIM(RTRIM(setting_value)) AS setting_value
      FROM dbo.workflow_config
     WHERE setting_key LIKE 'Company%' OR setting_key LIKE '%Server' OR setting_key LIKE 'BaseURL%'
     ORDER BY row_id ;
ELSE PRINT 'SKIP: workflow_config not present.' ;
"@)
    }
    if ($finproOnly) {
        [void]$sb.AppendLine(@"

PRINT '--- fincustom (BCP BACKUP) ---' ;
IF OBJECT_ID('dbo.fincustom','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], udf1 FROM dbo.fincustom WHERE key_name = 'BCP BACKUP' ;
ELSE PRINT 'SKIP: fincustom not present.' ;
"@)
    }
    if ($finOnly) {
        [void]$sb.AppendLine(@"

PRINT '--- transaction dates ---' ;
IF OBJECT_ID('dbo.fam_prof','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], trans_date FROM dbo.fam_prof ;
IF OBJECT_ID('dbo.hrm_prof','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], trans_date FROM dbo.hrm_prof ;
"@)
    }
    [void]$sb.AppendLine('GO')
    return $sb.ToString()
}

function Read-UpgradeScript {
    <#
        Reads a SQL file from $SqlScriptsRoot, applies line patches and an optional
        skip-to-marker, and returns the SQL as a string. Returns $null if the file
        does not exist (caller should emit a warning).
    #>
    param(
        [string]$RelativePath,
        [hashtable]$PatchLines  = @{},
        [string]$SkipToMarker   = $null
    )
    $fullPath = Join-Path $SqlScriptsRoot $RelativePath
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }

    $lines = Get-Content -LiteralPath $fullPath

    # Apply 1-based line patches (mirrors $sSqlCMD[1] = '...' pattern)
    foreach ($idx in $PatchLines.Keys) {
        $lines[$idx] = $PatchLines[$idx]
    }

    # Skip lines before the first line matching the marker
    if ($SkipToMarker) {
        $startIdx = ($lines | Select-String -Pattern $SkipToMarker -SimpleMatch | Select-Object -First 1).LineNumber - 1
        if ($startIdx -ge 0) { $lines = $lines[$startIdx..($lines.Count - 1)] }
    }

    return ($lines -join "`n")
}

#endregion

#region --- render base data-refresh SQL --------------------------------------

$info          = Get-PLUSDBProductInfo -DBName $destDBL
$template      = if ($info.UseTpl52) { $DefaultTemplate52 } else { $DefaultTemplate51 }
$templateNm    = Split-Path $template -Leaf
$specDBstr     = Get-PLUSCustSpecialDBStr -DBName $destDBL
$sRestorePt    = Format-PLUSRestoreDate -Value $RestoreDateTime
$now           = Get-Date
$sCurrentDT    = $now.ToString('yyyy-MM-dd HH:mm:ss')
$sCurrentTime  = $now.ToString('HH:mm:ss')
$productLogins = Get-PLUSProductLogins -ProdVer $info.ProdVer -CustomerLower $custl

if (-not (Test-Path -LiteralPath $template)) {
    throw "ERROR: Template not found at $template"
}

$templateText = Get-Content -LiteralPath $template -Raw
$renderedTpl  = $templateText.
    Replace('ZZZDestDBNameZZZ',       $destDBL).
    Replace('ZZZSrcDBNameZZZ',        $sourceDBL).
    Replace('ZZZCUSTZZZ',             $custu).
    Replace('ZZZCustZZZ',             $custl).
    Replace('ZZZlogicalFilenmMdfZZZ', $destDBL).
    Replace('ZZZlogicalFilenmLdfZZZ', "${destDBL}_Log").
    Replace('ZZZRestoreDateTimeZZZ',  $sRestorePt).
    Replace('ZZZCurrentUserZZZ',      $DefaultChangeUid).
    Replace('ZZZCurrentDateTimeZZZ',  $sCurrentDT).
    Replace('ZZZCurrentTimeZZZ',      $sCurrentTime).
    Replace('ZZZCustSpclDBStrZZZ',    $specDBstr)

$upgradeLabel = if ($PreDBUpgrade) { 'Pre-DB-Upgrade' } elseif ($PostDBUpgrade) { 'Post-DB-Upgrade' } else { $null }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine((Get-RenderHeader -DestDB $destDBL -SrcDB $sourceDBL -Info $info `
    -ChangeUid $DefaultChangeUid -RestorePoint $sRestorePt -TemplateName $templateNm `
    -IncludesUpgrade $upgradeLabel))

if (-not $info.UseTpl52) {
    [void]$sb.AppendLine((Get-UserRepairBlock -DestDB $destDBL -ProductLogins $productLogins))
}

[void]$sb.AppendLine('-- ============================================================')
[void]$sb.AppendLine("-- STEP 2 - Templated data refresh ($templateNm)")
[void]$sb.AppendLine('-- ============================================================')
[void]$sb.AppendLine($renderedTpl)
[void]$sb.AppendLine('GO')

if ($info.IsFinPro -and $info.Is52) {
    [void]$sb.AppendLine((Get-SpiFixBlock -DestDB $destDBL))
}
if ($info.IsFinPro -or $info.IsComPro) {
    [void]$sb.AppendLine((Get-ReapplyUserAccessBlock -DestDB $destDBL))
}
if (-not $info.IsAttach) {
    [void]$sb.AppendLine((Get-VerificationBlock -DestDB $destDBL -Info $info))
}

[void]$sb.AppendLine('')
[void]$sb.AppendLine("PRINT 'DONE - PLUS DB Data Refresh complete for $destDBL'")
[void]$sb.AppendLine('GO')

# $sections is an ordered list of [label, sql] pairs for remote execution or clipboard assembly
$sections = [System.Collections.Generic.List[pscustomobject]]::new()
$sections.Add([pscustomobject]@{ Label = 'Data Refresh' ; Sql = $sb.ToString() })

#endregion

#region --- upgrade script sections ------------------------------------------

$onbPatch = @{
    1 = "@CUST nvarchar(5) = '$custl',"
    2 = "@DBSinc nvarchar(8) = '',  `t`t--TRN, CYE, etc"
    3 = "@DBSexc NVARCHAR(8) = 'nunya',  `t`t--string to exclude matching DB names"
}

if ($PreDBUpgrade) {
    # 02 - Database Principals (skip first 2 lines, mirrors original: select -skip 2)
    $sql02Lines = (Get-Content (Join-Path $SqlScriptsRoot '02 Database Principals, Permissions.sql') -ErrorAction SilentlyContinue)
    if ($sql02Lines) {
        $sections.Add([pscustomobject]@{ Label = 'Pre-Upgrade: DB Principals' ; Sql = ($sql02Lines | Select-Object -Skip 2) -join "`n" })
    } else { Write-Warning "SKIP: '02 Database Principals, Permissions.sql' not found at $SqlScriptsRoot" }

    # 03 - SPI stored proc (skip first 2 lines)
    $sql03Lines = (Get-Content (Join-Path $SqlScriptsRoot '03-PROCEDURE-spi_sp_grantdbaccess.sql') -ErrorAction SilentlyContinue)
    if ($sql03Lines) {
        $sections.Add([pscustomobject]@{ Label = 'Pre-Upgrade: SPI Stored Proc' ; Sql = ($sql03Lines | Select-Object -Skip 2) -join "`n" })
    } else { Write-Warning "SKIP: '03-PROCEDURE-spi_sp_grantdbaccess.sql' not found at $SqlScriptsRoot" }

    # DB Onboarding 5.2 (pre)
    $sqlOnb = Read-UpgradeScript 'PLUS_DB-Onboarding_52.sql' -PatchLines $onbPatch
    if ($sqlOnb) {
        $sections.Add([pscustomobject]@{ Label = 'Pre-Upgrade: DB Onboarding' ; Sql = $sqlOnb })
    } else { Write-Warning "SKIP: 'PLUS_DB-Onboarding_52.sql' not found at $SqlScriptsRoot" }

    # PASP-to-ASP (only for specified customer codes)
    if ($custl -in ($FromAWSCustomerCodes | ForEach-Object { $_.ToLower() })) {
        $sqlPasp = Read-UpgradeScript '5.2\PASP-to-ASP\PLUS_52_PASP-to-ASP_DBchanges.sql' -SkipToMarker 'SET ANSI_NULLS ON'
        if ($sqlPasp) {
            $sections.Add([pscustomobject]@{ Label = 'Pre-Upgrade: PASP-to-ASP' ; Sql = $sqlPasp })
        } else { Write-Warning "SKIP: 'PLUS_52_PASP-to-ASP_DBchanges.sql' not found at $SqlScriptsRoot" }
    }

    # PLUS Cloud Groups (FinPro non-attach only)
    if ($info.IsFinPro) {
        $sqlGrp = Read-UpgradeScript 'PerDB_addPLUSCloudGrps.sql' -PatchLines @{ 1 = "@CUST nvarchar(5) = '$custl'," }
        if ($sqlGrp) {
            $sections.Add([pscustomobject]@{ Label = 'Pre-Upgrade: PLUS Cloud Groups' ; Sql = $sqlGrp })
        } else { Write-Warning "SKIP: 'PerDB_addPLUSCloudGrps.sql' not found at $SqlScriptsRoot" }
    }

    # Dev-only installers
    if ($DestSQLEnv -match 'DEV') {
        $sqlDev = Read-UpgradeScript '02 DEV ONLY Database Principals, Permissions for Installers.sql' -SkipToMarker '--START'
        if ($sqlDev) {
            $sections.Add([pscustomobject]@{ Label = 'Pre-Upgrade: Dev Installers' ; Sql = $sqlDev })
        } else { Write-Warning "SKIP: DEV installer script not found at $SqlScriptsRoot" }
    }
}

if ($PostDBUpgrade) {
    # DB Onboarding 5.2 (post)
    $sqlOnb = Read-UpgradeScript 'PLUS_DB-Onboarding_52.sql' -PatchLines $onbPatch
    if ($sqlOnb) {
        $sections.Add([pscustomobject]@{ Label = 'Post-Upgrade: DB Onboarding' ; Sql = $sqlOnb })
    } else { Write-Warning "SKIP: 'PLUS_DB-Onboarding_52.sql' not found at $SqlScriptsRoot" }

    # Proc header (FinPro non-attach only)
    if ($info.IsFinPro) {
        $sqlProc = Read-UpgradeScript 'autoRefresh\5.2\finpro\proc_header.sql'
        if ($sqlProc) {
            $sections.Add([pscustomobject]@{ Label = 'Post-Upgrade: Proc Header' ; Sql = $sqlProc })
        } else { Write-Warning "SKIP: 'autoRefresh\5.2\finpro\proc_header.sql' not found at $SqlScriptsRoot" }
    }
}

#endregion

#region --- header banner -----------------------------------------------------

Write-Host ''
Write-Host '=== PLUS-RefreshDBData ===' -ForegroundColor Cyan
Write-Host ("  Dest DB      : {0}" -f $destDBL) -ForegroundColor Cyan
Write-Host ("  Source DB    : {0} (label only)" -f $sourceDBL) -ForegroundColor Cyan
if ($DestSQLEnv) {
    Write-Host ("  SQL Instance : {0} ({1})" -f $sqlInstances[$DestSQLEnv], $DestSQLEnv) -ForegroundColor Cyan
}
Write-Host ("  Mode         : {0}" -f $(if ($CopyToClipboard) { 'Copy to clipboard' } else { 'Remote execution' })) -ForegroundColor Cyan
if ($PreDBUpgrade)  { Write-Host "  Upgrade      : Pre-DB-Upgrade scripts included"  -ForegroundColor Yellow }
if ($PostDBUpgrade) { Write-Host "  Upgrade      : Post-DB-Upgrade scripts included" -ForegroundColor Yellow }
Write-Host ''

#endregion

#region --- dispatch ----------------------------------------------------------

if ($CopyToClipboard) {

    # Assemble all sections into one string with labelled separators
    $allSql = ($sections | ForEach-Object {
        "-- ===================================================================`n" +
        "-- SECTION: $($_.Label)`n" +
        "-- ===================================================================`n" +
        $_.Sql
    }) -join "`n`n"

    if ($PSCmdlet.ShouldProcess('clipboard', "Copy $($sections.Count) section(s) for $destDBL")) {
        Set-Clipboard -Value $allSql
        Write-Host "SQL copied to clipboard ($($allSql.Length) characters, $($sections.Count) section(s))." -ForegroundColor Green
        $sections | ForEach-Object { Write-Host ("  - {0}" -f $_.Label) -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host "Paste into SSMS, confirm you are connected to the correct destination" -ForegroundColor Yellow
        Write-Host "SQL instance, then execute." -ForegroundColor Yellow
    }

} else {

    # SqlServer 22.x has an InOutOfProcHelper bug on this server; force 21.x which is also installed
    Import-Module SqlServer -RequiredVersion 21.1.18226 -Force

    $dstInstance = $sqlInstances[$DestSQLEnv]

    foreach ($section in $sections) {
        Write-Host "Executing '$($section.Label)' on $destDBL ($dstInstance) ..." -ForegroundColor Cyan
        if ($PSCmdlet.ShouldProcess($dstInstance, "Invoke-Sqlcmd '$($section.Label)' on '$destDBL'")) {
            try {
                Invoke-Sqlcmd `
                    -ServerInstance $dstInstance `
                    -Database       $destDBL `
                    -Query          $section.Sql `
                    -QueryTimeout   120 `
                    -ErrorAction    Stop
                Write-Host "  OK: $($section.Label) complete." -ForegroundColor Green
            } catch {
                throw "ERROR: '$($section.Label)' failed on '$destDBL' at $dstInstance. Re-run with -CopyToClipboard to inspect and run manually. Error: $_"
            }
        }
    }
}

Write-Host ''
Write-Host ("DONE: {0} at {1}" -f $destDBL, (Get-Date)) -ForegroundColor Green

#endregion
