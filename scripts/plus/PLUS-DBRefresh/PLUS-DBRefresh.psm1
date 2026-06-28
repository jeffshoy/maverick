#Requires -Version 5.1

<#
    PLUSDBRefreshKit.psm1

    Standalone renderer for PLUS database data-refresh T-SQL.

    What it does
        Produces a complete .sql file that a DBA can review and execute in SSMS
        against a freshly restored destination database. This replaces the
        SRE-only Update-PLUSDBData PowerShell flow for routine training and
        stage refreshes.

    What it does NOT do
        - It does not connect to any SQL instance.
        - It does not read any network share.
        - It does not run pre/post DB-upgrade scripts (those remain SRE-managed).

    Faithful to Update-PLUSDBData (PLUSSysAdmins.psm1) for:
        - Token replacement against the bundled 5.1 / 5.2 templates
        - Login / DB-user reconciliation (5.0/5.1 prelude)
        - SPI_INTEGRATION_DET URL fix (5.2 FinPro non-attach)
        - Reapply orphaned DB-user access (FinPro / ComPro non-attach)
        - Post-refresh verification SELECTs (PLUS_ShowPostRefreshData)
        - Optional refresh audit insert (PLUS_SQLRecordDBRefresh)
#>

# ---------------------------------- module-scoped state ----------------------------------

$script:ModuleRoot        = $PSScriptRoot
$script:ModuleVersion     = '1.0.0'
$script:DefaultTemplate51 = Join-Path $script:ModuleRoot 'Templates\Template_SQL_DBDataRefresh.txt'
$script:DefaultTemplate52 = Join-Path $script:ModuleRoot 'Templates\Template_SQL_DBDataRefresh_52.txt'
$script:DefaultOutputDir  = Join-Path $script:ModuleRoot 'Output'

# Stamped into menutb_cfg.change_uid (and the change_uid columns of any other
# table the templates touch) for every refresh. Change here if your team
# wants a different identifier.
$script:DefaultChangeUid  = 'clouddba'

# ---------------------------------- private helpers ----------------------------------

function Get-PLUSDBProductInfo {
    <#
        Mirrors product / template detection in Update-PLUSDBData.
        Wildcard cases come from PLUSSysAdmins.psm1 lines ~2070-2090.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DBName)

    $isAttach = $false
    $is52     = $false
    $useTpl52 = $false
    $prodVer  = $null

    switch -Wildcard ($DBName.ToLower()) {
        '*pro*attach*'   { $isAttach = $true ; $prodVer = '5.2' ; $useTpl52 = $true ; break }
        '*plus*attach*'  { $isAttach = $true ; $prodVer = '5.1' ; break }
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
    <# Mirrors $specDBstr derivation in Update-PLUSDBData. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DBName)

    $s = $DBName.Substring(3).
        Replace('finpro','').Replace('compro','').
        Replace('finplus51','').Replace('finplus','').
        Replace('complus51','').Replace('complus','').
        Replace('trn','')
    if ($s) { '_' + $s.ToUpper() } else { '' }
}

function Get-PLUSProductLogins {
    <# Mirrors $productLogins computation in Update-PLUSDBData. #>
    [CmdletBinding()]
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
    <# 'latest' or any parseable date -> MM-dd-yy, matching get-date -uformat "%m-%d-%y". #>
    [CmdletBinding()]
    param([string]$Value)
    if (-not $Value -or $Value -ieq 'latest') {
        return (Get-Date).ToString('MM-dd-yy')
    }
    try {
        return ([datetime]$Value).ToString('MM-dd-yy')
    } catch {
        throw "Could not parse RestoreDateTime '$Value'. Use a parseable date or 'latest'."
    }
}

function ConvertTo-TSqlSafeLiteral {
    <# Doubles single quotes for safe T-SQL string-literal embedding. #>
    param([string]$s)
    if ($null -eq $s) { return '' }
    return $s.Replace("'", "''")
}

