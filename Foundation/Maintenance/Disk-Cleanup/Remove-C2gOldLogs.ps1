#Requires -Version 5.1

<#
.SYNOPSIS
    Delete log files older than N days from c2g* EC2 instances in PALegacyCzp via SSM.
.DESCRIPTION
    Discovers running EC2 instances matching a Name-tag filter across one or more regions,
    verifies SSM agent reachability, then sends a PowerShell payload via SSM Run Command
    that removes files older than -RetentionDays from the following paths (each skipped
    gracefully if not present on the instance):

      - C:\inetpub\logs\LogFiles\W3SVC1
      - D:\Apache24\logs
      - D:\Click2GovLogs
      - D:\apache-tomcat\servers\c2g3Prod\logs

    BLAST RADIUS: All C2GWB* instances in us-east-1 and us-west-2 in PALegacyCzp.
    Always run with -WhatIf first to review the target list before committing.

    Prerequisites: AWS CLI v2 in PATH; active SSO session for the target profile.
.PARAMETER AwsProfile
    AWS profile name from ~/.aws/config. Default: PALegacyCzp.
.PARAMETER Regions
    One or more AWS regions to target. Default: us-east-1 and us-west-2.
.PARAMETER NameTagFilter
    EC2 Name-tag wildcard filter for instance discovery. Default: *C2GWB* (case-sensitive).
.PARAMETER RetentionDays
    Files last modified more than this many days ago will be deleted. Default: 30.
.PARAMETER SsmTimeoutSeconds
    Per-instance SSM command timeout. Default: 300 seconds (5 min).
.EXAMPLE
    # Dry-run (shows targets, no changes)
    .\Remove-C2gOldLogs.ps1 -WhatIf
.EXAMPLE
    # Single-server test
    .\Remove-C2gOldLogs.ps1 -NameTagFilter 'STPE-TC2GWB001' -Regions 'us-east-1' -WhatIf
.EXAMPLE
    # Full fleet with 60-day retention
    .\Remove-C2gOldLogs.ps1 -RetentionDays 60
.NOTES
    Author: ksloan
    Date:   2026-06-02
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]   $AwsProfile    = 'PALegacyCzp',

    [Parameter()]
    [string[]] $Regions       = @('us-east-1', 'us-west-2'),

    [Parameter()]
    [string]   $NameTagFilter = '*C2GWB*',

    [Parameter()]
    [int]      $RetentionDays = 30,

    [Parameter()]
    [int]      $SsmTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PS 5.1 converts native-executable stderr to error records, which $ErrorActionPreference='Stop'
# turns into terminating errors before $LASTEXITCODE can be checked. All AWS CLI calls go
# through this wrapper, which captures stderr silently and lets us test $LASTEXITCODE cleanly.
function Invoke-Aws {
    $output = & aws @args
    return $output
}

# Helper: write a script string to a BOM-free ASCII JSON params file.
# Builds the JSON with [char]34 so no editor can silently swap in curly quotes.
function New-SsmParamsFile {
    param([string]$Script)
    $q       = [char]34
    $escaped = $Script -replace '\\', '\\' -replace "$q", "\$q" `
                       -replace "`r", '\r'  -replace "`n", '\n' `
                       -replace "`t", '\t'
    $json    = "{${q}commands${q}:[${q}${escaped}${q}]}"
    $path    = [System.IO.Path]::GetTempFileName() + '.json'
    [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::ASCII.GetBytes($json))
    return $path
}

