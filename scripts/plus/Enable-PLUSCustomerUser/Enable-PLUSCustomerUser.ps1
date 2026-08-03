#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Re-enable a disabled PLUS customer user end-to-end: aspgov.pri AD account, centroid.cloud.lcl
    AD account, SQL database access, rpt folders, and credentials to clipboard.

.DESCRIPTION
    Standalone replacement for PLUS_CustomerUsers_QuickSetup -Reenable from the deprecated
    PLUSSysAdmins module. Does not require the legacy PowerShell profile or VM workstations.

    All configuration ships with the script under ./config/ and ./templates/.
    Symlink (or copy) config/ from the New-PLUSCustomerUser folder - both scripts share the
    same config files.

    What it does:
      1. Looks up the existing aspgov.pri user (disabled or enabled) by samAccountName
      2. Re-enables the account: sets a short Description (Re-enabled - date - who), stamps
         the Info field with who/when, adds/re-adds to the <CUST>_PLUS AD group, refreshes
         AD properties (Company, State, City, UPN, msDS-cloudExtensionAttribute18), and
         verifies the Enabled flag on the PDC emulator before continuing
      3. Optionally sets a Manager on the AD account (must be in the same OU)
      4. Creates/verifies rpt folders on prod and train file servers
      5. Re-grants SQL access via Template_SQL_GrantUserAccess.txt on the environment(s)
         selected interactively (Production/Train/Stage, 1/2/3 or a comma combination) or
         via -SqlEnv; PRD04/STG04 for 5.2 customers, PRD01/STG01 otherwise
      6. Ensures the centroid.cloud.lcl c_<samid> account exists and is enabled
      7. Resets the aspgov.pri password, outputs the credentials block to console and clipboard

    What it does NOT do (PSync watcher gone, no longer applicable):
      - Set an account expiration date (the old 31-day window was cleared by a PSync watcher
        script that no longer exists; setting it without clearing it would lock out re-enabled users)

.PARAMETER Samid
    aspgov.pri samAccountName of the user to re-enable (e.g. "opakalvarado").

.PARAMETER Is52Customer
    Override automatic 5.2 detection. When set, PRD04/STG04 SQL envs are included.
    By default the script checks the Version column in config/PLUSCustomers.csv.

.PARAMETER SqlEnv
    Advanced override: skip the interactive menu and target a specific SQL environment
    (PRD01, STG01, PRD04, STG04). Omit to use the interactive Production/Train/Stage
    selection menu (1/2/3 or a comma-separated combination, e.g. 1,2).

.EXAMPLE
    .\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado

.EXAMPLE
    .\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado -SqlEnv PRD01

.EXAMPLE
    .\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado -WhatIf

.NOTES
    Author: CloudOps SRE - CentralSquare Technologies
    Replaces: PLUS_CustomerUsers_QuickSetup -Reenable (PLUSSysAdmins.psm1)
    No VMware, no Rubrik, no PSync dependencies.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Samid,
    [Parameter()][switch]$Is52Customer,
    [Parameter()][ValidateSet('PRD01','STG01','PRD04','STG04')][string]$SqlEnv
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

