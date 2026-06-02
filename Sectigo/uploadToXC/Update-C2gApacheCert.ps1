#Requires -Version 5.1

<#
.SYNOPSIS
    Renew Apache TLS certificates on c2g* EC2 instances in PALegacyCzp via SSM Run Command.
.DESCRIPTION
    Discovers running EC2 instances matching a Name-tag filter across one or more regions,
    verifies SSM agent reachability, creates a temporary S3 bucket per region, uploads the
    cert files, generates 15-minute pre-signed URLs, then sends a PowerShell payload via
    SSM Run Command that:
      - Backs up D:\Apache24\conf to conf_<year> (idempotent)
      - Backs up the Java cacerts file (idempotent)
      - Downloads the new cert/key/intermediate/root/cacerts via the pre-signed URLs
      - Rewrites httpd.conf and httpd-custom.conf using idempotent regex (safe to re-run)
      - Optionally restarts Apache (-RestartApache)

    Temp S3 buckets are created with public-access blocking and deleted in a finally block
    regardless of outcome. Cert filenames are operator-supplied at run time with no hardcoded
    defaults, because the 180-day renewal cycle uses evolving suffixes (e.g. 2026pt2).

    BLAST RADIUS: All C2GWB* instances in us-east-1 and us-west-2 in PALegacyCzp.
    Always run with -WhatIf first to review the target list before committing.

    Prerequisites: AWS CLI v2 in PATH; active SSO session for the target profile.
.PARAMETER AwsProfile
    AWS profile name from ~/.aws/config. Default: PALegacyCzp.
.PARAMETER Regions
    One or more AWS regions to target. Default: us-east-1 and us-west-2.
.PARAMETER NameTagFilter
    EC2 Name-tag wildcard filter for instance discovery. Default: *C2GWB* (case-sensitive, matches AWS tag values).
.PARAMETER CertSourceDir
    Local directory containing all cert/key files to upload. Required.
.PARAMETER CertFile
    Filename of the leaf certificate (.crt). Required, no default.
    Example: star_aspgov_com_2026pt2.crt
.PARAMETER KeyFile
    Filename of the unencrypted private key (.key). Required, no default.
    Example: star_aspgov_com_2026pt2-decrypted.key
.PARAMETER Intermediate
    Filename of the Sectigo intermediate certificate (.crt). Required, no default.
    Example: Sectigo_intermediate.crt
.PARAMETER TrustedRoot
    Filename of the Sectigo trusted root certificate (.crt). Required, no default.
    Example: Sectigo_CA_root.crt
.PARAMETER CaCerts
    Filename of the Java cacerts bundle. Default: cacerts.
.PARAMETER ApacheConfDir
    Target Apache conf directory on the remote instances. Default: D:\Apache24\conf.
.PARAMETER JavaSecurityDir
    Target Java security directory on the remote instances.
    Default: C:\Program Files\Java\jdk1.8.0_181\jre\lib\security.
.PARAMETER PreSignedUrlMinutes
    TTL for S3 pre-signed download URLs. Default: 15 minutes.
.PARAMETER SsmTimeoutSeconds
    Per-instance SSM command timeout. Default: 600 seconds (10 min).
.PARAMETER RestartApache
    When specified, restarts the Apache service on each instance after cert swap.
    Off by default; operators typically prefer to restart server-by-server and
    verify the cert before continuing to the next host.
.PARAMETER RestartApacheOnly
    Skip cert delivery entirely and only restart the Apache service on each
    instance. Use this after a cert-only run to apply the new cert at a
    controlled time (e.g. after hours). Does not require -CertFile etc.
.EXAMPLE
    # Restart Apache fleet-wide after hours (no cert delivery)
    .\Update-C2gApacheCert.ps1 -RestartApacheOnly
.EXAMPLE
    # Dry-run (shows targets, no changes)
    .\Update-C2gApacheCert.ps1 `
        -CertSourceDir 'C:\temp\ASPGOV_Cert_Renewal\2026pt2\CertFiles' `
        -CertFile      'star_aspgov_com_2026pt2.crt' `
        -KeyFile       'star_aspgov_com_2026pt2-decrypted.key' `
        -Intermediate  'Sectigo_intermediate.crt' `
        -TrustedRoot   'Sectigo_CA_root.crt' `
        -WhatIf
