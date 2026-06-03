#Requires -Version 5.1

<#
.SYNOPSIS
    Find a running EC2 instance by Name tag across priority regions.
.DESCRIPTION
    Searches us-east-1, us-west-2, and ca-central-1 (in that order) for a running EC2
    instance whose Name tag matches the given server name. Stops at the first region
    with a hit. If the exact name returns nothing, fetches all running instances and filters
    client-side with a case-insensitive comparison — the only reliable way to match any tag
    casing (ALL-CAPS, all-lowercase, or mixed) since AWS tag filters are always case-sensitive.

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
# Inner lookup — one name, one region. Returns instance-id strings or $null.
# Exits non-zero and prints the AWS error if the CLI call itself fails.
# ---------------------------------------------------------------------------
function Invoke-DescribeInstances {
    param([string]$Name, [string]$Profile, [string]$Region)

    $output = aws ec2 describe-instances `
        --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=$Name" `
        --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name'].Value|[0],State.Name,Placement.AvailabilityZone]" `
        --output text `
        --profile $Profile --region $Region 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Error "AWS CLI error (profile=$Profile, region=$Region): $output"
        exit 1
    }

    return $output
}

# ---------------------------------------------------------------------------
# Search loop — exact fast-path, then fetch-all + case-insensitive local filter
# ---------------------------------------------------------------------------
foreach ($region in $Regions) {
    Write-Verbose "Searching $region for '$ServerName'..."

    # Phase 1: exact match — hits on the common case with a single API call
    $raw = Invoke-DescribeInstances -Name $ServerName -Profile $Profile -Region $region

    # Phase 2: AWS tag filters are case-sensitive and offer no case-insensitive option.
    # Fetch all running instances and filter client-side so any casing of the tag matches.
    if (-not $raw) {
        Write-Verbose "  Exact match missed; fetching all running instances for case-insensitive search..."
        $allRaw = aws ec2 describe-instances `
            --filters "Name=instance-state-name,Values=running" `
            --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name'].Value|[0],State.Name,Placement.AvailabilityZone]" `
            --output text `
            --profile $Profile --region $region 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Error "AWS CLI error (profile=$Profile, region=$region): $allRaw"
            exit 1
        }

        $searchLower = $ServerName.ToLower()
        $raw = ($allRaw.Trim() -split "`n") |
            Where-Object { $_ } |
            Where-Object { ($_ -split "`t")[1].Trim().ToLower() -eq $searchLower } |
            Out-String
    }

    if ($raw -and $raw.Trim()) {
        # Parse tab-separated rows from --output text
        $results = $raw.Trim() -split "`n" | Where-Object { $_ } | ForEach-Object {
            $cols = $_ -split "`t"
            [PSCustomObject]@{
                InstanceId = $cols[0].Trim()
                Name       = $cols[1].Trim()
                State      = $cols[2].Trim()
                Az         = $cols[3].Trim()
                Region     = $region
            }
        }
        return $results
    }
}

Write-Error "Instance '$ServerName' not found in any of: $($Regions -join ', '). Verify the Name tag, account, and instance state."
exit 1