# Helper: send one SSM command and poll to completion; returns invocation object.
function Invoke-SsmCommand {
    param([string]$InstanceId, [string]$ParamsFile, [string]$Comment)
    $sendRaw = Invoke-Aws ssm send-command `
        --document-name 'AWS-RunPowerShellScript' `
        --instance-ids  $InstanceId `
        --parameters    "file://$ParamsFile" `
        --timeout-seconds $SsmTimeoutSeconds `
        --comment       $Comment `
        --output json `
        --profile $AwsProfile --region $Region
    if ($LASTEXITCODE -ne 0) { throw "send-command failed: $($sendRaw -join ' ')" }
    $commandId = ($sendRaw | ConvertFrom-Json).Command.CommandId
    $deadline  = (Get-Date).AddSeconds($SsmTimeoutSeconds + 60)
    $inv       = $null
    do {
        Start-Sleep -Seconds 5
        $raw = Invoke-Aws ssm get-command-invocation `
            --command-id  $commandId --instance-id $InstanceId `
            --output json --profile $AwsProfile --region $Region
        if ($LASTEXITCODE -eq 0) { $inv = $raw | ConvertFrom-Json }
    } while (
        (-not $inv -or $inv.StatusDetails -notin @('Success','Failed','TimedOut','Cancelled')) -and
        (Get-Date) -lt $deadline
    )
    if (-not $inv) { throw 'Timed out waiting for SSM command.' }
    return $inv
}

# ─────────────────────────────────────────────────────────────────────────────
# Logging / transcript
# ─────────────────────────────────────────────────────────────────────────────
$year     = (Get-Date).Year
$datetime = Get-Date -Format 'yyyyMMddHHmmss'
$logRoot  = Join-Path $env:TEMP "c2g-log-cleanup\$year\$datetime"
New-Item -ItemType Directory -Path $logRoot -Force -WhatIf:$false | Out-Null
Start-Transcript -Path (Join-Path $logRoot 'transcript.txt') -WhatIf:$false

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Remove-C2gOldLogs.ps1' -ForegroundColor Cyan
Write-Host "  Run: $datetime  |  User: $env:USERNAME  |  Retention: $RetentionDays days" -ForegroundColor Cyan
Write-Host "  Log: $logRoot" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# SSO preflight
# ─────────────────────────────────────────────────────────────────────────────
Write-Host 'Checking SSO session... ' -ForegroundColor Yellow -NoNewline
$null = Invoke-Aws sts get-caller-identity --profile $AwsProfile
if ($LASTEXITCODE -ne 0) {
    Write-Host 'expired' -ForegroundColor Red
    Write-Host 'Opening browser for SSO login...' -ForegroundColor Cyan
    Invoke-Aws sso login --sso-session foundation
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'SSO login failed. Aborting.'
        Stop-Transcript
        exit 1
    }
    Write-Host 'SSO login successful.' -ForegroundColor Green
} else {
    Write-Host 'active.' -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# Per-region loop
# ─────────────────────────────────────────────────────────────────────────────
$allResults   = [System.Collections.Generic.List[pscustomobject]]::new()
$anyDiscovery = $false

foreach ($Region in $Regions) {
    Write-Host ''
    Write-Host "=== Region: $Region ===" -ForegroundColor Cyan

    # ── Discover instances ───────────────────────────────────────────────────
    Write-Host "  Discovering instances matching '$NameTagFilter'..." -ForegroundColor Yellow

    $rawInstances = Invoke-Aws ec2 describe-instances `
        --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=$NameTagFilter" `
        --output text `
        --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name']|[0].Value]" `
        --profile $AwsProfile --region $Region

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  EC2 describe-instances failed in ${Region}: $rawInstances"
        continue
    }

    $instances = @()
    foreach ($line in ($rawInstances -split "`n" | Where-Object { $_ -match '\S' })) {
        $parts = $line -split '\t'
        if ($parts.Count -ge 2) {
            $instances += [pscustomobject]@{
                Region     = $Region
                InstanceId = $parts[0].Trim()
                Name       = $parts[1].Trim()
            }
        }
    }

    if ($instances.Count -eq 0) {
        Write-Warning "  No running instances found matching '$NameTagFilter' in $Region."
        continue
    }

    $anyDiscovery = $true
    Write-Host "  Found $($instances.Count) instance(s)." -ForegroundColor Green

    # ── Verify SSM agent reachability ────────────────────────────────────────
    Write-Host '  Checking SSM agent status...' -ForegroundColor Yellow

    $onlineIds   = [System.Collections.Generic.HashSet[string]]::new()
    $nextToken   = $null
    $ssmPageFail = $false
    do {
        $pageArgs = @('ssm','describe-instance-information','--output','json','--profile',$AwsProfile,'--region',$Region)
        if ($nextToken) { $pageArgs += @('--next-token', $nextToken) }
        $ssmRaw = Invoke-Aws @pageArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  SSM describe-instance-information failed in ${Region}: $ssmRaw"
            $ssmPageFail = $true; break
        }
        $ssmPage = $ssmRaw | ConvertFrom-Json
        foreach ($info in $ssmPage.InstanceInformationList) {
            if ($info.PingStatus -eq 'Online') { $null = $onlineIds.Add($info.InstanceId) }
        }
        $nextToken = if ($ssmPage.PSObject.Properties['NextToken']) { $ssmPage.NextToken } else { $null }
    } while ($nextToken)

    if ($ssmPageFail) { continue }

    $ssmReadyInstances = @($instances | Where-Object { $onlineIds -contains $_.InstanceId })
    $ssmOffline        = @($instances | Where-Object { $onlineIds -notcontains $_.InstanceId })

    foreach ($i in $ssmOffline) {
        Write-Warning "  SSM OFFLINE - skipping: $($i.InstanceId) ($($i.Name))"
        $allResults.Add([pscustomobject]@{
            Region       = $Region; InstanceId = $i.InstanceId; Name = $i.Name
            SsmStatus    = 'Offline'; FilesDeleted = 'n/a'; Result = 'skipped'
            Error        = 'SSM agent offline'
        })
    }

    if ($ssmReadyInstances.Count -eq 0) {
        Write-Warning "  No SSM-reachable instances in $Region."
        continue
    }

    Write-Host "  $($ssmReadyInstances.Count) instance(s) SSM-reachable." -ForegroundColor Green

    # ── WhatIf: print targets and skip ───────────────────────────────────────
    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host "[WhatIf] [$Region] Would clean logs on:" -ForegroundColor Yellow
        foreach ($i in $ssmReadyInstances) {
            Write-Host "[WhatIf]   $($i.InstanceId)  $($i.Name)"
        }
        foreach ($i in $ssmOffline) {
            Write-Host "[WhatIf]   $($i.InstanceId)  $($i.Name)  (SSM OFFLINE - would skip)" -ForegroundColor DarkGray
        }
        continue
    }

    # ── Build payload ────────────────────────────────────────────────────────
    $payload = @"
