#Requires -Version 5.1
#Requires -Modules ActiveDirectory

# SqlServer 22.x has an InOutOfProcHelper bug on this server; force 21.x which is also installed
Import-Module SqlServer -RequiredVersion 21.1.18226 -Force

<#
.SYNOPSIS
    Grant (or re-grant) SQL database access and AD group membership for an existing PLUS customer user.

.DESCRIPTION
    Standalone replacement for PLUS_GrantUserAccess from the deprecated PLUSSysAdmins module.
    Use this when SQL access needs to be (re-)applied independently — e.g. after a DB refresh
    that dropped user permissions, or when a step was skipped during New/Enable-PLUSCustomerUser.

    Does not require the legacy PowerShell profile or VM workstations.
    All configuration ships with the script under ./config/ and ./templates/.

    What it does:
      1. Looks up the aspgov.pri user and verifies they exist and are enabled
      2. (Re-)adds the user to the <CUST>_PLUS AD group
      3. Creates/verifies rpt report folders on the production and training file servers
      4. Grants SQL access via Template_SQL_GrantUserAccess.txt on PRD04+STG04 (5.2 customers)
         or PRD01+STG01 (non-5.2 customers) — never both; 5.2 customers have no presence on PRD01/STG01

    What it does NOT do:
      - Create or modify the AD user account
      - Reset passwords
      - Create or modify the centroid.cloud.lcl account

.PARAMETER Samid
    aspgov.pri samAccountName of the user (e.g. "opakalvarado").

.PARAMETER Is52Customer
    Override automatic 5.2 detection. When set, PRD04/STG04 SQL envs are included.
    By default the script checks the Platform column in config/PLUSCustomers.csv.

.PARAMETER IsUserDBA
    If set, the user is granted User_DBA='Y' in the database (customer admin level).
    By default, checks msDS-cloudExtensionAttribute18 on the AD account.

.EXAMPLE
    .\Grant-PLUSUserAccess.ps1 -Samid opakalvarado

.EXAMPLE
    .\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -WhatIf

.EXAMPLE
    .\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -Is52Customer

.NOTES
    Author: CloudOps SRE — CentralSquare Technologies
    Replaces: PLUS_GrantUserAccess (PLUSSysAdmins.psm1)
    No VMware, no Rubrik, no PSync dependencies.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Samid,
    [Parameter()][switch]$Is52Customer,
    [Parameter()][switch]$IsUserDBA
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- helpers -----------------------------------------------------------

function Get-PLUSConfig {
    param([string]$ConfigDir)

    $csvPath = Join-Path $ConfigDir 'PLUSCustomers.csv'
    if (-not (Test-Path $csvPath)) { throw "Missing required config file: $csvPath" }

    $rows = @(Import-Csv $csvPath | Where-Object { $_.SiteCode -match '\S' -and $_.SiteCode -notmatch '^\s*#' })

    return @{
        Customers   = @($rows | ForEach-Object { $_.SiteCode.Trim().ToLower() })
        Customers52 = @($rows | Where-Object { $_.Platform.Trim() -eq '52' } | ForEach-Object { $_.SiteCode.Trim().ToLower() })
    }
}

function Add-PLUSGroupMembership {
    param(
        [string]$Samid,
        [string]$CustUpper,
        [string]$PdcAspgov
    )

    $group = "${CustUpper}_PLUS"

    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Add-ADGroupMember '$group' <- '$Samid'")) {
        try {
            Add-ADGroupMember -Identity $group -Members $Samid -Server $PdcAspgov -ErrorAction Stop
            Write-Verbose "  ASPGOV: Added $Samid to $group"
            return [pscustomobject]@{ Group = $group; Status = 'ADDED' }
        } catch {
            if ($_ -match 'already a member') {
                Write-Verbose "  ASPGOV: $Samid is already in $group (no change needed)"
                return [pscustomobject]@{ Group = $group; Status = 'ALREADY-MEMBER' }
            } else {
                return [pscustomobject]@{ Group = $group; Status = "FAILED: $_" }
            }
        }
    } else {
        return [pscustomobject]@{ Group = $group; Status = 'WHATIF' }
    }
}

