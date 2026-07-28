#Requires -Version 7.0

<#
.SYNOPSIS
    Adds a new client domain to SES and both Postfix relay_domains files.
.DESCRIPTION
    1. Checks if the SES identity already exists in the target region. If not, creates it with
       Easy DKIM (RSA_2048_BIT, signatures enabled, Route53 disabled) and outputs DKIM records.
    2. Adds the domain alphabetically into the Government/municipal section of relay_domains on
       BOTH Postfix relays (us-east-1 and us-west-2). Other sections are untouched.
    3. Runs postmap, reloads postfix, and validates on both relays.
.PARAMETER Domain
    The client's email domain (e.g. clientdomain.com).
.PARAMETER Region
    The AWS region to create the SES identity in. 'east' = us-east-1, 'west' = us-west-2.
.EXAMPLE
    .\Add-SmtpClient.ps1 -Domain cityofsolanabeach.ca.gov -Region west -WhatIf
    .\Add-SmtpClient.ps1 -Domain cityofsolanabeach.ca.gov -Region west
.NOTES
    Author: CloudOps SRE
    Requires: AWS CLI v2, profile PALegacySharedServices (foundation SSO)
    SSM Parameters (must exist in both us-east-1 and us-west-2):
      /relay/svc-wsl-relay  - Windows password for cloud\svc-wsl-relay (runs WSL)
      /relay/relayadmin     - sudo password for relayadmin inside WSL (different per region)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Domain,

    [Parameter(Mandatory)]
    [ValidateSet('east', 'west')]
    [string] $Region
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AwsProfile    = 'PALegacySharedServices'
$SesRegion     = if ($Region -eq 'east') { 'us-east-1' } else { 'us-west-2' }
$WslUser       = 'cloud\svc-wsl-relay'
$SsmWslRelay   = '/relay/svc-wsl-relay'
$SsmRelayAdmin = '/relay/relayadmin'

$relays = @(
    [pscustomobject]@{ Name = 'inf-relay001 (us-east-1)'; InstanceId = 'i-034b91ef8516afd72'; Region = 'us-east-1' }
    [pscustomobject]@{ Name = 'inf-relay101 (us-west-2)'; InstanceId = 'i-0be7224e91e5b785a'; Region = 'us-west-2' }
)

# ── Step 1: SES Identity ────────────────────────────────────────────────────────
Write-Host "`n=== Step 1: SES Identity ($SesRegion) ===" -ForegroundColor Cyan

$existingRaw = & aws sesv2 get-email-identity --email-identity $Domain `
    --profile $AwsProfile --region $SesRegion --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    $existing = $existingRaw | ConvertFrom-Json
    $status   = if ($existing.VerifiedForSendingStatus) { 'Verified' } else { 'Verification pending' }
    Write-Host "  Identity '$Domain' already exists in $SesRegion." -ForegroundColor Yellow
    Write-Host "  Status: $status" -ForegroundColor $(if ($existing.VerifiedForSendingStatus) { 'Green' } else { 'Yellow' })
    Write-Host "  Skipping SES creation - proceeding to relay update." -ForegroundColor Yellow
    if (-not $existing.VerifiedForSendingStatus) {
        Write-Host "`n  NOTE: Identity not yet verified. DKIM records:" -ForegroundColor Yellow
        foreach ($token in $existing.DkimAttributes.Tokens) {
            Write-Host "    ${token}._domainkey.$Domain  CNAME  ${token}.dkim.amazonses.com" -ForegroundColor White
        }
    }
} else {
    Write-Host "  Identity '$Domain' not found. Creating..." -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess("SES $SesRegion", "Create identity for $Domain")) {
        $createResult = & aws sesv2 create-email-identity `
            --email-identity $Domain `
            --dkim-signing-attributes 'DomainSigningAttributesOrigin=AWS_SES,NextSigningKeyLength=RSA_2048_BIT' `
            --profile $AwsProfile --region $SesRegion --output json 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to create SES identity: $createResult" }
        $created = $createResult | ConvertFrom-Json
        Write-Host "  Identity created. Status: Verification pending" -ForegroundColor Green

        # Write DKIM records to CSV in Downloads folder
        $csvPath = "$env:USERPROFILE\Downloads\dkim-$Domain.csv"
        $dkimRows = $created.DkimAttributes.Tokens | ForEach-Object {
            [pscustomobject]@{
                Name  = "${_}._domainkey.$Domain"
                Type  = 'CNAME'
                Value = "${_}.dkim.amazonses.com"
            }
        }
        $dkimRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "`n  DKIM CSV saved to: $csvPath" -ForegroundColor Green

        Write-Host "`n  DKIM records to send to customer:" -ForegroundColor Cyan
        Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
        foreach ($token in $created.DkimAttributes.Tokens) {
            Write-Host "  Name:  ${token}._domainkey.$Domain" -ForegroundColor White
            Write-Host "  Type:  CNAME"                                   -ForegroundColor White
            Write-Host "  Value: ${token}.dkim.amazonses.com"             -ForegroundColor White
            Write-Host ""
        }
        Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  Once DNS records are added, identity will show Verified." -ForegroundColor Yellow
    }
}

