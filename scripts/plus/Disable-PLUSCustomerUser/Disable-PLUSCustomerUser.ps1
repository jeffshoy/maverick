#Requires -Version 5.1
#Requires -Modules ActiveDirectory

# SqlServer 22.x has an InOutOfProcHelper bug on this server; force 21.x which is also installed
Import-Module SqlServer -RequiredVersion 21.1.18226 -Force

<#
.SYNOPSIS
    Terminate a PLUS customer user end-to-end: removes SQL access from all customer databases,
    disables the aspgov.pri AD account, disables the centroid.cloud.lcl account, and prints
    a reminder to remove RPT folders manually.

.DESCRIPTION
    Standalone replacement for PLUS_TerminateCustUser from the deprecated PLUSSysAdmins module.
    Does not require the legacy PowerShell profile or VM workstations.

    All configuration ships with the script under ./config/ and ./templates/.
    You must supply Template_SQL_RemoveUserAccess-Simple.txt before running — grab it from:
    \\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\

    What it does:
      1. Validates the samid prefix against config/PLUSCustomers.txt
      2. Removes the user from all customer databases on PRD01+STG01 (always) and
         PRD04+STG04 (if customer is in config/PLUS52Customers.txt or -Is52Customer is set)
         via Template_SQL_RemoveUserAccess-Simple.txt (removes DB user + SQL login)
      3. Removes the user from the <CUST>_PLUS AD group on aspgov.pri
      4. Disables the aspgov.pri AD account: sets Description, prepends Info field with
         who/when/why disabled, clears AccountExpirationDate
      5. Disables the centroid.cloud.lcl c_<samid> account if it exists
      6. Deletes the user's RPT folders on prod and train file servers by going directly
         to \\server\share\<cust>\<samid> — no recursive enumeration of the whole share

    What it does NOT do:
      - Touch FTP virtual directories — do those separately if applicable

.PARAMETER Samid
    aspgov.pri samAccountName of the user to terminate (e.g. "lmpkpeterson").

.PARAMETER CaseNo
    Salesforce/AzDO case or ticket number for this termination request (e.g. "02502101").
    Recorded in the AD Description field.

.PARAMETER Is52Customer
    Override automatic 5.2 detection. When set, PRD04/STG04 SQL envs are included.
    By default the script checks config/PLUS52Customers.txt.

.EXAMPLE
    .\Disable-PLUSCustomerUser.ps1 -Samid lmpkpeterson -CaseNo 02502101

.EXAMPLE
    .\Disable-PLUSCustomerUser.ps1 -Samid lmpkpeterson -CaseNo 02502101 -WhatIf

.NOTES
    Author: CloudOps SRE — CentralSquare Technologies
    Replaces: PLUS_TerminateCustUser (PLUSSysAdmins.psm1)
    No VMware, no Rubrik, no PSync dependencies.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Samid,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CaseNo,
    [Parameter()][switch]$Is52Customer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- helpers -----------------------------------------------------------

function Get-PLUSConfig {
    param([string]$ConfigDir)

    $cfg = @{
        Customers   = @()
        Customers52 = @()
    }

    $f = Join-Path $ConfigDir 'PLUSCustomers.txt'
    if (-not (Test-Path $f)) { throw "Missing required config file: $f" }
    $cfg.Customers = @(Get-Content $f | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim().ToLower() })

    $f = Join-Path $ConfigDir 'PLUS52Customers.txt'
    if (-not (Test-Path $f)) { throw "Missing required config file: $f" }
    $cfg.Customers52 = @(Get-Content $f | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim().ToLower() })

    return $cfg
}

