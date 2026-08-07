#Requires -Version 7.0

<#
.SYNOPSIS
    Orchestrates full CZP NaviLine client provisioning — EC2 launch, domain join, and AD setup.
.DESCRIPTION
    1. Validates the reserved IP falls in the expected /24 for the chosen region (warns only)
    2. Auto-refreshes the foundation AWS SSO session if expired — no manual login required
    3. Launches the client EC2 instance in PALegacyCzp from the region's golden launch template
    4. Polls until the instance appears in SSM
    5. Renames and domain-joins the server using a three-tier approach:
         Tier 1: Add-Computer via SSM (rename, then join, then restart as separate steps)
         Tier 2: djoin.exe offline domain join (falls back here if Tier 1 hangs/fails)
         Tier 3: Prompts engineer for manual RDP join as last resort
    6. Confirms domain join
    7. Activates Windows against AWS KMS (169.254.169.250) — GPO later overrides the KMS
       server to an address unreachable from the CZP subnet, so this must happen before
       gpupdate applies that policy
    8. Generates a machine certificate for RDP: triggers domain CA auto-enrollment via
       certutil -pulse, polls briefly, and falls back to a self-signed certificate bound
       to the RDP listener if the CA doesn't issue one in time
    9. Runs Set-CzpNavilineAdConfig.ps1 on the aspgov.pri DC via a WinRM PSSession as
       svc-czp-navi-prov (sets LocalAccountTokenFilterPolicy on the DC first if not
       already set) — moves the computer to aspgov.pri/C2G and applies group memberships
    10. Runs gpupdate /force on the client server, then reboots it
    11. Prompts whether to create DNS records now (unless -CreateDns/-SkipDns was passed):
         - Internal aspgov.pri A record (client hostname -> private IP) on the region's DC
         - Internal aspgov.com CNAMEs on inf-svrdns001 (fixed server, all regions):
             <ClientCode>-egov.aspgov.com and s-<ClientCode>-egov.aspgov.com, both aliasing
             the aspgov.pri A record
         - Public Azure DNS A record (<ClientCode>-egov.aspgov.com -> public IP) in the
           aspgov.com zone, via az CLI — only if a public IP was supplied

    Remaining manual steps after this script completes: SecureLink entry, RFC update in
    Salesforce, and F5 BIG-IP WAF configuration. These are reported in the final summary
    and are not automated here.

    RESUME: if a prior run already launched and domain-joined the instance but failed or
    exited before AD config completed, pass -ExistingInstanceId to skip EC2 launch and the
    tiered domain join, and go straight to confirming domain join, then AD config, gpupdate,
    reboot, and DNS.

    PREREQUISITE: the ASPGOV\svc-czp-navi-prov service account must already exist,
    with move-in rights delegated on aspgov.pri/C2G and manage-membership rights on
    WSUS_PROD_2AM_GROUP and Apply_Schannel_TLS1_2_Enabled. Its password must be stored
    as a SecureString SSM Parameter at /czp-naviline/svc-czp-navi-prov in BOTH
    PALegacyCzp and PALegacySharedServices, in BOTH us-east-1 and us-west-2. This is a
    one-time manual setup step — see runbooks/czp-naviline-automation-context.md.
.PARAMETER ClientCode
    Short client code in uppercase (e.g. AUGU)
.PARAMETER IPAddress
    Internal IP reserved in Netbox for the client's server
.PARAMETER Region
    Deployment region: east or use1 (us-east-1), west or usw2 (us-west-2)
.PARAMETER Environment
    Prod or Test. If not supplied, the script prompts interactively (defaults to Prod).