`$ErrorActionPreference = 'Stop'
`$threshold = (Get-Date).AddDays(-$RetentionDays)
`$totalDeleted = 0

`$logPaths = @(
    'C:\inetpub\logs\LogFiles\W3SVC1',
    'D:\Apache24\logs',
    'D:\Click2GovLogs',
    'D:\apache-tomcat\servers\c2g3Prod\logs'
)

foreach (`$path in `$logPaths) {
    if (-not (Test-Path `$path -PathType Container)) {
        Write-Output ('SKIP (not found): ' + `$path)
        continue
    }
    `$old = Get-ChildItem `$path | Where-Object { `$_.LastWriteTime -lt `$threshold }
    if (`$old.Count -eq 0) {
        Write-Output ('SKIP (nothing old): ' + `$path)
        continue
    }
    `$old | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    `$totalDeleted += `$old.Count
    Write-Output ('DELETED ' + `$old.Count + ' file(s) from: ' + `$path)
}

`$status = [pscustomobject]@{ host = `$env:COMPUTERNAME; filesDeleted = `$totalDeleted; status = 'success' }
Write-Output ('__STATUS__:' + (`$status | ConvertTo-Json -Compress))
"@

    # ── Send SSM command per instance ────────────────────────────────────────
    foreach ($instance in $ssmReadyInstances) {
        Write-Host "  [$($instance.Name)] Cleaning logs..." -ForegroundColor Cyan

        $rowBase = [pscustomobject]@{
            Region       = $Region
            InstanceId   = $instance.InstanceId
            Name         = $instance.Name
            SsmStatus    = 'Sent'
            FilesDeleted = ''
            Result       = ''
            Error        = ''
        }

        $p = $null
        try {
            $p   = New-SsmParamsFile $payload
            $inv = Invoke-SsmCommand $instance.InstanceId $p "c2g log cleanup $year $env:USERNAME"

            $hostLog = Join-Path $logRoot "$Region-$($instance.InstanceId)-$($instance.Name).txt"
            Set-Content -Path $hostLog -Value "=== STDOUT ===`n$($inv.StandardOutputContent)`n=== STDERR ===`n$($inv.StandardErrorContent)" -WhatIf:$false

            $statusLine = $inv.StandardOutputContent -split "`n" |
                Where-Object { $_ -match '^__STATUS__:' } | Select-Object -Last 1
            if ($statusLine) {
                $parsed = ($statusLine -replace '^__STATUS__:') | ConvertFrom-Json
                $rowBase.FilesDeleted = $parsed.filesDeleted
            }

            if ($inv.StatusDetails -eq 'Success') {
                $rowBase.SsmStatus = 'Success'
                $rowBase.Result    = 'success'
                Write-Host "  [$($instance.Name)] SUCCESS - $($rowBase.FilesDeleted) file(s) deleted" -ForegroundColor Green
            } else {
                $rowBase.SsmStatus = $inv.StatusDetails
                $rowBase.Result    = 'failed'
                $rowBase.Error     = "SSM status: $($inv.StatusDetails)"
                Write-Warning "  [$($instance.Name)] FAILED - $($inv.StatusDetails)"
                $se = $inv.StandardErrorContent
                if ($se) { Write-Warning "  Stderr: $se" }
            }
        } catch {
            $rowBase.SsmStatus = 'Error'
            $rowBase.Result    = 'failed'
            $rowBase.Error     = $_.Exception.Message
            Write-Warning "  [$($instance.Name)] ERROR - $($_.Exception.Message)"
        } finally {
            if ($p -and (Test-Path $p)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        }

        $allResults.Add($rowBase)
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# WhatIf exit
# ─────────────────────────────────────────────────────────────────────────────
if ($WhatIfPreference) {
    Write-Host ''
    Write-Host '[WhatIf] No changes made.' -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────────────────────
if (-not $anyDiscovery) {
    Write-Error "No instances found matching '$NameTagFilter' in any region: $($Regions -join ', ')"
    Stop-Transcript
    exit 1
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  SUMMARY' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

$allResults | Format-Table Region, Name, InstanceId, Result, FilesDeleted, Error -AutoSize

$csvPath = Join-Path $logRoot 'results.csv'
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -WhatIf:$false
Write-Host "Results saved to: $csvPath" -ForegroundColor Cyan

$failCount = @($allResults | Where-Object { $_.Result -eq 'failed' }).Count
if ($failCount -gt 0) {
    Write-Host ''
    Write-Warning "$failCount instance(s) failed. Review per-host logs in $logRoot"
    Stop-Transcript
    exit 1
}

$totalFiles = ($allResults | Where-Object { $_.Result -eq 'success' } |
    Measure-Object -Property FilesDeleted -Sum).Sum
Write-Host ''
Write-Host "Done. $($allResults.Where({$_.Result -eq 'success'}).Count) instance(s) cleaned, $totalFiles total file(s) deleted." -ForegroundColor Green
Stop-Transcript
exit 0