function Enable-AspgovCustomerUser {
    <#
    Re-enables the aspgov.pri user: enables the account, sets a short Description,
    stamps the Info field, refreshes AD properties from the OU, adds to <CUST>_PLUS.
    Verifies Enabled=$true on the PDC emulator before returning - the PDC emulator is
    authoritative here; if ADUC or another DC still shows the account disabled right
    after this returns OK, that is AD replication lag to that DC, not a failed re-enable.
    Returns the refreshed ADUser object.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Microsoft.ActiveDirectory.Management.ADUser]$User,
        [string]$CustUpper,
        [string]$CustName,
        [string]$CustState,
        [string]$PdcAspgov,
        [string]$RunningAs
    )

    $samid = $User.SamAccountName.ToLower()
    $group = "${CustUpper}_PLUS"

    # Stamp Info field with who/when re-enabled
    $existingInfo = $User.Info
    $infoLine     = "Re-enabled $((Get-Date).ToShortDateString()) [$RunningAs]"
    if ($existingInfo) {
        if ($existingInfo -notmatch [regex]::Escape($infoLine)) {
            $newInfo = $existingInfo.TrimEnd() + "`n" + $infoLine
        } else {
            $newInfo = $existingInfo
        }
    } else {
        $newInfo = $infoLine
    }

    # Short, human-readable Description (replaces whatever was there, e.g. a DISABLED stamp)
    $newDescription = "Re-enabled - $((Get-Date).ToShortDateString()) - $RunningAs"

    # Normalise display fields from what's already on the account
    $firstName   = (Get-Culture).TextInfo.ToTitleCase($User.GivenName.Trim().ToLower())
    $lastName    = (Get-Culture).TextInfo.ToTitleCase($User.Surname.Trim().ToLower())
    $displayName = (Get-Culture).TextInfo.ToTitleCase($User.DisplayName.Trim().ToLower()).TrimEnd()
    $upn         = "$samid@aspgov.pri"

    # Determine msDS-cloudExtensionAttribute18 value - preserve CustAdmin if already set
    $custAdmin = if ($User.'msDS-cloudExtensionAttribute18' -eq 'IsPLUSCustAdmin=TRUE') {
        'IsPLUSCustAdmin=TRUE'
    } else {
        'IsPLUSCustAdmin=FALSE'
    }

    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Enable account + refresh properties for '$samid'")) {
        Set-ADUser -Identity $samid -Server $PdcAspgov `
            -Enabled           $true `
            -GivenName         $firstName `
            -Surname           $lastName `
            -DisplayName       $displayName `
            -UserPrincipalName $upn `
            -Company           $CustName `
            -State             $CustState `
            -City              $CustName `
            -Replace           @{ Description = $newDescription; Info = $newInfo } `
            -ErrorAction       Stop
        Write-Verbose "  ASPGOV: Enabled $samid, set Description, stamped Info"

        # Verify the write actually landed on the PDC emulator before reporting success
        $verify = Get-ADUser -Identity $samid -Server $PdcAspgov -Properties Enabled -ErrorAction Stop
        if (-not $verify.Enabled) {
            throw "ERROR: Set-ADUser reported success but '$samid' still shows Enabled=`$false on PDC emulator '$PdcAspgov'. Aborting - do not report this account as re-enabled."
        }
        Write-Host "  OK: ASPGOV\$samid enabled and refreshed (verified on $PdcAspgov)." -ForegroundColor Green
    }

    # Rename the AD object to match the cleaned display name
    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Rename-ADObject '$samid' to '$displayName'")) {
        try {
            Rename-ADObject -Identity $User.DistinguishedName -NewName $displayName -Server $PdcAspgov -ErrorAction Stop
            Write-Verbose "  ASPGOV: Renamed object to '$displayName'"
        } catch {
            Write-Warning "  Could not rename AD object for $samid to '$displayName' - skipping (non-fatal). Error: $_"
        }
    }

    # Refresh the msDS-cloudExtensionAttribute18 stamp
    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Set msDS-cloudExtensionAttribute18=$custAdmin on '$samid'")) {
        try {
            Set-ADUser -Identity $samid -Server $PdcAspgov `
                -Clear @('msDS-cloudExtensionAttribute18') -ErrorAction SilentlyContinue
            Set-ADUser -Identity $samid -Server $PdcAspgov `
                -Add @{ 'msDS-cloudExtensionAttribute18' = $custAdmin } -ErrorAction SilentlyContinue
            Write-Verbose "  ASPGOV: Set msDS-cloudExtensionAttribute18=$custAdmin on $samid"
        } catch {
            Write-Warning "  Could not set msDS-cloudExtensionAttribute18 on $samid - skipping (non-fatal). Error: $_"
        }
    }

    # (Re-)add to the <CUST>_PLUS group - idempotent, ignore "already a member"
    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Add-ADGroupMember '$group' <- '$samid'")) {
        try {
            Add-ADGroupMember -Identity $group -Members $samid -Server $PdcAspgov -ErrorAction Stop
            Write-Verbose "  ASPGOV: Added $samid to $group"
        } catch {
            if ($_ -match 'already a member') {
                Write-Verbose "  ASPGOV: $samid is already in $group (no change needed)"
            } else {
                throw "Failed adding $samid to $group on aspgov.pri. Error: $_"
            }
        }
    }

    # Return refreshed user object
    return Get-ADUser -Identity $samid -Server $PdcAspgov -Properties * -ErrorAction Stop
}