function New-PLUSReportFolders {
    param(
        [string]$Samid,
        [string]$CustLower,
        [bool]$Is52
    )

    $servers = @('plus-efp-fs.aspgov.com', 'plus-efp-fs-train.aspgov.com')
    if ($Is52) {
        $shares = @('Userfolders', 'Userfolders52', 'Userfolders52TRN')
    } else {
        $shares = @('Userfolders')
    }

    $results = @()
    foreach ($server in $servers) {
        foreach ($share in $shares) {
            if ($share -eq 'Userfolders52' -and $server -match 'train') { continue }
            $custSharePath = "\\$server\$share\$CustLower"
            if (-not (Test-Path $custSharePath)) {
                $results += [pscustomobject]@{ Path = "\\$server\$share\$CustLower\$Samid\rpt"; Status = 'SKIP-no-cust-share' }
                continue
            }
            $rptPath = "$custSharePath\$Samid\rpt"
            if (Test-Path $rptPath) {
                $results += [pscustomobject]@{ Path = $rptPath; Status = 'ALREADY-EXISTS' }
            } elseif ($PSCmdlet.ShouldProcess($rptPath, 'New-Item rpt folder')) {
                try {
                    $null = New-Item -ItemType Directory -Path $rptPath -Force -ErrorAction Stop
                    $results += [pscustomobject]@{ Path = $rptPath; Status = 'CREATED' }
                } catch {
                    $results += [pscustomobject]@{ Path = $rptPath; Status = "FAILED: $_" }
                }
            } else {
                $results += [pscustomobject]@{ Path = $rptPath; Status = 'WHATIF' }
            }
        }
    }
    return $results
}

function Build-PLUSSqlUserInfo {
    param(
        [string]$Samid,
        [string]$FirstName,
        [string]$LastName,
        [string]$EmailAddress,
        [string]$EmployeeID,
        [bool]$IsUserDBA
    )

    $isAdmin  = if ($IsUserDBA) { "'Y'" } else { "'N'" }
    $fnUpper  = $FirstName.Trim().Replace("'", "''").ToUpper()
    $lnUpper  = $LastName.Trim().Replace("'", '').ToUpper()
    $emailLow = $EmailAddress.Trim().ToLower()
    return "('ASPGOV\$Samid','$fnUpper','$lnUpper','$emailLow','$EmployeeID',$isAdmin)--,"
}

function Invoke-PLUSGrantUserAccess {
    param(
        [string]$Samid,
        [string]$CustLower,
        [string]$SqlEnv,
        [string]$SqlInstance,
        [string]$UserInfoToken,
        [string]$TemplatePath,
        [bool]$OnlyTrain
    )

    if (-not (Test-Path $TemplatePath)) {
        return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = "SKIP-no-template ($TemplatePath)"; ScriptPath = $null }
    }

    if ($OnlyTrain) {
        $cursorWhere = "name LIKE LOWER('$CustLower' + '%' + 'trn' + '%') AND (name LIKE '%fin%' OR name LIKE '%comp%') AND name NOT LIKE '%[_]%'"
    } else {
        $cursorWhere = "name LIKE LOWER('$CustLower' + '%' + '' + '%') AND (name LIKE '%fin%' OR name LIKE '%comp%') AND name NOT LIKE '%[_]%'"
    }

    $rawTemplate = Get-Content $TemplatePath -Raw
    $sql = $rawTemplate `
        -replace 'ZZZCustZZZ',            $CustLower `
        -replace 'ZZZUsersInfoZZZ',        $UserInfoToken `
        -replace 'ZZZexecSectbAccessZZZ',  '0' `
        -replace 'ZZZcursorwhereZZZ',      $cursorWhere

    $ts         = Get-Date -Format 'yyyyMMdd_HHmmss'
    $scriptFile = Join-Path $env:TEMP "GrantUserAccess_${Samid}_${CustLower}_${SqlEnv}_${ts}.sql"

    if ($PSCmdlet.ShouldProcess($SqlInstance, "Invoke-Sqlcmd GrantUserAccess for $Samid ($SqlEnv)")) {
        try {
            $generatedSql = Invoke-Sqlcmd `
                -ServerInstance $SqlInstance `
                -Query          $sql `
                -QueryTimeout   120 `
                -ErrorAction    Stop |
                Out-String -Width 800

            $generatedSql = $generatedSql -replace "Changed database context to 'master'\.", ''
            Set-Content -Path $scriptFile -Value $generatedSql -Force

            Invoke-Sqlcmd `
                -ServerInstance $SqlInstance `
                -InputFile      $scriptFile `
                -QueryTimeout   120 `
                -ErrorAction    Stop

            return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = 'OK'; ScriptPath = $scriptFile }
        } catch {
            return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = "FAILED: $_"; ScriptPath = $scriptFile }
        }
    } else {
        return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = 'WHATIF'; ScriptPath = $null }
    }
}

