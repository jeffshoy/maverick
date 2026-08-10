#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys a new FE 1.0 legacy Cognos Linux client instance from the golden AMI.
.DESCRIPTION
    Automates Steps 1-4 and the internal DNS step of runbooks/fe-legacy-cognos-client-deploy.md:
      1. Launches an EC2 instance in the client's PALegacyFinEnt{CLIENT} account from the
         golden Cognos Linux AMI (v1.2 — Tanium and domain-join packages pre-installed)
      2. Waits for the instance to appear online in SSM
      3. Sets the hostname to {CLIENT}-{T|P}ONSLRP001
      4. Generates a single random password for both `ubuntu` and `ubuntu-admin`, sets it on
         the instance, and stores it as a SecureString SSM Parameter
      5. Creates internal DNS A records via SSM against the client's own domain controller
         (see DNS Records below) — no domain admin credential needed, since the DC's own
         machine account has authority to update zones it hosts

    Network and IAM configuration (VPC/Subnet/Security Group/IAM Instance Profile) are NOT
    supplied by the caller — they are discovered from an existing reference instance in the
    same account/region: first an {CLIENT}-*ONSRP* report server (any environment), falling
    back to an {CLIENT}-*ONSJB* job server if no report server is found. If discovery finds
    more than one candidate, the operator is prompted to choose.

    DNS RECORDS: the client's domain controller is discovered by searching for a running
    instance matching {CLIENT}-*PDC00* (covers PDC001, PDC002, etc. — some clients have more
    than one DC). Two A records are created there, idempotently (skipped if already present):
      - {client}.cloud.lcl : {CLIENT}-{T|P}ONSLRP001 -> private IP
      - {client}cloud.aspgov.com : {client}-rptlnx (Prod) or {client}-rptlnx-tst (Test) -> private IP
    If the DC can't be found, or either SSM command fails, this step WARNS and falls through
    to the manual steps in the final summary — it does NOT abort the run, since the instance,
    hostname, and password steps have already succeeded by this point.

    PREREQUISITE: a domain admin account for the client's own AD "bubble" domain
    ({client}.cloud.lcl) must already exist before deploying — this is a distinct account per
    client, not a shared credential. Confirm you have valid domain admin credentials for that
    specific domain before running this script, since Step 6 (domain join, see below) needs
    them immediately after this script finishes.

    OUT OF SCOPE (manual steps per the runbook — see runbooks/fe-legacy-cognos-client-deploy.md):
      6. Domain join (realm discover / realm join) — intentionally NOT automated. Domain-join
         credential prompts don't work reliably over every automation surface this script may
         be invoked from (e.g. non-interactive tool pipes), so this step is always manual.
      7. Moving the computer object to the client's AD OU
      9. Cognos configuration (handed off to the GlobalLogic team)
      Proxy configuration (already baked into the AMI) and security tooling (Tanium already
      baked into the AMI — see runbooks/fe-legacy-cognos-ami-build.md Phase 8b) need no action.

    TROUBLESHOOTING — AMI not shared with the client account: if run-instances fails with an
    AMI permission error, the golden AMI/KMS key may not be shared with this client's AWS
    account yet. See the "AMI Not Shared" section in
    .claude/skills/fe-cognos-linux-deploy/SKILL.md for the sharing commands.

    Any parameter omitted at the command line is prompted for interactively.
.PARAMETER ClientCode
    Short client code (e.g. ANCO). Used to derive the AWS profile PALegacyFinEnt{CLIENT} and
    the AD domain {client}.cloud.lcl (lowercased).
.PARAMETER Region
    Deployment region: east or use1 (us-east-1), west or usw2 (us-west-2).
.PARAMETER Environment
    Prod or Test. Determines the ONSLRP naming letter (P/T) and the SSM Parameter Store path
    tier (prd-fe / tst-fe).