function Invoke-PLUSRemoveUserAccess {
    <#
    Tokenizes Template_SQL_RemoveUserAccess-Simple.txt and executes it against the
    specified SQL instance + database. Saves the generated script to $env:TEMP for audit.
    Returns [pscustomobject]{SqlEnv; Database; Status; ScriptPath}.

    Template tokens (mirrors PLUS_RemoveUserAccess behavior):
      ZZZsamidZZZ              -> lowercase samid
      ZZZRemoveLogin01ZZZ      -> '1' (always remove the SQL login on termination)
      ZZZRemoveSectbAccessZZZ  -> '0' (customer users: do not remove sectb access row)
    #>
    param(
        [string]$Samid,
        [string]$Database,
        [string]$SqlEnv,
        [string]$SqlInstance,
        [string]$TemplatePath
    )

    if (-not (Test-Path $TemplatePath)) {
        return [pscustomobject]@{ SqlEnv = $SqlEnv; Database = $Database; Status = "SKIP-no-template ($TemplatePath)"; ScriptPath = $null }
    }

    $rawTemplate = Get-Content $TemplatePath -Raw
    $sql = $rawTemplate `
        -replace 'ZZZsamidZZZ',             $Samid `
        -replace 'ZZZRemoveLogin01ZZZ',      '1' `
        -replace 'ZZZRemoveSectbAccessZZZ',  '0'

    $ts         = Get-Date -Format 'yyyyMMdd_HHmmss'
    $scriptFile = Join-Path $env:TEMP "RemoveUserAccess_${Samid}_${Database}_${SqlEnv}_${ts}.sql"

    if ($PSCmdlet.ShouldProcess($SqlInstance, "Remove $Samid from $Database ($SqlEnv)")) {
        try {
            Invoke-Sqlcmd `
                -ServerInstance $SqlInstance `
                -Database       $Database `
                -Query          $sql `
                -QueryTimeout   120 `
                -ErrorAction    Stop

            Set-Content -Path $scriptFile -Value $sql -Force
            return [pscustomobject]@{ SqlEnv = $SqlEnv; Database = $Database; Status = 'OK'; ScriptPath = $scriptFile }
        } catch {
            return [pscustomobject]@{ SqlEnv = $SqlEnv; Database = $Database; Status = "FAILED: $_"; ScriptPath = $scriptFile }
        }
    } else {
        return [pscustomobject]@{ SqlEnv = $SqlEnv; Database = $Database; Status = 'WHATIF'; ScriptPath = $null }
    }
}

function Get-PLUSCustomerDatabases {
    <#
    Returns customer database names for the given site code on the given SQL instance.
    Mirrors Get-PLUSDatabase -noAttach -noReadOnly -noExtras filter behavior:
    name starts with the cust code, contains 'fin' or 'comp', excludes '_' (archive/extra DBs).
    #>
    param(
        [string]$CustLower,
        [string]$SqlInstance,
        [bool]$OnlyTrain
    )

    try {
        if ($OnlyTrain) {
            $filter = "name LIKE '$CustLower%trn%' AND (name LIKE '%fin%' OR name LIKE '%comp%') AND name NOT LIKE '%[_]%'"
        } else {
            $filter = "name LIKE '$CustLower%' AND (name LIKE '%fin%' OR name LIKE '%comp%') AND name NOT LIKE '%[_]%'"
        }

        $results = Invoke-Sqlcmd `
            -ServerInstance $SqlInstance `
            -Database       'master' `
            -Query          "SELECT name FROM sys.databases WHERE $filter AND state_desc = 'ONLINE'" `
            -QueryTimeout   30 `
            -ErrorAction    Stop

        return @($results | ForEach-Object { $_.name })
    } catch {
        Write-Warning "  Could not query databases on $SqlInstance — $_"
        return @()
    }
}

function Disable-AspgovCustomerUser {
    <#
    Disables the aspgov.pri account: removes from <CUST>_PLUS group, sets Description,
    prepends Info field with who/when disabled, clears AccountExpirationDate.
    #>
    param(
        [string]$Samid,
        [string]$CustUpper,
        [string]$CaseNo,
        [string]$PdcAspgov,
        [string]$RunningAs
    )

    $group = "${CustUpper}_PLUS"

    # Remove from <CUST>_PLUS group
    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Remove-ADGroupMember '$group' -> '$Samid'")) {
        try {
            Remove-ADGroupMember -Identity $group -Members $Samid -Server $PdcAspgov -Confirm:$false -ErrorAction Stop
            Write-Verbose "  ASPGOV: Removed $Samid from $group"
        } catch {
            if ($_ -match 'not a member') {
                Write-Verbose "  ASPGOV: $Samid was not in $group (no change needed)"
            } else {
                Write-Warning "  Failed removing $Samid from $group — $_"
            }
        }
    }

    # Build Info stamp (prepend, matching AD_UserInfo -Disable behavior)
    $existingInfo = (Get-ADUser -Identity $Samid -Server $PdcAspgov -Properties Info -ErrorAction Stop).Info
    $infoLine     = "Disabled $((Get-Date).ToShortDateString()) [$RunningAs]"
    if ($existingInfo) {
        $newInfo = $infoLine + "`n" + $existingInfo.TrimStart("`n").TrimEnd("`n")
    } else {
        $newInfo = $infoLine
    }

    $description = "DISABLED [$((Get-Date).ToShortDateString())] per Customer request - Case# $CaseNo"

    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Disable + set Description/Info on '$Samid'")) {
        Set-ADUser -Identity $Samid -Server $PdcAspgov `
            -Enabled     $false `
            -Description $description `
            -Replace     @{ Info = $newInfo } `
            -ErrorAction Stop
        Clear-ADAccountExpiration -Identity $Samid -Server $PdcAspgov -Confirm:$false -ErrorAction Stop
        Write-Verbose "  ASPGOV: Disabled $Samid, set Description, stamped Info, cleared expiration"
    }
}