.EXAMPLE
    # Single-host smoke test in one region
    .\Update-C2gApacheCert.ps1 `
        -CertSourceDir 'C:\temp\ASPGOV_Cert_Renewal\2026pt2\CertFiles' `
        -CertFile      'star_aspgov_com_2026pt2.crt' `
        -KeyFile       'star_aspgov_com_2026pt2-decrypted.key' `
        -Intermediate  'Sectigo_intermediate.crt' `
        -TrustedRoot   'Sectigo_CA_root.crt' `
        -NameTagFilter 'WINH-PC2GWB001' `
        -Regions       'us-east-1'
.EXAMPLE
    # Full fleet renewal with optional Apache restart
    .\Update-C2gApacheCert.ps1 `
        -CertSourceDir 'C:\temp\ASPGOV_Cert_Renewal\2026pt2\CertFiles' `
        -CertFile      'star_aspgov_com_2026pt2.crt' `
        -KeyFile       'star_aspgov_com_2026pt2-decrypted.key' `
        -Intermediate  'Sectigo_intermediate.crt' `
        -TrustedRoot   'Sectigo_CA_root.crt' `
        -RestartApache
.NOTES
    Author: ksloan
    Date:   2026-06-01
    Replaces the vSphere-based c2g-cert-update.ps1.
    Ticket: (add AzDo work item reference here)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]   $AwsProfile    = 'PALegacyCzp',

    [Parameter()]
    [string[]] $Regions       = @('us-east-1', 'us-west-2'),

    [Parameter()]
    [string]   $NameTagFilter = '*C2GWB*',

    # Cert params are not required when -RestartApacheOnly is used.
    # Validated manually after param binding so -RestartApacheOnly doesn't prompt.
    [Parameter()]
    [string] $CertSourceDir,

    [Parameter()]
    [string] $CertFile,

    [Parameter()]
    [string] $KeyFile,

    [Parameter()]
    [string] $Intermediate,

    [Parameter()]
    [string] $TrustedRoot,

    [Parameter()]
    [string] $CaCerts = 'cacerts',

    [Parameter()]
    [string] $ApacheConfDir   = 'D:\Apache24\conf',

    [Parameter()]
    [string] $JavaSecurityDir = 'C:\Program Files\Java\jdk1.8.0_181\jre\lib\security',

    [Parameter()]
    [int]    $PreSignedUrlMinutes = 15,

    [Parameter()]
    [int]    $SsmTimeoutSeconds   = 600,

    [Parameter()]
    [switch] $RestartApache,

    [Parameter()]
    [switch] $RestartApacheOnly
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

# Cert params are only required when doing a cert delivery run
if (-not $RestartApacheOnly) {
    foreach ($p in @('CertSourceDir','CertFile','KeyFile','Intermediate','TrustedRoot')) {
        if ([string]::IsNullOrWhiteSpace((Get-Variable $p).Value)) {
            throw “-$p is required unless -RestartApacheOnly is specified.”
        }
    }
    if (-not (Test-Path $CertSourceDir -PathType Container)) {
        throw “-CertSourceDir '$CertSourceDir' does not exist or is not a directory.”
    }
}

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Logging / transcript
# -WhatIf:$false ensures logging always runs regardless of WhatIf preference.
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$year     = (Get-Date).Year
$datetime = Get-Date -Format 'yyyyMMddHHmmss'
$logRoot  = Join-Path $env:TEMP "c2g-cert-update\$year\$datetime"
New-Item -ItemType Directory -Path $logRoot -Force -WhatIf:$false | Out-Null
Start-Transcript -Path (Join-Path $logRoot 'transcript.txt') -WhatIf:$false

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Update-C2gApacheCert.ps1' -ForegroundColor Cyan
Write-Host "  Run: $datetime  |  User: $env:USERNAME" -ForegroundColor Cyan
Write-Host "  Log: $logRoot" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# SSO preflight (pattern from Foundation\RDS-license-reset\connectto_foundation.ps1)
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Validate cert source files locally before touching any Invoke-Aws resource
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if (-not $RestartApacheOnly) {
    Write-Host ''
    Write-Host 'Validating cert source files...' -ForegroundColor Yellow

    $certFiles = @($CertFile, $KeyFile, $Intermediate, $TrustedRoot, $CaCerts)
    foreach ($f in $certFiles) {
        $path = Join-Path $CertSourceDir $f
        if (-not (Test-Path $path -PathType Leaf)) {
            Write-Error "Required file not found: $path"
            Stop-Transcript
            exit 1
        }
        Write-Verbose "  Found: $path"
    }

    $keyPath    = Join-Path $CertSourceDir $KeyFile
    $keyContent = Get-Content -Raw -Path $keyPath -ErrorAction Stop
    if ($keyContent -match 'ENCRYPTED') {
        Write-Error "Key file '$KeyFile' appears to be encrypted. Provide the unencrypted key."
        Stop-Transcript
        exit 1
    }

    Write-Host "  All $($certFiles.Count) files validated." -ForegroundColor Green
}

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# WhatIf banner
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if ($WhatIfPreference) {
    Write-Host ''
    Write-Host '[WhatIf] Dry-run mode - discovery and validation only. No Invoke-Aws changes will be made.' -ForegroundColor Yellow
    Write-Host "[WhatIf] CertFile     : $CertFile"
    Write-Host "[WhatIf] KeyFile      : $KeyFile"
    Write-Host "[WhatIf] Intermediate : $Intermediate"
    Write-Host "[WhatIf] TrustedRoot  : $TrustedRoot"
    Write-Host "[WhatIf] CaCerts      : $CaCerts"
    Write-Host "[WhatIf] ApacheConfDir: $ApacheConfDir"
    Write-Host '[WhatIf] Regex map    :'
    Write-Host '[WhatIf]   (c2gkeystore\.crt|star_aspgov_com_[\w]+\.crt)  ->  <CertFile>'
    Write-Host '[WhatIf]   (c2gkeystore\.key|star_aspgov_com_[\w]+-decrypted\.key)  ->  <KeyFile>'
    Write-Host '[WhatIf]   (DigiCertCA\.crt|Sectigo_intermediate\.crt)  ->  <Intermediate>'
    Write-Host '[WhatIf]   (DigicertTrustedRoot\.crt|Sectigo_CA_root\.crt)  ->  <TrustedRoot>'
    Write-Host ''
}

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Per-region loop
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$allResults   = [System.Collections.Generic.List[pscustomobject]]::new()
$anyDiscovery = $false

foreach ($Region in $Regions) {
    Write-Host ''
    Write-Host "=== Region: $Region ===" -ForegroundColor Cyan

    # â”€â”€ Discover instances â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
        Write-Warning "  No running instances found matching '$NameTagFilter' in $Region. Continuing to next region."
        continue
    }

    $anyDiscovery = $true
    Write-Host "  Found $($instances.Count) instance(s):" -ForegroundColor Green
    foreach ($i in $instances) {
        Write-Host "    $($i.InstanceId)  $($i.Name)"
    }

    # â”€â”€ Verify SSM agent reachability â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # The InstanceIds filter has a ~100-value limit, so we page all SSM-managed
    # instances in the region and intersect with our EC2 list locally.
    Write-Host '  Checking SSM agent status...' -ForegroundColor Yellow

    $onlineIds   = [System.Collections.Generic.HashSet[string]]::new()
    $nextToken   = $null
    $ssmPageFail = $false
    do {
        $pageArgs = @(
            'ssm', 'describe-instance-information',
            '--output', 'json',
            '--profile', $AwsProfile,
            '--region', $Region
        )
        if ($nextToken) { $pageArgs += @('--next-token', $nextToken) }

        $ssmRaw = Invoke-Aws @pageArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  SSM describe-instance-information failed in ${Region}: $ssmRaw"
            $ssmPageFail = $true
            break
        }
        $ssmPage = $ssmRaw | ConvertFrom-Json
        foreach ($info in $ssmPage.InstanceInformationList) {
            if ($info.PingStatus -eq 'Online') {
                $null = $onlineIds.Add($info.InstanceId)
            }
        }
        # NextToken is absent (not null) when there is no further page;
        # accessing a missing property throws under Set-StrictMode -Version Latest.
        $nextToken = if ($ssmPage.PSObject.Properties['NextToken']) { $ssmPage.NextToken } else { $null }
    } while ($nextToken)

    if ($ssmPageFail) { continue }

    $ssmReadyInstances = @($instances | Where-Object { $onlineIds -contains $_.InstanceId })
    $ssmOffline        = @($instances | Where-Object { $onlineIds -notcontains $_.InstanceId })

    foreach ($i in $ssmOffline) {
        Write-Warning "  SSM OFFLINE - skipping: $($i.InstanceId) ($($i.Name))"
        $allResults.Add([pscustomobject]@{
            Region        = $Region
            InstanceId    = $i.InstanceId
            Name          = $i.Name
            SsmStatus     = 'Offline'
            Backup        = 'n/a'
            Downloads     = 'n/a'
            ConfigChanges = 'n/a'
            ApacheRestart = 'n/a'
            Result        = 'skipped'
            Error         = 'SSM agent offline'
        })
    }

    if ($ssmReadyInstances.Count -eq 0) {
        Write-Warning "  No SSM-reachable instances in $Region. Skipping region."
        continue
    }

    Write-Host "  $($ssmReadyInstances.Count) instance(s) SSM-reachable." -ForegroundColor Green

    # â”€â”€ WhatIf: print targets and skip to next region â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host "[WhatIf] [$Region] Would update the following instance(s):" -ForegroundColor Yellow
        foreach ($i in $ssmReadyInstances) {
            Write-Host "[WhatIf]   $($i.InstanceId)  $($i.Name)"
        }
        foreach ($i in $ssmOffline) {
            Write-Host "[WhatIf]   $($i.InstanceId)  $($i.Name)  (SSM OFFLINE - would skip)" -ForegroundColor DarkGray
        }
        continue
    }

    # â”€â”€ RestartApacheOnly: skip cert delivery, just restart the service â”€â”€â”€â”€â”€
    if ($RestartApacheOnly) {
        $restartOnlyScript = @”
`$ErrorActionPreference = 'Stop'
`$apacheDir = `$null
foreach (`$candidate in @('D:\Apache24\conf', 'C:\Apache24\conf')) {
    if (Test-Path `$candidate) { `$apacheDir = `$candidate; break }
}
if (-not `$apacheDir) {
    Write-Warning -Message ('Apache not found on D:\ or C:\. Skipping.')
    `$status = [pscustomobject]@{ host = `$env:COMPUTERNAME; apacheRestart = 'n/a'; status = 'skipped-no-apache' }
    Write-Output ('__STATUS__:' + (`$status | ConvertTo-Json -Compress))
    exit 0
}
`$svc = Get-Service -Name 'Apache*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (`$svc) {
    Restart-Service -InputObject `$svc -Force -ErrorAction Stop
    Write-Output ('Apache service ' + `$svc.Name + ' restarted.')
    `$restart = 'restarted'
} else {
    Write-Warning -Message ('No Apache* service found. Skipping.')
    `$restart = 'service-not-found'
}
`$status = [pscustomobject]@{ host = `$env:COMPUTERNAME; apacheRestart = `$restart; status = 'success' }
Write-Output ('__STATUS__:' + (`$status | ConvertTo-Json -Compress))
“@
        foreach ($instance in $ssmReadyInstances) {
            Write-Host “  [$($instance.Name)] Restarting Apache...” -ForegroundColor Cyan
            $rowBase = [pscustomobject]@{
                Region        = $Region
                InstanceId    = $instance.InstanceId
                Name          = $instance.Name
                SsmStatus     = 'Sent'
                Backup        = 'n/a'
                Downloads     = 'n/a'
                ConfigChanges = 'n/a'
                ApacheRestart = ''
                Result        = ''
                Error         = ''
            }
            $p1 = $null
            try {
                $p1  = New-SsmParamsFile $restartOnlyScript
                $inv = Invoke-SsmCommand $instance.InstanceId $p1 “c2g apache restart $year $env:USERNAME”

                $hostLog = Join-Path $logRoot “$Region-$($instance.InstanceId)-$($instance.Name).txt”
                Set-Content -Path $hostLog -Value “=== STDOUT ===`n$($inv.StandardOutputContent)`n=== STDERR ===`n$($inv.StandardErrorContent)” -WhatIf:$false

                $statusLine = $inv.StandardOutputContent -split “`n” |
                    Where-Object { $_ -match '^__STATUS__:' } | Select-Object -Last 1
                $parsed = $null
                if ($statusLine) { $parsed = ($statusLine -replace '^__STATUS__:') | ConvertFrom-Json }

                if ($inv.StatusDetails -eq 'Success') {
                    if ($parsed -and $parsed.status -eq 'skipped-no-apache') {
                        $rowBase.SsmStatus = 'Success'; $rowBase.Result = 'skipped'
                        $rowBase.Error = 'Apache not found on D:\ or C:\'
                        Write-Warning “  [$($instance.Name)] SKIPPED - Apache not found”
                    } else {
                        $rowBase.SsmStatus    = 'Success'
                        $rowBase.Result       = 'success'
                        $rowBase.ApacheRestart = if ($parsed) { $parsed.apacheRestart } else { 'unknown' }
                        Write-Host “  [$($instance.Name)] SUCCESS” -ForegroundColor Green
                    }
                } else {
                    $rowBase.SsmStatus = $inv.StatusDetails; $rowBase.Result = 'failed'
                    $rowBase.Error     = “SSM status: $($inv.StatusDetails)”
                    Write-Warning “  [$($instance.Name)] FAILED - $($inv.StatusDetails)”
                    $se = $inv.StandardErrorContent
                    if ($se) { Write-Warning “  Stderr: $se” }
                }
            } catch {
                $rowBase.SsmStatus = 'Error'; $rowBase.Result = 'failed'
                $rowBase.Error = $_.Exception.Message
                Write-Warning “  [$($instance.Name)] ERROR - $($_.Exception.Message)”
            } finally {
                if ($p1 -and (Test-Path $p1)) { Remove-Item $p1 -Force -ErrorAction SilentlyContinue }
            }
            $allResults.Add($rowBase)
        }
        continue
    }

    # â”€â”€ GZip+base64 encode cert files â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # Instances have no outbound S3 access (SSM uses a VPC endpoint).
    # SSM hard limit is 97KB per command. cacerts compresses to ~33KB b64 on
    # its own, leaving ~60KB for the script — tight but sufficient for the main
    # command. cacerts is delivered in a separate first command to stay under the
    # limit, then the main command writes the 4 cert files and edits the config.
    Write-Host “  Encoding $($certFiles.Count) cert files for inline delivery...” -ForegroundColor Yellow

    $b64 = @{}
    foreach ($f in $certFiles) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $CertSourceDir $f))
        $ms    = [System.IO.MemoryStream]::new()
        $gz    = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
        $gz.Write($bytes, 0, $bytes.Length)
        $gz.Close()
        $b64[$f] = [Convert]::ToBase64String($ms.ToArray())
        Write-Verbose “  Encoded $f ($($bytes.Length) raw -> $($b64[$f].Length) b64)”
    }

    $certFilesSize   = ($b64[$CertFile].Length + $b64[$KeyFile].Length + $b64[$Intermediate].Length + $b64[$TrustedRoot].Length) / 1KB
    $caCertsSize     = $b64[$CaCerts].Length / 1KB
    Write-Host (“  Files encoded. Cert files: {0:N1} KB  cacerts: {1:N1} KB” -f $certFilesSize, $caCertsSize) -ForegroundColor Green

    try {
        $restartBlock = if ($RestartApache) {
            @'
$svc = Get-Service -Name 'Apache*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($svc) {
    Restart-Service -InputObject $svc -Force -ErrorAction Stop
    Write-Output “Apache service '$($svc.Name)' restarted.”
    $apacheRestart = 'restarted'
} else {
    Write-Warning “No service matching 'Apache*' found. Skipping restart.”
    $apacheRestart = 'not-found'
}
'@
        } else {
            [char]36 + “apacheRestart = 'skipped'”
        }

        # cacerts compresses to ~103KB b64, which exceeds the 97KB SSM hard limit
        # even alone. Split it into two halves (~52KB each) delivered in separate
        # commands, then concatenate on the instance before decompressing.
        $caCertsB64   = $b64[$CaCerts]
        $splitAt      = [int]($caCertsB64.Length / 2)
        $caCertsPart1 = $caCertsB64.Substring(0, $splitAt)
        $caCertsPart2 = $caCertsB64.Substring($splitAt)
        $caCertsTmp1  = 'C:\Windows\Temp\cacerts.gz.b64.p1'
        $caCertsTmp2  = 'C:\Windows\Temp\cacerts.gz.b64.p2'

        # Command 1: stage first half of cacerts
        $cmd1Script = @”