.PARAMETER PublicIPAddress
    Public IP for the Azure DNS A record (<ClientCode>-egov.aspgov.com). Optional — if DNS
    creation proceeds without this, the script prompts for it separately (blank skips only
    the public Azure record; internal DNS records don't need a public IP).
.PARAMETER CreateDns
    Skip the "create DNS records?" prompt and proceed directly to DNS record creation.
.PARAMETER SkipDns
    Skip the "create DNS records?" prompt and skip DNS record creation entirely.
.PARAMETER ExistingInstanceId
    Resume a prior run against an already-launched, already-domain-joined instance. Skips
    EC2 launch and the tiered domain join; starts from confirming domain join, then runs
    AD config, gpupdate/reboot, and DNS as normal.
.EXAMPLE
    .\Invoke-CzpNavilineProvision.ps1 -ClientCode AUGU -IPAddress 172.30.12.14 -Region east
.EXAMPLE
    .\Invoke-CzpNavilineProvision.ps1 -ClientCode AUGU -IPAddress 172.30.12.14 -Region use1 -Environment Test
.EXAMPLE
    .\Invoke-CzpNavilineProvision.ps1 -ClientCode AUGU -IPAddress 172.30.12.14 -Region east -CreateDns -PublicIPAddress 203.0.113.10
.EXAMPLE
    .\Invoke-CzpNavilineProvision.ps1 -ClientCode AUGU -IPAddress 172.30.12.14 -Region east -ExistingInstanceId i-0c4400e40b1e97ea2 -CreateDns -PublicIPAddress 203.0.113.10
.NOTES
    Author: CloudOps SRE
    Account: PALegacyCzp (797320052894); AD work via PALegacySharedServices
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ClientCode,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $IPAddress,

    [Parameter(Mandatory)]
    [ValidateSet('east', 'use1', 'west', 'usw2')]
    [string] $Region,

    [Parameter()]
    [ValidateSet('Prod', 'Test')]
    [string] $Environment,

    [Parameter()]
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
    [string] $PublicIPAddress,

    [Parameter()]
    [switch] $CreateDns,

    [Parameter()]
    [switch] $SkipDns,

    [Parameter()]
    [ValidatePattern('^i-[0-9a-f]{8,17}$')]
    [string] $ExistingInstanceId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ClientCode = $ClientCode.ToUpper()
$Region = switch ($Region) {
    'east' { 'use1' }
    'west' { 'usw2' }
    default { $Region }
}

if (-not $Environment) {
    $answer = Read-Host "Is this a TEST instance? (y/N)"
    $Environment = if ($answer -match '^[Yy]') { 'Test' } else { 'Prod' }
}
$EnvLetter = if ($Environment -eq 'Test') { 'T' } else { 'P' }

$CzpProfile = 'PALegacyCzp'
$DcProfile  = 'PALegacySharedServices'
$SvcAccount = 'ASPGOV\svc-czp-navi-prov'
$SsmParam   = '/czp-naviline/svc-czp-navi-prov'
$SsoSession = 'foundation'
$TargetOu   = 'OU=C2G,DC=aspgov,DC=pri'

$DnsInternalInstanceId = 'i-04d29591f3a1ba9f4'   # inf-svrdns001 — fixed, all regions
$DnsInternalProfile    = 'PALegacySharedServices'
$DnsInternalRegion     = 'us-east-1'
$AzureSubscriptionId   = '991cd2ea-42a9-40c0-819d-557f37a3ae2b'
$AzureDnsRg            = 'Azure_DNS_RG'
$AzureDnsZone          = 'aspgov.com'

$RegionLookup = @{
    'use1' = @{
        AwsRegion  = 'us-east-1'
        Template   = 'lt-0835492de97e6e968'
        ExpectedCidr = '172.30.12.'
        DcInstanceId = 'i-0b1671eddda2d5ab2'   # inf-svrdc101 — hosts aspgov.pri DNS zone directly
    }
    'usw2' = @{
        AwsRegion  = 'us-west-2'
        Template   = 'lt-0f44a807767fb1341'
        ExpectedCidr = '172.29.12.'
        DcInstanceId = 'i-06d5b0b213faddcf6'   # INF-SVRDC111 — hosts aspgov.pri DNS zone directly
    }
}
$RegionInfo   = $RegionLookup[$Region]
$AwsRegion    = $RegionInfo.AwsRegion
$Template     = $RegionInfo.Template
$DcInstanceId = $RegionInfo.DcInstanceId

$ComputerName = "$ClientCode-${EnvLetter}C2GWB001"
$LogRoot = "C:\Temp\CzpNavilineBuilds\$ClientCode"
if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
$LogFile = Join-Path $LogRoot "$ClientCode-provision.log"
Start-Transcript -Path $LogFile -Append | Out-Null

$ProgressActivity = "CZP NaviLine Provisioning: $ComputerName"
$TotalSteps = 11
function Show-ProvisionProgress {
    param([int]$StepNumber, [string]$StepName)
    Write-Progress -Activity $ProgressActivity -Status "Step $StepNumber of $TotalSteps`: $StepName" -PercentComplete (($StepNumber / $TotalSteps) * 100)
}

# ── Step 0: Validate IP ───────────────────────────────────────────────────────
Show-ProvisionProgress -StepNumber 1 -StepName 'IP Validation'
Write-Host "`n=== IP Validation ===" -ForegroundColor Cyan

if ($IPAddress -notlike "$($RegionInfo.ExpectedCidr)*") {
    Write-Warning "IP $IPAddress does not fall in the expected $($RegionInfo.ExpectedCidr)0/24 range for $Region. Proceeding anyway — confirm the Netbox reservation is correct."
} else {
    Write-Host "  IP $IPAddress is in the expected range for $Region." -ForegroundColor Green
}

# ── Step 1: Ensure AWS SSO session is valid (auto-refresh) ───────────────────
function Ensure-SsoSession {
    param([string]$Profile)
    $identity = aws sts get-caller-identity --profile $Profile 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($identity -match 'expired|Token has expired|InvalidGrantException') {
            Write-Host "  SSO session for '$Profile' expired — refreshing via '$SsoSession'..." -ForegroundColor Yellow
            aws sso login --sso-session $SsoSession
            $identity = aws sts get-caller-identity --profile $Profile 2>&1
            if ($LASTEXITCODE -ne 0) { throw "SSO refresh did not resolve access for profile '$Profile': $identity" }
        } else {
            throw "Unable to resolve identity for profile '$Profile': $identity"
        }
    }
    Write-Host "  Session OK for '$Profile'." -ForegroundColor Green
}

Show-ProvisionProgress -StepNumber 2 -StepName 'SSO Session Check'
Write-Host "`n=== SSO Session Check ===" -ForegroundColor Cyan
Ensure-SsoSession -Profile $CzpProfile
Ensure-SsoSession -Profile $DcProfile

# ── Step 2: Launch EC2 instance ───────────────────────────────────────────────
Show-ProvisionProgress -StepNumber 3 -StepName 'Launch EC2 Instance'
Write-Host "`n=== Step 2: Launch EC2 Instance ===" -ForegroundColor Cyan

function Start-CzpInstance {
    param([string]$TemplateId, [string]$Name, [string]$IP, [string]$Reg, [string]$Code)
    $tagsJson = '[{"ResourceType":"instance","Tags":[' +
        '{"Key":"Name","Value":"' + $Name + '"},' +
        '{"Key":"cst_name","Value":"' + $Name + '"},' +
        '{"Key":"cst_cost_center","Value":"' + $Code + '"},' +
        '{"Key":"cst_tenant","Value":"' + $Code.ToLower() + '"}' +
        ']}]'
    $netJson = '[{"DeviceIndex":0,"PrivateIpAddress":"' + $IP + '"}]'
    $result = aws ec2 run-instances --launch-template "LaunchTemplateId=$TemplateId" --network-interfaces $netJson --tag-specifications $tagsJson --profile $CzpProfile --region $Reg --output json 2>&1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Failed to launch $Name : $result" }
    return $result.Instances[0].InstanceId
}

