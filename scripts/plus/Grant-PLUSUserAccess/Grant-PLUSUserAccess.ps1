#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Grant (or re-grant) SQL database access and AD group membership for an existing PLUS customer user.

.DESCRIPTION
    Standalone replacement for PLUS_GrantUserAccess from the deprecated PLUSSysAdmins module.
    Use this when SQL access needs to be (re-)applied independently - e.g. after a DB refresh
    that dropped user permissions, or when a step was skipped during New/Enable-PLUSCustomerUser.

    Does not require the legacy PowerShell profile or VM workstations.
    All configuration ships with the script under ./config/ and ./templates/.

    What it does:
      1. Looks up the aspgov.pri user and verifies they exist and are enabled
      2. (Re-)adds the user to the <CUST>_PLUS AD group
      3. Creates/verifies rpt report folders on the production and training file servers
      4. Grants SQL access via Template_SQL_GrantUserAccess.txt on PRD04+STG04 (5.2 customers)
         or PRD01+STG01 (non-5.2 customers) - never both; 5.2 customers have no presence on PRD01/STG01

    What it does NOT do:
      - Create or modify the AD user account
      - Reset passwords
      - Create or modify the centroid.cloud.lcl account

.PARAMETER Samid
    aspgov.pri samAccountName of the user (e.g. "opakalvarado").

.PARAMETER SqlEnv
    Advanced override: skip the interactive menu and target a specific SQL environment
    (PRD01, STG01, PRD04, STG04). STG envs use the train database filter by default.
    Omit to use the interactive Production/Train/Stage selection menu.

.PARAMETER IsUserDBA
    Grants PLUS Admin backend permissions (allows the user to manage other users within
    the PLUS application). By default, checks msDS-cloudExtensionAttribute18 on the AD account.

.EXAMPLE
    .\Grant-PLUSUserAccess.ps1 -Samid opakalvarado

.EXAMPLE
    .\Grant-PLUSUserAccess.ps1 -Samid opakalvarado -SqlEnv PRD01

.NOTES
    Author: CloudOps SRE - CentralSquare Technologies
    Replaces: PLUS_GrantUserAccess (PLUSSysAdmins.psm1)
    No VMware, no Rubrik, no PSync dependencies.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Samid,
    [Parameter()][ValidateSet('PRD01','STG01','PRD04','STG04')][string]$SqlEnv,
    [Parameter()][ValidateNotNullOrEmpty()][string]$CustCode,
    [Parameter()][switch]$IsUserDBA
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# SqlServer 22.x has an InOutOfProcHelper bug on this server; force 21.x which is also installed
Import-Module SqlServer -RequiredVersion 21.1.18226 -Force

#region --- helpers -----------------------------------------------------------

function Get-PLUSConfig {
    param([string]$ConfigDir)

    $csvPath = Join-Path $ConfigDir 'PLUSCustomers.csv'
    if (-not (Test-Path $csvPath)) { throw "Missing required config file: $csvPath" }

    $rows = @(Import-Csv $csvPath | Where-Object { $_.SiteCode -match '\S' -and $_.SiteCode -notmatch '^\s*#' })

    $names = @{}
    $rows | Where-Object { $_.Name -match '\S' } | ForEach-Object {
        $names[$_.SiteCode.Trim().ToLower()] = [pscustomobject]@{ Name = $_.Name.Trim() }
    }

    return @{
        Customers     = @($rows | ForEach-Object { $_.SiteCode.Trim().ToLower() })
        Customers52   = @($rows | Where-Object { $_.Version.Trim() -eq '5.2' } | ForEach-Object { $_.SiteCode.Trim().ToLower() })
        CustomerNames = $names
    }
}

