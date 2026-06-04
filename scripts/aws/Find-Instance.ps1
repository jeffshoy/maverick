#Requires -Version 7.0

<#
.SYNOPSIS
    Find a running EC2 instance by Name tag across priority regions.
.DESCRIPTION
    Searches us-east-1, us-west-2, and ca-central-1 (in that order) for a running EC2
    instance whose Name tag matches the given server name. Stops at the first region
    with a hit. If the exact name returns nothing, fetches all running instances and filters
    client-side with a case-insensitive comparison — the only reliable way to match any tag
    casing (ALL-CAPS, all-lowercase, or mixed) since AWS tag filters are always case-sensitive.

    All regions are queried in parallel (wall-clock = slowest single call, not sum).

    AWS CLI errors (expired token, missing profile, AccessDenied) are surfaced
    immediately and cause a non-zero exit — never silently swallowed.

    Returns one or more PSCustomObjects: InstanceId, Name, Region, State, Az.
.PARAMETER ServerName
    EC2 Name tag value to search for (e.g. CLD-PPLSAPM001).
.PARAMETER Profile
    AWS CLI profile name from ~/.aws/config.
.PARAMETER Regions
    Ordered list of regions to search. Defaults to the team priority list:
    us-east-1, us-west-2, ca-central-1.
.EXAMPLE
    Find-Instance.ps1 -ServerName CLD-PPLSAPM001 -Profile PALegacyPlus
.EXAMPLE
    Find-Instance.ps1 -ServerName ARCT-PTRKRD001 -Profile PALegacySharedServices -Regions us-east-1
.NOTES
    Returns all matches if multiple instances share the same Name tag (e.g. blue/green
    pairs). Callers are responsible for disambiguating when Count > 1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ServerName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Profile,

    [string[]] $Regions = @('us-east-1', 'us-west-2', 'ca-central-1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Region scan — all regions in parallel (PS7 required; see #Requires above)
# ---------------------------------------------------------------------------
$parallelResults = $Regions | ForEach-Object -Parallel {
    # Re-define helpers inside the parallel runspace
    function Invoke-DescribeInstances {
        param([string]$Name, [string]$Profile, [string]$Region)
        $outputArr = aws ec2 describe-instances `
            --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=$Name" `
            --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name'].Value|[0],State.Name,Placement.AvailabilityZone]" `
            --output text `
            --profile $Profile --region $Region 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "AWS CLI error (profile=$Profile, region=$Region): $($outputArr -join ' ')"
        }
        return [string]($outputArr | Out-String)
    }

    function Parse-InstanceRows {
        param([string]$Raw, [string]$Region)
        if (-not $Raw -or -not $Raw.Trim()) { return @() }
        return $Raw.Trim() -split "`n" | Where-Object { $_ } | ForEach-Object {
            $cols = $_ -split "`t"
            [PSCustomObject]@{
                InstanceId = $cols[0].Trim()
                Name       = $cols[1].Trim()
                State      = $cols[2].Trim()
                Az         = $cols[3].Trim()
                Region     = $Region
            }
        }
    }

    $region = $_
    $profile = $using:Profile
    $serverName = $using:ServerName

    try {
        $raw = [string](Invoke-DescribeInstances -Name $serverName -Profile $profile -Region $region | Out-String)
        if ($raw -and $raw.Trim()) {
            return [PSCustomObject]@{ Region = $region; Results = @(Parse-InstanceRows -Raw $raw -Region $region) }
        }

        $allRawArr = aws ec2 describe-instances `
            --filters "Name=instance-state-name,Values=running" `
            --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name'].Value|[0],State.Name,Placement.AvailabilityZone]" `
            --output text `
            --profile $profile --region $region 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "AWS CLI error (profile=$profile, region=$region): $($allRawArr -join ' ')"
        }

        # Join array to string — aws 2>&1 returns [string[]] in PS7
        $allRaw = [string]($allRawArr | Out-String)
        $searchLower = $serverName.ToLower()
        $filtered = ($allRaw.Trim() -split "`n") |
            Where-Object { $_ } |
            Where-Object {
                $cols = $_ -split "`t"
                $cols.Count -ge 2 -and $cols[1].Trim().ToLower() -eq $searchLower
            } |
            Out-String

        $hits = @(Parse-InstanceRows -Raw ([string]$filtered) -Region $region)
        return [PSCustomObject]@{ Region = $region; Results = $hits }
    } catch {
        # Surface error from parallel thread
        return [PSCustomObject]@{ Region = $region; Results = @(); Error = $_.Exception.Message }
    }
} -ThrottleLimit 3

# Check for errors from parallel threads (use PSObject.Properties — strict mode safe)
$errors = @($parallelResults | Where-Object { $_.PSObject.Properties['Error'] -and $_.PSObject.Properties['Error'].Value })
if ($errors) {
    Write-Host ""
    Write-Error $errors[0].PSObject.Properties['Error'].Value
    exit 1
}

# Return results in region-priority order (first region with hits wins)
foreach ($region in $Regions) {
    $regionResult = $parallelResults | Where-Object { $_.Region -eq $region }
    if ($regionResult -and @($regionResult.Results).Count -gt 0) {
        return $regionResult.Results
    }
}

Write-Error "Instance '$ServerName' not found in any of: $($Regions -join ', '). Verify the Name tag, account, and instance state."
exit 1
