#requires -version 7.0
<#
.SYNOPSIS
    Azure DevOps Integration Module for AWS Management Studio

.VERSION
    1.0.0 (AzDo Repository Integration)

.DOCUMENTATION
    Provides enterprise distribution capabilities via Azure DevOps repository
    - Auto-update detection via AzDo REST API
    - Secure download with corporate authentication
    - Version comparison and release management
    - SMB share fallback when AzDo unavailable
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module variables
$script:AzDoConfig = @{
    Organization = ""
    Project = ""
    Repository = ""
    BaseUrl = ""
    PersonalAccessToken = ""
    SMBFallbackPath = ""
}

$script:CurrentVersion = "6.2.5"

#region AzDo Configuration Functions

function Set-AzDoConfiguration {
    <#
    .SYNOPSIS
        Configure Azure DevOps repository settings
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Organization,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Project,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Repository,
        
        [string]$PersonalAccessToken,
        
        [string]$SMBFallbackPath
    )
    
    $script:AzDoConfig.Organization = $Organization
    $script:AzDoConfig.Project = $Project
    $script:AzDoConfig.Repository = $Repository
    $script:AzDoConfig.BaseUrl = "https://dev.azure.com/$Organization/$Project/_apis"
    $script:AzDoConfig.PersonalAccessToken = $PersonalAccessToken
    $script:AzDoConfig.SMBFallbackPath = $SMBFallbackPath
    
    Write-Verbose "AzDo configuration updated for $Organization/$Project/$Repository"
}

function Get-AzDoConfiguration {
    <#
    .SYNOPSIS
        Get current Azure DevOps configuration
    #>
    return $script:AzDoConfig.Clone()
}

#endregion

#region Version Management Functions

function Get-CurrentVersion {
    <#
    .SYNOPSIS
        Get current application version
    #>
    return $script:CurrentVersion
}

function Set-CurrentVersion {
    <#
    .SYNOPSIS
        Set current application version
    #>
    param([Parameter(Mandatory)][string]$Version)
    $script:CurrentVersion = $Version
}

function Compare-Versions {
    <#
    .SYNOPSIS
        Compare two semantic versions
    #>
    param(
        [Parameter(Mandatory)][string]$Version1,
        [Parameter(Mandatory)][string]$Version2
    )
    
    try {
        $v1 = [System.Version]::Parse($Version1)
        $v2 = [System.Version]::Parse($Version2)
        return $v1.CompareTo($v2)
    } catch {
        Write-Warning "Version comparison failed: $($_.Exception.Message)"
        return 0
    }
}

#endregion

#region AzDo API Functions

function Get-GitLatestRelease {
    <#
    .SYNOPSIS
        Get latest release using Git commands (works with VS Code authentication)
    #>
    param(
        [string]$GitRepoPath = (Get-Location)
    )
    
    try {
        Push-Location $GitRepoPath
        
        # Fetch latest from origin
        $fetchResult = & git fetch origin 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{ Available = $false; Source = "Git"; Error = "Git fetch failed: $fetchResult" }
        }
        
        # Get latest tag
        $latestTag = & git describe --tags --abbrev=0 origin/master 2>$null
        if ($LASTEXITCODE -eq 0 -and $latestTag) {
            $version = $latestTag -replace '^v', ''
            return @{
                Version = $version
                Available = $true
                Source = "Git"
                Tag = $latestTag
            }
        }
        
        # Fallback to commit comparison
        $localCommit = & git rev-parse HEAD
        $remoteCommit = & git rev-parse origin/master
        
        if ($localCommit -ne $remoteCommit) {
            return @{
                Version = "latest"
                Available = $true
                Source = "Git"
                CommitsBehind = (& git rev-list --count HEAD..origin/master)
            }
        }
        
        return @{ Available = $false; Source = "Git"; Message = "Up to date" }
        
    } catch {
        return @{ Available = $false; Source = "Git"; Error = $_.Exception.Message }
    } finally {
        Pop-Location
    }
}

