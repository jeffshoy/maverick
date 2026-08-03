#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Create a new PLUS customer user end-to-end: aspgov.pri AD account, centroid.cloud.lcl
    AD account, SQL database access, and report (rpt) folders on the file servers.

.DESCRIPTION
    Standalone replacement for PLUS_Create_CustomerUser from the deprecated PLUSSysAdmins
    module. Does not require the legacy PowerShell profile or VM workstations.

    All configuration ships with the script under ./config/ and ./templates/.
    You must supply Template_SQL_GrantUserAccess.txt before running - see the README for where to grab it.

    What it does:
      1. Validates the customer site code against config/PLUSCustomers.csv
      2. Builds and collision-checks the samAccountName on aspgov.pri
      3. Creates the aspgov.pri AD user in OU=USERS,OU=<CUST>,OU=Customer,DC=aspgov,DC=pri
         and adds them to the <CUST>_PLUS AD group
      4. Sets msDS-cloudExtensionAttribute18 = IsPLUSCustAdmin=FALSE on the new account
      5. Creates report folders: \\plus-efp-fs[.|-train.]\aspgov.com\Userfolders[52|52TRN]\<cust>\<samid>\rpt
      6. Grants SQL access via Template_SQL_GrantUserAccess.txt on PRD04+STG04 (5.2 customers)
         or PRD01+STG01 (non-5.2 customers) - never both; 5.2 customers have no presence on PRD01/STG01
      7. Creates c_<samid> on centroid.cloud.lcl (skips gracefully if no OU mapping exists)
      8. Outputs the credentials block to console and copies it to clipboard

    What it does NOT do (PSync watcher gone, no longer applicable):
      - Set an account expiration date (the old 31-day window was cleared by a PSync watcher
        script that no longer exists; setting it without clearing it would lock out new users)

.PARAMETER Cust
    3-character PLUS customer site code (e.g. "SJC"). Case-insensitive.

.PARAMETER FirstName
    User's first name.

.PARAMETER MiddleInitial
    User's middle initial. Used as a tiebreaker if the default samid is taken.

.PARAMETER LastName
    User's last name.

.PARAMETER EmailAddress
    User's email address.


.PARAMETER IsUserDBA
    If set, the user is granted User_DBA='Y' in the database (customer admin level).

.PARAMETER ExistingUID
    Pre-existing UID/employeeID to use in the database (for migrations where the user
    already has a record in the customer databases).

.PARAMETER Is52Customer
    Override automatic 5.2 detection. When set, PRD04/STG04 SQL envs are included.
    By default the script checks the Version column in config/PLUSCustomers.csv.

.PARAMETER SamidOverride
    Override the auto-generated samAccountName. Use with caution.

.EXAMPLE
    .\New-PLUSCustomerUser.ps1 -Cust SJC -FirstName Rand -LastName "Al'Thor" `
        -EmailAddress ralthor@sjcfl.us

.EXAMPLE
    .\New-PLUSCustomerUser.ps1 -Cust TMK -FirstName Jane -LastName Smith `
        -EmailAddress jsmith@tompkins.gov -WhatIf

.NOTES
    Author: CloudOps SRE - CentralSquare Technologies
    Replaces: PLUS_Create_CustomerUser (PLUSSysAdmins.psm1)
    No VMware, no Rubrik, no PSync dependencies.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateLength(3,3)][ValidatePattern('[a-zA-Z]{3}')][string]$Cust,
    [Parameter(Mandatory)][string]$FirstName,
    [Parameter()][string]$MiddleInitial,
    [Parameter(Mandatory)][string]$LastName,
    [Parameter(Mandatory)][string]$EmailAddress,

    [Parameter()][switch]$IsUserDBA,
    [Parameter()][string]$ExistingUID,
    [Parameter()][switch]$Is52Customer,
    [Parameter()][string]$SamidOverride
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

