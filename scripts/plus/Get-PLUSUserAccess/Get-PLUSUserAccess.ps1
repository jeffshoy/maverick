#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Read-only diagnostic: show the full access picture for a PLUS customer user across
    AD (aspgov.pri), Centroid (centroid.cloud.lcl), and SQL.

.DESCRIPTION
    Standalone diagnostic for the PLUS user-admin toolkit. Makes NO changes to any system.
    Use this to audit a user's current state before running Enable/Disable/Grant scripts,
    to confirm access was applied correctly, or to troubleshoot a login issue.

    What it does:
      1. Looks up the aspgov.pri AD account and displays account health, attributes,
         and PLUS group membership
      2. Checks for a matching c_<samid> account on centroid.cloud.lcl
      3. Queries the PLUS SQL instance(s) to confirm crosswalk, sectb_user, SQL login,
         and database user records

    What it does NOT do:
      - Make any changes to AD, SQL, file servers, or any other system
      - Require ShouldProcess / WhatIf (read-only throughout)

.PARAMETER Samid
    aspgov.pri samAccountName of the user (e.g. "sjcjsmith").

.PARAMETER SqlEnv
    Advanced override: skip the interactive menu and target a specific SQL environment
    (PRD01, STG01, PRD04, STG04). Omit to use the interactive Production/Train/Stage
    selection menu (1/2/3 or a comma-separated combination, e.g. 1,2). Train and Stage
    both query the same STG instance for this customer, so selecting both only queries it once.

.EXAMPLE
    .\Get-PLUSUserAccess.ps1 -Samid sjcjsmith

.EXAMPLE
    .\Get-PLUSUserAccess.ps1 -Samid sjcjsmith -SqlEnv STG04

.EXAMPLE
    .\Get-PLUSUserAccess.ps1 -Samid sjcjsmith -Verbose

.NOTES
    Author: CloudOps SRE - CentralSquare Technologies
    Read-only diagnostic - no changes made to any system.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Samid,
    [Parameter()][ValidateSet('PRD01','STG01','PRD04','STG04')][string]$SqlEnv,
    [Parameter()][ValidateNotNullOrEmpty()][string]$CustCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# SqlServer 22.x has an InOutOfProcHelper bug on this server; force 21.x which is also installed
Import-Module SqlServer -RequiredVersion 21.1.18226 -Force

#region --- helpers -----------------------------------------------------------

function Get-PLUSConfig {
    <#
    Loads config/PLUSCustomers.csv and returns a hashtable with keys:
    Customers, Customers52, CustomersLNFI, CentroidOuMap, CustomerNames.
    #>
    param([string]$ConfigDir)

    $csvPath = Join-Path $ConfigDir 'PLUSCustomers.csv'
    if (-not (Test-Path $csvPath)) { throw "Missing required config file: $csvPath" }

    $rows = @(Import-Csv $csvPath | Where-Object { $_.SiteCode -match '\S' -and $_.SiteCode -notmatch '^\s*#' })

    $names = @{}
    $rows | Where-Object { $_.Name -match '\S' } | ForEach-Object {
        $names[$_.SiteCode.Trim().ToLower()] = [pscustomobject]@{
            Name  = $_.Name.Trim()
            State = $_.State.Trim()
        }
    }

    return @{
        Customers     = @($rows | ForEach-Object { $_.SiteCode.Trim().ToLower() })
        Customers52   = @($rows | Where-Object { $_.Version.Trim() -eq '5.2' } | ForEach-Object { $_.SiteCode.Trim().ToLower() })
        CustomersLNFI = @($rows | Where-Object { $_.UIDLNFI.Trim()  -eq 'Y'  } | ForEach-Object { $_.SiteCode.Trim().ToLower() })
        CentroidOuMap = @($rows | Where-Object { $_.CentroidOU -match '\S' } | ForEach-Object {
            [pscustomobject]@{ cust = $_.SiteCode.Trim().ToLower(); CentroidCustomerOU = $_.CentroidOU.Trim() }
        })
        CustomerNames = $names
    }
}

#endregion --- helpers --------------------------------------------------------

#region --- main script -------------------------------------------------------

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
$configDir = Join-Path $scriptDir '..\config'

$sqlInstances = @{
    PRD01 = 'CLD-PPLSDB001.aspgov.pri\PLUS'
    STG01 = 'CLD-SPLSDB001.aspgov.pri\PLUS'
    PRD04 = 'CLD-PPLSDB004.aspgov.pri\PLUS'
    STG04 = 'CLD-SPLSDB004.aspgov.pri\PLUS'
}