$instanceId = $null
$joinResult = $null
if ($ExistingInstanceId) {
    Write-Host "  Resuming against existing instance: $ExistingInstanceId (skipping EC2 launch)." -ForegroundColor Yellow
    $instanceId = $ExistingInstanceId
    $joinResult = 'Skipped (existing instance)'

    if ($WhatIfPreference) {
        Write-Host "`n=== WhatIf: Remaining Steps (Preview Only — Not Executed) ===" -ForegroundColor Cyan
        Write-Host "  Would confirm $ComputerName ($ExistingInstanceId) is domain-joined." -ForegroundColor DarkGray
        Write-Host "  Would activate Windows against AWS KMS (169.254.169.250)." -ForegroundColor DarkGray
        Write-Host "  Would generate/bind an RDP certificate (domain CA auto-enrollment, self-signed fallback)." -ForegroundColor DarkGray
        Write-Host "  Would run Set-CzpNavilineAdConfig.ps1 on DC $DcInstanceId as $SvcAccount (OU move + group membership)." -ForegroundColor DarkGray
        Write-Host "  Would run gpupdate /force and reboot $ComputerName." -ForegroundColor DarkGray
        Write-Host "  Would prompt to create DNS records: aspgov.pri A record, aspgov.com CNAMEs on inf-svrdns001, and an Azure public A record if a public IP is provided." -ForegroundColor DarkGray
        Stop-Transcript | Out-Null
        exit 0
    }
} else {
    if ($PSCmdlet.ShouldProcess($ComputerName, "Launch EC2 in PALegacyCzp ($AwsRegion)")) {
        Write-Host "  Launching $ComputerName ($IPAddress)..." -ForegroundColor Cyan
        $instanceId = Start-CzpInstance -TemplateId $Template -Name $ComputerName -IP $IPAddress -Reg $AwsRegion -Code $ClientCode
        Write-Host "  Launched: $instanceId" -ForegroundColor Green
    }

    if ($WhatIfPreference) {
        Write-Host "`n=== WhatIf: Remaining Steps (Preview Only — Not Executed) ===" -ForegroundColor Cyan
        Write-Host "  Would poll SSM until $ComputerName is Online (up to 15 min)." -ForegroundColor DarkGray
        Write-Host "  Would rename to $ComputerName and domain-join aspgov.pri into $TargetOu (tiered: Add-Computer -> djoin -> manual RDP)." -ForegroundColor DarkGray
        Write-Host "  Would confirm domain join." -ForegroundColor DarkGray
        Write-Host "  Would activate Windows against AWS KMS (169.254.169.250)." -ForegroundColor DarkGray
        Write-Host "  Would generate/bind an RDP certificate (domain CA auto-enrollment, self-signed fallback)." -ForegroundColor DarkGray
        Write-Host "  Would run Set-CzpNavilineAdConfig.ps1 on DC $DcInstanceId as $SvcAccount (OU move + group membership)." -ForegroundColor DarkGray
        Write-Host "  Would run gpupdate /force and reboot $ComputerName." -ForegroundColor DarkGray
        Write-Host "  Would prompt to create DNS records: aspgov.pri A record, aspgov.com CNAMEs on inf-svrdns001, and an Azure public A record if a public IP is provided." -ForegroundColor DarkGray
        Stop-Transcript | Out-Null
        exit 0
    }
}

# ── Step 3: Poll until SSM online ─────────────────────────────────────────────
Show-ProvisionProgress -StepNumber 4 -StepName 'Waiting for instance to appear in SSM'
Write-Host "`n=== Step 3: Waiting for instance to appear in SSM (up to 15 min) ===" -ForegroundColor Cyan

function Wait-SsmOnline {
    param([string]$InstanceId, [string]$Profile, [string]$Reg, [string]$Label, [int]$TimeoutSeconds = 900)
    $elapsed = 0
    do {
        Start-Sleep -Seconds 30
        $elapsed += 30
        $info = aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$InstanceId" --profile $Profile --region $Reg --query "InstanceInformationList[0].PingStatus" --output text 2>&1
        Write-Host "  $Label ($InstanceId): $info [${elapsed}s]" -ForegroundColor DarkGray
        if ($info -eq 'Online') { return $true }
    } while ($elapsed -lt $TimeoutSeconds)
    throw "Timed out waiting for $Label to appear in SSM after ${TimeoutSeconds}s"
}

function Invoke-SsmCommand {
    param([string]$InstanceId, [string]$Profile, [string]$Reg, [string[]]$Commands, [string]$Comment, [int]$TimeoutSeconds = 90)
    $paramsJson = ConvertTo-Json @{ commands = $Commands } -Compress
    $cmdId = (aws ssm send-command --instance-ids $InstanceId --document-name AWS-RunPowerShellScript --parameters $paramsJson --comment $Comment --profile $Profile --region $Reg --query "Command.CommandId" --output text 2>&1)
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Status = 'SendFailed'; Output = ''; Error = $cmdId } }
    $elapsed = 0
    do {
        Start-Sleep -Seconds 5; $elapsed += 5
        $inv = aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId --profile $Profile --region $Reg --output json 2>&1 | ConvertFrom-Json
    } while ($inv.Status -in @('Pending', 'InProgress') -and $elapsed -lt $TimeoutSeconds)
    return [pscustomobject]@{ Status = $inv.Status; Output = $inv.StandardOutputContent; Error = $inv.StandardErrorContent }
}