.EXAMPLE
    .\Invoke-FeCognosLinuxDeploy.ps1 -ClientCode ANCO -Region east -Environment Test
.EXAMPLE
    .\Invoke-FeCognosLinuxDeploy.ps1
    # Prompts for ClientCode, Region, and Environment interactively.
.EXAMPLE
    .\Invoke-FeCognosLinuxDeploy.ps1 -ClientCode ANCO -Region east -Environment Prod -WhatIf
.NOTES
    Author: CloudOps SRE
    Reference runbooks: runbooks/fe-legacy-cognos-client-deploy.md,
    runbooks/fe-legacy-cognos-ami-build.md
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string] $ClientCode,

    [Parameter()]
    [ValidateSet('east', 'use1', 'west', 'usw2')]
    [string] $Region,

    [Parameter()]
    [ValidateSet('Prod', 'Test')]
    [string] $Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve inputs (prompt for anything not supplied) ────────────────────────
if (-not $ClientCode) {
    $ClientCode = Read-Host "Client code (e.g. ANCO)"
}
if (-not $ClientCode) { throw "Client code is required." }
$ClientCode = $ClientCode.ToUpper()

if (-not $Region) {
    $Region = Read-Host "Region (east/use1 or west/usw2)"
}
$Region = switch ($Region) {
    'east' { 'use1' }
    'west' { 'usw2' }
    default { $Region }
}
if ($Region -notin @('use1', 'usw2')) { throw "Region must be east/use1 or west/usw2." }

if (-not $Environment) {
    $answer = Read-Host "Is this a TEST instance? (y/N)"
    $Environment = if ($answer -match '^[Yy]') { 'Test' } else { 'Prod' }
}
$EnvLetter = if ($Environment -eq 'Test') { 'T' } else { 'P' }
$EnvTier   = if ($Environment -eq 'Test') { 'tst-fe' } else { 'prd-fe' }

$AwsProfile = "PALegacyFinEnt$ClientCode"
$SsoSession = 'foundation'
$ComputerName = "$ClientCode-${EnvLetter}ONSLRP001"
$AdDomain = "$($ClientCode.ToLower()).cloud.lcl"  # for display in the final summary only — domain join itself is manual

$RegionLookup = @{
    'use1' = @{ AwsRegion = 'us-east-1'; Ami = 'ami-04a1a6ee507695289' }
    'usw2' = @{ AwsRegion = 'us-west-2'; Ami = 'ami-06dfdbf3cac70c6a7' }
}
$RegionInfo = $RegionLookup[$Region]
$AwsRegion  = $RegionInfo.AwsRegion
$Ami        = $RegionInfo.Ami

# Generic tags common to every FE Legacy Cognos Linux instance, regardless of client.
# No AWS launch template resource exists for these — each PALegacyFinEnt{CLIENT} account is
# separate and launch templates aren't cross-account shareable like the golden AMI is. This
# hashtable is the equivalent of "the template" and is merged with per-client/per-environment
# tags below at run-instances time.
$GenericTags = [ordered]@{
    cst_compliance_domain = 'pci'
    cst_product_line      = 'pa_financeenterprise'
    cst_tenancy            = 'single'
    DataDog                = 'enabled'
    CloudWatchAgent         = 'enabled'
    cst_application         = 'report_server'
}

# Environment-dependent tags (differ between Test and Prod, so can't live in $GenericTags)
$EnvironmentTags = [ordered]@{
    cst_environment    = if ($Environment -eq 'Test') { 'tst' } else { 'prd' }
    cst_backup_policy  = if ($Environment -eq 'Test') { 'nonprod' } else { 'prod' }
}

# Client-specific tags (same set the script has always applied)
$ClientTags = [ordered]@{
    Name            = $ComputerName
    cst_name        = $ComputerName
    cst_cost_center = $ClientCode
    cst_tenant      = $ClientCode.ToLower()
}