# ---- Step 0: Load config and validate samid ---------------------------------
Write-Verbose 'Loading configuration...'
$cfg = Get-PLUSConfig -ConfigDir $configDir

$samidL = $Samid.Trim().ToLower()
$custL  = $samidL.Substring(0, 3)
if ($CustCode) { $custL = $CustCode.Trim().ToLower() }

if ($custL -notin $cfg.Customers) {
    Write-Host "ERROR: '$($custL.ToUpper())' is not a valid customer site code in config/PLUSCustomers.csv. Check the samid and try again." -ForegroundColor Red
    exit 1
}

# Select SQL environment(s)
if ($SqlEnv) {
    $sqlEnvs = @($SqlEnv)
} else {
    $is52      = $custL -in $cfg.Customers52
    $custName  = if ($cfg.CustomerNames.ContainsKey($custL)) { $cfg.CustomerNames[$custL].Name } else { $custL.ToUpper() }
    $prdEnv    = if ($is52) { 'PRD04' } else { 'PRD01' }
    $stgEnv    = if ($is52) { 'STG04' } else { 'STG01' }
    $prdServer = if ($is52) { 'cld-pplsdb004' } else { 'cld-pplsdb001' }
    $stgServer = if ($is52) { 'cld-splsdb004' } else { 'cld-splsdb001' }
    $versionTag = if ($is52) { ' - PLUS 5.2' } else { '' }

    Write-Host ""
    Write-Host "  Customer: $custName ($($custL.ToUpper()))$versionTag" -ForegroundColor Cyan
    Write-Host "  1) Production  ($prdServer)" -ForegroundColor White
    Write-Host "  2) Train       ($stgServer)" -ForegroundColor White
    Write-Host "  3) Stage       ($stgServer)" -ForegroundColor White
    Write-Host ""

    do {
        $raw   = (Read-Host "  Select environments [1/2/3 or combination e.g. 1,2]").Trim() -replace '\s', ''
        $parts = @($raw -split ',' | ForEach-Object { $_.Trim() } | Select-Object -Unique | Sort-Object)
        $valid = $parts.Count -ge 1 -and @($parts | Where-Object { $_ -notin @('1','2','3') }).Count -eq 0
        if (-not $valid) {
            Write-Host "  Enter 1, 2, 3 or a comma-separated combination (e.g. 1,2 or 1,2,3)." -ForegroundColor Yellow
        }
    } while (-not $valid)

    # Train and Stage share the same STG instance for this read-only check - dedupe so
    # selecting both doesn't run the same database queries twice.
    $chosenEnvs = @()
    if ('1' -in $parts) { $chosenEnvs += $prdEnv }
    if ('2' -in $parts) { $chosenEnvs += $stgEnv }
    if ('3' -in $parts) { $chosenEnvs += $stgEnv }
    $sqlEnvs = @($chosenEnvs | Select-Object -Unique)
}

# ---- Step 1: aspgov.pri AD lookup -------------------------------------------
Write-Host ('-' * 60) -ForegroundColor Cyan
Write-Host "STEP 1 - AD (aspgov.pri)" -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor Cyan

Write-Verbose 'Resolving aspgov.pri PDC emulator...'
try {
    $pdcAspgov = (Get-ADDomain aspgov.pri -ErrorAction Stop).PDCEmulator
} catch {
    Write-Warning "Could not query aspgov.pri domain - falling back to inf-svrdc101.aspgov.pri. Error: $_"
    $pdcAspgov = 'inf-svrdc101.aspgov.pri'
}

$adUser = $null
try {
    $adUser = Get-ADUser -Identity $samidL -Server $pdcAspgov -Properties * -ErrorAction Stop
} catch {
    Write-Host "ERROR: No user found for '$samidL' on aspgov.pri. Check the samid and try again. Error: $_" -ForegroundColor Red
    exit 1
}

# Account health summary
$enabledColor = if ($adUser.Enabled) { 'Green' } else { 'Red' }
$lockedColor  = if ($adUser.LockedOut) { 'Red' } else { 'Green' }
$pwExpColor   = if ($adUser.PasswordExpired) { 'Yellow' } else { 'Green' }