if ($ExistingInstanceId) {
    Write-Host "  Skipping SSM online poll (resuming against existing instance)." -ForegroundColor Yellow
} else {
    Wait-SsmOnline -InstanceId $instanceId -Profile $CzpProfile -Reg $AwsRegion -Label $ComputerName | Out-Null
    Write-Host "  Instance online in SSM." -ForegroundColor Green
}

# ── Step 4: Rename and domain join (three-tier) ───────────────────────────────
Show-ProvisionProgress -StepNumber 5 -StepName 'Rename and Domain Join'
Write-Host "`n=== Step 4: Rename and Domain Join ===" -ForegroundColor Cyan

function Invoke-TieredDomainJoin {
    param([string]$InstanceId, [string]$NewName, [string]$Profile, [string]$Reg, [string]$DcInstanceId, [string]$DcProfile)

    Write-Host "  [$NewName] Tier 1: Rename via SSM..." -ForegroundColor Cyan
    $r1 = Invoke-SsmCommand -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Comment "Rename $NewName" -TimeoutSeconds 60 -Commands @(
        "Rename-Computer -NewName '$NewName' -Force"
        "Write-Output 'Rename command issued'"
    )
    if ($r1.Status -ne 'Success') {
        Write-Warning "  [$NewName] Rename did not confirm success (Status: $($r1.Status)). Error: $($r1.Error)"
    } else {
        Write-Host "  [$NewName] Rename issued. Restarting to apply..." -ForegroundColor Green
    }

    Invoke-SsmCommand -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Comment "Restart after rename $NewName" -TimeoutSeconds 20 -Commands @(
        "Restart-Computer -Force"
    ) | Out-Null
    Start-Sleep -Seconds 45
    Wait-SsmOnline -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Label "$NewName (post-rename)" -TimeoutSeconds 300 | Out-Null

    Write-Host "  [$NewName] Tier 1: Domain join via Add-Computer (no restart)..." -ForegroundColor Cyan
    $joinCommands = @(
        'Import-Module AWS.Tools.SimpleSystemsManagement'
        "`$pass = (Get-SSMParameterValue -Name '$SsmParam' -WithDecryption `$true -Region '$Reg').Parameters[0].Value"
        "`$cred = New-Object System.Management.Automation.PSCredential('$SvcAccount', (ConvertTo-SecureString `$pass -AsPlainText -Force))"
        "Add-Computer -DomainName aspgov.pri -OUPath '$TargetOu' -Credential `$cred -Force -ErrorAction Stop"
        "Write-Output 'JOIN_OK'"
    )
    $r2 = Invoke-SsmCommand -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Comment "Domain join $NewName" -TimeoutSeconds 90 -Commands $joinCommands

    if ($r2.Status -eq 'Success' -and $r2.Output -match 'JOIN_OK') {
        Write-Host "  [$NewName] Tier 1 SUCCESS — Add-Computer joined the domain." -ForegroundColor Green
        Invoke-SsmCommand -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Comment "Restart after join $NewName" -TimeoutSeconds 20 -Commands @('Restart-Computer -Force') | Out-Null
        Start-Sleep -Seconds 60
        Wait-SsmOnline -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Label "$NewName (post-join)" -TimeoutSeconds 300 | Out-Null
        return 'Tier1-Success'
    }

    Write-Warning "  [$NewName] Tier 1 FAILED or hung (Status: $($r2.Status)). Falling back to Tier 2 (djoin offline join)."

    # ── Tier 2: djoin.exe offline domain join ──
    Write-Host "  [$NewName] Tier 2: Provisioning offline domain join blob on DC..." -ForegroundColor Cyan
    $blobFile = "C:\Temp\CzpNavilineBuilds\$ClientCode\$NewName.djoin"
    $provisionCommands = @(
        "if (-not (Test-Path 'C:\Temp\CzpNavilineBuilds\$ClientCode')) { New-Item -ItemType Directory -Path 'C:\Temp\CzpNavilineBuilds\$ClientCode' -Force | Out-Null }"
        "djoin.exe /provision /domain aspgov.pri /machine $NewName /machineou `"$TargetOu`" /savefile `"$blobFile`" /reuse"
        "Write-Output 'PROVISION_DONE'"
        "[Convert]::ToBase64String([System.IO.File]::ReadAllBytes('$blobFile'))"
    )
    $r3 = Invoke-SsmCommand -InstanceId $DcInstanceId -Profile $DcProfile -Reg $Reg -Comment "djoin provision $NewName" -TimeoutSeconds 60 -Commands $provisionCommands

    if ($r3.Status -ne 'Success' -or $r3.Output -notmatch 'PROVISION_DONE') {
        Write-Warning "  [$NewName] Tier 2 djoin provisioning FAILED. Error: $($r3.Error)"
        return 'AllTiersFailed'
    }

    $blobB64 = ($r3.Output -split "`n" | Where-Object { $_ -and $_ -ne 'PROVISION_DONE' } | Select-Object -Last 1).Trim()
    if (-not $blobB64) {
        Write-Warning "  [$NewName] Tier 2: Could not extract djoin blob content."
        return 'AllTiersFailed'
    }

    Write-Host "  [$NewName] Tier 2: Applying offline join blob on target server..." -ForegroundColor Cyan
    $applyCommands = @(
        "`$bytes = [Convert]::FromBase64String('$blobB64')"
        "[System.IO.File]::WriteAllBytes('C:\Windows\Temp\$NewName.djoin', `$bytes)"
        "djoin.exe /requestodj /loadfile 'C:\Windows\Temp\$NewName.djoin' /windowspath `$env:SystemRoot /localos"
        "Write-Output 'APPLY_OK'"
    )
    $r4 = Invoke-SsmCommand -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Comment "djoin apply $NewName" -TimeoutSeconds 60 -Commands $applyCommands

    if ($r4.Status -eq 'Success' -and $r4.Output -match 'APPLY_OK') {
        Write-Host "  [$NewName] Tier 2 SUCCESS — offline join applied. Restarting..." -ForegroundColor Green
        Invoke-SsmCommand -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Comment "Restart after djoin $NewName" -TimeoutSeconds 20 -Commands @('Restart-Computer -Force') | Out-Null
        Start-Sleep -Seconds 60
        Wait-SsmOnline -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Label "$NewName (post-djoin)" -TimeoutSeconds 300 | Out-Null
        return 'Tier2-Success'
    }

    Write-Warning "  [$NewName] Tier 2 djoin apply FAILED (Status: $($r4.Status)). Error: $($r4.Error)"
    return 'AllTiersFailed'
}