[System.IO.File]::WriteAllText('$caCertsTmp1', '$caCertsPart1')
Write-Output 'cacerts part 1 staged'
“@

        # Command 2: stage second half of cacerts
        $cmd2Script = @”
[System.IO.File]::WriteAllText('$caCertsTmp2', '$caCertsPart2')
Write-Output 'cacerts part 2 staged'
“@

        # Command 3: write 4 cert files inline, reconstruct cacerts from both staged
        # halves, do backups, config edits, then clean up temp files.
        $cmd3Script = @”
`$ErrorActionPreference = 'Stop'
`$year         = $year
`$apacheDirHint = '$($ApacheConfDir -replace “'”,”''”)'
`$javaSecDir   = '$($JavaSecurityDir -replace “'”,”''”)'
`$certFile     = '$($CertFile -replace “'”,”''”)'
`$keyFile      = '$($KeyFile -replace “'”,”''”)'
`$intermediate = '$($Intermediate -replace “'”,”''”)'
`$trustedRoot  = '$($TrustedRoot -replace “'”,”''”)'
`$caCerts      = '$($CaCerts -replace “'”,”''”)'
`$caCertsTmp1  = '$caCertsTmp1'
`$caCertsTmp2  = '$caCertsTmp2'

# Discover Apache conf dir: D:\Apache24\conf first, then C:\Apache24\conf
`$apacheDir = `$null
foreach (`$candidate in @('D:\Apache24\conf', 'C:\Apache24\conf')) {
    if (Test-Path `$candidate) { `$apacheDir = `$candidate; break }
}
if (-not `$apacheDir) {
    Write-Warning -Message ('Apache not found on D:\ or C:\. Skipping this server.')
    `$status = [pscustomobject]@{
        host = `$env:COMPUTERNAME; backup = 'n/a'; writes = 0
        configChanges = 0; apacheRestart = 'n/a'; status = 'skipped-no-apache'
    }
    Write-Output ('__STATUS__:' + (`$status | ConvertTo-Json -Compress))
    exit 0
}
Write-Output “Apache conf dir: `$apacheDir”

function Expand-GzB64 {
    param([string]`$b64, [string]`$dest)
    `$compressed = [Convert]::FromBase64String(`$b64)
    `$ms  = [System.IO.MemoryStream]::new(`$compressed)
    `$gz  = [System.IO.Compression.GZipStream]::new(`$ms, [System.IO.Compression.CompressionMode]::Decompress)
    `$out = [System.IO.MemoryStream]::new()
    `$gz.CopyTo(`$out); `$gz.Close()
    [System.IO.File]::WriteAllBytes(`$dest, `$out.ToArray())
}

# Backup Apache conf dir (idempotent)
`$backupDir = `$apacheDir + '_' + `$year
if (-not (Test-Path `$backupDir)) {
    Copy-Item -Recurse `$apacheDir `$backupDir -Force
    Write-Output “Backup created: `$backupDir”
    `$backup = 'created'
} else {
    Write-Output “Backup already exists: `$backupDir”
    `$backup = 'exists'
}