Write-Host ""
Write-Host ("  SamAccountName  : {0}" -f $adUser.SamAccountName)
Write-Host ("  DisplayName     : {0}" -f $adUser.DisplayName)
Write-Host ("  GivenName       : {0}" -f $adUser.GivenName)
Write-Host ("  Surname         : {0}" -f $adUser.Surname)
Write-Host ("  EmailAddress    : {0}" -f $adUser.EmailAddress)
Write-Host ("  EmployeeID      : {0}" -f $adUser.EmployeeID)
Write-Host ""
Write-Host ("  Enabled         : {0}" -f $adUser.Enabled) -ForegroundColor $enabledColor
Write-Host ("  LockedOut       : {0}" -f $adUser.LockedOut) -ForegroundColor $lockedColor
Write-Host ("  PasswordExpired : {0}" -f $adUser.PasswordExpired) -ForegroundColor $pwExpColor
Write-Host ("  PasswordLastSet : {0}" -f $adUser.PasswordLastSet)
Write-Host ("  AccountExpires  : {0}" -f $(if ($adUser.AccountExpirationDate) { $adUser.AccountExpirationDate } else { '(never)' }))
Write-Host ""
Write-Host ("  Description     : {0}" -f $adUser.Description)
Write-Host ("  Info            : {0}" -f $adUser.Info)
Write-Host ("  CloudAttr18     : {0}" -f $adUser.'msDS-cloudExtensionAttribute18')
Write-Host ""

# PLUS group membership
$plusGroups = @($adUser.MemberOf | Where-Object { $_ -like '*_PLUS*' })
if ($plusGroups.Count -gt 0) {
    $groupNames = ($plusGroups | ForEach-Object {
        if ($_ -match 'CN=([^,]+),') { $matches[1] } else { $_ }
    }) -join ', '
    Write-Host ("  PLUS Groups     : {0}" -f $groupNames) -ForegroundColor Green
} else {
    Write-Host "  PLUS Groups     : (none - user is NOT in any _PLUS group)" -ForegroundColor Yellow
}

Write-Host ""

# ---- Step 2: Centroid lookup ------------------------------------------------
Write-Host ('-' * 60) -ForegroundColor Cyan
Write-Host "STEP 2 - Centroid (centroid.cloud.lcl)" -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor Cyan
Write-Host ""