function Get-AzDoLatestRelease {
    <#
    .SYNOPSIS
        Get latest release from Azure DevOps repository
    #>
    try {
        if (-not $script:AzDoConfig.BaseUrl) {
            throw "AzDo configuration not set. Use Set-AzDoConfiguration first."
        }
        
        $headers = @{
            'Authorization' = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:AzDoConfig.PersonalAccessToken)")))"
            'Content-Type' = 'application/json'
        }
        
        $releasesUrl = "$($script:AzDoConfig.BaseUrl)/git/repositories/$($script:AzDoConfig.Repository)/refs?filter=heads/tags"
        
        Write-Verbose "Checking AzDo releases: $releasesUrl"
        
        $response = Invoke-RestMethod -Uri $releasesUrl -Headers $headers -Method Get -TimeoutSec 10
        
        if ($response -and $response.value) {
            # Parse latest tag/release
            $latestTag = $response.value | 
                Where-Object { $_.name -like "refs/tags/v*" } |
                Sort-Object { [System.Version]::Parse(($_.name -replace 'refs/tags/v', '')) } -Descending |
                Select-Object -First 1
            
            if ($latestTag) {
                $version = $latestTag.name -replace 'refs/tags/v', ''
                return @{
                    Version = $version
                    Available = $true
                    Source = "AzDo"
                    Url = "$($script:AzDoConfig.BaseUrl)/git/repositories/$($script:AzDoConfig.Repository)/items?path=/&versionDescriptor.version=$version"
                }
            }
        }
        
        return @{ Available = $false; Source = "AzDo"; Error = "No releases found" }
        
    } catch {
        Write-Warning "AzDo API call failed: $($_.Exception.Message)"
        return @{ Available = $false; Source = "AzDo"; Error = $_.Exception.Message }
    }
}

function Test-AzDoConnectivity {
    <#
    .SYNOPSIS
        Test connectivity to Azure DevOps
    #>
    try {
        if (-not $script:AzDoConfig.BaseUrl) {
            return @{ Connected = $false; Error = "Configuration not set" }
        }
        
        $headers = @{
            'Authorization' = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:AzDoConfig.PersonalAccessToken)")))"
        }
        
        $testUrl = "$($script:AzDoConfig.BaseUrl)/projects/$($script:AzDoConfig.Project)"
        $response = Invoke-RestMethod -Uri $testUrl -Headers $headers -Method Get -TimeoutSec 5
        
        return @{ Connected = $true; ProjectName = $response.name }
        
    } catch {
        return @{ Connected = $false; Error = $_.Exception.Message }
    }
}

#endregion

#region SMB Fallback Functions

function Get-SMBLatestRelease {
    <#
    .SYNOPSIS
        Get latest release from SMB share fallback
    #>
    try {
        if (-not $script:AzDoConfig.SMBFallbackPath -or -not (Test-Path $script:AzDoConfig.SMBFallbackPath)) {
            return @{ Available = $false; Source = "SMB"; Error = "SMB path not available" }
        }
        
        $currentPath = Join-Path $script:AzDoConfig.SMBFallbackPath "current"
        $versionFile = Join-Path $currentPath "version.txt"
        
        if (Test-Path $versionFile) {
            $version = Get-Content $versionFile -Raw | ForEach-Object { $_.Trim() }
            return @{
                Version = $version
                Available = $true
                Source = "SMB"
                Path = $currentPath
            }
        }
        
        return @{ Available = $false; Source = "SMB"; Error = "Version file not found" }
        
    } catch {
        Write-Warning "SMB fallback failed: $($_.Exception.Message)"
        return @{ Available = $false; Source = "SMB"; Error = $_.Exception.Message }
    }
}