# Backup Java cacerts (idempotent)
`$caCertsBackup = Join-Path `$javaSecDir (`$caCerts + '_' + `$year)
if (-not (Test-Path `$caCertsBackup)) {
    Copy-Item (Join-Path `$javaSecDir `$caCerts) `$caCertsBackup -Force
    Write-Output “Backup created: `$caCertsBackup”
} else {
    Write-Output “Backup already exists: `$caCertsBackup”
}

# Write the 4 cert files from inline base64
`$certWrites = @(
    @{ B64 = '$($b64[$CertFile])';     Dest = (Join-Path `$apacheDir `$certFile)     },
    @{ B64 = '$($b64[$KeyFile])';      Dest = (Join-Path `$apacheDir `$keyFile)      },
    @{ B64 = '$($b64[$Intermediate])'; Dest = (Join-Path `$apacheDir `$intermediate) },
    @{ B64 = '$($b64[$TrustedRoot])';  Dest = (Join-Path `$apacheDir `$trustedRoot)  }
)
`$writeCount = 0
foreach (`$w in `$certWrites) {
    Expand-GzB64 `$w.B64 `$w.Dest
    Write-Output “Written: `$(`$w.Dest)”
    `$writeCount++
}

# Reconstruct cacerts by joining both staged halves from commands 1 and 2
if (-not (Test-Path `$caCertsTmp1)) { throw “Staged cacerts part 1 not found: `$caCertsTmp1” }
if (-not (Test-Path `$caCertsTmp2)) { throw “Staged cacerts part 2 not found: `$caCertsTmp2” }
`$caCertsB64 = [System.IO.File]::ReadAllText(`$caCertsTmp1) + [System.IO.File]::ReadAllText(`$caCertsTmp2)
Expand-GzB64 `$caCertsB64 (Join-Path `$javaSecDir `$caCerts)
Write-Output “Written: `$(Join-Path `$javaSecDir `$caCerts)”
`$writeCount++
Remove-Item `$caCertsTmp1, `$caCertsTmp2 -Force -ErrorAction SilentlyContinue

# Idempotent regex rewrite of httpd.conf and httpd-custom.conf
`$regexMap = @(
    @{ Pattern = '(c2gkeystore\.crt|star_aspgov_com_[\w]+\.crt)';           Replace = `$certFile      },
    @{ Pattern = '(c2gkeystore\.key|star_aspgov_com_[\w]+-decrypted\.key)'; Replace = `$keyFile       },
    @{ Pattern = '(DigiCertCA\.crt|Sectigo_intermediate\.crt)';             Replace = `$intermediate  },
    @{ Pattern = '(DigicertTrustedRoot\.crt|Sectigo_CA_root\.crt)';         Replace = `$trustedRoot   }
)
`$confFiles    = @('httpd.conf', 'httpd-custom.conf')
`$totalChanges = 0
foreach (`$confFile in `$confFiles) {
    `$confPath = Join-Path `$apacheDir `$confFile
    if (-not (Test-Path `$confPath -PathType Leaf)) {
        Write-Warning -Message ('Not found, skipping: ' + `$confPath)
        continue
    }
    `$content     = Get-Content -Path `$confPath -Raw
    `$fileChanges = 0
    foreach (`$entry in `$regexMap) {
        `$newContent = `$content -replace `$entry.Pattern, `$entry.Replace
        if (`$newContent -ne `$content) { `$fileChanges++; `$content = `$newContent }
    }
    Set-Content -Path `$confPath -Value `$content -NoNewline
    Write-Output (`$confFile + ': ' + `$fileChanges + ' pattern(s) replaced.')
    `$totalChanges += `$fileChanges
}

# Optional Apache restart
$restartBlock

# Structured status line parsed by orchestrator
`$status = [pscustomobject]@{
    host = `$env:COMPUTERNAME; backup = `$backup; writes = `$writeCount
    configChanges = `$totalChanges; apacheRestart = `$apacheRestart; status = 'success'
}
Write-Output ('__STATUS__:' + (`$status | ConvertTo-Json -Compress))
“@

        # Helper: write a script string to a BOM-free ASCII JSON params file.
        # Builds the JSON with [char]34 for double-quotes so no editor can
        # silently swap them for curly/smart quotes.
        function New-SsmParamsFile {
            param([string]$Script)
            $q       = [char]34
            $escaped = $Script -replace '\\', '\\' -replace “$q”, “\$q” `
                               -replace “`r”, '\r'  -replace “`n”, '\n' `
                               -replace “`t”, '\t'
            $json    = “{${q}commands${q}:[${q}${escaped}${q}]}”
            $path    = [System.IO.Path]::GetTempFileName() + '.json'
            [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::ASCII.GetBytes($json))
            return $path
        }

        # Helper: send one SSM command and poll to completion; returns invocation object
        function Invoke-SsmCommand {
            param([string]$InstanceId, [string]$ParamsFile, [string]$Comment)
            $sendRaw = Invoke-Aws ssm send-command `
                --document-name 'AWS-RunPowerShellScript' `
                --instance-ids  $InstanceId `
                --parameters    “file://$ParamsFile” `
                --timeout-seconds $SsmTimeoutSeconds `
                --comment       $Comment `
                --output json `
                --profile $AwsProfile --region $Region
            if ($LASTEXITCODE -ne 0) { throw “send-command failed: $($sendRaw -join ' ')” }
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

        # â”€â”€ Send three SSM commands per instance â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        foreach ($instance in $ssmReadyInstances) {
            Write-Host “  [$($instance.Name)] Sending SSM commands (3)...” -ForegroundColor Cyan

            $rowBase = [pscustomobject]@{
                Region        = $Region
                InstanceId    = $instance.InstanceId
                Name          = $instance.Name
                SsmStatus     = 'Sent'
                Backup        = ''
                Downloads     = ''
                ConfigChanges = ''
                ApacheRestart = ''
                Result        = ''
                Error         = ''
            }

            $p1 = $null; $p2 = $null; $p3 = $null
            try {
                $p1 = New-SsmParamsFile $cmd1Script
                Write-Verbose “  [$($instance.Name)] Cmd 1: cacerts part 1...”
                $inv1 = Invoke-SsmCommand $instance.InstanceId $p1 “c2g cacerts p1 $year $env:USERNAME”
                if ($inv1.StatusDetails -ne 'Success') {
                    throw “Command 1 (cacerts p1) failed: $($inv1.StatusDetails)`n$($inv1.StandardErrorContent)”
                }

                $p2 = New-SsmParamsFile $cmd2Script
                Write-Verbose “  [$($instance.Name)] Cmd 2: cacerts part 2...”
                $inv2 = Invoke-SsmCommand $instance.InstanceId $p2 “c2g cacerts p2 $year $env:USERNAME”
                if ($inv2.StatusDetails -ne 'Success') {
                    throw “Command 2 (cacerts p2) failed: $($inv2.StatusDetails)`n$($inv2.StandardErrorContent)”
                }

                $p3   = New-SsmParamsFile $cmd3Script
                Write-Verbose “  [$($instance.Name)] Cmd 3: cert update...”
                $inv3 = Invoke-SsmCommand $instance.InstanceId $p3 “c2g cert update $year $env:USERNAME”

                $hostLog = Join-Path $logRoot “$Region-$($instance.InstanceId)-$($instance.Name).txt”
                $combined = “=== CMD1 STDOUT ===`n$($inv1.StandardOutputContent)`n” +
                            “=== CMD1 STDERR ===`n$($inv1.StandardErrorContent)`n” +
                            “=== CMD2 STDOUT ===`n$($inv2.StandardOutputContent)`n” +
                            “=== CMD2 STDERR ===`n$($inv2.StandardErrorContent)`n” +
                            “=== CMD3 STDOUT ===`n$($inv3.StandardOutputContent)`n” +
                            “=== CMD3 STDERR ===`n$($inv3.StandardErrorContent)”
                Set-Content -Path $hostLog -Value $combined -WhatIf:$false

                $statusLine = $inv3.StandardOutputContent -split “`n” |
                    Where-Object { $_ -match '^__STATUS__:' } | Select-Object -Last 1
                if ($statusLine) {
                    $parsed = ($statusLine -replace '^__STATUS__:') | ConvertFrom-Json
                    $rowBase.Backup        = $parsed.backup
                    $rowBase.Downloads     = $parsed.writes
                    $rowBase.ConfigChanges = $parsed.configChanges
                    $rowBase.ApacheRestart = $parsed.apacheRestart
                }

                if ($inv3.StatusDetails -eq 'Success') {
                    if ($parsed -and $parsed.status -eq 'skipped-no-apache') {
                        $rowBase.SsmStatus = 'Success'
                        $rowBase.Result    = 'skipped'
                        $rowBase.Error     = 'Apache not found on D:\ or C:\'
                        Write-Warning “  [$($instance.Name)] SKIPPED - Apache not found on D:\ or C:\”
                    } else {
                        $rowBase.SsmStatus = 'Success'
                        $rowBase.Result    = 'success'
                        Write-Host “  [$($instance.Name)] SUCCESS” -ForegroundColor Green
                    }
                } else {
                    $rowBase.SsmStatus = $inv3.StatusDetails
                    $rowBase.Result    = 'failed'
                    $rowBase.Error     = “SSM status: $($inv3.StatusDetails)”
                    Write-Warning “  [$($instance.Name)] FAILED - SSM status: $($inv3.StatusDetails)”
                    $stderr3 = $inv3.StandardErrorContent
                    if ($stderr3) { Write-Warning “  Stderr: $stderr3” }
                }
            } catch {
                $rowBase.SsmStatus = 'Error'
                $rowBase.Result    = 'failed'
                $rowBase.Error     = $_.Exception.Message
                Write-Warning “  [$($instance.Name)] ERROR - $($_.Exception.Message)”
            } finally {
                foreach ($p in @($p1, $p2, $p3)) {
                    if ($p -and (Test-Path $p)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
                }
            }

            $allResults.Add($rowBase)
        }

    } catch {
        Write-Warning "  Unexpected error in region ${Region}: $($_.Exception.Message)"
    }
}

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# WhatIf exit
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if ($WhatIfPreference) {
    Write-Host ''
    Write-Host '[WhatIf] No changes made.' -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Final summary
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if (-not $anyDiscovery) {
    Write-Error "No instances found matching '$NameTagFilter' in any region: $($Regions -join ', ')"
    Stop-Transcript
    exit 1
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  SUMMARY' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

$allResults | Format-Table Region, Name, InstanceId, Result, Backup, Downloads, ConfigChanges, ApacheRestart, Error -AutoSize

$csvPath = Join-Path $logRoot 'results.csv'
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -WhatIf:$false
Write-Host "Results saved to: $csvPath" -ForegroundColor Cyan

$failCount = @($allResults | Where-Object { $_.Result -ne 'success' }).Count
if ($failCount -gt 0) {
    Write-Host ''
    Write-Warning "$failCount instance(s) failed or were skipped. Review the summary and per-host logs in $logRoot"
    Stop-Transcript
    exit 1
}

Write-Host ''
Write-Host "All $($allResults.Count) instance(s) updated successfully." -ForegroundColor Green
Stop-Transcript
exit 0