$centroidSam = "c_$samidL"
$centroidUser = $null
try {
    $centroidUser = Get-ADUser -Identity $centroidSam -Server 'centroid.cloud.lcl' `
        -Properties Enabled, DistinguishedName -ErrorAction SilentlyContinue
} catch {
    # SilentlyContinue does not always suppress on PS5.1 for missing users - absorb here
    $centroidUser = $null
}

if ($centroidUser) {
    $cColor = if ($centroidUser.Enabled) { 'Green' } else { 'Yellow' }
    Write-Host ("  Found   : {0}" -f $centroidSam) -ForegroundColor $cColor
    Write-Host ("  Enabled : {0}" -f $centroidUser.Enabled) -ForegroundColor $cColor
    Write-Host ("  DN      : {0}" -f $centroidUser.DistinguishedName)
} else {
    Write-Host ("  NOT FOUND: no account named '$centroidSam' on centroid.cloud.lcl") -ForegroundColor Yellow
}

Write-Host ""

# ---- Step 3: SQL access check -----------------------------------------------
Write-Host ('-' * 60) -ForegroundColor Cyan
Write-Host "STEP 3 - SQL" -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor Cyan
Write-Host ""

foreach ($env in $sqlEnvs) {
    $instance = $sqlInstances[$env]
    Write-Host ("  Checking {0} ({1}) ..." -f $env, $instance) -ForegroundColor Cyan

    # Find customer databases on this instance
    $dbQuery = @"
SELECT name FROM sys.databases
WHERE name LIKE '$custL%'
  AND (name LIKE '%fin%' OR name LIKE '%comp%')
  AND name NOT LIKE '%[_]%'
ORDER BY name
"@

    $databases = @()
    try {
        $databases = @(Invoke-Sqlcmd `
            -ServerInstance $instance `
            -Database       'master' `
            -Query          $dbQuery `
            -QueryTimeout   30 `
            -ErrorAction    Stop)
    } catch {
        Write-Host ("  WARNING: Could not query sys.databases on {0}. Error: {1}" -f $instance, $_) -ForegroundColor Yellow
        continue
    }

    if ($databases.Count -eq 0) {
        Write-Host ("  WARNING: No customer databases found on {0}" -f $instance) -ForegroundColor Yellow
        continue
    }

    Write-Verbose ("  Found {0} database(s) on {1}: {2}" -f $databases.Count, $instance, ($databases.name -join ', '))

    foreach ($dbRow in $databases) {
        $db = $dbRow.name
        Write-Host ""
        Write-Host ("    Database: {0}.{1}" -f $instance, $db) -ForegroundColor Cyan

        # 1. Find UID in sectb_crosswalk
        $crosswalkQuery = "SELECT TOP 1 spiuser FROM sectb_crosswalk WHERE winuser = '$samidL'"
        $uidRow = $null
        try {
            $uidRow = Invoke-Sqlcmd `
                -ServerInstance $instance `
                -Database       $db `
                -Query          $crosswalkQuery `
                -QueryTimeout   30 `
                -ErrorAction    Stop | Select-Object -First 1
        } catch {
            Write-Host ("      WARNING: Could not query sectb_crosswalk on {0}.{1}. Error: {2}" -f $instance, $db, $_) -ForegroundColor Yellow
            continue
        }

        if (-not $uidRow -or -not $uidRow.spiuser) {
            Write-Host ("      NO ACCESS - '$samidL' not found in sectb_crosswalk for {0}" -f $db) -ForegroundColor Red
            continue
        }

        $uid = $uidRow.spiuser
        Write-Verbose ("      sectb_crosswalk UID: $uid")

        # 2. sectb_user record
        $sectbUserQuery = "SELECT uid, lname, fname, email, user_dba, stampdate FROM sectb_user WHERE uid LIKE '%$uid%'"
        try {
            $sectbRows = @(Invoke-Sqlcmd `
                -ServerInstance $instance `
                -Database       $db `
                -Query          $sectbUserQuery `
                -QueryTimeout   30 `
                -ErrorAction    Stop)
            if ($sectbRows.Count -gt 0) {
                Write-Host "      sectb_user:" -ForegroundColor Cyan
                $sectbRows | Format-Table uid, lname, fname, email, user_dba, stampdate -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
            } else {
                Write-Host ("      WARNING: UID '$uid' not found in sectb_user for {0}" -f $db) -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("      WARNING: Could not query sectb_user on {0}.{1}. Error: {2}" -f $instance, $db, $_) -ForegroundColor Yellow
        }

        # 3. SQL Login
        $loginQuery = "SELECT name, is_disabled, create_date FROM sys.server_principals WHERE name LIKE '%$samidL%' ORDER BY name"
        try {
            $loginRows = @(Invoke-Sqlcmd `
                -ServerInstance $instance `
                -Database       'master' `
                -Query          $loginQuery `
                -QueryTimeout   30 `
                -ErrorAction    Stop)
            if ($loginRows.Count -gt 0) {
                Write-Host "      SQL Login:" -ForegroundColor Cyan
                $loginRows | Format-Table name, is_disabled, create_date -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
            } else {
                Write-Host "      SQL Login: (none matching '$samidL')" -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("      WARNING: Could not query sys.server_principals on {0}. Error: {1}" -f $instance, $_) -ForegroundColor Yellow
        }

        # 4. Database user
        $dbUserQuery = @"
SELECT d.name AS db_user, d.default_schema_name, s.name AS login
FROM sys.database_principals d
JOIN sys.server_principals s ON d.sid = s.sid
WHERE d.name LIKE '%$samidL%'
"@
        try {
            $dbUserRows = @(Invoke-Sqlcmd `
                -ServerInstance $instance `
                -Database       $db `
                -Query          $dbUserQuery `
                -QueryTimeout   30 `
                -ErrorAction    Stop)
            if ($dbUserRows.Count -gt 0) {
                Write-Host "      DB User:" -ForegroundColor Cyan
                $dbUserRows | Format-Table db_user, default_schema_name, login -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
            } else {
                Write-Host "      DB User: (none matching '$samidL')" -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("      WARNING: Could not query sys.database_principals on {0}.{1}. Error: {2}" -f $instance, $db, $_) -ForegroundColor Yellow
        }

        # Summary line for this database
        if ($uidRow -and $uidRow.spiuser) {
            Write-Host ("      HAS ACCESS - {0} found in {1}.{2}" -f $samidL, $instance, $db) -ForegroundColor Green
        } else {
            Write-Host ("      NO ACCESS - {0} not found in {1}.{2}" -f $samidL, $instance, $db) -ForegroundColor Red
        }
    }

    Write-Host ""
}

# ---- Final summary ----------------------------------------------------------
Write-Host ('-' * 60) -ForegroundColor Cyan
Write-Host ("DONE - checked {0} @ {1}" -f $samidL, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Green
Write-Host ('-' * 60) -ForegroundColor Cyan

#endregion --- main script ----------------------------------------------------
