#requires -version 7.0
<#
.SYNOPSIS
    Version Tracker Module for AWS Management Studio

.DESCRIPTION
    Tracks application version changes and triggers appropriate automated tests
#>

Set-StrictMode -Version Latest

function Get-CachedVersion {
    <#
    .SYNOPSIS
        Get the cached version from settings
    #>
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $versionFile = Join-Path $settingsDir 'version-cache.json'
    
    if (Test-Path $versionFile) {
        try {
            $versionData = Get-Content $versionFile -Raw | ConvertFrom-Json
            return $versionData
        } catch {
            return $null
        }
    }
    return $null
}

function Set-CachedVersion {
    <#
    .SYNOPSIS
        Cache the current version
    #>
    param([string]$Version)
    
    $versionData = @{
        Version = $Version
        LastUpdated = Get-Date
        TestsRun = @()
    }
    
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }
    $versionFile = Join-Path $settingsDir 'version-cache.json'
    $versionData | ConvertTo-Json -Depth 3 | Set-Content $versionFile -Encoding UTF8
}

function Get-VersionChangeType {
    <#
    .SYNOPSIS
        Determine the type of version change
    #>
    param([string]$OldVersion, [string]$NewVersion)
    
    if (-not $OldVersion) { return "Initial" }
    
    $old = [version]$OldVersion
    $new = [version]$NewVersion
    
    if ($new.Major -gt $old.Major) { return "Major" }
    if ($new.Minor -gt $old.Minor) { return "Feature" }
    if ($new.Build -gt $old.Build) { return "BugFix" }
    
    return "None"
}

function Start-AutomaticVersionTest {
    <#
    .SYNOPSIS
        Start appropriate test based on version change type
    #>
    param([string]$ChangeType, [string]$NewVersion)
    
    Write-Host "🔄 Version change detected ($ChangeType): Running automatic tests..." -ForegroundColor Cyan
    
    switch ($ChangeType) {
        "Major" {
            Write-Host "🧪 Major version change - Running comprehensive tests..." -ForegroundColor Yellow
            Start-ComprehensiveTest -ShowProgress
        }
        "Feature" {
            Write-Host "🧪 Feature version change - Running comprehensive tests..." -ForegroundColor Yellow
            Start-ComprehensiveTest -ShowProgress
        }
        "BugFix" {
            Write-Host "🧪 Bug fix version change - Running quick tests..." -ForegroundColor Green
            Start-QuickTest -ShowProgress
        }
        "Initial" {
            Write-Host "🧪 Initial version - Running quick tests..." -ForegroundColor Blue
            Start-QuickTest -ShowProgress
        }
    }
    
    # Update cached version after successful test
    Set-CachedVersion -Version $NewVersion
    Write-Host "✅ Automatic testing completed for version $NewVersion" -ForegroundColor Green
}

function Test-VersionChange {
    <#
    .SYNOPSIS
        Check if version has changed and trigger appropriate tests
    #>
    param([string]$CurrentVersion)
    
    $cachedData = Get-CachedVersion
    $cachedVersion = if ($cachedData) { $cachedData.Version } else { $null }
    
    if ($cachedVersion -ne $CurrentVersion) {
        $changeType = Get-VersionChangeType -OldVersion $cachedVersion -NewVersion $CurrentVersion
        
        if ($changeType -ne "None") {
            Start-AutomaticVersionTest -ChangeType $changeType -NewVersion $CurrentVersion
            return $true
        }
    }
    
    return $false
}

Export-ModuleMember -Function Test-VersionChange, Get-CachedVersion, Set-CachedVersion