function Get-RenderHeader {
    param($DestDB,$SrcDB,$Info,$ChangeUid,$RestorePoint,$TemplateName)
    $utc = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
@"
/* ======================================================================
   PLUS DB Data Refresh - Generated Script
   ----------------------------------------------------------------------
   Generated UTC:     $utc
   Generator:         PLUSDBRefreshKit v$($script:ModuleVersion)
   ----------------------------------------------------------------------
   Destination DB:    $DestDB
   Source DB:         $SrcDB
   Restore Point:     $RestorePoint
   Product Version:   $($Info.ProdVer)
   Is Attach DB:      $($Info.IsAttach)
   Template:          $TemplateName
   Stamped change_uid: $ChangeUid
   ----------------------------------------------------------------------
   IMPORTANT BEFORE RUNNING:
   1. Connect SSMS to the DESTINATION SQL instance.
   2. Confirm the destination database is the freshly-restored copy.
   3. Review the script. You can run it section-by-section if you prefer.
   4. SRE-managed pre/post-upgrade SQL (DB onboarding, principals, AWS
      migration, dev-only access) is NOT included by design - request
      from the SRE team if a refresh requires those steps.
   ====================================================================== */

"@
}

function Get-UserRepairBlock {
    <#
        Mirrors the PS-side login/DB-user reconciliation that runs BEFORE the
        templated query in Update-PLUSDBData. Only emitted when the chosen
        template (5.0/5.1/9.0/9.1) does not already include sp_adduser logic.
    #>
    param($DestDB,$ProductLogins)
    $literals = ($ProductLogins | ForEach-Object {
        "    (N'" + (ConvertTo-TSqlSafeLiteral $_) + "')"
    }) -join ",`r`n"
@"
-- ============================================================
-- STEP 1 - Login / DB-user reconciliation (5.0/5.1/9.0/9.1 prelude)
-- Mirrors the PS-side reconciliation that runs before the
-- templated refresh in Update-PLUSDBData.
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
    <#
        Mirrors PLUS_52_FixSPIINTEGRATIONDET for the common case (URL rewrites).
        The SRE-side template (Template_SQL_FinProDB-SPI_INTEGRATION_DET.txt)
        may include additional logic - if so, ask SRE to provide it and
        extend this block.
    #>
    param($DestDB)
@"
-- ============================================================
-- STEP 3 - SPI_INTEGRATION_DET URL fix (5.2 FinPro non-attach)
-- Rewrites APP_SERVICES_URL, LINK_LOGIN_URL, and POD_URL to point
-- at the destination AP server (built from @CUST and the env
-- detected from @@SERVERNAME).
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
       SET OPTION_VALUE = (
           SELECT 'https://' + @APserver
                  + RIGHT(OPTION_VALUE, LEN(OPTION_VALUE) - CHARINDEX('.com', OPTION_VALUE) - 3)
             FROM dbo.SPI_INTEGRATION_DET
            WHERE OPTION_VALUE LIKE 'https://%' AND OPTION_NAME = 'APP_SERVICES_URL')
     WHERE OPTION_VALUE LIKE 'https://%' AND OPTION_NAME = 'APP_SERVICES_URL' ;

    UPDATE dbo.SPI_INTEGRATION_DET
       SET OPTION_VALUE = (
           SELECT 'https://' + @APserver
                  + RIGHT(OPTION_VALUE, LEN(OPTION_VALUE) - CHARINDEX('.com', OPTION_VALUE) - 3)
             FROM dbo.SPI_INTEGRATION_DET
            WHERE OPTION_VALUE LIKE 'https://%' AND OPTION_NAME = 'LINK_LOGIN_URL')
     WHERE OPTION_VALUE LIKE 'https://%' AND OPTION_NAME = 'LINK_LOGIN_URL' ;

    UPDATE dbo.SPI_INTEGRATION_DET
       SET OPTION_VALUE = (
           SELECT 'https://' + @APserver
                  + RIGHT(OPTION_VALUE, LEN(OPTION_VALUE) - CHARINDEX('.com', OPTION_VALUE) - 3)
             FROM dbo.SPI_INTEGRATION_DET
            WHERE OPTION_VALUE LIKE 'https://%' AND OPTION_NAME = 'POD_URL')
     WHERE OPTION_VALUE LIKE 'https://%' AND OPTION_NAME = 'POD_URL' ;

    SELECT db_name() AS [DBNAME], 'SPI_INTEGRATION_DET (after)' AS [TABLENM], * FROM dbo.SPI_INTEGRATION_DET ;
END
ELSE
BEGIN
    PRINT 'SKIP: dbo.SPI_INTEGRATION_DET does not exist on ' + DB_NAME() ;
END
GO
"@
}