$LogRoot = "C:\Temp\FeCognosLinuxDeploy\$ClientCode"
if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
$LogFile = Join-Path $LogRoot "$ClientCode-$EnvLetter-deploy.log"
Start-Transcript -Path $LogFile -Append | Out-Null

$ProgressActivity = "FE Cognos Linux Deploy: $ComputerName"
$TotalSteps = 6
function Show-DeployProgress {
    param([int]$StepNumber, [string]$StepName)
    Write-Progress -Activity $ProgressActivity -Status "Step $StepNumber of $TotalSteps`: $StepName" -PercentComplete (($StepNumber / $TotalSteps) * 100)
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

Show-DeployProgress -StepNumber 1 -StepName 'SSO Session Check'
Write-Host "`n=== Step 1: SSO Session Check ===" -ForegroundColor Cyan
Ensure-SsoSession -Profile $AwsProfile

# ── Step 2: Discover network/IAM config from a reference instance ────────────
Show-DeployProgress -StepNumber 2 -StepName 'Reference Instance Discovery'
Write-Host "`n=== Step 2: Reference Instance Discovery ===" -ForegroundColor Cyan

function Find-ReferenceInstances {
    param([string]$NamePattern, [string]$Profile, [string]$Reg)
    $raw = aws ec2 describe-instances `
        --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=$NamePattern" `
        --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name'].Value|[0],State.Name,SubnetId,VpcId,IamInstanceProfile.Arn,join(',', SecurityGroups[].GroupId)]" `
        --output json `
        --profile $Profile --region $Reg 2>&1
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI error discovering reference instances (pattern=$NamePattern): $raw" }
    # -NoEnumerate: ConvertFrom-Json unwraps a single-element outer array by default,
    # collapsing a lone [InstanceId,Name,...] row into 7 separate scalar "rows".
    $rows = $raw | ConvertFrom-Json -NoEnumerate
    return @($rows | ForEach-Object {
        [PSCustomObject]@{
            InstanceId    = $_[0]
            Name          = $_[1]
            State         = $_[2]
            SubnetId      = $_[3]
            VpcId         = $_[4]
            IamProfileArn = $_[5]
            SecurityGroupIds = $_[6]
        }
    })
}

$reportPattern = "$ClientCode-*ONSRP*"
$jobPattern    = "$ClientCode-*ONSJB*"

Write-Host "  Searching for report server matching '$reportPattern'..." -ForegroundColor DarkGray
$candidates = Find-ReferenceInstances -NamePattern $reportPattern -Profile $AwsProfile -Reg $AwsRegion
$matchedPattern = $reportPattern

if ($candidates.Count -eq 0) {
    Write-Host "  No report server found. Falling back to job server matching '$jobPattern'..." -ForegroundColor Yellow
    $candidates = Find-ReferenceInstances -NamePattern $jobPattern -Profile $AwsProfile -Reg $AwsRegion
    $matchedPattern = $jobPattern
}

if ($candidates.Count -eq 0) {
    Write-Progress -Activity $ProgressActivity -Completed
    Stop-Transcript | Out-Null
    throw "No reference instance found in $AwsProfile / $AwsRegion matching '$reportPattern' or '$jobPattern'. Cannot discover VPC/Subnet/Security Group/IAM role — supply these manually or verify the account/region."
}

$reference = $null
if ($candidates.Count -eq 1) {
    $reference = $candidates[0]
    Write-Host "  Matched '$matchedPattern': $($reference.Name) ($($reference.InstanceId))" -ForegroundColor Green
} else {
    Write-Host "  Multiple instances matched '$matchedPattern':" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host "    [$i] $($candidates[$i].Name)  $($candidates[$i].InstanceId)  $($candidates[$i].State)" -ForegroundColor White
    }
    $choice = Read-Host "  Select an instance by index [0-$($candidates.Count - 1)]"
    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 0 -or $idx -ge $candidates.Count) {
        Write-Progress -Activity $ProgressActivity -Completed
        Stop-Transcript | Out-Null
        throw "Invalid selection '$choice'."
    }
    $reference = $candidates[$idx]
}

$SubnetId  = $reference.SubnetId
$SgIds     = $reference.SecurityGroupIds -split ','
$IamProfileArn = $reference.IamProfileArn
$IamProfileName = if ($IamProfileArn) { ($IamProfileArn -split '/')[-1] } else { $null }

if (-not $SubnetId -or -not $SgIds -or -not $IamProfileName) {
    Write-Progress -Activity $ProgressActivity -Completed
    Stop-Transcript | Out-Null
    throw "Reference instance $($reference.InstanceId) is missing Subnet/SecurityGroup/IamInstanceProfile data. Cannot proceed."
}

Write-Host "  Discovered — Subnet: $SubnetId | Security Groups: $($SgIds -join ', ') | IAM Profile: $IamProfileName | VPC: $($reference.VpcId)" -ForegroundColor Green

# ── Step 3: Launch EC2 instance ───────────────────────────────────────────────
Show-DeployProgress -StepNumber 3 -StepName 'Launch EC2 Instance'
Write-Host "`n=== Step 3: Launch EC2 Instance ===" -ForegroundColor Cyan

$instanceId = $null
if ($PSCmdlet.ShouldProcess($ComputerName, "Launch EC2 in $AwsProfile ($AwsRegion) from AMI $Ami")) {
    $allTags = [ordered]@{}
    foreach ($set in @($GenericTags, $EnvironmentTags, $ClientTags)) {
        foreach ($key in $set.Keys) { $allTags[$key] = $set[$key] }
    }
    $tagList = @($allTags.Keys | ForEach-Object { @{ Key = $_; Value = $allTags[$_] } })
    $tagsJson = ConvertTo-Json -Compress -Depth 5 @(
        @{ ResourceType = 'instance'; Tags = $tagList }
    )
    $ebsJson = '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","Encrypted":true}}]'

    $runArgs = @(
        'ec2', 'run-instances',
        '--profile', $AwsProfile, '--region', $AwsRegion,
        '--image-id', $Ami,
        '--instance-type', 'r6a.xlarge',
        '--subnet-id', $SubnetId,
        '--security-group-ids', @($SgIds),
        '--iam-instance-profile', "Name=$IamProfileName",
        '--block-device-mappings', $ebsJson,
        '--tag-specifications', $tagsJson,
        '--output', 'json'
    )
    $result = (aws @runArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Failed to launch $ComputerName : $result" }
    $launchedInstance = ($result | ConvertFrom-Json).Instances[0]
    $instanceId = $launchedInstance.InstanceId
    $privateIp = $launchedInstance.PrivateIpAddress
    Write-Host "  Launched: $instanceId ($privateIp)" -ForegroundColor Green
}

if ($WhatIfPreference) {
    Write-Host "`n=== WhatIf: Remaining Steps (Preview Only — Not Executed) ===" -ForegroundColor Cyan
    Write-Host "  Would poll SSM until $ComputerName is Online (up to 15 min)." -ForegroundColor DarkGray
    Write-Host "  Would set hostname to $ComputerName." -ForegroundColor DarkGray
    Write-Host "  Would generate a random password for ubuntu/ubuntu-admin and store it at /tenant/$($ClientCode.ToLower())-$EnvTier/cognoslx/admin_password." -ForegroundColor DarkGray
    Write-Host "  Would create internal DNS A records on the client's domain controller (see DNS Records)." -ForegroundColor DarkGray
    Write-Host "  Domain join, AD OU move, and Cognos config remain manual — see summary at completion." -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
    exit 0
}

# ── Step 4: Poll until SSM online ─────────────────────────────────────────────
Show-DeployProgress -StepNumber 4 -StepName 'Waiting for instance to appear in SSM'
Write-Host "`n=== Step 4: Waiting for instance to appear in SSM (up to 15 min) ===" -ForegroundColor Cyan

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

function Invoke-SsmShellCommand {
    param([string]$InstanceId, [string]$Profile, [string]$Reg, [string[]]$Commands, [string]$Comment, [int]$TimeoutSeconds = 90)
    $paramsJson = ConvertTo-Json @{ commands = $Commands } -Compress
    $cmdId = (aws ssm send-command --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters $paramsJson --comment $Comment --profile $Profile --region $Reg --query "Command.CommandId" --output text 2>&1)
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Status = 'SendFailed'; Output = ''; Error = $cmdId } }
    $elapsed = 0
    do {
        Start-Sleep -Seconds 5; $elapsed += 5
        $inv = aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId --profile $Profile --region $Reg --output json 2>&1 | ConvertFrom-Json
    } while ($inv.Status -in @('Pending', 'InProgress') -and $elapsed -lt $TimeoutSeconds)
    return [pscustomobject]@{ Status = $inv.Status; Output = $inv.StandardOutputContent; Error = $inv.StandardErrorContent }
}

Wait-SsmOnline -InstanceId $instanceId -Profile $AwsProfile -Reg $AwsRegion -Label $ComputerName | Out-Null
Write-Host "  Instance online in SSM." -ForegroundColor Green

# Re-fetch the private IP now the instance is confirmed running — safer than trusting the
# run-instances response, which can occasionally omit it depending on launch timing.
$privateIp = aws ec2 describe-instances --profile $AwsProfile --region $AwsRegion --instance-ids $instanceId --query "Reservations[0].Instances[0].PrivateIpAddress" --output text 2>&1
if ($LASTEXITCODE -ne 0 -or -not $privateIp -or $privateIp -eq 'None') {
    Write-Warning "  Could not determine private IP for $instanceId — DNS record creation will be skipped."
    $privateIp = $null
}

# ── Step 5: Set hostname, passwords, and store SSM Parameter ─────────────────
Show-DeployProgress -StepNumber 5 -StepName 'Hostname and Password Configuration'
Write-Host "`n=== Step 5: Hostname and Password Configuration ===" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($ComputerName, "Set hostname")) {
    $hostResult = Invoke-SsmShellCommand -InstanceId $instanceId -Profile $AwsProfile -Reg $AwsRegion -Comment "Set hostname $ComputerName" -TimeoutSeconds 30 -Commands @(
        "sudo hostnamectl set-hostname $ComputerName"
        "echo HOSTNAME_SET"
    )
    if ($hostResult.Status -eq 'Success' -and $hostResult.Output -match 'HOSTNAME_SET') {
        Write-Host "  Hostname set to $ComputerName." -ForegroundColor Green
    } else {
        Write-Warning "  Hostname set did not confirm success (Status: $($hostResult.Status)). Error: $($hostResult.Error)"
    }
}