#endregion --- helpers --------------------------------------------------------

#region --- main script -------------------------------------------------------

$scriptDir   = $PSScriptRoot
$configDir   = Join-Path $scriptDir '..\config'
$tmplDir     = Join-Path $scriptDir 'templates'
$sqlTmplPath = Join-Path $tmplDir 'Template_SQL_GrantUserAccess.txt'

$sqlInstances = @{
    PRD01 = 'CLD-PPLSDB001.aspgov.pri\PLUS'
    STG01 = 'CLD-SPLSDB001.aspgov.pri\PLUS'
    PRD04 = 'CLD-PPLSDB004.aspgov.pri\PLUS'
    STG04 = 'CLD-SPLSDB004.aspgov.pri\PLUS'
}

# ---- Step 0: Load config ----------------------------------------------------
Write-Verbose 'Loading configuration...'
$cfg = Get-PLUSConfig -ConfigDir $configDir

# ---- Step 1: Normalize and validate inputs ----------------------------------
$samidL = $Samid.Trim().ToLower()
$custL  = $samidL.Substring(0, 3)
$custU  = $custL.ToUpper()

if ($custL -notin $cfg.Customers) {
    throw "ERROR: '$custU' is not a valid customer site code in config/PLUSCustomers.csv. Check the samid and try again."
}

$bIs52 = $Is52Customer.IsPresent -or ($custL -in $cfg.Customers52)

# ---- Step 2: Resolve aspgov PDC ---------------------------------------------
Write-Verbose 'Resolving aspgov.pri PDC emulator...'
try {
    $pdcAspgov = (Get-ADDomain aspgov.pri -ErrorAction Stop).PDCEmulator
} catch {
    Write-Warning "Could not query aspgov.pri domain — falling back to inf-svrdc101.aspgov.pri. Error: $_"
    $pdcAspgov = 'inf-svrdc101.aspgov.pri'
}

# ---- Step 3: Look up the aspgov.pri user ------------------------------------
Write-Host "Looking up ASPGOV\$samidL ..." -ForegroundColor Cyan