function Resolve-PLUSSamid {
    <#
    Builds the candidate samAccountNames, checks aspgov.pri for collisions,
    and returns the first available one. Throws on unresolvable collision.
    #>
    param(
        [string]$Cust,
        [string]$FirstName,
        [string]$MiddleInitial,
        [string]$LastName,
        [string[]]$LNFICustomers,
        [string]$PdcAspgov,
        [string]$Override
    )

    if ($Override) {
        $samid = ($Override.Trim().ToLower() -replace "'", '' -replace '-', '' -replace ' ', '')
        Write-Verbose "Samid override: $samid"
        return $samid
    }

    $isLNFI = $Cust -in $LNFICustomers
    if ($isLNFI) {
        $samid  = ($Cust + $LastName  + $FirstName.Substring(0, 1))
        $samid2 = ($Cust + $LastName  + $FirstName.Substring(0, 1) + $MiddleInitial)
        $filter = ($Cust + '*' + $LastName + '*' + $FirstName.Substring(0, 1))
    } else {
        $samid  = ($Cust + $FirstName.Substring(0, 1) + $LastName)
        $samid2 = ($Cust + $FirstName.Substring(0, 1) + $MiddleInitial + $LastName)
        $filter = ($Cust + '*' + $FirstName.Substring(0, 1) + '*' + $LastName)
    }

    $samid  = $samid.ToLower()  -replace "'", '' -replace '-', '' -replace ' ', ''
    $samid2 = $samid2.ToLower() -replace "'", '' -replace '-', '' -replace ' ', ''

    Write-Verbose "Checking aspgov.pri for samid '$samid' ..."
    $exists1 = $null
    try { $exists1 = Get-ADUser -Identity $samid -Server $PdcAspgov -ErrorAction SilentlyContinue } catch {}

    if ($null -eq $exists1) {
        Write-Verbose "  $samid is available."
        return $samid
    }

    # samid taken - try samid2 if we have a middle initial
    if ($samid2 -ne $samid) {
        Write-Verbose "  $samid is taken. Trying $samid2 ..."
        $exists2 = $null
        try { $exists2 = Get-ADUser -Identity $samid2 -Server $PdcAspgov -ErrorAction SilentlyContinue } catch {}
        if ($null -eq $exists2) {
            Write-Verbose "  $samid2 is available."
            return $samid2
        }
        $similar = (Get-ADUser -Filter "samaccountname -like '$filter'" -Server $PdcAspgov |
            Sort-Object samaccountname).samaccountname -join ', '
        throw "Both '$samid' and '$samid2' already exist on aspgov.pri. Cannot continue. Similar accounts: $similar. Try again with a different middle initial."
    } else {
        throw "'$samid' already exists on aspgov.pri and no middle initial was provided. Try again with a middle initial."
    }
}