function New-StrongPassword {
    param([int]$Length = 20)
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes($Length * 2)
    $b64 = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
    return $b64.Substring(0, $Length) + "!A9"
}

$password = New-StrongPassword
$ssmParamName = "/tenant/$($ClientCode.ToLower())-$EnvTier/cognoslx/admin_password"

if ($PSCmdlet.ShouldProcess($ComputerName, "Set ubuntu/ubuntu-admin passwords and store SSM parameter $ssmParamName")) {
    $pwCommands = @(
        "echo 'ubuntu-admin:$password' | sudo chpasswd"
        "echo 'ubuntu:$password' | sudo chpasswd"
        "echo PASSWORDS_SET"
    )
    $pwResult = Invoke-SsmShellCommand -InstanceId $instanceId -Profile $AwsProfile -Reg $AwsRegion -Comment "Set passwords $ComputerName" -TimeoutSeconds 30 -Commands $pwCommands
    if ($pwResult.Status -eq 'Success' -and $pwResult.Output -match 'PASSWORDS_SET') {
        Write-Host "  ubuntu/ubuntu-admin passwords set." -ForegroundColor Green
    } else {
        throw "Failed to set passwords on $ComputerName (Status: $($pwResult.Status)). Error: $($pwResult.Error)"
    }

    aws ssm put-parameter --profile $AwsProfile --region $AwsRegion --name $ssmParamName --type SecureString --value $password --overwrite --description "ubuntu/ubuntu-admin password for $ClientCode Cognos Linux instance ($Environment)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to store password in SSM Parameter Store at $ssmParamName." }
    Write-Host "  Password stored at SSM Parameter: $ssmParamName" -ForegroundColor Green
}
$password = $null