function Get-ReapplyUserAccessBlock {
    <#
        Mirrors PLUS_SQL_ReapplyUserAccess. Reattaches DB users with no
        matching server login to <cust><dbuser>sql logins, when those
        logins exist on the destination instance.
    #>
    param($DestDB)
@"
-- ============================================================
-- STEP 4 - Reapply DB User Access (FinPro / ComPro non-attach)
-- ============================================================
USE [$DestDB] ;
GO
DECLARE @cust   NVARCHAR(3) = LEFT(DB_NAME(), 3) ;
DECLARE @dbuser SYSNAME ;
DECLARE @login  SYSNAME ;
DECLARE @sql    NVARCHAR(MAX) = N'' ;

DECLARE orphan_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
      FROM sys.database_principals d
      LEFT JOIN sys.server_principals s ON d.sid = s.sid
     WHERE d.type = 'S'
       AND d.default_schema_name NOT IN ('dbo','guest')
       AND d.name NOT LIKE '%user%'
       AND s.name IS NULL ;

OPEN orphan_cur ;
FETCH NEXT FROM orphan_cur INTO @dbuser ;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @login = @cust + LTRIM(RTRIM(@dbuser)) + N'sql' ;
    IF EXISTS (SELECT 1 FROM master.sys.server_principals WHERE name = @login)
        SET @sql = @sql + N'ALTER USER [' + @dbuser + N'] WITH LOGIN = [' + @login + N'] ; ' ;
    FETCH NEXT FROM orphan_cur INTO @dbuser ;
END
CLOSE orphan_cur ; DEALLOCATE orphan_cur ;

IF LEN(@sql) > 0
BEGIN
    PRINT 'Re-attaching orphaned DB users:' ;
    PRINT @sql ;
    EXEC sp_executesql @sql ;
END
ELSE PRINT 'No orphaned DB users found in ' + DB_NAME() + '.' ;
GO
"@
}