if ($ExistingInstanceId) {
    Write-Host "  Skipping tiered domain join (resuming against existing instance)." -ForegroundColor Yellow
} else {
    if ($PSCmdlet.ShouldProcess($ComputerName, "Rename and domain join")) {
        $joinResult = Invoke-TieredDomainJoin -InstanceId $instanceId -NewName $ComputerName -Profile $CzpProfile -Reg $AwsRegion -DcInstanceId $DcInstanceId -DcProfile $DcProfile
    }

    if ($joinResult -eq 'AllTiersFailed') {
        Write-Host "`n=== MANUAL ACTION REQUIRED ===" -ForegroundColor Red
        Write-Host "  $ComputerName ($instanceId): domain join failed via SSM and djoin. RDP in and run Add-Computer manually." -ForegroundColor Red
        Write-Host "  Once confirmed domain-joined, re-run this script's AD phase manually or contact the CloudOps team." -ForegroundColor Yellow
        Write-Progress -Activity $ProgressActivity -Completed
        Stop-Transcript | Out-Null
        exit 1
    }

    Write-Host "  $ComputerName : $joinResult" -ForegroundColor Green
}

# ── Step 5: Confirm domain join ───────────────────────────────────────────────
Show-ProvisionProgress -StepNumber 6 -StepName 'Confirming Domain Join'
Write-Host "`n=== Step 5: Confirming Domain Join ===" -ForegroundColor Cyan

function Confirm-DomainJoined {
    param([string]$InstanceId, [string]$Profile, [string]$Reg, [string]$Label)
    $r = Invoke-SsmCommand -InstanceId $InstanceId -Profile $Profile -Reg $Reg -Comment "Confirm domain join $Label" -TimeoutSeconds 30 -Commands @(
        '(Get-WmiObject Win32_ComputerSystem).Domain'
    )
    $domain = $r.Output.Trim()
    if ($domain -eq 'aspgov.pri') {
        Write-Host "  $Label confirmed joined to aspgov.pri" -ForegroundColor Green
        return $true
    }
    Write-Warning "  $Label domain is '$domain', not aspgov.pri"
    return $false
}

$joined = Confirm-DomainJoined -InstanceId $instanceId -Profile $CzpProfile -Reg $AwsRegion -Label $ComputerName
if (-not $joined) {
    Write-Error "Server is not confirmed domain-joined. Investigate before proceeding to AD setup."
    Write-Progress -Activity $ProgressActivity -Completed
    Stop-Transcript | Out-Null
    exit 1
}

# ── Step 6: Activate Windows against AWS KMS ──────────────────────────────────
Show-ProvisionProgress -StepNumber 7 -StepName 'Windows Activation'
Write-Host "`n=== Step 6: Windows Activation ===" -ForegroundColor Cyan

$activationResult = Invoke-SsmCommand -InstanceId $instanceId -Profile $CzpProfile -Reg $AwsRegion -Comment "Activate Windows on $ComputerName" -TimeoutSeconds 60 -Commands @(
    'slmgr /skms 169.254.169.250'
    'slmgr /ato'
    '(cscript //nologo C:\Windows\System32\slmgr.vbs /dli) -join "`n"'
)
if ($activationResult.Status -eq 'Success' -and $activationResult.Output -match 'Licensed') {
    Write-Host "  Windows activated against AWS KMS (License Status: Licensed)." -ForegroundColor Green
} else {
    Write-Warning "  Could not confirm Windows activation (Status: $($activationResult.Status)). Output: $($activationResult.Output) Error: $($activationResult.Error)"
    Write-Warning "  Not fatal — GPO may re-override the KMS setting later, requiring a manual re-run of 'slmgr /skms 169.254.169.250; slmgr /ato' on the server."
}

# ── Step 7: Generate RDP certificate ───────────────────────────────────────────
Show-ProvisionProgress -StepNumber 8 -StepName 'RDP Certificate'
Write-Host "`n=== Step 7: Generate RDP Certificate ===" -ForegroundColor Cyan