function New-AspgovCustomerUser {
    <#
    Creates the aspgov.pri AD user, adds them to the <CUST>_PLUS group,
    and stamps msDS-cloudExtensionAttribute18.
    Returns nothing; throws on failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Samid,
        [string]$DisplayName,
        [string]$FirstName,
        [string]$LastName,
        [string]$EmailAddress,
        [string]$CustUpper,
        [string]$CustName,
        [string]$CustState,
        [string]$EmployeeID,
        [string]$InitialPassword,
        [string]$PdcAspgov
    )

    $path    = "OU=USERS,OU=$CustUpper,OU=Customer,DC=aspgov,DC=pri"
    $upn     = "$Samid@aspgov.pri"
    $group   = "${CustUpper}_PLUS"

    if ($PSCmdlet.ShouldProcess("aspgov.pri", "New-ADUser '$Samid' in $path")) {
        New-ADUser `
            -Name              $DisplayName `
            -SamAccountName    $Samid `
            -AccountPassword   (ConvertTo-SecureString $InitialPassword -AsPlainText -Force) `
            -DisplayName       $DisplayName `
            -EmailAddress      $EmailAddress `
            -GivenName         $FirstName `
            -Surname           $LastName `
            -UserPrincipalName $upn `
            -Path              $path `
            -Company           $CustName `
            -State             $CustState `
            -City              $CustName `
            -EmployeeID        $EmployeeID `
            -Server            $PdcAspgov `
            -Enabled           $true `
            -ChangePasswordAtLogon $true `
            -ErrorAction Stop
        Write-Verbose "  ASPGOV: Created $Samid in $path"
        Write-Host "  OK: ASPGOV\$Samid created." -ForegroundColor Green
    }

    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Add-ADGroupMember '$group' <- '$Samid'")) {
        try {
            Add-ADGroupMember -Identity $group -Members $Samid -Server $PdcAspgov -ErrorAction Stop
            Write-Verbose "  ASPGOV: Added $Samid to $group"
        } catch {
            throw "Failed adding $Samid to $group on aspgov.pri. Check group exists. Error: $_"
        }
    }

    # Stamp the PLUS admin attribute - non-fatal if schema is absent on this DC
    if ($PSCmdlet.ShouldProcess("aspgov.pri", "Set msDS-cloudExtensionAttribute18 on '$Samid'")) {
        try {
            Set-ADUser -Identity $Samid -Server $PdcAspgov `
                -Add @{ 'msDS-cloudExtensionAttribute18' = 'IsPLUSCustAdmin=FALSE' } `
                -ErrorAction SilentlyContinue
            Write-Verbose "  ASPGOV: Set msDS-cloudExtensionAttribute18=IsPLUSCustAdmin=FALSE on $Samid"
        } catch {
            Write-Warning "  Could not set msDS-cloudExtensionAttribute18 on $Samid - skipping (non-fatal). Error: $_"
        }
    }
}

function New-PLUSReportFolders {
    <#
    Creates the rpt folder for the user on prod and train file servers.
    Customer users get prod + train only (no stage, no dev) - mirrors PLUS_CreateRPT behavior.
    Returns an array of [pscustomobject]{Path; Status} result objects.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Samid,
        [string]$CustLower,
        [bool]$Is52
    )

    # Prod and train only for customer users (matching PLUSSysAdmins.psm1:5452)
    $servers = @('plus-efp-fs.aspgov.com', 'plus-efp-fs-train.aspgov.com')
    # 5.2 customers get both Userfolders52 and Userfolders52TRN; all customers get Userfolders
    if ($Is52) {
        $shares = @('Userfolders', 'Userfolders52', 'Userfolders52TRN')
    } else {
        $shares = @('Userfolders')
    }

    $results = @()
    foreach ($server in $servers) {
        # Skip Userfolders52 on train (matches PLUSSysAdmins.psm1:5461 logic)
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
    <#
    Builds the ZZZUsersInfoZZZ token value for the SQL template.
    Mirrors PLUS_MakeSQLLine (PLUSSysAdmins.psm1:3201) but reads from the
    parameters we already have instead of re-querying AD.
    Format: ('ASPGOV\samid','FIRST','LAST','email','employeeid','N')
    #>
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
    Tokenizes Template_SQL_GrantUserAccess.txt and executes it against the
    specified SQL instance. Saves the generated script to $env:TEMP for audit.
    Verifies the sectb_crosswalk row actually landed before reporting OK - the
    template's two-phase print-then-execute pattern can silently do nothing
    without throwing, so absence of an exception is not proof of success.
    Returns [pscustomobject]{SqlEnv; Status; ScriptPath}.

    Template tokens:
      ZZZCustZZZ            -> lowercase cust code
      ZZZUsersInfoZZZ       -> SQL row tuple from Build-PLUSSqlUserInfo
      ZZZexecSectbAccessZZZ -> '0' for customer users
      ZZZcursorwhereZZZ     -> WHERE clause
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Samid,
        [string]$CustLower,
        [string]$SqlEnv,             # e.g. 'PRD01','STG01','PRD04','STG04'
        [string]$SqlInstance,        # e.g. 'CLD-PPLSDB001.aspgov.pri\PLUS'
        [string]$UserInfoToken,
        [string]$TemplatePath,
        [bool]$OnlyTrain             # true for STG envs - match legacy -onlyTrain behavior
    )

    if (-not (Test-Path $TemplatePath)) {
        return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = "SKIP-no-template ($TemplatePath)"; ScriptPath = $null }
    }

    # Build the WHERE clause for this run
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

    if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Invoke-Sqlcmd GrantUserAccess for $Samid ($SqlEnv)")) {
        return [pscustomobject]@{ SqlEnv = $SqlEnv; Status = 'WHATIF'; ScriptPath = $null }
    }

    # A newly-created ASPGOV account can take a while to replicate to whichever DC this SQL
    # instance resolves Windows logins against - CREATE LOGIN ... FROM WINDOWS (the first
    # statement the generated script runs) fails with "Windows NT user or group ... not
    # found" until that catches up, which aborts the entire generated script including every
    # downstream per-database grant. Retry the whole generate-and-execute cycle on that
    # specific error so a single New-PLUSCustomerUser.ps1 run succeeds without a manual
    # Grant-PLUSUserAccess.ps1 re-run. Any other error fails immediately, no retries.
    $replicationRetryDelaysSec = @(30, 60, 120, 120, 120, 120)   # ~9.5 min total if every retry fires
    $maxAttempts               = $replicationRetryDelaysSec.Count + 1

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            # Phase 1: run the template query to produce the per-database execution script.
            # @EXECUTENOW=0 in the template means every real statement is PRINTed, not EXECed -
            # Invoke-Sqlcmd only puts PRINT/message output on the pipeline with -Verbose, and
            # only once stream 4 is redirected onto stream 1 (4>&1). Without both, $generatedSql
            # is empty and Phase 2 below silently executes nothing.
            $generatedSql = Invoke-Sqlcmd `
                -ServerInstance    $SqlInstance `
                -Query             $sql `
                -QueryTimeout      120 `
                -Verbose `
                -ErrorAction       Stop `
                4>&1 |
                Out-String -Width 800

            # Strip "Changed database context to 'master'." noise, and the "VERBOSE: " prefix
            # PowerShell prepends to each line when a VerboseRecord (from 4>&1 above) is
            # rendered to text - the captured SQL must be plain text for Phase 2 to replay it.
            $generatedSql = $generatedSql -replace "Changed database context to 'master'\.", ''
            $generatedSql = ($generatedSql -split "`r?`n" | ForEach-Object { $_ -replace '^VERBOSE:\s?', '' }) -join "`r`n"

            Set-Content -Path $scriptFile -Value $generatedSql -Force

            # Phase 2: execute the generated script
            Invoke-Sqlcmd `
                -ServerInstance    $SqlInstance `
                -InputFile         $scriptFile `
                -QueryTimeout      120 `
                                -ErrorAction       Stop

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

function New-CentroidCustomerUser {
    <#
    Creates c_<samid> on centroid.cloud.lcl.
    Skips gracefully if no OU mapping is found for the customer.
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

    # Lookup OU name from the CSV map
    $mapRow = $OuMap | Where-Object { $_.cust.Trim().ToUpper() -eq $CustUpper } | Select-Object -First 1
    if (-not $mapRow -or -not $mapRow.CentroidCustomerOU) {
        return [pscustomobject]@{
            Status = "SKIPPED-no-OU-mapping"
            Samid  = $null
            Dn     = $null
        }
    }

    $centroidOuName    = $mapRow.CentroidCustomerOU
    $customersBaseDn   = 'OU=Customers,DC=centroid,DC=cloud,DC=lcl'
    $centroidUsersDn   = "OU=Users,OU=$centroidOuName,$customersBaseDn"

    # Verify the target OU exists
    try {
        $null = Get-ADOrganizationalUnit -Server $PdcCentroid -Identity $centroidUsersDn -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            Status = "FAILED-target-OU-missing: $centroidUsersDn - $_"
            Samid  = $null
            Dn     = $null
        }
    }

    # Build centroid samid (c_<aspgov_samid>), enforce 20-char AD limit
    $centroidSam = "c_$AspgovSamid"
    if ($centroidSam.Length -gt 20) {
        $centroidSam = $centroidSam.Substring(0, 20)
        Write-Warning "Centroid samAccountName exceeded 20 chars; truncated to '$centroidSam'."
    }

    # Check for an existing centroid user with the same email (avoid duplicate mail)
    $existsByMail = Get-ADUser -Server $PdcCentroid -Filter "mail -eq '$EmailAddress'" -ErrorAction SilentlyContinue
    if ($existsByMail) {
        return [pscustomobject]@{
            Status = "SKIPPED-email-already-exists ($($existsByMail.SamAccountName))"
            Samid  = $existsByMail.SamAccountName
            Dn     = $existsByMail.DistinguishedName
        }
    }

    $centroidUpn = "$centroidSam@$PdcCentroid"

    if ($PSCmdlet.ShouldProcess("centroid.cloud.lcl", "New-ADUser '$centroidSam' in $centroidUsersDn")) {
        try {
            New-ADUser `
                -Server               $PdcCentroid `
                -Name                 $DisplayName `
                -SamAccountName       $centroidSam `
                -UserPrincipalName    $centroidUpn `
                -DisplayName          $DisplayName `
                -GivenName            $FirstName `
                -Surname              $LastName `
                -EmailAddress         $EmailAddress `
                -OfficePhone          $EmailAddress `
                -AccountPassword      (ConvertTo-SecureString $InitialPassword -AsPlainText -Force) `
                -Path                 $centroidUsersDn `
                -Enabled              $true `
                -ChangePasswordAtLogon $false `
                -ErrorAction          Stop

            return [pscustomobject]@{
                Status = 'OK'
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
        return [pscustomobject]@{
            Status = 'WHATIF'
            Samid  = $centroidSam
            Dn     = $centroidUsersDn
        }
    }
}

function Format-PLUSCredentialsBlock {
    <#
    Builds the credentials + ticket-comment text block.
    Mirrors PLUS_UserCredsTixComment (PLUSSysAdmins.psm1:7226) with PSync wording removed.
    #>
    param(
        [string]$Samid,
        [string]$InitialPassword,
        [string]$CustName,
        [string]$FirstName,
        [string]$LastName,
        [string]$EmailAddress,

        [string]$CentroidSamid,
        [string]$CentroidStatus
    )

    $displayName = "$FirstName $LastName"
    $now         = Get-Date -Format 'M/d/yyyy'

    $block = @"
========================================
  CREDENTIALS -- $($Samid.ToUpper())
========================================
Username : ASPGOV\$($Samid.ToUpper())
Password : $InitialPassword
Centroid : $CentroidSamid  [$CentroidStatus]

Customer : $CustName
Name     : $displayName
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

# Resolve paths
$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
$configDir   = Join-Path $scriptDir '..\config'
$tmplDir     = Join-Path $scriptDir '..\templates'
$sqlTmplPath = Join-Path $tmplDir 'Template_SQL_GrantUserAccess.txt'

# SQL instance map (from PLUS_GetSQLInstance, PLUSSysAdmins.psm1:642)
$sqlInstances = @{
    PRD01 = 'CLD-PPLSDB001.aspgov.pri\PLUS'
    STG01 = 'CLD-SPLSDB001.aspgov.pri\PLUS'
    PRD04 = 'CLD-PPLSDB004.aspgov.pri\PLUS'
    STG04 = 'CLD-SPLSDB004.aspgov.pri\PLUS'
}

# ---- Step 0: Load config ----------------------------------------------------
Write-Verbose 'Loading configuration...'
$cfg = Get-PLUSConfig -ConfigDir $configDir

Write-Verbose ("Loaded {0} customers ({1} on 5.2, {2} LNFI), {3} Centroid mappings" -f
    $cfg.Customers.Count, $cfg.Customers52.Count, $cfg.CustomersLNFI.Count, $cfg.CentroidOuMap.Count)

# ---- Step 1: Normalize and validate inputs ----------------------------------
$EmailAddress  = $EmailAddress.Trim().ToLower()
$FirstName     = $FirstName.Trim().ToLower()
$LastName      = $LastName.Trim().ToLower()
$MiddleInitial = if ($MiddleInitial) { $MiddleInitial.Trim().ToLower() } else { '' }

$custL         = $Cust.Trim().ToLower()
$custU         = $custL.ToUpper()

if ($custL -notin $cfg.Customers) {
    throw "ERROR: '$custU' is not a valid customer site code in config/PLUSCustomers.csv. Check the code and try again."
}

$bIs52 = $Is52Customer.IsPresent -or ($custL -in $cfg.Customers52)

# Resolve customer name + state (from PLUSCustomers.csv Name/State columns, fallback to site code)
if ($cfg.CustomerNames.ContainsKey($custL)) {
    $custName  = $cfg.CustomerNames[$custL].Name
    $custState = $cfg.CustomerNames[$custL].State
} else {
    Write-Warning "No customer name found for '$custU' in PLUSCustomers.csv - using site code as display name. Add Name/State to the CSV for better output."
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

# ---- Step 3: Build and collision-check samid --------------------------------
$samid = Resolve-PLUSSamid `
    -Cust          $custL `
    -FirstName     $FirstName `
    -MiddleInitial $MiddleInitial `
    -LastName      $LastName `
    -LNFICustomers $cfg.CustomersLNFI `
    -PdcAspgov     $pdcAspgov `
    -Override      $SamidOverride

Write-Host "Samid resolved: $samid" -ForegroundColor Cyan

# ---- Step 4: Build user properties ------------------------------------------
# Title-case display name
$displayName = if ($MiddleInitial) {
    (Get-Culture).TextInfo.ToTitleCase("$FirstName $MiddleInitial $LastName")
} else {
    (Get-Culture).TextInfo.ToTitleCase("$FirstName $LastName")
}

# Initial password: Welcome<FI><LI>!<MMDD>  (e.g. WelcomeJD!0603)
$now          = Get-Date
$initPassword = 'Welcome' + $FirstName.Substring(0, 1).ToUpper() + $LastName.Substring(0, 1).ToUpper() + '!' + $now.ToString('MMdd')

# EmployeeID: use ExistingUID if supplied, else derive from samid (chars after the 3-char cust prefix, max 8)
if ($ExistingUID) {
    $employeeID = $ExistingUID.Trim()
} else {
    $raw = $samid.Substring(3)
    $employeeID = if ($raw.Length -gt 8) { $raw.Substring(0, 8) } else { $raw }
}

$bIsDBA = $IsUserDBA.IsPresent

# ---- Step 5: Create aspgov.pri AD user + group membership -------------------
Write-Host "Creating ASPGOV\$samid ($displayName, $EmailAddress) ..." -ForegroundColor Cyan

New-AspgovCustomerUser `
    -Samid           $samid `
    -DisplayName     $displayName `
    -FirstName       (Get-Culture).TextInfo.ToTitleCase($FirstName) `
    -LastName        (Get-Culture).TextInfo.ToTitleCase($LastName) `
    -EmailAddress    $EmailAddress `
    -CustUpper       $custU `
    -CustName        $custName `
    -CustState       $custState `
    -EmployeeID      $employeeID `
    -InitialPassword $initPassword `
    -PdcAspgov       $pdcAspgov

# ---- Step 6: Create rpt folders ---------------------------------------------
Write-Host "Creating RPT report folders ..." -ForegroundColor Cyan
$rptResults = New-PLUSReportFolders -Samid $samid -CustLower $custL -Is52 $bIs52
$rptResults | ForEach-Object {
    $color = if ($_.Status -eq 'CREATED' -or $_.Status -eq 'ALREADY-EXISTS') { 'Green' } `
             elseif ($_.Status -like 'SKIP*' -or $_.Status -eq 'WHATIF')     { 'Yellow' } `
             else { 'Red' }
    Write-Host ("  {0,-20} {1}" -f $_.Status, $_.Path) -ForegroundColor $color
}

# ---- Step 7: SQL access grant -----------------------------------------------
Write-Host "Granting SQL access ..." -ForegroundColor Cyan

$userInfoToken = Build-PLUSSqlUserInfo `
    -Samid        $samid `
    -FirstName    $FirstName `
    -LastName     $LastName `
    -EmailAddress $EmailAddress `
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
        -Samid         $samid `
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

# ---- Step 8: Create centroid.cloud.lcl user ---------------------------------
Write-Host "Creating centroid.cloud.lcl user ..." -ForegroundColor Cyan
$centroidResult = New-CentroidCustomerUser `
    -AspgovSamid     $samid `
    -CustUpper       $custU `
    -DisplayName     $displayName `
    -FirstName       (Get-Culture).TextInfo.ToTitleCase($FirstName) `
    -LastName        (Get-Culture).TextInfo.ToTitleCase($LastName) `
    -EmailAddress    $EmailAddress `
    -InitialPassword $initPassword `
    -OuMap           $cfg.CentroidOuMap `
    -PdcCentroid     $pdcCentroid

$centroidColor = switch -Wildcard ($centroidResult.Status) {
    'OK'       { 'Green'  }
    'WHATIF'   { 'Yellow' }
    'SKIPPED*' { 'Yellow' }
    default    { 'Red'    }
}
Write-Host ("  {0} {1}" -f $centroidResult.Status, $centroidResult.Samid) -ForegroundColor $centroidColor

# ---- Step 9: Output credentials block ---------------------------------------
$centroidSamDisplay = if ($null -ne $centroidResult.Samid) { $centroidResult.Samid } else { 'N/A' }

$credBlock = Format-PLUSCredentialsBlock `
    -Samid           $samid `
    -InitialPassword $initPassword `
    -CustName        $custName `
    -FirstName       (Get-Culture).TextInfo.ToTitleCase($FirstName) `
    -LastName        (Get-Culture).TextInfo.ToTitleCase($LastName) `
    -EmailAddress    $EmailAddress `
    -CentroidSamid   $centroidSamDisplay `
    -CentroidStatus  $centroidResult.Status

Write-Host "`n$credBlock" -BackgroundColor DarkBlue -ForegroundColor White
Set-Clipboard -Value $credBlock
Write-Host "`n[Credentials block copied to clipboard]" -ForegroundColor Cyan

# ---- Step 10: Open credentials email draft ----------------------------------
$emailTmplPath = Join-Path $tmplDir 'Email-NewCustomerUserCredentials.htm'
New-PLUSCredsEmail `
    -Samid        $samid `
    -FirstName    (Get-Culture).TextInfo.ToTitleCase($FirstName) `
    -CustName     $custName `
    -CustCode     $custU `
    -TemplatePath $emailTmplPath `
    -IsReenable   $false

#endregion --- main script ----------------------------------------------------