function Reset-AspgovPassword {
    <#
    Resets the aspgov.pri password to a fresh initial value.
    Returns the new password string.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Samid,
        [string]$FirstName,
        [string]$LastName,
        [string]$PdcAspgov
    )

    $now      = Get-Date
    $password = 'Welcome' + $FirstName.Substring(0, 1).ToUpper() + $LastName.Substring(0, 1).ToUpper() + '!' + $now.ToString('MMdd')

    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Set-ADAccountPassword for '$Samid'")) {
        Set-ADAccountPassword -Identity $Samid -Server $PdcAspgov `
            -NewPassword (ConvertTo-SecureString $password -AsPlainText -Force) `
            -Reset -ErrorAction Stop
        Set-ADUser -Identity $Samid -Server $PdcAspgov -ChangePasswordAtLogon $true -ErrorAction Stop
        Write-Verbose "  ASPGOV: Password reset for $Samid"
        Write-Host "  OK: Password reset." -ForegroundColor Green
    }

    return $password
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

    # A newly re-enabled/renamed ASPGOV account can take a while to replicate to whichever DC
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

function Enable-CentroidCustomerUser {
    <#
    Ensures the centroid.cloud.lcl c_<samid> account exists and is enabled.
    If the account exists but is disabled, re-enables it and resets its password.
    If it does not exist, creates it (same logic as New-PLUSCustomerUser).
    Returns [pscustomobject]{Status; Samid; Dn}.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$AspgovSamid,
        [string]$CustUpper,
        [string]$DisplayName,
        [string]$FirstName,
        [string]$LastName,
        [string]$EmailAddress,
        [string]$InitialPassword,
        [object[]]$OuMap,
        [string]$PdcCentroid
    )

    $centroidSam = "c_$AspgovSamid"
    if ($centroidSam.Length -gt 20) {
        $centroidSam = $centroidSam.Substring(0, 20)
        Write-Warning "Centroid samAccountName exceeded 20 chars; truncated to '$centroidSam'."
    }

    # Check if the centroid account already exists
    $existing = Get-ADUser -Server $PdcCentroid -Filter "samaccountname -eq '$centroidSam'" `
        -Properties Enabled -ErrorAction SilentlyContinue

    if ($existing) {
        if ($existing.Enabled) {
            return [pscustomobject]@{
                Status = 'ALREADY-ENABLED'
                Samid  = $centroidSam
                Dn     = $existing.DistinguishedName
            }
        }

        # Account exists but is disabled - re-enable it and reset the password
        if ($PSCmdlet.ShouldProcess("centroid.cloud.lcl", "Enable + reset password for '$centroidSam'")) {
            try {
                Set-ADAccountPassword -Identity $existing.DistinguishedName -Server $PdcCentroid `
                    -NewPassword (ConvertTo-SecureString $InitialPassword -AsPlainText -Force) `
                    -Reset -ErrorAction Stop
                Enable-ADAccount -Identity $existing.DistinguishedName -Server $PdcCentroid -ErrorAction Stop
                return [pscustomobject]@{
                    Status = 'RE-ENABLED'
                    Samid  = $centroidSam
                    Dn     = $existing.DistinguishedName
                }
            } catch {
                return [pscustomobject]@{
                    Status = "FAILED-reenable: $_"
                    Samid  = $centroidSam
                    Dn     = $existing.DistinguishedName
                }
            }
        } else {
            return [pscustomobject]@{ Status = 'WHATIF'; Samid = $centroidSam; Dn = $existing.DistinguishedName }
        }
    }

    # Account does not exist - create it (same as New-PLUSCustomerUser)
    $mapRow = $OuMap | Where-Object { $_.cust.Trim().ToUpper() -eq $CustUpper } | Select-Object -First 1
    if (-not $mapRow -or -not $mapRow.CentroidCustomerOU) {
        return [pscustomobject]@{
            Status = 'SKIPPED-no-OU-mapping'
            Samid  = $null
            Dn     = $null
        }
    }

    $centroidOuName  = $mapRow.CentroidCustomerOU
    $customersBaseDn = 'OU=Customers,DC=centroid,DC=cloud,DC=lcl'
    $centroidUsersDn = "OU=Users,OU=$centroidOuName,$customersBaseDn"

    try {
        $null = Get-ADOrganizationalUnit -Server $PdcCentroid -Identity $centroidUsersDn -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            Status = "FAILED-target-OU-missing: $centroidUsersDn - $_"
            Samid  = $null
            Dn     = $null
        }
    }

    $centroidUpn = "$centroidSam@$PdcCentroid"

    if ($PSCmdlet.ShouldProcess("centroid.cloud.lcl", "New-ADUser '$centroidSam' in $centroidUsersDn")) {
        try {
            New-ADUser `
                -Server                $PdcCentroid `
                -Name                  $DisplayName `
                -SamAccountName        $centroidSam `
                -UserPrincipalName     $centroidUpn `
                -DisplayName           $DisplayName `
                -GivenName             $FirstName `
                -Surname               $LastName `
                -EmailAddress          $EmailAddress `
                -OfficePhone           $EmailAddress `
                -AccountPassword       (ConvertTo-SecureString $InitialPassword -AsPlainText -Force) `
                -Path                  $centroidUsersDn `
                -Enabled               $true `
                -ChangePasswordAtLogon $false `
                -ErrorAction           Stop

            return [pscustomobject]@{
                Status = 'CREATED'
                Samid  = $centroidSam
                Dn     = "$centroidSam,$centroidUsersDn"
            }
        } catch {
            return [pscustomobject]@{
                Status = "FAILED: $_"
                Samid  = $centroidSam
                Dn     = $null
            }
        }
    } else {
        return [pscustomobject]@{ Status = 'WHATIF'; Samid = $centroidSam; Dn = $centroidUsersDn }
    }
}

function Format-PLUSReenableCredentialsBlock {
    param(
        [string]$Samid,
        [string]$NewPassword,
        [string]$CustName,
        [string]$FirstName,
        [string]$LastName,
        [string]$EmailAddress,
        [string]$CentroidSamid,
        [string]$CentroidStatus
    )

    $now = Get-Date -Format 'M/d/yyyy'

    $block = @"
========================================
  CREDENTIALS (RE-ENABLED) -- $($Samid.ToUpper())
========================================
Username : ASPGOV\$($Samid.ToUpper())
Password : $NewPassword
Centroid : $CentroidSamid  [$CentroidStatus]

Customer : $CustName
Name     : $FirstName $LastName
Email    : $EmailAddress
Date     : $now

Send credentials to the user manually.
========================================
"@

    return $block
}

function New-PLUSCredsEmail {
    <#
    Renders the HTML credentials email template and opens it in the default browser.
    Returns the path to the saved .htm file, or $null if the template is missing.
    #>
    param(
        [string]$Samid,
        [string]$FirstName,
        [string]$CustName,
        [string]$CustCode,
        [string]$TemplatePath,
        [bool]$IsReenable = $false
    )

    if (-not (Test-Path $TemplatePath)) {
        Write-Warning "  Email template not found: $TemplatePath - skipping email draft."
        return $null
    }

    $pwdLine = "<span style='background:yellow'><b><i>Your temporary password will be sent via a separate communication.</i></b></span>"

    $body = Get-Content $TemplatePath -Raw
    $tomorrow = (Get-Date).AddDays(1).ToShortDateString()
    $tokens = [ordered]@{
        'ZZZFNameZZZ'         = $FirstName
        'ZZZCustomerNameZZZ'  = $CustName
        'ZZZCUSTZZZ'          = $CustCode.ToUpper()
        'ZZZSAMIDZZZ'         = $Samid.ToUpper()
        'ZZZPWDLINEZZZ'       = $pwdLine
        'ZZZTOMORROWZZZ'      = $tomorrow
        'ZZZEMAILSIGZZZ'      = ''
        'ZZZFirstUsersInfoZZZ'= ''
    }
    foreach ($token in $tokens.GetEnumerator()) { $body = $body -replace $token.Key, $token.Value }

    if ($IsReenable) {
        $body = $body -replace ' new account ',     ' account '
        $body = $body -replace ' has been created', ' has been re-enabled'
        $body = $body -replace 'You will not be able to access', 'As a reminder, you will not be able to access'
    }

    $dateDir   = Join-Path $env:TEMP "PLUSUserAdmin\$(Get-Date -Format 'yyyy-MM-dd')"
    if (-not (Test-Path $dateDir)) { $null = New-Item -ItemType Directory -Path $dateDir -Force }
    $suffix    = if ($IsReenable) { 'Reenable' } else { 'New' }
    $emailFile = Join-Path $dateDir "UserCredsEmail_${suffix}_$($Samid.ToUpper()).htm"
    Set-Content -Path $emailFile -Value $body -Encoding UTF8 -Force

    Write-Host "  Email draft saved to: $emailFile" -ForegroundColor Cyan
    Start-Process $emailFile
    return $emailFile
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
$samidL  = $Samid.Trim().ToLower()
$custL   = $samidL.Substring(0, 3)
$custU   = $custL.ToUpper()

if ($custL -notin $cfg.Customers) {
    throw "ERROR: '$custU' is not a valid customer site code in config/PLUSCustomers.csv. Check the samid and try again."
}

$bIs52 = $Is52Customer.IsPresent -or ($custL -in $cfg.Customers52)

if ($cfg.CustomerNames.ContainsKey($custL)) {
    $custName  = $cfg.CustomerNames[$custL].Name
    $custState = $cfg.CustomerNames[$custL].State
} else {
    Write-Warning "No customer name found for '$custU' in PLUSCustomers.csv - using site code as display name."
    $custName  = $custU
    $custState = ''
}

# ---- Step 2: Resolve aspgov PDC ---------------------------------------------
Write-Verbose 'Resolving aspgov.pri PDC emulator...'
try {
    $pdcAspgov = (Get-ADDomain aspgov.pri -ErrorAction Stop).PDCEmulator
} catch {
    Write-Warning "Could not query aspgov.pri domain - falling back to inf-svrdc101.aspgov.pri. Error: $_"
    $pdcAspgov = 'inf-svrdc101.aspgov.pri'
}
$pdcCentroid = 'centroid.cloud.lcl'

# ---- Step 3: Look up the aspgov.pri user ------------------------------------
Write-Host "Looking up ASPGOV\$samidL ..." -ForegroundColor Cyan

$adUser = $null
try {
    # Include disabled users - this is a re-enable script
    $adUser = Get-ADUser -Filter "samaccountname -eq '$samidL'" `
        -Server $pdcAspgov -Properties * -ErrorAction Stop
} catch {
    throw "ERROR: Failed to query aspgov.pri for '$samidL'. Error: $_"
}

