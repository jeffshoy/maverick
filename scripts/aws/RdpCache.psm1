#Requires -Version 7.0

<#
.SYNOPSIS
    Persistent server-name -> instance cache for Connect-RDP.ps1.
.DESCRIPTION
    Stores {InstanceId, Region, LastSeen} keyed by "<Profile>\<ServerName>" at
    $env:LOCALAPPDATA\cloudops\rdp-cache.json. Saves a full Find-Instance region
    scan (~1-3s) on repeat connections to the same server.

    Get-CachedInstance  — returns a PSCustomObject on hit, $null on miss/stale.
    Set-CachedInstance  — writes or updates an entry after a successful Find-Instance.
    Remove-CachedInstance — evicts a stale or invalid entry.

    TTL: 30 days. Entries older than that are treated as misses.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$_CachePath = Join-Path $env:LOCALAPPDATA 'cloudops\rdp-cache.json'
$_CacheTtlDays = 30

function _LoadCache {
    $dir = Split-Path $_CachePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $_CachePath)) { return @{} }
    try {
        $raw = Get-Content $_CachePath -Raw | ConvertFrom-Json
        # ConvertFrom-Json returns a PSCustomObject; convert to hashtable
        $ht = @{}
        $raw.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        return $ht
    } catch { return @{} }
}

function _SaveCache([hashtable]$cache) {
    $dir = Split-Path $_CachePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cache | ConvertTo-Json -Depth 3 | Set-Content $_CachePath -Encoding UTF8
}

function _CacheKey([string]$Profile, [string]$ServerName) {
    return "$Profile\$ServerName"
}

function Get-CachedInstance {
    <#
    .SYNOPSIS
        Look up a cached instance entry. Returns $null on miss, expired TTL, or
        if the instance is no longer running/matching (lazy verify via AWS CLI).
    .PARAMETER ServerName
        EC2 Name tag of the target server.
    .PARAMETER Profile
        AWS CLI profile name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ServerName,
        [Parameter(Mandatory)] [string] $Profile
    )

    $cache = _LoadCache
    $key   = _CacheKey $Profile $ServerName
    $entry = $cache[$key]

    if (-not $entry) { return $null }

    # TTL check
    try {
        $lastSeen = [datetime]::Parse($entry.LastSeen)
        if (([datetime]::UtcNow - $lastSeen).TotalDays -gt $_CacheTtlDays) {
            Write-Verbose "Cache entry for '$key' expired (>$_CacheTtlDays days old); evicting."
            Remove-CachedInstance -ServerName $ServerName -Profile $Profile
            return $null
        }
    } catch {
        Remove-CachedInstance -ServerName $ServerName -Profile $Profile
        return $null
    }

    # Lazy verify: confirm the instance is still running and tag still matches
    Write-Verbose "Cache hit for '$ServerName' ($($entry.InstanceId), $($entry.Region)). Verifying..."
    $verifyOut = aws ec2 describe-instances `
        --instance-ids $entry.InstanceId `
        --region $entry.Region `
        --profile $Profile `
        --query "Reservations[0].Instances[0].[InstanceId,Tags[?Key=='Name'].Value|[0],State.Name,Placement.AvailabilityZone]" `
        --output text 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "Cache verify failed (AWS error); evicting entry."
        Remove-CachedInstance -ServerName $ServerName -Profile $Profile
        return $null
    }

    if (-not $verifyOut -or -not $verifyOut.Trim()) {
        Write-Verbose "Instance $($entry.InstanceId) not found; evicting cache entry."
        Remove-CachedInstance -ServerName $ServerName -Profile $Profile
        return $null
    }

    $cols = $verifyOut.Trim() -split "`t"
    $instanceId = $cols[0].Trim()
    $tagName    = if ($cols.Count -ge 2) { $cols[1].Trim() } else { '' }
    $state      = if ($cols.Count -ge 3) { $cols[2].Trim() } else { '' }
    $az         = if ($cols.Count -ge 4) { $cols[3].Trim() } else { '' }

    if ($state -ne 'running') {
        Write-Verbose "Instance $instanceId is '$state', not running; evicting cache entry."
        Remove-CachedInstance -ServerName $ServerName -Profile $Profile
        return $null
    }

    if ($tagName.ToLower() -ne $ServerName.ToLower()) {
        Write-Verbose "Name tag mismatch ('$tagName' vs '$ServerName'); evicting cache entry."
        Remove-CachedInstance -ServerName $ServerName -Profile $Profile
        return $null
    }

    return [PSCustomObject]@{
        InstanceId = $instanceId
        Name       = $tagName
        State      = $state
        Az         = $az
        Region     = $entry.Region
    }
}

function Set-CachedInstance {
    <#
    .SYNOPSIS
        Store or refresh a cache entry after a successful instance lookup.
    .PARAMETER ServerName
        EC2 Name tag of the target server.
    .PARAMETER Profile
        AWS CLI profile name.
    .PARAMETER InstanceId
        EC2 instance ID.
    .PARAMETER Region
        AWS region the instance was found in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ServerName,
        [Parameter(Mandatory)] [string] $Profile,
        [Parameter(Mandatory)] [string] $InstanceId,
        [Parameter(Mandatory)] [string] $Region
    )

    $cache = _LoadCache
    $key   = _CacheKey $Profile $ServerName
    $cache[$key] = [ordered]@{
        InstanceId = $InstanceId
        Region     = $Region
        LastSeen   = ([datetime]::UtcNow).ToString('o')
    }
    _SaveCache $cache
}

function Remove-CachedInstance {
    <#
    .SYNOPSIS
        Evict a stale or invalid entry from the cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ServerName,
        [Parameter(Mandatory)] [string] $Profile
    )

    $cache = _LoadCache
    $key   = _CacheKey $Profile $ServerName
    if ($cache.ContainsKey($key)) {
        $cache.Remove($key)
        _SaveCache $cache
    }
}

Export-ModuleMember -Function Get-CachedInstance, Set-CachedInstance, Remove-CachedInstance