$adUser = $null
try {
    $adUser = Get-ADUser -Filter "samaccountname -eq '$samidL'" `
        -Server $pdcAspgov -Properties * -ErrorAction Stop
} catch {
    throw "ERROR: Failed to query aspgov.pri for '$samidL'. Error: $_"
}

if (-not $adUser) {
    throw "ERROR: No user found for samid '$samidL' on aspgov.pri. Check the samid and try again."
}

if (-not $adUser.Enabled) {
    throw "ERROR: Account '$samidL' is disabled. Enable the account first, or use Enable-PLUSCustomerUser.ps1."
}

Write-Host ("  Found: {0} | Enabled: {1}" -f $adUser.DisplayName, $adUser.Enabled) -ForegroundColor Cyan

# Derive name/contact from the existing AD account
$firstName  = (Get-Culture).TextInfo.ToTitleCase($adUser.GivenName.Trim().ToLower())
$lastName   = (Get-Culture).TextInfo.ToTitleCase($adUser.Surname.Trim().ToLower())
$emailAddr  = $adUser.EmailAddress.Trim().ToLower()
$employeeID = $adUser.EmployeeID.Trim()

# DBA flag: explicit switch wins; otherwise read from AD attribute
$bIsDBA = $IsUserDBA.IsPresent -or ($adUser.'msDS-cloudExtensionAttribute18' -eq 'IsPLUSCustAdmin=TRUE')

# ---- Step 4: Add to <CUST>_PLUS group ---------------------------------------
Write-Host "Verifying AD group membership ..." -ForegroundColor Cyan
$groupResult = Add-PLUSGroupMembership -Samid $samidL -CustUpper $custU -PdcAspgov $pdcAspgov
$groupColor  = switch ($groupResult.Status) {
    'ADDED'          { 'Green'  }
    'ALREADY-MEMBER' { 'Green'  }
    'WHATIF'         { 'Yellow' }
    default          { 'Red'    }
}
Write-Host ("  {0,-20} {1}" -f $groupResult.Status, $groupResult.Group) -ForegroundColor $groupColor

# ---- Step 5: Create/verify rpt folders --------------------------------------
Write-Host "Verifying RPT report folders ..." -ForegroundColor Cyan
$rptResults = New-PLUSReportFolders -Samid $samidL -CustLower $custL -Is52 $bIs52
$rptResults | ForEach-Object {
    $color = if ($_.Status -eq 'CREATED' -or $_.Status -eq 'ALREADY-EXISTS') { 'Green' } `
             elseif ($_.Status -like 'SKIP*' -or $_.Status -eq 'WHATIF')     { 'Yellow' } `
             else { 'Red' }
    Write-Host ("  {0,-20} {1}" -f $_.Status, $_.Path) -ForegroundColor $color
}

# ---- Step 6: SQL access grant -----------------------------------------------
Write-Host "Granting SQL access ..." -ForegroundColor Cyan

$userInfoToken = Build-PLUSSqlUserInfo `
    -Samid        $samidL `
    -FirstName    $firstName `
    -LastName     $lastName `
    -EmailAddress $emailAddr `
    -EmployeeID   $employeeID `
    -IsUserDBA    $bIsDBA

if ($bIs52) {
    $sqlEnvs = @(
        @{ Env = 'PRD04'; Instance = $sqlInstances.PRD04; OnlyTrain = $false }
        @{ Env = 'STG04'; Instance = $sqlInstances.STG04; OnlyTrain = $true  }
    )
} else {
    $sqlEnvs = @(
        @{ Env = 'PRD01'; Instance = $sqlInstances.PRD01; OnlyTrain = $false }
        @{ Env = 'STG01'; Instance = $sqlInstances.STG01; OnlyTrain = $true  }
    )
}

$sqlResults = @()
foreach ($e in $sqlEnvs) {
    Write-Host ("  Granting on {0} ({1}) ..." -f $e.Env, $e.Instance) -ForegroundColor Cyan
    $r = Invoke-PLUSGrantUserAccess `
        -Samid         $samidL `
        -CustLower     $custL `
        -SqlEnv        $e.Env `
        -SqlInstance   $e.Instance `
        -UserInfoToken $userInfoToken `
        -TemplatePath  $sqlTmplPath `
        -OnlyTrain     $e.OnlyTrain
    $sqlResults += $r
    $color = if ($r.Status -eq 'OK') { 'Green' } elseif ($r.Status -eq 'WHATIF') { 'Yellow' } else { 'Red' }
    Write-Host ("  {0,-8} {1}" -f $r.Status, $r.SqlEnv) -ForegroundColor $color
    if ($r.ScriptPath) { Write-Verbose "    Script saved to: $($r.ScriptPath)" }
}

# ---- Summary ----------------------------------------------------------------
$failed = @($sqlResults | Where-Object { $_.Status -notmatch '^(OK|WHATIF|SKIP)' })
if ($failed.Count -gt 0) {
    Write-Warning "One or more SQL environments failed. Review output above."
    exit 1
}

Write-Host "`nDone. SQL access granted for ASPGOV\$samidL." -ForegroundColor Green

#endregion --- main script ----------------------------------------------------
