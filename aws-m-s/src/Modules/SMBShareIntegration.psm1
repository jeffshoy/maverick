#requires -version 7.0
<#
.SYNOPSIS
    SMB Share Integration Module for AWS Management Studio

.DESCRIPTION
    Provides centralized bug tracking, logging, and distribution via network share
#>

Set-StrictMode -Version Latest

# SMB Share Configuration
$script:SMBShareConfig = @{
    Enabled = $false
    BasePath = $null
    BugsPath = $null
    LogsPath = $null
    AnalyticsPath = $null
    ReleasesPath = $null
    LastCheck = $null
    Available = $false
}

function Initialize-SMBShareConfig {
    <#
    .SYNOPSIS
        Initialize SMB share configuration from settings
    #>
    try {
        $settingsPath = Join-Path $env:APPDATA 'AWS-Management-Studio\smb-config.json'
        
        if (Test-Path $settingsPath) {
            $config = Get-Content $settingsPath -Raw | ConvertFrom-Json
            $script:SMBShareConfig.Enabled = $config.Enabled
            $script:SMBShareConfig.BasePath = $config.BasePath
        } else {
            # Default configuration
            $script:SMBShareConfig.Enabled = $false
            $script:SMBShareConfig.BasePath = "\\fileshare.cloud.lcl\Users\derek.johnson\Scripts\aws-management-studio"
        }
        
        # Set derived paths
        if ($script:SMBShareConfig.BasePath) {
            $script:SMBShareConfig.BugsPath = Join-Path $script:SMBShareConfig.BasePath "bugs"
            $script:SMBShareConfig.LogsPath = Join-Path $script:SMBShareConfig.BasePath "logs"
            $script:SMBShareConfig.AnalyticsPath = Join-Path $script:SMBShareConfig.BasePath "analytics"
            $script:SMBShareConfig.ReleasesPath = Join-Path $script:SMBShareConfig.BasePath "releases"
        }
        
        Write-Verbose "SMB Share configuration initialized"
    } catch {
        Write-Warning "Failed to initialize SMB share configuration: $($_.Exception.Message)"
    }
}

function Test-SMBShareAvailability {
    <#
    .SYNOPSIS
        Test if SMB share is available
    #>
    param(
        [switch]$Force
    )
    
    # Return cached result if recent (within 5 minutes)
    if (-not $Force -and $script:SMBShareConfig.LastCheck) {
        $timeSinceCheck = (Get-Date) - $script:SMBShareConfig.LastCheck
        if ($timeSinceCheck.TotalMinutes -lt 5) {
            return $script:SMBShareConfig.Available
        }
    }
    
    if (-not $script:SMBShareConfig.Enabled) {
        Write-Verbose "SMB share integration is disabled"
        return $false
    }
    
    if (-not $script:SMBShareConfig.BasePath) {
        Write-Verbose "SMB share base path not configured"
        return $false
    }
    
    try {
        # Test network share accessibility with timeout
        $testPath = $script:SMBShareConfig.BasePath
        $available = Test-Path $testPath -ErrorAction Stop
        
        $script:SMBShareConfig.Available = $available
        $script:SMBShareConfig.LastCheck = Get-Date
        
        if ($available) {
            Write-Verbose "SMB share is available: $testPath"
        } else {
            Write-Verbose "SMB share is not accessible: $testPath"
        }
        
        return $available
    } catch {
        Write-Verbose "SMB share connectivity test failed: $($_.Exception.Message)"
        $script:SMBShareConfig.Available = $false
        $script:SMBShareConfig.LastCheck = Get-Date
        return $false
    }
}

function Save-BugReportToSMB {
    <#
    .SYNOPSIS
        Save bug report to SMB share for team visibility
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$BugReport
    )
    
    if (-not (Test-SMBShareAvailability)) {
        Write-Verbose "SMB share not available, skipping network save"
        return $false
    }
    
    try {
        $bugsPath = $script:SMBShareConfig.BugsPath
        $openPath = Join-Path $bugsPath "open"
        
        # Ensure directory exists
        if (-not (Test-Path $openPath)) {
            New-Item -ItemType Directory -Path $openPath -Force | Out-Null
        }
        
        # Save bug report as individual JSON file
        $fileName = "bug-$($BugReport.Id)-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $filePath = Join-Path $openPath $fileName
        
        $BugReport | ConvertTo-Json -Depth 10 | Set-Content $filePath -Encoding UTF8
        
        # Copy screenshots to SMB share
        if ($BugReport.ContainsKey('Screenshots') -and $BugReport.Screenshots -and $BugReport.Screenshots.Count -gt 0) {
            $screenshotsPath = Join-Path $openPath "screenshots"
            if (-not (Test-Path $screenshotsPath)) {
                New-Item -ItemType Directory -Path $screenshotsPath -Force | Out-Null
            }
            
            $copiedScreenshots = @()
            foreach ($screenshot in $BugReport.Screenshots) {
                if (Test-Path $screenshot) {
                    $screenshotName = "$($BugReport.Id)-$([System.IO.Path]::GetFileName($screenshot))"
                    $destPath = Join-Path $screenshotsPath $screenshotName
                    Copy-Item $screenshot $destPath -Force
                    $copiedScreenshots += $destPath
                }
            }
            
            # Update bug report with SMB screenshot paths
            $BugReport.SMBScreenshots = $copiedScreenshots
            $BugReport | ConvertTo-Json -Depth 10 | Set-Content $filePath -Encoding UTF8
        }
        
        Write-Host "Bug report saved to SMB share: $fileName" -ForegroundColor Green
        return $true
    } catch {
        Write-Warning "Failed to save bug report to SMB share: $($_.Exception.Message)"
        return $false
    }
}