# ── Step 2: Postfix relay_domains on both relays ────────────────────────────────
Write-Host "`n=== Step 2: Postfix relay_domains (both relays) ===" -ForegroundColor Cyan

foreach ($relay in $relays) {
    Write-Host "`n  Updating $($relay.Name)..." -ForegroundColor Cyan

    if (-not $PSCmdlet.ShouldProcess($relay.Name, "Add '$Domain' to relay_domains")) { continue }

    # Build the SSM PowerShell script with relay region hardcoded — avoids IMDS lookup
    $relayRegion = $relay.Region
    $ssmLines = @(
        '$ErrorActionPreference = "Stop"'
        "Import-Module AWS.Tools.SimpleSystemsManagement -ErrorAction Stop"
        ''
        "# Retrieve credentials from SSM Parameter Store (region: $relayRegion)"
        "`$wslPass  = (Get-SSMParameterValue -Name '$SsmWslRelay'  -WithDecryption `$true -Region '$relayRegion').Parameters[0].Value"
        "`$sudoPass = (Get-SSMParameterValue -Name '$SsmRelayAdmin' -WithDecryption `$true -Region '$relayRegion').Parameters[0].Value"
        'if ([string]::IsNullOrEmpty($wslPass))  { throw "Failed to get svc-wsl-relay password" }'
        'if ([string]::IsNullOrEmpty($sudoPass)) { throw "Failed to get relayadmin password" }'
        ''
        "`$secPass    = ConvertTo-SecureString `$wslPass -AsPlainText -Force"
        "`$credential = New-Object System.Management.Automation.PSCredential(`"$WslUser`", `$secPass)"
        ''
        '# Write Python script that inserts domain into Government section alphabetically'
        '$py = @"'
        'import sys'
        "domain = '$Domain'"
        "filepath = '/etc/postfix/relay_domains'"
        "section_header = '# Government / municipal customers'"
        'with open(filepath, "r") as f:'
        '    lines = f.readlines()'
        'import re'
        'for line in lines:'
        '    s = line.strip()'
        '    if s and not s.startswith("#") and re.split(r"\s+", s)[0] == domain:'
        '        print("ALREADY_PRESENT")'
        '        sys.exit(0)'
        'in_gov = False'
        'header_lines_seen = 0'
        'insert_at = None'
        'new_entry = "{:<30} OK\n".format(domain)'
        'for i, line in enumerate(lines):'
        '    if section_header in line:'
        '        in_gov = True'
        '        header_lines_seen = 1'
        '        continue'
        '    if in_gov:'
        '        s = line.strip()'
        '        # Skip comment lines that are part of the section header block (e.g. closing dashes line)'
        '        if header_lines_seen < 2 and s.startswith("#"):'
        '            header_lines_seen += 1'
        '            continue'
        '        # Hit a new section — insert before it'
        '        if s.startswith("#") and section_header not in s:'
        '            insert_at = i'
        '            break'
        '        if not s:'
        '            continue'
        '        if domain < s.split()[0] and insert_at is None:'
        '            insert_at = i'
        '            break'
        'if insert_at is None:'
        '    for i in range(len(lines)-1,-1,-1):'
        '        if lines[i].strip() and not lines[i].strip().startswith("#"):'
        '            insert_at = i + 1'
        '            break'
        'if insert_at is None:'
        '    print("ERROR: no insert position found"); sys.exit(1)'
        'lines.insert(insert_at, new_entry)'
        'with open(filepath + ".tmp", "w") as f:'
        '    f.writelines(lines)'
        'print("INSERTED")'
        '"@'
        '[System.IO.File]::WriteAllText("C:\Windows\Temp\relay_insert.py", $py, (New-Object System.Text.UTF8Encoding $false))'
        ''
        '# Execute as svc-wsl-relay via WinRM loopback PSSession'
        '# Run python directly and apply postfix changes inline — avoids bash wrapper output capture issues'
        '$so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck'
        '$session = New-PSSession -ComputerName localhost -Credential $credential -SessionOption $so -ErrorAction Stop'
        'try {'
        '    $result = Invoke-Command -Session $session -ScriptBlock {'
        '        param($sp)'
        '        # Write sudo password to a temp file to avoid special char expansion in bash'
        '        $pwFile = "/mnt/c/Windows/Temp/relay_sudo.tmp"'
        '        [System.IO.File]::WriteAllText("C:\Windows\Temp\relay_sudo.tmp", ($sp + "`n"), (New-Object System.Text.UTF8Encoding $false))'
        '        # Step 1: Run python to check/insert'
        '        $pyOut = (wsl.exe -e bash -c "cat $pwFile | sudo -S python3 /mnt/c/Windows/Temp/relay_insert.py 2>/dev/null") -join "" | Out-String'
        '        $pyOut = $pyOut.Trim() -replace "`0",""'
        '        if ($pyOut -eq "ALREADY_PRESENT") { Remove-Item C:\Windows\Temp\relay_sudo.tmp -Force -ErrorAction SilentlyContinue; return "ALREADY_PRESENT" }'
        '        if ($pyOut -ne "INSERTED") { Remove-Item C:\Windows\Temp\relay_sudo.tmp -Force -ErrorAction SilentlyContinue; return "ERROR: python output: $pyOut" }'
        '        # Step 2: Apply changes'
        '        wsl.exe -e bash -c "cat $pwFile | sudo -S mv /etc/postfix/relay_domains.tmp /etc/postfix/relay_domains" 2>&1 | Out-Null'
        '        wsl.exe -e bash -c "cat $pwFile | sudo -S postmap /etc/postfix/relay_domains" 2>&1 | Out-Null'
        '        wsl.exe -e bash -c "cat $pwFile | sudo -S systemctl reload postfix" 2>&1 | Out-Null'
        '        # Step 3: Validate'
        '        $v = (wsl.exe -e bash -c "postmap -q ' + $Domain + ' hash:/etc/postfix/relay_domains 2>&1") -join "" | Out-String'
        '        Remove-Item C:\Windows\Temp\relay_sudo.tmp -Force -ErrorAction SilentlyContinue'
        '        return ("VALIDATE:" + ($v.Trim() -replace "`0",""))'
        '    } -ArgumentList $sudoPass'
        '    Write-Output ($result -join "")'
        '} finally {'
        '    Remove-PSSession $session -ErrorAction SilentlyContinue'
        '}'
    )
    $ssmScript = $ssmLines -join "`n"

    $paramsJson = ConvertTo-Json @{ commands = @($ssmScript) } -Compress

    $cmdId = (& aws ssm send-command `
        --instance-ids $relay.InstanceId `
        --document-name 'AWS-RunPowerShellScript' `
        --parameters $paramsJson `
        --comment "smtp-add-client: $Domain" `
        --profile $AwsProfile `
        --region $relay.Region `
        --query 'Command.CommandId' `
        --output text 2>&1)

    if ($LASTEXITCODE -ne 0) { throw "Failed to send SSM command to $($relay.Name): $cmdId" }
    Write-Host "  Command sent ($cmdId). Polling..." -ForegroundColor DarkGray

    $timeout = 90
    $elapsed = 0
    do {
        Start-Sleep -Seconds 5
        $elapsed += 5
        $inv = & aws ssm get-command-invocation `
            --command-id $cmdId `
            --instance-id $relay.InstanceId `
            --profile $AwsProfile `
            --region $relay.Region `
            --output json 2>&1 | ConvertFrom-Json
    } while ($inv.Status -in @('Pending', 'InProgress') -and $elapsed -lt $timeout)

    if ($inv.Status -eq 'Success') {
        $out = $inv.StandardOutputContent.Trim()
        if ($out -match 'ALREADY_PRESENT') {
            Write-Host "  $($relay.Name): '$Domain' already in relay_domains - no change." -ForegroundColor Yellow
        } elseif ($out -match 'VALIDATE:OK') {
            Write-Host "  $($relay.Name): Added and validated OK." -ForegroundColor Green
        } else {
            Write-Host "  $($relay.Name): Output: $out" -ForegroundColor Yellow
        }
        if ($inv.StandardErrorContent.Trim()) {
            Write-Warning "  $($relay.Name) stderr: $($inv.StandardErrorContent.Trim())"
        }
    } elseif ($inv.Status -eq 'TimedOut') {
        Write-Error "  $($relay.Name): SSM command timed out after ${timeout}s."
    } else {
        Write-Error "  $($relay.Name): SSM command failed (Status: $($inv.Status)).`n  Error: $($inv.StandardErrorContent)"
    }
}

Write-Host "`n=== Complete ===" -ForegroundColor Green
Write-Host "  Domain '$Domain' processed." -ForegroundColor Green