function Test-SMBConnectivity {
    <#
    .SYNOPSIS
        Test connectivity to SMB share
    #>
    try {
        if (-not $script:AzDoConfig.SMBFallbackPath) {
            return @{ Connected = $false; Error = "SMB path not configured" }
        }
        
        $testResult = Test-Path $script:AzDoConfig.SMBFallbackPath
        return @{ Connected = $testResult; Path = $script:AzDoConfig.SMBFallbackPath }
        
    } catch {
        return @{ Connected = $false; Error = $_.Exception.Message }
    }
}

#endregion

#region Update Management Functions

function Test-UpdateAvailable {
    <#
    .SYNOPSIS
        Check if updates are available from Git, AzDo, or SMB fallback
    #>
    $currentVersion = Get-CurrentVersion
    
    # Try Git first (works with VS Code authentication)
    Write-Verbose "Checking Git for updates..."
    $gitRelease = Get-GitLatestRelease
    
    if ($gitRelease.Available -and $gitRelease.Version -ne "latest") {
        $comparison = Compare-Versions -Version1 $gitRelease.Version -Version2 $currentVersion
        if ($comparison -gt 0) {
            return @{
                UpdateAvailable = $true
                Source = "Git"
                CurrentVersion = $currentVersion
                LatestVersion = $gitRelease.Version
                Release = $gitRelease
            }
        }
    } elseif ($gitRelease.Available -and $gitRelease.CommitsBehind -gt 0) {
        return @{
            UpdateAvailable = $true
            Source = "Git"
            CurrentVersion = $currentVersion
            LatestVersion = "$($gitRelease.CommitsBehind) commits ahead"
            Release = $gitRelease
        }
    }
    
    # Try AzDo API as fallback
    Write-Verbose "Checking AzDo API for updates..."
    $azDoRelease = Get-AzDoLatestRelease
    
    if ($azDoRelease.Available) {
        $comparison = Compare-Versions -Version1 $azDoRelease.Version -Version2 $currentVersion
        if ($comparison -gt 0) {
            return @{
                UpdateAvailable = $true
                Source = "AzDo"
                CurrentVersion = $currentVersion
                LatestVersion = $azDoRelease.Version
                Release = $azDoRelease
            }
        }
    }
    
    # Fallback to SMB
    Write-Verbose "Checking SMB fallback for updates..."
    $smbRelease = Get-SMBLatestRelease
    
    if ($smbRelease.Available) {
        $comparison = Compare-Versions -Version1 $smbRelease.Version -Version2 $currentVersion
        if ($comparison -gt 0) {
            return @{
                UpdateAvailable = $true
                Source = "SMB"
                CurrentVersion = $currentVersion
                LatestVersion = $smbRelease.Version
                Release = $smbRelease
            }
        }
    }
    
    return @{
        UpdateAvailable = $false
        CurrentVersion = $currentVersion
        AzDoStatus = $azDoRelease
        SMBStatus = $smbRelease
    }
}

function Get-UpdateStatus {
    <#
    .SYNOPSIS
        Get comprehensive update status including connectivity
    #>
    $azDoConnectivity = Test-AzDoConnectivity
    $smbConnectivity = Test-SMBConnectivity
    $updateCheck = Test-UpdateAvailable
    
    return @{
        AzDo = @{
            Connected = $azDoConnectivity.Connected
            Error = $azDoConnectivity.Error
            ProjectName = $azDoConnectivity.ProjectName
        }
        SMB = @{
            Connected = $smbConnectivity.Connected
            Error = $smbConnectivity.Error
            Path = $smbConnectivity.Path
        }
        Update = $updateCheck
        Timestamp = Get-Date
    }
}

#endregion

# Export module functions
Export-ModuleMember -Function @(
    'Set-AzDoConfiguration',
    'Get-AzDoConfiguration',
    'Get-CurrentVersion',
    'Set-CurrentVersion',
    'Compare-Versions',
    'Get-GitLatestRelease',
    'Get-AzDoLatestRelease',
    'Test-AzDoConnectivity',
    'Get-SMBLatestRelease', 
    'Test-SMBConnectivity',
    'Test-UpdateAvailable',
    'Get-UpdateStatus'
)