function Add-PLUSGroupMembership {
    [CmdletBinding(SupportsShouldProcess)]
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
    [CmdletBinding(SupportsShouldProcess)]
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
    <#
    Tokenizes Template_SQL_GrantUserAccess.txt and executes it against the specified
    SQL instance. Verifies the sectb_crosswalk row actually landed before reporting OK -
    the template's two-phase print-then-execute pattern can silently do nothing without
    throwing, so absence of an exception is not proof of success.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Samid,
        [string]$CustLower,
        [string]$SqlEnv,
        [string]$SqlInstance,
        [string]$UserInfoToken,
        [string]$TemplatePath,
        [string]$FilterMode   # 'prod', 'train', or 'stage'
    )

    if (-not (Test-Path $TemplatePath)) {
        return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = "SKIP-no-template ($TemplatePath)"; ScriptPath = $null }
    }

    switch ($FilterMode) {
        'train' {
            $cursorWhere = "name LIKE LOWER('$CustLower' + '%trn%') AND (name LIKE '%fin%' OR name LIKE '%comp%') AND name NOT LIKE '%[_]%'"
        }
        'stage' {
            $cursorWhere = "name LIKE LOWER('$CustLower%') AND name NOT LIKE '%trn%' AND (name LIKE '%fin%' OR name LIKE '%comp%') AND name NOT LIKE '%[_]%'"
        }
        default {  # 'prod'
            $cursorWhere = "name LIKE LOWER('$CustLower%') AND (name LIKE '%fin%' OR name LIKE '%comp%') AND name NOT LIKE '%[_]%'"
        }
    }

    $rawTemplate = Get-Content $TemplatePath -Raw
    $sql = $rawTemplate `
        -replace 'ZZZCustZZZ',            $CustLower `
        -replace 'ZZZUsersInfoZZZ',        $UserInfoToken `
        -replace 'ZZZexecSectbAccessZZZ',  '0' `
        -replace 'ZZZcursorwhereZZZ',      $cursorWhere

    $ts         = Get-Date -Format 'yyyyMMdd_HHmmss'
    $scriptFile = Join-Path $env:TEMP "GrantUserAccess_${Samid}_${CustLower}_${SqlEnv}_${ts}.sql"

    if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Invoke-Sqlcmd GrantUserAccess for $Samid ($SqlEnv)")) {
        return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = 'WHATIF'; ScriptPath = $null }
    }

    # A newly-created/renamed ASPGOV account can take a while to replicate to whichever DC
    # this SQL instance resolves Windows logins against - CREATE LOGIN ... FROM WINDOWS (the
    # first statement the generated script runs) fails with "Windows NT user or group ... not
    # found" until that catches up, which aborts the entire generated script including every
    # downstream per-database grant. Retry the whole generate-and-execute cycle on that
    # specific error so a single run succeeds without a manual re-run. Any other error fails
    # immediately, no retries.
    $replicationRetryDelaysSec = @(30, 60, 120, 120, 120, 120)   # ~9.5 min total if every retry fires
    $maxAttempts               = $replicationRetryDelaysSec.Count + 1

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            # @EXECUTENOW=0 in the template means every real statement is PRINTed, not EXECed -
            # Invoke-Sqlcmd only puts PRINT/message output on the pipeline with -Verbose, and
            # only once stream 4 is redirected onto stream 1 (4>&1). Without both, $generatedSql
            # is empty and Phase 2 below silently executes nothing.
            $generatedSql = Invoke-Sqlcmd `
                -ServerInstance $SqlInstance `
                -Query          $sql `
                -QueryTimeout   120 `
                -Verbose `
                -ErrorAction    Stop `
                4>&1 |
                Out-String -Width 800

            # Strip "Changed database context to 'master'." noise, and the "VERBOSE: " prefix
            # PowerShell prepends to each line when a VerboseRecord (from 4>&1 above) is
            # rendered to text - the captured SQL must be plain text for Phase 2 to replay it.
            $generatedSql = $generatedSql -replace "Changed database context to 'master'\.", ''
            $generatedSql = ($generatedSql -split "`r?`n" | ForEach-Object { $_ -replace '^VERBOSE:\s?', '' }) -join "`r`n"
            Set-Content -Path $scriptFile -Value $generatedSql -Force

            Invoke-Sqlcmd `
                -ServerInstance $SqlInstance `
                -InputFile      $scriptFile `
                -QueryTimeout   120 `
                -ErrorAction    Stop

            # Verify the sectb_crosswalk row actually landed. Phase 1/2 above only fail on a
            # thrown exception - if Phase 1's PRINT capture was empty/incomplete (e.g. the
            # cursor matched zero databases, or Invoke-Sqlcmd's message-stream capture dropped
            # part of the output), Phase 2 can silently execute nothing and still report success.
            $verifyDbs = @()
            try {
                $verifyDbs = @(Invoke-Sqlcmd `
                    -ServerInstance $SqlInstance `
                    -Database       'master' `
                    -Query          "SELECT name FROM sys.databases WHERE $cursorWhere" `
                    -QueryTimeout   30 `
                    -ErrorAction    Stop)
            } catch {
                return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = "FAILED-not-verified: could not query sys.databases to verify sectb_crosswalk - $_"; ScriptPath = $scriptFile }
            }

            $crosswalkFound = $false
            $samidLower = $Samid.ToLower()
            foreach ($dbRow in $verifyDbs) {
                try {
                    $uidRow = Invoke-Sqlcmd `
                        -ServerInstance $SqlInstance `
                        -Database       $dbRow.name `
                        -Query          "SELECT TOP 1 spiuser FROM sectb_crosswalk WHERE winuser = '$samidLower'" `
                        -QueryTimeout   30 `
                        -ErrorAction    Stop | Select-Object -First 1
                    if ($uidRow -and $uidRow.spiuser) { $crosswalkFound = $true; break }
                } catch {
                    Write-Verbose "  Could not query sectb_crosswalk on $SqlInstance.$($dbRow.name) during verification - $_"
                }
            }

            if (-not $crosswalkFound) {
                return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = "FAILED-not-verified: sectb_crosswalk row for '$samidLower' not found in any target database on $SqlInstance"; ScriptPath = $scriptFile }
            }

            return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = 'OK'; ScriptPath = $scriptFile }
        } catch {
            $isAdReplicationLag = $_ -match 'Windows NT user or group .* not found'

            if ($isAdReplicationLag -and $attempt -lt $maxAttempts) {
                $delay = $replicationRetryDelaysSec[$attempt - 1]
                Write-Warning "  ASPGOV\$Samid not yet visible to $SqlInstance (AD replication lag) - attempt $attempt of $maxAttempts, retrying in ${delay}s..."
                Start-Sleep -Seconds $delay
                continue
            }

            if ($isAdReplicationLag) {
                return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = "FAILED: AD replication lag persisted after $maxAttempts attempts - $_"; ScriptPath = $scriptFile }
            }

            return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = "FAILED: $_"; ScriptPath = $scriptFile }
        }
    }
}