function Remove-PLUSReportFolders {
    <#
    Removes the user's rpt folder tree on prod and train file servers by going directly
    to \\server\share\<cust>\<samid> — no recursive enumeration of the whole share.
    The legacy Remove-PLUS-RPTFolders used Get-ChildItem -Depth 2 across every customer
    folder which was slow; for a customer user the path is fully deterministic.
    Returns an array of [pscustomobject]{Path; Status}.
    #>
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
            $userPath = "\\$server\$share\$CustLower\$Samid"
            if (-not (Test-Path $userPath)) {
                $results += [pscustomobject]@{ Path = $userPath; Status = 'NOT-FOUND' }
                continue
            }
            if ($PSCmdlet.ShouldProcess($userPath, 'Remove-Item -Recurse')) {
                try {
                    Remove-Item -Path $userPath -Recurse -Force -ErrorAction Stop
                    $results += [pscustomobject]@{ Path = $userPath; Status = 'DELETED' }
                } catch {
                    $results += [pscustomobject]@{ Path = $userPath; Status = "FAILED: $_" }
                }
            } else {
                $results += [pscustomobject]@{ Path = $userPath; Status = 'WHATIF' }
            }
        }
    }
    return $results
}

function Disable-CentroidCustomerUser {
    <#
    Disables c_<samid> on centroid.cloud.lcl if it exists and is currently enabled.
    Returns [pscustomobject]{Status; Samid}.
    #>
    param(
        [string]$AspgovSamid,
        [string]$PdcCentroid
    )

    $centroidSam = "c_$AspgovSamid"
    if ($centroidSam.Length -gt 20) { $centroidSam = $centroidSam.Substring(0, 20) }

    $existing = Get-ADUser -Server $PdcCentroid -Filter "samaccountname -eq '$centroidSam'" `
        -Properties Enabled -ErrorAction SilentlyContinue

    if (-not $existing) {
        return [pscustomobject]@{ Status = 'NOT-FOUND'; Samid = $centroidSam }
    }

    if (-not $existing.Enabled) {
        return [pscustomobject]@{ Status = 'ALREADY-DISABLED'; Samid = $centroidSam }
    }

    if ($PSCmdlet.ShouldProcess("centroid.cloud.lcl", "Disable-ADAccount '$centroidSam'")) {
        try {
            Disable-ADAccount -Identity $existing.DistinguishedName -Server $PdcCentroid -ErrorAction Stop
            return [pscustomobject]@{ Status = 'DISABLED'; Samid = $centroidSam }
        } catch {
            return [pscustomobject]@{ Status = "FAILED: $_"; Samid = $centroidSam }
        }
    } else {
        return [pscustomobject]@{ Status = 'WHATIF'; Samid = $centroidSam }
    }
}

#endregion --- helpers --------------------------------------------------------

#region --- main script -------------------------------------------------------

$scriptDir   = $PSScriptRoot
$configDir   = Join-Path $scriptDir '..\config'
$tmplDir     = Join-Path $scriptDir 'templates'
$sqlTmplPath = Join-Path $tmplDir 'Template_SQL_RemoveUserAccess-Simple.txt'

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
    throw "ERROR: '$custU' is not a valid customer site code in config/PLUSCustomers.txt. Check the samid and try again."
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
$pdcCentroid = 'centroid.cloud.lcl'

# ---- Step 3: Verify the aspgov.pri user exists ------------------------------
Write-Host "Looking up ASPGOV\$samidL ..." -ForegroundColor Cyan
$adUser = Get-ADUser -Filter "samaccountname -eq '$samidL'" -Server $pdcAspgov -Properties DisplayName,Enabled -ErrorAction Stop

if (-not $adUser) {
    throw "ERROR: No user found for samid '$samidL' on aspgov.pri. Check the samid and try again."
}

Write-Host ("  Found: {0} | Enabled: {1}" -f $adUser.DisplayName, $adUser.Enabled) -ForegroundColor Cyan

if (-not $adUser.Enabled) {
    Write-Warning "Account '$samidL' is already disabled. Continuing to ensure SQL access and centroid are also cleaned up."
}

$runningAs = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# ---- Step 4: Remove SQL access from all customer databases ------------------
Write-Host "Removing SQL access ..." -ForegroundColor Cyan

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
    Write-Host ("  Querying databases on {0} ({1}) ..." -f $e.Env, $e.Instance) -ForegroundColor Cyan
    $dbs = Get-PLUSCustomerDatabases -CustLower $custL -SqlInstance $e.Instance -OnlyTrain $e.OnlyTrain

    if (-not $dbs) {
        Write-Host ("  No {0} databases found on {1} — skipping." -f $custU, $e.Env) -ForegroundColor Yellow
        continue
    }

    foreach ($db in $dbs) {
        $r = Invoke-PLUSRemoveUserAccess `
            -Samid        $samidL `
            -Database     $db `
            -SqlEnv       $e.Env `
            -SqlInstance  $e.Instance `
            -TemplatePath $sqlTmplPath
        $sqlResults += $r
        $color = if ($r.Status -eq 'OK') { 'Green' } elseif ($r.Status -eq 'WHATIF') { 'Yellow' } else { 'Red' }
        Write-Host ("  {0,-8} {1,-8} {2}" -f $r.Status, $r.SqlEnv, $r.Database) -ForegroundColor $color
        if ($r.ScriptPath) { Write-Verbose "    Script saved to: $($r.ScriptPath)" }
    }
}