$rdpCertResult = Invoke-SsmCommand -InstanceId $instanceId -Profile $CzpProfile -Reg $AwsRegion -Comment "Generate RDP certificate on $ComputerName" -TimeoutSeconds 180 -Commands @(
    'certutil -pulse'
    '$cert = $null'
    'for ($i = 0; $i -lt 6; $i++) {'
    '    Start-Sleep -Seconds 20'
    "    `$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { `$_.Subject -like `"CN=`$env:COMPUTERNAME*`" -and `$_.Issuer -ne `$_.Subject } | Select-Object -First 1"
    '    if ($cert) { break }'
    '}'
    'if (-not $cert) {'
    "    `$hostname = `"`$env:COMPUTERNAME.aspgov.pri`""
    '    $cert = New-SelfSignedCertificate -DnsName $hostname -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(5)'
    '    Export-Certificate -Cert $cert -FilePath C:\Windows\Temp\rdp-cert.cer | Out-Null'
    '    Import-Certificate -FilePath C:\Windows\Temp\rdp-cert.cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null'
    '    Remove-Item C:\Windows\Temp\rdp-cert.cer -ErrorAction SilentlyContinue'
    '    Write-Output "SELF_SIGNED_CERT_USED"'
    '} else {'
    '    Write-Output "CA_CERT_USED"'
    '}'
    '$thumbprint = $cert.Thumbprint'
    'wmic /namespace:\\root\cimv2\TerminalServices PATH Win32_TSGeneralSetting Set SSLCertificateSHA1Hash="$thumbprint" | Out-Null'
    'Restart-Service TermService -Force'
    'Write-Output "RDPCERT_OK"'
)
if ($rdpCertResult.Status -eq 'Success' -and $rdpCertResult.Output -match 'RDPCERT_OK') {
    $certSource = if ($rdpCertResult.Output -match 'SELF_SIGNED_CERT_USED') { 'self-signed (CA did not issue in time)' } else { 'domain CA (auto-enrollment)' }
    Write-Host "  RDP certificate bound ($certSource)." -ForegroundColor Green
} else {
    Write-Warning "  Failed to generate/bind RDP certificate (Status: $($rdpCertResult.Status)). Error: $($rdpCertResult.Error)"
    Write-Warning "  Not fatal — hostname-based RDP may show NLA errors until this is fixed manually. Connecting by IP still works."
}

# ── Step 8: Run AD config on DC as svc-czp-navi-prov (direct -Credential, no PSSession) ──
Show-ProvisionProgress -StepNumber 9 -StepName 'Active Directory Configuration'
Write-Host "`n=== Step 8: Active Directory Configuration ===" -ForegroundColor Cyan

# Upload the AD script content to the DC as base64 (avoids heredoc/escaping issues over SSM)
$adScriptContent = Get-Content "scripts\czp-naviline\Set-CzpNavilineAdConfig.ps1" -Raw -Encoding UTF8
$adScriptB64     = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($adScriptContent))

$uploadResult = Invoke-SsmCommand -InstanceId $DcInstanceId -Profile $DcProfile -Reg $AwsRegion -Comment "Upload AD script for $ClientCode" -TimeoutSeconds 30 -Commands @(
    "`$bytes = [Convert]::FromBase64String('$adScriptB64')"
    "[System.IO.File]::WriteAllBytes('C:\Windows\Temp\Set-CzpNavilineAdConfig.ps1', `$bytes)"
    "Write-Output 'SCRIPT_UPLOADED'"
)
if ($uploadResult.Status -ne 'Success' -or $uploadResult.Output -notmatch 'SCRIPT_UPLOADED') {
    throw "Failed to upload AD script to DC: $($uploadResult.Error)"
}
Write-Host "  AD script uploaded to DC." -ForegroundColor Green

# Authenticate as svc-czp-navi-prov directly on each AD cmdlet call, same pattern as
# the domain-join step (Add-Computer -Credential) — no PSSession/WinRM loopback needed.
# Credential fetched via aws CLI v2 (native binary, no .NET Framework dependency — the
# AWS.Tools PowerShell module requires .NET 4.7.2+, which these DCs don't have). Proxy
# is explicitly bypassed: the DC's configured WinHTTP proxy (172.30.20.55:8080) does not
# proxy AWS API traffic correctly for this client — direct connectivity to AWS already
# works from these DCs, confirmed via Test-NetConnection.
$runCommands = @(
    '$env:HTTP_PROXY = ""; $env:HTTPS_PROXY = ""; $env:NO_PROXY = "*"'
    "`$pass = & 'C:\Program Files\Amazon\AWSCLIV2\aws.exe' ssm get-parameter --name '$SsmParam' --with-decryption --region '$AwsRegion' --query 'Parameter.Value' --output text"
    "`$cred = New-Object System.Management.Automation.PSCredential('$SvcAccount', (ConvertTo-SecureString `$pass -AsPlainText -Force))"
    "& 'C:\Windows\Temp\Set-CzpNavilineAdConfig.ps1' -ComputerName '$ComputerName' -Credential `$cred -ErrorAction Stop"
    "Write-Output 'ADCONFIG_OK'"
)

$adResult = Invoke-SsmCommand -InstanceId $DcInstanceId -Profile $DcProfile -Reg $AwsRegion -Comment "Run AD config for $ClientCode" -TimeoutSeconds 90 -Commands $runCommands

# Gate on the explicit success marker, not just SSM's own Status — SSM reports "Success"
# whenever PowerShell finishes running, even if the AD script inside it threw an error
# (that's exactly what caused gpupdate/reboot to run once despite AD config failing).
if ($adResult.Status -eq 'Success' -and $adResult.Output -match 'ADCONFIG_OK') {
    Write-Host $adResult.Output -ForegroundColor White
} else {
    Write-Error "AD configuration failed (Status: $($adResult.Status)).`n$($adResult.Output)`n$($adResult.Error)`n`nFalling back: RDP into the DC and run C:\Windows\Temp\Set-CzpNavilineAdConfig.ps1 manually with -ComputerName $ComputerName."
    Write-Progress -Activity $ProgressActivity -Completed
    Stop-Transcript | Out-Null
    exit 1
}