if (-not $adUser) {
    throw "ERROR: No user found for samid '$samidL' on aspgov.pri. Check the samid and try again."
}

Write-Host ("  Found: {0} | Enabled: {1} | Last logon: {2}" -f `
    $adUser.DisplayName, $adUser.Enabled, $adUser.LastLogonDate) -ForegroundColor Cyan

if ($adUser.Enabled) {
    Write-Warning "Account '$samidL' is already enabled. Continuing to refresh access (SQL, rpt folders, centroid)."
}

# Derive name/contact from the existing AD account
$firstName   = (Get-Culture).TextInfo.ToTitleCase($adUser.GivenName.Trim().ToLower())
$lastName    = (Get-Culture).TextInfo.ToTitleCase($adUser.Surname.Trim().ToLower())
$emailAddr   = $adUser.EmailAddress.Trim().ToLower()
$employeeID  = $adUser.EmployeeID.Trim()
$bIsDBA      = $adUser.'msDS-cloudExtensionAttribute18' -eq 'IsPLUSCustAdmin=TRUE'

# Who is running this (for the Info field stamp)
$runningAs = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# ---- Step 4: Re-enable aspgov.pri account + refresh properties --------------
Write-Host "Re-enabling ASPGOV\$samidL ($firstName $lastName) ..." -ForegroundColor Cyan

$adUser = Enable-AspgovCustomerUser `
    -User        $adUser `
    -CustUpper   $custU `
    -CustName    $custName `
    -CustState   $custState `
    -PdcAspgov   $pdcAspgov `
    -RunningAs   $runningAs

# ---- Step 5: Reset password -------------------------------------------------
Write-Host "Resetting password for ASPGOV\$samidL ..." -ForegroundColor Cyan
$newPassword = Reset-AspgovPassword `
    -Samid     $samidL `
    -FirstName $firstName `
    -LastName  $lastName `
    -PdcAspgov $pdcAspgov

# ---- Step 6: Create/verify rpt folders --------------------------------------
Write-Host "Verifying RPT report folders ..." -ForegroundColor Cyan
$rptResults = New-PLUSReportFolders -Samid $samidL -CustLower $custL -Is52 $bIs52
$rptResults | ForEach-Object {
    $color = if ($_.Status -eq 'CREATED' -or $_.Status -eq 'ALREADY-EXISTS') { 'Green' } `
             elseif ($_.Status -like 'SKIP*' -or $_.Status -eq 'WHATIF')     { 'Yellow' } `
             else { 'Red' }
    Write-Host ("  {0,-20} {1}" -f $_.Status, $_.Path) -ForegroundColor $color
}

# ---- Step 7: SQL access grant -----------------------------------------------
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
    $prdEnv    = if ($bIs52) { 'PRD04' } else { 'PRD01' }
    $stgEnv    = if ($bIs52) { 'STG04' } else { 'STG01' }
    $prdServer = if ($bIs52) { 'cld-pplsdb004' } else { 'cld-pplsdb001' }
    $stgServer = if ($bIs52) { 'cld-splsdb004' } else { 'cld-splsdb001' }
    $versionTag = if ($bIs52) { ' - PLUS 5.2' } else { '' }

    Write-Host ""
    Write-Host "  Customer: $custName ($custU)$versionTag" -ForegroundColor Cyan
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
    $color = if ($r.Status -eq 'OK') { 'Green' } elseif ($r.Status -eq 'WHATIF') { 'Yellow' } else { 'Red' }
    Write-Host ("  {0,-8} {1}" -f $r.Status, $r.SqlEnv) -ForegroundColor $color
    if ($r.ScriptPath) { Write-Verbose "    Script saved to: $($r.ScriptPath)" }
}

# ---- Step 8: Ensure centroid.cloud.lcl account is enabled -------------------
Write-Host "Verifying centroid.cloud.lcl user ..." -ForegroundColor Cyan
$centroidResult = Enable-CentroidCustomerUser `
    -AspgovSamid     $samidL `
    -CustUpper       $custU `
    -DisplayName     ($adUser.DisplayName.Trim()) `
    -FirstName       $firstName `
    -LastName        $lastName `
    -EmailAddress    $emailAddr `
    -InitialPassword $newPassword `
    -OuMap           $cfg.CentroidOuMap `
    -PdcCentroid     $pdcCentroid

$centroidColor = switch -Wildcard ($centroidResult.Status) {
    'OK'             { 'Green'  }
    'ALREADY-ENABLED'{ 'Green'  }
    'RE-ENABLED'     { 'Green'  }
    'CREATED'        { 'Green'  }
    'WHATIF'         { 'Yellow' }
    'SKIPPED*'       { 'Yellow' }
    default          { 'Red'    }
}
Write-Host ("  {0} {1}" -f $centroidResult.Status, $centroidResult.Samid) -ForegroundColor $centroidColor

# ---- Step 9: Output credentials block ---------------------------------------
$centroidSamDisplay = if ($null -ne $centroidResult.Samid) { $centroidResult.Samid } else { 'N/A' }

$credBlock = Format-PLUSReenableCredentialsBlock `
    -Samid           $samidL `
    -NewPassword     $newPassword `
    -CustName        $custName `
    -FirstName       $firstName `
    -LastName        $lastName `
    -EmailAddress    $emailAddr `
    -CentroidSamid   $centroidSamDisplay `
    -CentroidStatus  $centroidResult.Status

Write-Host "`n$credBlock" -BackgroundColor DarkBlue -ForegroundColor White
Set-Clipboard -Value $credBlock
Write-Host "`n[Credentials block copied to clipboard]" -ForegroundColor Cyan

# ---- Step 10: Open credentials email draft ----------------------------------
$emailTmplPath = Join-Path $tmplDir 'Email-NewCustomerUserCredentials.htm'
New-PLUSCredsEmail `
    -Samid        $samidL `
    -FirstName    $firstName `
    -CustName     $custName `
    -CustCode     $custU `
    -TemplatePath $emailTmplPath `
    -IsReenable   $true

#endregion --- main script ----------------------------------------------------