# ── Step 6: Create internal DNS A records on the client's domain controller ──
Show-DeployProgress -StepNumber 6 -StepName 'Internal DNS Records'
Write-Host "`n=== Step 6: Internal DNS Records ===" -ForegroundColor Cyan

$dnsRecordsCreated = @()
$dnsWarning = $null

if (-not $privateIp) {
    $dnsWarning = "Skipped — private IP could not be determined."
    Write-Warning "  $dnsWarning"
} else {
    $dcPattern = "$ClientCode-*PDC00*"
    Write-Host "  Searching for domain controller matching '$dcPattern'..." -ForegroundColor DarkGray
    $dcCandidates = Find-ReferenceInstances -NamePattern $dcPattern -Profile $AwsProfile -Reg $AwsRegion

    if ($dcCandidates.Count -eq 0) {
        $dnsWarning = "No domain controller found matching '$dcPattern'. Create DNS records manually (Step 6 of the runbook)."
        Write-Warning "  $dnsWarning"
    } else {
        $dc = $dcCandidates[0]
        if ($dcCandidates.Count -gt 1) {
            Write-Host "  Multiple DCs matched '$dcPattern' — using $($dc.Name) ($($dc.InstanceId)). Any should work; they share the same zones." -ForegroundColor Yellow
        } else {
            Write-Host "  Found DC: $($dc.Name) ($($dc.InstanceId))" -ForegroundColor Green
        }

        function New-DnsARecord {
            param([string]$DcInstanceId, [string]$Profile, [string]$Reg, [string]$ZoneName, [string]$RecordName, [string]$IpAddress)
            $psCommands = @(
                "Import-Module DnsServer",
                "if (-not (Get-DnsServerResourceRecord -ZoneName '$ZoneName' -ComputerName 'localhost' -Name '$RecordName' -ErrorAction SilentlyContinue)) { Add-DnsServerResourceRecordA -ZoneName '$ZoneName' -ComputerName 'localhost' -Name '$RecordName' -IPv4Address '$IpAddress'; Write-Output 'A_RECORD_CREATED' } else { Write-Output 'A_RECORD_EXISTS' }"
            )
            $paramsJson = ConvertTo-Json @{ commands = $psCommands } -Compress
            $cmdId = (aws ssm send-command --instance-ids $DcInstanceId --document-name AWS-RunPowerShellScript --parameters $paramsJson --comment "Create $ZoneName A record for $RecordName" --profile $Profile --region $Reg --query "Command.CommandId" --output text 2>&1)
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Status = 'SendFailed'; Output = ''; Error = $cmdId } }
            $elapsed = 0
            do {
                Start-Sleep -Seconds 3; $elapsed += 3
                $inv = aws ssm get-command-invocation --command-id $cmdId --instance-id $DcInstanceId --profile $Profile --region $Reg --output json 2>&1 | ConvertFrom-Json
            } while ($inv.Status -in @('Pending', 'InProgress') -and $elapsed -lt 30)
            return [pscustomobject]@{ Status = $inv.Status; Output = $inv.StandardOutputContent; Error = $inv.StandardErrorContent }
        }

        $ldapZone = "$($ClientCode.ToLower()).cloud.lcl"
        $aspgovZone = "$($ClientCode.ToLower())cloud.aspgov.com"
        $aspgovRecordName = if ($Environment -eq 'Test') { "$($ClientCode.ToLower())-rptlnx-tst" } else { "$($ClientCode.ToLower())-rptlnx" }

        $recordsToCreate = @(
            @{ Zone = $ldapZone; Name = $ComputerName; Description = "$ldapZone / $ComputerName" }
            @{ Zone = $aspgovZone; Name = $aspgovRecordName; Description = "$aspgovZone / $aspgovRecordName" }
        )

        foreach ($record in $recordsToCreate) {
            if ($PSCmdlet.ShouldProcess($record.Description, "Create DNS A record -> $privateIp")) {
                $dnsResult = New-DnsARecord -DcInstanceId $dc.InstanceId -Profile $AwsProfile -Reg $AwsRegion -ZoneName $record.Zone -RecordName $record.Name -IpAddress $privateIp
                if ($dnsResult.Status -eq 'Success' -and $dnsResult.Output -match 'A_RECORD_CREATED|A_RECORD_EXISTS') {
                    $outcome = $dnsResult.Output.Trim()
                    Write-Host "  $outcome`: $($record.Description) -> $privateIp" -ForegroundColor Green
                    $dnsRecordsCreated += "$($record.Description) ($outcome)"
                } else {
                    Write-Warning "  Failed to create '$($record.Description)' (Status: $($dnsResult.Status)). Error: $($dnsResult.Error)"
                    $dnsRecordsCreated += "$($record.Description) (FAILED)"
                }
            }
        }
    }
}