function Get-BugReportsFromSMB {
    <#
    .SYNOPSIS
        Get all bug reports from SMB share
    #>
    param(
        [ValidateSet("Open", "Resolved", "All")]
        [string]$Status = "All"
    )
    
    if (-not (Test-SMBShareAvailability)) {
        Write-Verbose "SMB share not available"
        return @()
    }
    
    try {
        $bugsPath = $script:SMBShareConfig.BugsPath
        $reports = @()
        
        $searchPaths = switch ($Status) {
            "Open" { @(Join-Path $bugsPath "open") }
            "Resolved" { @(Join-Path $bugsPath "resolved") }
            "All" { @(
                (Join-Path $bugsPath "open"),
                (Join-Path $bugsPath "resolved"),
                (Join-Path $bugsPath "archive")
            )}
        }
        
        foreach ($path in $searchPaths) {
            if (Test-Path $path) {
                $bugFiles = Get-ChildItem $path -Filter "bug-*.json" -File
                foreach ($file in $bugFiles) {
                    try {
                        $report = Get-Content $file.FullName -Raw | ConvertFrom-Json
                        $reports += $report
                    } catch {
                        Write-Warning "Failed to load bug report: $($file.Name)"
                    }
                }
            }
        }
        
        return $reports
    } catch {
        Write-Warning "Failed to retrieve bug reports from SMB share: $($_.Exception.Message)"
        return @()
    }
}

function Move-BugReportStatus {
    <#
    .SYNOPSIS
        Move bug report between status folders on SMB share
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BugId,
        
        [Parameter(Mandatory)]
        [ValidateSet("Open", "Resolved", "Archive")]
        [string]$NewStatus
    )
    
    if (-not (Test-SMBShareAvailability)) {
        Write-Warning "SMB share not available"
        return $false
    }
    
    try {
        $bugsPath = $script:SMBShareConfig.BugsPath
        
        # Find the bug report file
        $searchPaths = @("open", "resolved", "archive")
        $foundFile = $null
        $currentFolder = $null
        
        foreach ($folder in $searchPaths) {
            $path = Join-Path $bugsPath $folder
            if (Test-Path $path) {
                $files = Get-ChildItem $path -Filter "bug-$BugId-*.json" -File
                if ($files.Count -gt 0) {
                    $foundFile = $files[0]
                    $currentFolder = $folder
                    break
                }
            }
        }
        
        if (-not $foundFile) {
            Write-Warning "Bug report $BugId not found on SMB share"
            return $false
        }
        
        # Don't move if already in target folder
        if ($currentFolder -eq $NewStatus.ToLower()) {
            Write-Verbose "Bug report already in $NewStatus folder"
            return $true
        }
        
        # Move to new status folder
        $targetFolder = Join-Path $bugsPath $NewStatus.ToLower()
        if (-not (Test-Path $targetFolder)) {
            New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
        }
        
        $targetPath = Join-Path $targetFolder $foundFile.Name
        Move-Item $foundFile.FullName $targetPath -Force
        
        # Move associated screenshots
        $screenshotsFolder = Join-Path (Split-Path $foundFile.FullName -Parent) "screenshots"
        if (Test-Path $screenshotsFolder) {
            $screenshots = Get-ChildItem $screenshotsFolder -Filter "$BugId-*" -File
            if ($screenshots.Count -gt 0) {
                $targetScreenshotsFolder = Join-Path $targetFolder "screenshots"
                if (-not (Test-Path $targetScreenshotsFolder)) {
                    New-Item -ItemType Directory -Path $targetScreenshotsFolder -Force | Out-Null
                }
                
                foreach ($screenshot in $screenshots) {
                    $targetScreenshot = Join-Path $targetScreenshotsFolder $screenshot.Name
                    Move-Item $screenshot.FullName $targetScreenshot -Force
                }
            }
        }
        
        Write-Host "Bug report $BugId moved to $NewStatus" -ForegroundColor Green
        return $true
    } catch {
        Write-Warning "Failed to move bug report: $($_.Exception.Message)"
        return $false
    }
}