#endregion --- helpers --------------------------------------------------------

#region --- main script -------------------------------------------------------

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
$configDir   = Join-Path $scriptDir '..\config'
$tmplDir     = Join-Path $scriptDir '..\templates'
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
if ($CustCode) { $custL = $CustCode.Trim().ToLower() }
$custU  = $custL.ToUpper()

if ($custL -notin $cfg.Customers) {
    throw "ERROR: '$custU' is not a valid customer site code in config/PLUSCustomers.csv. Check the samid and try again."
}

$bIs52 = $custL -in $cfg.Customers52

# ---- Step 2: Resolve aspgov PDC ---------------------------------------------
Write-Verbose 'Resolving aspgov.pri PDC emulator...'
try {
    $pdcAspgov = (Get-ADDomain aspgov.pri -ErrorAction Stop).PDCEmulator
} catch {
    Write-Warning "Could not query aspgov.pri domain - falling back to inf-svrdc101.aspgov.pri. Error: $_"
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

if ($SqlEnv) {
    $filterMode = if ($SqlEnv -in @('STG01','STG04')) { 'train' } else { 'prod' }
    $sqlEnvs = @(@{ Env = $SqlEnv; Instance = $sqlInstances[$SqlEnv]; FilterMode = $filterMode })
} else {
    $prdEnv = if ($bIs52) { 'PRD04' } else { 'PRD01' }
    $stgEnv = if ($bIs52) { 'STG04' } else { 'STG01' }
    $prdServer = if ($bIs52) { 'cld-pplsdb004' } else { 'cld-pplsdb001' }
    $stgServer = if ($bIs52) { 'cld-splsdb004' } else { 'cld-splsdb001' }
    $versionTag = if ($bIs52) { ' - PLUS 5.2' } else { '' }
    $custDisplayName = if ($cfg.CustomerNames.ContainsKey($custL)) { $cfg.CustomerNames[$custL].Name } else { $custU }

    Write-Host ""
    Write-Host "  Customer: $custDisplayName ($custU)$versionTag" -ForegroundColor Cyan
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

    $sqlEnvs = @()
    if ('1' -in $parts) { $sqlEnvs += @{ Env = $prdEnv; Instance = $sqlInstances[$prdEnv]; FilterMode = 'prod'  } }
    if ('2' -in $parts) { $sqlEnvs += @{ Env = $stgEnv; Instance = $sqlInstances[$stgEnv]; FilterMode = 'train' } }
    if ('3' -in $parts) { $sqlEnvs += @{ Env = $stgEnv; Instance = $sqlInstances[$stgEnv]; FilterMode = 'stage' } }
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
        -FilterMode    $e.FilterMode
    $sqlResults += $r
    $color = if ($r.Status -eq 'OK') { 'Green' } elseif ($r.Status -like 'WHATIF' -or $r.Status -like 'SKIP*') { 'Yellow' } else { 'Red' }
    Write-Host ("  {0,-8} {1}" -f $r.Status, $r.SqlEnv) -ForegroundColor $color
    if ($r.ScriptPath) { Write-Verbose "    Script saved to: $($r.ScriptPath)" }
}

# ---- Summary ----------------------------------------------------------------
$failed  = @($sqlResults | Where-Object { $_.Status -notmatch '^(OK|WHATIF|SKIP)' })
$whatif  = @($sqlResults | Where-Object { $_.Status -eq 'WHATIF' })
if ($failed.Count -gt 0) {
    Write-Warning "One or more SQL environments failed. Review output above."
    exit 1
}

if ($whatif.Count -eq 0) {
    Write-Host "`nDone. SQL access granted for ASPGOV\$samidL." -ForegroundColor Green
}

#endregion --- main script ----------------------------------------------------