# ── Step 9: gpupdate and reboot ────────────────────────────────────────────────
Show-ProvisionProgress -StepNumber 10 -StepName 'gpupdate and Reboot'
Write-Host "`n=== Step 9: gpupdate and Reboot ===" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($ComputerName, "Run gpupdate /force and reboot")) {
    $gpResult = Invoke-SsmCommand -InstanceId $instanceId -Profile $CzpProfile -Reg $AwsRegion -Comment "gpupdate $ComputerName" -TimeoutSeconds 120 -Commands @(
        'gpupdate /force'
        'Write-Output "GPUPDATE_DONE"'
    )
    if ($gpResult.Status -eq 'Success' -and $gpResult.Output -match 'GPUPDATE_DONE') {
        Write-Host "  gpupdate /force completed." -ForegroundColor Green
    } else {
        Write-Warning "  gpupdate did not confirm success (Status: $($gpResult.Status)). Error: $($gpResult.Error)"
    }

    Invoke-SsmCommand -InstanceId $instanceId -Profile $CzpProfile -Reg $AwsRegion -Comment "Reboot after gpupdate $ComputerName" -TimeoutSeconds 20 -Commands @('Restart-Computer -Force') | Out-Null
    Write-Host "  Reboot issued." -ForegroundColor Green
}

# ── Step 10: DNS Records ───────────────────────────────────────────────────────
Show-ProvisionProgress -StepNumber 11 -StepName 'DNS Records'
Write-Host "`n=== Step 10: DNS Records ===" -ForegroundColor Cyan

$dnsResults = [pscustomobject]@{
    InternalA     = 'Skipped'
    InternalCname = 'Skipped'
    PublicA       = 'Skipped'
}

$doDns = $false
if ($CreateDns) {
    $doDns = $true
} elseif ($SkipDns) {
    $doDns = $false
} else {
    $answer = Read-Host "Create DNS records for $ComputerName now? (Y/n)"
    $doDns = -not ($answer -match '^[Nn]')
}

if (-not $doDns) {
    Write-Host "  Skipping DNS record creation (not requested)." -ForegroundColor Yellow
} else {
    if (-not $PublicIPAddress) {
        $PublicIPAddress = Read-Host "  Enter public IP for $ClientCode-egov.aspgov.com (leave blank to skip only the public Azure record)"
    }

    # ── 8a: Internal aspgov.pri A record (on the region's DC) ──
    Write-Host "  [aspgov.pri] Checking/creating A record for $ComputerName..." -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess("$ComputerName.aspgov.pri", "Create internal A record -> $IPAddress")) {
        $aRecordCommands = @(
            'Import-Module DnsServer'
            "if (-not (Get-DnsServerResourceRecord -ZoneName 'aspgov.pri' -ComputerName 'localhost' -Name '$ComputerName' -ErrorAction SilentlyContinue)) { Add-DnsServerResourceRecordA -ZoneName 'aspgov.pri' -ComputerName 'localhost' -Name '$ComputerName' -IPv4Address '$IPAddress'; Write-Output 'A_RECORD_CREATED' } else { Write-Output 'A_RECORD_EXISTS' }"
        )
        $aResult = Invoke-SsmCommand -InstanceId $DcInstanceId -Profile $DcProfile -Reg $AwsRegion -Comment "Create aspgov.pri A record for $ComputerName" -TimeoutSeconds 30 -Commands $aRecordCommands
        if ($aResult.Status -eq 'Success' -and $aResult.Output -match 'A_RECORD_CREATED|A_RECORD_EXISTS') {
            $dnsResults.InternalA = $aResult.Output.Trim()
            Write-Host "  $($dnsResults.InternalA): $ComputerName.aspgov.pri -> $IPAddress" -ForegroundColor Green
        } else {
            $dnsResults.InternalA = 'Failed'
            Write-Warning "  Failed to create/verify aspgov.pri A record (Status: $($aResult.Status)). Error: $($aResult.Error)"
        }
    }

    # ── 8b: Internal aspgov.com CNAMEs (fixed server: inf-svrdns001) ──
    Write-Host "  [aspgov.com internal] Checking/creating CNAMEs on inf-svrdns001..." -ForegroundColor Cyan
    $cnameLabels = @("$($ClientCode.ToLower())-egov", "s-$($ClientCode.ToLower())-egov")
    $cnameOutcomes = @()
    foreach ($label in $cnameLabels) {
        if ($PSCmdlet.ShouldProcess("$label.aspgov.com", "Create internal CNAME -> $ComputerName.aspgov.pri")) {
            $cnameCommands = @(
                'Import-Module DnsServer'
                "if (-not (Get-DnsServerResourceRecord -ZoneName 'aspgov.com' -ComputerName 'localhost' -Name '$label' -RRType CName -ErrorAction SilentlyContinue)) { Add-DnsServerResourceRecordCName -ZoneName 'aspgov.com' -ComputerName 'localhost' -Name '$label' -HostNameAlias '$ComputerName.aspgov.pri'; Write-Output 'CNAME_CREATED' } else { Write-Output 'CNAME_EXISTS' }"
            )
            $cResult = Invoke-SsmCommand -InstanceId $DnsInternalInstanceId -Profile $DnsInternalProfile -Reg $DnsInternalRegion -Comment "Create aspgov.com CNAME $label" -TimeoutSeconds 30 -Commands $cnameCommands
            if ($cResult.Status -eq 'Success' -and $cResult.Output -match 'CNAME_CREATED|CNAME_EXISTS') {
                $outcome = $cResult.Output.Trim()
                Write-Host "  $outcome`: $label.aspgov.com -> $ComputerName.aspgov.pri" -ForegroundColor Green
            } else {
                $outcome = 'Failed'
                Write-Warning "  Failed to create/verify CNAME '$label' (Status: $($cResult.Status)). Error: $($cResult.Error)"
            }
            $cnameOutcomes += $outcome
        }
    }
    $dnsResults.InternalCname = $cnameOutcomes -join ', '

    # ── 8c: Public Azure DNS A record ──
    if (-not $PublicIPAddress) {
        Write-Host "  [Azure public] No public IP provided — skipping public A record." -ForegroundColor Yellow
    } else {
        Write-Host "  [Azure public] Checking/creating A record for $($ClientCode.ToLower())-egov.aspgov.com..." -ForegroundColor Cyan
        $azAcct = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Azure session not active — running az login..." -ForegroundColor Yellow
            az login | Out-Null
        }
        az account set --subscription $AzureSubscriptionId

        $azRecordName = "$($ClientCode.ToLower())-egov"
        $existing = az network dns record-set a show --zone-name $AzureDnsZone --resource-group $AzureDnsRg --name $azRecordName --query "arecords[].ipv4Address" --output tsv 2>&1

        if ($LASTEXITCODE -eq 0 -and $existing) {
            if ($existing.Trim() -eq $PublicIPAddress) {
                $dnsResults.PublicA = 'AlreadyCorrect'
                Write-Host "  Azure A record already points to $PublicIPAddress — no change needed." -ForegroundColor Yellow
            } else {
                Write-Warning "  Azure A record for '$azRecordName' already exists pointing to '$existing' (requested: $PublicIPAddress)."
                $confirm = Read-Host "  Overwrite existing Azure A record with $PublicIPAddress? (y/N)"
                if ($confirm -match '^[Yy]') {
                    if ($PSCmdlet.ShouldProcess("$azRecordName.aspgov.com (Azure)", "Overwrite public A record -> $PublicIPAddress")) {
                        az network dns record-set a remove-record --resource-group $AzureDnsRg --zone-name $AzureDnsZone --record-set-name $azRecordName --ipv4-address $existing.Trim() | Out-Null
                        az network dns record-set a add-record --resource-group $AzureDnsRg --zone-name $AzureDnsZone --record-set-name $azRecordName --ipv4-address $PublicIPAddress | Out-Null
                        $dnsResults.PublicA = 'Overwritten'
                        Write-Host "  Azure A record updated: $azRecordName.aspgov.com -> $PublicIPAddress" -ForegroundColor Green
                    }
                } else {
                    $dnsResults.PublicA = 'SkippedByUser'
                    Write-Host "  Skipped overwriting existing Azure A record." -ForegroundColor Yellow
                }
            }
        } else {
            if ($PSCmdlet.ShouldProcess("$azRecordName.aspgov.com (Azure)", "Create public A record -> $PublicIPAddress")) {
                az network dns record-set a add-record --resource-group $AzureDnsRg --zone-name $AzureDnsZone --record-set-name $azRecordName --ipv4-address $PublicIPAddress | Out-Null
                $dnsResults.PublicA = 'Created'
                Write-Host "  Azure A record created: $azRecordName.aspgov.com -> $PublicIPAddress" -ForegroundColor Green
            }
        }
    }
}