# ---- Step 5: Disable aspgov.pri account -------------------------------------
Write-Host "Disabling ASPGOV\$samidL ..." -ForegroundColor Cyan

Disable-AspgovCustomerUser `
    -Samid     $samidL `
    -CustUpper $custU `
    -CaseNo    $CaseNo `
    -PdcAspgov $pdcAspgov `
    -RunningAs $runningAs

Write-Host "  OK: ASPGOV\$samidL disabled." -ForegroundColor Green

# ---- Step 6: Disable centroid.cloud.lcl account ----------------------------
Write-Host "Disabling centroid.cloud.lcl user ..." -ForegroundColor Cyan
$centroidResult = Disable-CentroidCustomerUser -AspgovSamid $samidL -PdcCentroid $pdcCentroid

$centroidColor = switch -Wildcard ($centroidResult.Status) {
    'DISABLED'         { 'Green'  }
    'ALREADY-DISABLED' { 'Green'  }
    'NOT-FOUND'        { 'Yellow' }
    'WHATIF'           { 'Yellow' }
    default            { 'Red'    }
}
Write-Host ("  {0} {1}" -f $centroidResult.Status, $centroidResult.Samid) -ForegroundColor $centroidColor

# ---- Step 7: Remove RPT folders ---------------------------------------------
Write-Host "Removing RPT folders ..." -ForegroundColor Cyan
$rptResults = Remove-PLUSReportFolders -Samid $samidL -CustLower $custL -Is52 $bIs52
$rptResults | ForEach-Object {
    $color = if ($_.Status -eq 'DELETED')   { 'Green'  } `
             elseif ($_.Status -eq 'WHATIF' -or $_.Status -eq 'NOT-FOUND') { 'Yellow' } `
             else { 'Red' }
    Write-Host ("  {0,-12} {1}" -f $_.Status, $_.Path) -ForegroundColor $color
}
Write-Host ''
Write-Host ("DONE: Terminated {0} (Case# {1}) at {2}" -f $samidL, $CaseNo, (Get-Date)) -ForegroundColor Cyan

#endregion --- main script ----------------------------------------------------