function Get-VerificationBlock {
    <#
        Mirrors PLUS_ShowPostRefreshData -> PLUS_CheckMenutbcfg, PLUS_CheckCRNConfig,
        PLUS_CheckWorkflowConfig, fincustom check, PLUS_SQLGetTransDates.
        All read-only.
    #>
    param($DestDB,$Info)
    $finproOnly = $Info.IsFinPro
    $finOnly    = $Info.IsFin

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(@"
-- ============================================================
-- STEP 5 - POST-REFRESH VERIFICATION (read-only)
-- Skim each result set to confirm the rewire took effect.
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

PRINT '--- DB users / logins (reconciliation status) ---' ;
SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB],
       d.name AS [USER], d.default_schema_name AS [SCHEMA],
       s.name AS [LOGIN], s.type_desc AS [LOGIN_TYPE], s.is_disabled
  FROM sys.database_principals d
  LEFT JOIN sys.server_principals s ON d.sid = s.sid
 WHERE d.type IN ('R','S')
   AND d.name LIKE '%user%'
 ORDER BY d.name ;
"@)

    if ($finOnly) {
        [void]$sb.AppendLine(@"

PRINT '--- workflow_config (Company / *Server / BaseURL%) ---' ;
IF OBJECT_ID('dbo.workflow_config','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], 'workflow_config' AS [TABLE],
           row_id, workflow_service,
           LTRIM(RTRIM(setting_key))   AS setting_key,
           LTRIM(RTRIM(setting_value)) AS setting_value
      FROM dbo.workflow_config
     WHERE setting_key LIKE 'Company%'
        OR setting_key LIKE '%Server'
        OR setting_key LIKE 'BaseURL%'
     ORDER BY row_id ;
ELSE PRINT 'SKIP: workflow_config not present.' ;
"@)
    }

    if ($finproOnly) {
        [void]$sb.AppendLine(@"

PRINT '--- fincustom (BCP BACKUP) ---' ;
IF OBJECT_ID('dbo.fincustom','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], 'fincustom' AS [TABLE], udf1
      FROM dbo.fincustom WHERE key_name = 'BCP BACKUP' ;
ELSE PRINT 'SKIP: fincustom not present.' ;
"@)
    }

    if ($finOnly) {
        [void]$sb.AppendLine(@"

PRINT '--- transaction dates ---' ;
IF OBJECT_ID('dbo.fam_prof','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], 'fam_prof' AS [TABLE], trans_date FROM dbo.fam_prof ;
IF OBJECT_ID('dbo.hrm_prof','U') IS NOT NULL
    SELECT @@SERVERNAME AS [INSTANCE], DB_NAME() AS [DB], 'hrm_prof' AS [TABLE], trans_date FROM dbo.hrm_prof ;
"@)
    }

    [void]$sb.AppendLine('GO')
    return $sb.ToString()
}

# ---------------------------------- public cmdlet ----------------------------------

function New-PLUSDBRefreshScript {
    <#
        .SYNOPSIS
        Renders a complete, ready-to-execute T-SQL data-refresh script for a
        PLUS database. Intended to be reviewed and executed by a DBA in SSMS
        against the destination SQL instance.

        .DESCRIPTION
        Replaces the SRE-only Update-PLUSDBData flow for routine training
        and stage refreshes. Reads no network shares, connects to no SQL
        instance: the rendered script is produced entirely from local
        templates and handed to the DBA.

        Output script structure:
          1. Login/DB-user reconciliation (5.0/5.1/9.0/9.1 only)
          2. Templated data refresh (menutb_cfg, crn_cfg, web_profile,
             workflow_config, fincustom, role/user repair, compat level)
          3. SPI_INTEGRATION_DET URL fix (5.2 FinPro non-attach)
          4. Reapply orphaned DB-user access (FinPro / ComPro non-attach)
          5. Post-refresh verification SELECTs (read-only)

        .PARAMETER DestDB
        Destination database name (e.g. orotrnfinpro). Required.

        .PARAMETER SrcDB
        Source database name. Defaults to DestDB with 'trn' removed.

        .PARAMETER RestoreDateTime
        Restore-point label stamped into menutb_cfg.customer.
        'latest' (default) or any parseable date string.

        .PARAMETER OutputPath
        Override path for the rendered .sql file. Defaults to
        ./Output/<DestDB>_DataRefresh_<utc>.sql alongside the module.

        .PARAMETER NoUserRepair
        Skip the login/DB-user reconciliation prelude. (5.0/5.1/9.0/9.1
        only; the 5.2 template already handles this via sp_adduser.)

        .PARAMETER NoSpiFix
        Skip the SPI_INTEGRATION_DET URL-rewrite block.

        .PARAMETER NoReapplyUserAccess
        Skip the orphaned-DB-user reattachment block.

        .PARAMETER NoVerification
        Skip the appended post-refresh verification SELECTs.

        .PARAMETER Template51Path
        Override path to the 5.0/5.1/9.0 template. Defaults to the bundled file.

        .PARAMETER Template52Path
        Override path to the 5.2/9.1 template. Defaults to the bundled file.

        .PARAMETER PassThru
        Also return the rendered SQL as a string.

        .PARAMETER NoFile
        Do not write a file; emit the rendered SQL to the pipeline. Implies -PassThru.

        .PARAMETER Force
        Overwrite the output file if it already exists.

        .EXAMPLE
        New-PLUSDBRefreshScript -DestDB orotrnfinpro

        Produces ./Output/orotrnfinpro_DataRefresh_<timestamp>.sql.

        .EXAMPLE
        New-PLUSDBRefreshScript -DestDB orotrnfinpro -RestoreDateTime '2026-06-25 23:59:00'

        Refresh to a specific point-in-time label.

        .EXAMPLE
        New-PLUSDBRefreshScript -DestDB orotrnfinpro -NoFile | Out-Host

        Render to console instead of disk.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, Position=0)]
        [Alias('ddb','DestinationDB')]
        [ValidateNotNullOrEmpty()]
        [string]$DestDB,

        [Alias('sdb','SourceDB')]
        [string]$SrcDB,

        [Alias('restoreto','restoredt','date','time')]
        [string]$RestoreDateTime = 'latest',

        [Alias('out','o')]
        [string]$OutputPath,

        [switch]$NoUserRepair,
        [switch]$NoSpiFix,
        [switch]$NoReapplyUserAccess,
        [switch]$NoVerification,

        [string]$Template51Path = $script:DefaultTemplate51,
        [string]$Template52Path = $script:DefaultTemplate52,

        [switch]$PassThru,
        [switch]$NoFile,
        [switch]$Force
    )

    # ----- 0. validate inputs -----
    if ($DestDB.Length -lt 4) {
        throw "DestDB '$DestDB' is too short. Expected '<3-char-cust><dbname>' (e.g. orotrnfinpro)."
    }
    if (-not (Test-Path -LiteralPath $Template51Path)) { throw "5.0/5.1 template not found: $Template51Path" }
    if (-not (Test-Path -LiteralPath $Template52Path)) { throw "5.2/9.1 template not found: $Template52Path" }

    if (-not $SrcDB) {
        $SrcDB = if ($DestDB -match 'trn') { $DestDB -replace 'trn','' } else { $DestDB }
    }

    # ----- 1. detect product version -----
    $info       = Get-PLUSDBProductInfo -DBName $DestDB
    $template   = if ($info.UseTpl52) { $Template52Path } else { $Template51Path }
    $templateNm = Split-Path $template -Leaf
    Write-Verbose "Detected ProdVer=$($info.ProdVer); IsAttach=$($info.IsAttach); Template=$templateNm"

    # ----- 2. compute tokens -----
    $cust  = $DestDB.Substring(0,3)
    $custu = $cust.ToUpper()
    $custl = $cust.ToLower()
    $specDBstr     = Get-PLUSCustSpecialDBStr -DBName $DestDB
    $sRestorePt    = Format-PLUSRestoreDate    -Value  $RestoreDateTime
    $now           = Get-Date
    $sCurrentDT    = $now.ToString('yyyy-MM-dd HH:mm:ss')
    $sCurrentTime  = $now.ToString('HH:mm:ss')
    $logicalFN_MDF = $DestDB
    $logicalFN_LDF = "${DestDB}_Log"
    $productLogins = Get-PLUSProductLogins -ProdVer $info.ProdVer -CustomerLower $custl

    # ----- 3. read & token-replace the template -----
    $templateText = Get-Content -LiteralPath $template -Raw
    $renderedTpl  = $templateText.
        Replace('ZZZDestDBNameZZZ',       $DestDB).
        Replace('ZZZSrcDBNameZZZ',        $SrcDB).
        Replace('ZZZCUSTZZZ',             $custu).
        Replace('ZZZCustZZZ',             $custl).
        Replace('ZZZlogicalFilenmMdfZZZ', $logicalFN_MDF).
        Replace('ZZZlogicalFilenmLdfZZZ', $logicalFN_LDF).
        Replace('ZZZRestoreDateTimeZZZ',  $sRestorePt).
        Replace('ZZZCurrentUserZZZ',      $script:DefaultChangeUid).
        Replace('ZZZCurrentDateTimeZZZ',  $sCurrentDT).
        Replace('ZZZCurrentTimeZZZ',      $sCurrentTime).
        Replace('ZZZCustSpclDBStrZZZ',    $specDBstr)

    # ----- 4. compose the script -----
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine((Get-RenderHeader -DestDB $DestDB -SrcDB $SrcDB -Info $info `
        -ChangeUid $script:DefaultChangeUid `
        -RestorePoint $sRestorePt -TemplateName $templateNm))

    if (-not $NoUserRepair -and -not $info.UseTpl52) {
        [void]$sb.AppendLine((Get-UserRepairBlock -DestDB $DestDB -ProductLogins $productLogins))
    }

    [void]$sb.AppendLine('-- ============================================================')
    [void]$sb.AppendLine("-- STEP 2 - Templated data refresh ($templateNm)")
    [void]$sb.AppendLine('-- ============================================================')
    [void]$sb.AppendLine($renderedTpl)
    [void]$sb.AppendLine('GO')

    if (-not $NoSpiFix -and $info.IsFinPro -and $info.Is52) {
        [void]$sb.AppendLine((Get-SpiFixBlock -DestDB $DestDB))
    }

    if (-not $NoReapplyUserAccess -and ($info.IsFinPro -or $info.IsComPro)) {
        [void]$sb.AppendLine((Get-ReapplyUserAccessBlock -DestDB $DestDB))
    }

    if (-not $NoVerification) {
        [void]$sb.AppendLine((Get-VerificationBlock -DestDB $DestDB -Info $info))
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("PRINT 'DONE - PLUS DB Data Refresh complete for $DestDB'")
    [void]$sb.AppendLine('GO')

    $finalText = $sb.ToString()

    # ----- 5. emit -----
    if ($NoFile) { return $finalText }

    if (-not $OutputPath) {
        $stamp      = $now.ToString('yyyyMMdd-HHmmss')
        $OutputPath = Join-Path $script:DefaultOutputDir "${DestDB}_DataRefresh_${stamp}.sql"
    }
    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
        throw "Output file '$OutputPath' already exists. Use -Force to overwrite."
    }

    # UTF-8 without BOM (cleanest for SSMS).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $finalText, $utf8NoBom)

    if ($PassThru) { return $finalText }
    return Get-Item -LiteralPath $OutputPath
}

Set-Alias -Name PLUS_RenderRefresh -Value New-PLUSDBRefreshScript
Set-Alias -Name pdbrender          -Value New-PLUSDBRefreshScript

Export-ModuleMember -Function 'New-PLUSDBRefreshScript' -Alias 'PLUS_RenderRefresh','pdbrender'