Write-Progress -Activity $ProgressActivity -Completed

# ── Final summary ──────────────────────────────────────────────────────────────
Write-Host "`n=== Provisioning Complete ===" -ForegroundColor Green
Write-Host "  Client Code:     $ClientCode" -ForegroundColor White
Write-Host "  Environment:     $Environment" -ForegroundColor White
Write-Host "  Computer Name:   $ComputerName" -ForegroundColor White
Write-Host "  Region:          $AwsRegion" -ForegroundColor White
Write-Host "  Instance:        $instanceId ($IPAddress)" -ForegroundColor White
Write-Host "  Domain Join:     $joinResult" -ForegroundColor White
Write-Host "  Log file:        $LogFile" -ForegroundColor White
Write-Host ""
Write-Host "  Windows Activation: $(if ($activationResult.Status -eq 'Success' -and $activationResult.Output -match 'Licensed') { 'Licensed' } else { 'Not confirmed - check manually' })" -ForegroundColor White
Write-Host "  RDP Certificate:    $(if ($rdpCertResult.Status -eq 'Success' -and $rdpCertResult.Output -match 'RDPCERT_OK') { if ($rdpCertResult.Output -match 'SELF_SIGNED_CERT_USED') { 'Bound (self-signed)' } else { 'Bound (domain CA)' } } else { 'Not confirmed - check manually' })" -ForegroundColor White
Write-Host ""
Write-Host "  DNS RECORDS:" -ForegroundColor White
Write-Host "  Internal A (aspgov.pri):        $($dnsResults.InternalA)" -ForegroundColor White
Write-Host "  Internal CNAMEs (aspgov.com):   $($dnsResults.InternalCname)" -ForegroundColor White
Write-Host "  Public A (Azure aspgov.com):     $($dnsResults.PublicA)" -ForegroundColor White
Write-Host ""
Write-Host "  REMAINING MANUAL STEPS:" -ForegroundColor Yellow
Write-Host "  1. Create SecureLink entry for $ComputerName at https://securelink.aspgov.com/rss-servlet/signon.action" -ForegroundColor Yellow
Write-Host "  2. Update the RFC in Salesforce (instance ID, private IP, deployment date, status: Complete)" -ForegroundColor Yellow
Write-Host "  3. Configure F5 BIG-IP WAF (node, pool, policy, virtual server) — see Phase 6 of czp-naviline-client-deploy.md" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Note: if you need hostname-based RDP to this server right now, run 'klist purge' on YOUR workstation first" -ForegroundColor Yellow
Write-Host "  to clear stale Kerberos tickets. Connecting by IP works immediately without this." -ForegroundColor Yellow

Stop-Transcript | Out-Null