Write-Progress -Activity $ProgressActivity -Completed

# ── Final summary ──────────────────────────────────────────────────────────────
Write-Host "`n=== Deployment Summary ===" -ForegroundColor Green
Write-Host "  Client Code:      $ClientCode" -ForegroundColor White
Write-Host "  Environment:      $Environment" -ForegroundColor White
Write-Host "  Computer Name:    $ComputerName" -ForegroundColor White
Write-Host "  Region:           $AwsRegion" -ForegroundColor White
Write-Host "  Instance:         $instanceId" -ForegroundColor White
Write-Host "  Reference Server: $($reference.Name) ($matchedPattern)" -ForegroundColor White
Write-Host "  Private IP:       $privateIp" -ForegroundColor White
Write-Host "  Password Param:   $ssmParamName" -ForegroundColor White
Write-Host "  Log file:         $LogFile" -ForegroundColor White
Write-Host ""
Write-Host "  DNS RECORDS:" -ForegroundColor White
if ($dnsWarning) {
    Write-Host "  $dnsWarning" -ForegroundColor Yellow
} else {
    foreach ($r in $dnsRecordsCreated) { Write-Host "  $r" -ForegroundColor White }
}
Write-Host ""
Write-Host "  REMAINING MANUAL STEPS (runbooks/fe-legacy-cognos-client-deploy.md):" -ForegroundColor Yellow
Write-Host "  1. Domain join — SSM into $instanceId and run:" -ForegroundColor Yellow
Write-Host "       sudo realm discover $AdDomain" -ForegroundColor Yellow
Write-Host "       sudo realm join $AdDomain -U <domain-admin-user>" -ForegroundColor Yellow
Write-Host "     Requires a domain admin account in $ClientCode's own AD bubble domain" -ForegroundColor Yellow
Write-Host "     ($AdDomain) — confirm this exists before running." -ForegroundColor Yellow
Write-Host "  2. Move the computer object from Computers to the client's Servers OU (Step 7)." -ForegroundColor Yellow
Write-Host "  3. Hand off to the GlobalLogic team for Cognos configuration (Step 9) — RDP via" -ForegroundColor Yellow
Write-Host "     SSM port forwarding and run cogconfig.sh as ubuntu-admin." -ForegroundColor Yellow

Stop-Transcript | Out-Null
