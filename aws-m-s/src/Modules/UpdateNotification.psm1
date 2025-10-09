#requires -version 7.0
<#
.SYNOPSIS
    Update Notification Module for AWS Management Studio

.VERSION
    1.0.0 (Update Notification System)

.DOCUMENTATION
    Provides update notification UI integration
    - Check for updates on startup
    - Display update notifications
    - Handle update downloads
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-UpdateNotification {
    <#
    .SYNOPSIS
        Show update notification dialog
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$UpdateInfo,
        
        [System.Windows.Window]$ParentWindow
    )
    
    try {
        $message = @"
🚀 AWS Management Studio Update Available!

Current Version: $($UpdateInfo.CurrentVersion)
Latest Version: $($UpdateInfo.LatestVersion)
Source: $($UpdateInfo.Source)

Would you like to update now?
"@
        
        $result = [System.Windows.MessageBox]::Show(
            $message,
            "Update Available",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )
        
        return $result -eq [System.Windows.MessageBoxResult]::Yes
        
    } catch {
        Write-Warning "Failed to show update notification: $($_.Exception.Message)"
        return $false
    }
}

function Add-UpdateCheckToUI {
    <#
    .SYNOPSIS
        Add update check functionality to main window
    #>
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$MainWindow
    )
    
    try {
        # Add update check menu item if menu exists
        $mainMenu = $MainWindow.FindName("MainMenu")
        if ($mainMenu) {
            $helpMenu = $mainMenu.Items | Where-Object { $_.Header -like "*Help*" } | Select-Object -First 1
            if ($helpMenu) {
                $updateMenuItem = New-Object System.Windows.Controls.MenuItem
                $updateMenuItem.Header = "Check for Updates..."
                $updateMenuItem.Add_Click({
                    Start-UpdateCheck -MainWindow $MainWindow
                })
                $helpMenu.Items.Add($updateMenuItem)
            }
        }
        
        # Add status bar update indicator
        $statusBar = $MainWindow.FindName("StatusBar") -or $MainWindow.FindName("statusBar")
        if ($statusBar) {
            $updateStatus = New-Object System.Windows.Controls.TextBlock
            $updateStatus.Name = "UpdateStatus"
            $updateStatus.Text = ""
            $updateStatus.Margin = "10,0,0,0"
            $statusBar.Items.Add($updateStatus)
        }
        
        Write-Verbose "Update UI components added successfully"
        
    } catch {
        Write-Warning "Failed to add update UI components: $($_.Exception.Message)"
    }
}

function Start-UpdateCheck {
    <#
    .SYNOPSIS
        Start update check process
    #>
    param(
        [System.Windows.Window]$MainWindow,
        [switch]$Silent
    )
    
    try {
        # Import AzDo integration module
        $azDoModulePath = Join-Path $PSScriptRoot "AzDoIntegration.psm1"
        if (Test-Path $azDoModulePath) {
            Import-Module $azDoModulePath -Force
        } else {
            if (-not $Silent) {
                [System.Windows.MessageBox]::Show(
                    "AzDo integration module not found. Update check unavailable.",
                    "Update Check",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                )
            }
            return
        }
        
        # Load configuration
        $configPath = Join-Path $PSScriptRoot "..\Config\azdo-config.json"
        if (Test-Path $configPath) {
            $config = Get-Content $configPath | ConvertFrom-Json
            Set-AzDoConfiguration -Organization $config.organization -Project $config.project -Repository $config.repository -SMBFallbackPath $config.smbFallbackPath
        }
        
        # Check for updates
        $updateStatus = Get-UpdateStatus
        
        # Update status bar
        if ($MainWindow) {
            $statusText = $MainWindow.FindName("UpdateStatus")
            if ($statusText) {
                $MainWindow.Dispatcher.Invoke({
                    if ($updateStatus.Update.UpdateAvailable) {
                        $statusText.Text = "🔄 Update Available: v$($updateStatus.Update.LatestVersion)"
                        $statusText.Foreground = "Orange"
                    } else {
                        $statusText.Text = "✅ Up to date"
                        $statusText.Foreground = "Green"
                    }
                })
            }
        }
        
        # Show notification if update available
        if ($updateStatus.Update.UpdateAvailable -and -not $Silent) {
            $shouldUpdate = Show-UpdateNotification -UpdateInfo $updateStatus.Update -ParentWindow $MainWindow
            if ($shouldUpdate) {
                Start-UpdateProcess -UpdateInfo $updateStatus.Update
            }
        }
        
        return $updateStatus
        
    } catch {
        Write-Warning "Update check failed: $($_.Exception.Message)"
        if (-not $Silent) {
            [System.Windows.MessageBox]::Show(
                "Update check failed: $($_.Exception.Message)",
                "Update Check Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    }
}

function Start-UpdateProcess {
    <#
    .SYNOPSIS
        Start the update download and installation process
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$UpdateInfo
    )
    
    try {
        $message = @"
Update process will:
1. Download latest version from $($UpdateInfo.Source)
2. Backup current version
3. Install new version
4. Restart application

This may take a few minutes. Continue?
"@
        
        $result = [System.Windows.MessageBox]::Show(
            $message,
            "Confirm Update",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            # For now, just show a placeholder message
            [System.Windows.MessageBox]::Show(
                "Update functionality will be implemented in the next phase. Please manually update for now.",
                "Update Process",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        }
        
    } catch {
        Write-Warning "Update process failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Update process failed: $($_.Exception.Message)",
            "Update Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
}

# Export module functions
Export-ModuleMember -Function @(
    'Show-UpdateNotification',
    'Add-UpdateCheckToUI',
    'Start-UpdateCheck',
    'Start-UpdateProcess'
)