function Write-SMBLog {
    <#
    .SYNOPSIS
        Write log entry to SMB share for centralized logging
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info",
        
        [string]$Category = "General"
    )
    
    if (-not (Test-SMBShareAvailability)) {
        return
    }
    
    try {
        $logsPath = $script:SMBShareConfig.LogsPath
        if (-not (Test-Path $logsPath)) {
            New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
        }
        
        $logFile = Join-Path $logsPath "app-log-$(Get-Date -Format 'yyyyMMdd').log"
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$env:USERNAME@$env:COMPUTERNAME] [$Level] [$Category] $Message"
        
        Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
    } catch {
        # Silent fail for logging
        Write-Verbose "Failed to write to SMB log: $($_.Exception.Message)"
    }
}

function Send-UsageAnalytics {
    <#
    .SYNOPSIS
        Send usage analytics to SMB share
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Action,
        
        [hashtable]$Metadata = @{}
    )
    
    if (-not (Test-SMBShareAvailability)) {
        return
    }
    
    try {
        $analyticsPath = $script:SMBShareConfig.AnalyticsPath
        if (-not (Test-Path $analyticsPath)) {
            New-Item -ItemType Directory -Path $analyticsPath -Force | Out-Null
        }
        
        $analyticsFile = Join-Path $analyticsPath "usage-$(Get-Date -Format 'yyyyMM').json"
        
        $entry = @{
            Timestamp = Get-Date
            User = $env:USERNAME
            Machine = $env:COMPUTERNAME
            Action = $Action
            Version = "6.3.1"
            Metadata = $Metadata
        }
        
        # Append to monthly analytics file
        $existingData = @()
        if (Test-Path $analyticsFile) {
            try {
                $existingData = Get-Content $analyticsFile -Raw | ConvertFrom-Json
            } catch {
                # Start fresh if file is corrupted
            }
        }
        
        $existingData += $entry
        $existingData | ConvertTo-Json -Depth 10 | Set-Content $analyticsFile -Encoding UTF8
    } catch {
        Write-Verbose "Failed to send usage analytics: $($_.Exception.Message)"
    }
}

function Get-SMBShareStatus {
    <#
    .SYNOPSIS
        Get current SMB share configuration and status
    #>
    $status = [PSCustomObject]@{
        Enabled = $script:SMBShareConfig.Enabled
        BasePath = $script:SMBShareConfig.BasePath
        Available = Test-SMBShareAvailability
        LastCheck = $script:SMBShareConfig.LastCheck
        BugsPath = $script:SMBShareConfig.BugsPath
        LogsPath = $script:SMBShareConfig.LogsPath
        AnalyticsPath = $script:SMBShareConfig.AnalyticsPath
        ReleasesPath = $script:SMBShareConfig.ReleasesPath
    }
    
    return $status
}

function Set-SMBShareConfiguration {
    <#
    .SYNOPSIS
        Configure SMB share settings
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,
        
        [bool]$Enabled = $true
    )
    
    try {
        $script:SMBShareConfig.BasePath = $BasePath
        $script:SMBShareConfig.Enabled = $Enabled
        
        # Update derived paths
        $script:SMBShareConfig.BugsPath = Join-Path $BasePath "bugs"
        $script:SMBShareConfig.LogsPath = Join-Path $BasePath "logs"
        $script:SMBShareConfig.AnalyticsPath = Join-Path $BasePath "analytics"
        $script:SMBShareConfig.ReleasesPath = Join-Path $BasePath "releases"
        
        # Save configuration
        $settingsPath = Join-Path $env:APPDATA 'AWS-Management-Studio\smb-config.json'
        $settingsDir = Split-Path $settingsPath -Parent
        
        if (-not (Test-Path $settingsDir)) {
            New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        }
        
        $config = @{
            Enabled = $Enabled
            BasePath = $BasePath
        }
        
        $config | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
        
        # Test connectivity
        $available = Test-SMBShareAvailability -Force
        
        if ($available) {
            Write-Host "SMB share configured successfully: $BasePath" -ForegroundColor Green
        } else {
            Write-Warning "SMB share configured but not currently accessible: $BasePath"
        }
        
        return $true
    } catch {
        Write-Warning "Failed to configure SMB share: $($_.Exception.Message)"
        return $false
    }
}

# Initialize on module load
Initialize-SMBShareConfig

Export-ModuleMember -Function Test-SMBShareAvailability, Save-BugReportToSMB, Get-BugReportsFromSMB, Move-BugReportStatus, Write-SMBLog, Send-UsageAnalytics, Get-SMBShareStatus, Set-SMBShareConfiguration
