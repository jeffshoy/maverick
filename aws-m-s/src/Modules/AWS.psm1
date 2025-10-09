# AWS module - Profile management and API calls
function Get-AwsProfiles {
    try {
        Write-DebugLog "Retrieving AWS profiles from CLI configuration" "INFO" "Profile"
        $profiles = & aws configure list-profiles 2>$null
        if ($LASTEXITCODE -eq 0 -and $profiles) {
            $profileList = $profiles -split "`n" | Where-Object { $_.Trim() } | Sort-Object
            Write-DebugLog "Found $($profileList.Count) AWS profiles" "INFO" "Profile"
            
            # Add recent profiles to the top of the sorted list
            $settings = Get-Settings
            if ($settings.RecentProfiles) {
                $recentProfiles = @()
                foreach ($recent in $settings.RecentProfiles) {
                    if ($recent -in $profileList) {
                        $recentProfiles += $recent
                        $profileList = $profileList | Where-Object { $_ -ne $recent }
                    }
                }
                $profileList = $recentProfiles + $profileList
                Write-DebugLog "Profile dropdown populated with $($profileList.Count) profiles ($($recentProfiles.Count) recent)" "INFO" "Profile"
            }
            
            # Set profile list normally
            $cmbProfile.ItemsSource = $profileList
            $cmbProfile.SelectedIndex = -1
        } else {
            Write-DebugLog "No AWS profiles found or AWS CLI not available" "WARN" "Profile"
        }
    } catch {
        Write-DebugLog "Failed to load AWS profiles: $($_.Exception.Message)" "ERROR" "Profile"
        Write-Warning "Failed to load AWS profiles: $($_.Exception.Message)"
    }
}

function Test-ProfileSsoStatus {
    $profileName = $cmbProfile.Text.Trim()
    if (-not $profileName) {
        $lblProfileStatus.Content = "No profile selected"
        $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Gray)
        Update-CommandFrameworkPermissions ""
        Stop-AutoRefresh
        return
    }
    
    # Validate profile name for dangerous characters
    $dangerousChars = @('`', '$', '&', '|', ';', '<', '>', '"', "'", '\', '/', '(', ')')
    foreach ($char in $dangerousChars) {
        if ($profileName.IndexOf($char) -ge 0) {
            $lblProfileStatus.Content = "⚠️ Invalid characters in profile name"
            $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
            return
        }
    }
    
    # Cancel any existing SSO check job
    Stop-SsoCheckJob
    
    # Quick profile existence check (synchronous - very fast)
    $availableProfiles = & aws configure list-profiles 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $availableProfiles -or $profileName -notin ($availableProfiles -split "`n" | Where-Object { $_.Trim() })) {
        $lblProfileStatus.Content = "❌ Profile not found - Create SSO profile"
        $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
        Update-CommandFrameworkPermissions ""
        Stop-AutoRefresh
        return
    }
    
    # Quick network connectivity check
    $connectivityTest = Test-NetworkConnectivity
    if (-not $connectivityTest.IsConnected) {
        $lblProfileStatus.Content = "❌ Network Error: $($connectivityTest.Message)"
        $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
        Update-CommandFrameworkPermissions ""
        Stop-AutoRefresh
        return
    }
    
    # Update UI for SSO check start
    $lblProfileStatus.Content = "Checking SSO status..."
    $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Orange)
    $btnCheckStatus.IsEnabled = $false
    
    # Create background runspace for SSO check
    $script:SsoCheckRunspace = [runspacefactory]::CreateRunspace()
    $script:SsoCheckRunspace.Open()
    
    # Create PowerShell instance for background execution
    $script:SsoCheckPowerShell = [powershell]::Create()
    $script:SsoCheckPowerShell.Runspace = $script:SsoCheckRunspace
    
    # Define the SSO check script block
    $ssoCheckScript = {
        param($ProfileName)
        
        try {
            # Test AWS CLI with the profile
            $result = & aws sts get-caller-identity --profile $ProfileName --cli-read-timeout 15 --cli-connect-timeout 5 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                return @{
                    Success = $true
                    Status = "Active"
                    Message = "✅ SSO Active - Ready"
                }
            } else {
                # Check if it's an SSO-related error or profile configuration issue
                $errorOutput = $result -join " "
                if ($errorOutput -match "profile.*not found|No such file|could not be found") {
                    return @{ Success = $false; Status = "NotFound"; Message = "❌ Profile not found - Create SSO profile" }
                } elseif ($errorOutput -match "sso.*session.*expired|token.*expired|SSO.*expired|Token.*does not exist|Error loading SSO Token") {
                    return @{ Success = $false; Status = "Expired"; Message = "❌ SSO Expired - Login Required" }
                } elseif ($errorOutput -match "sso.*login|SSO.*login") {
                    return @{ Success = $false; Status = "LoginRequired"; Message = "❌ SSO Login Required" }
                } else {
                    return @{ Success = $false; Status = "Error"; Message = "❌ Profile Error - Check Configuration" }
                }
            }
        } catch {
            return @{ Success = $false; Status = "Unknown"; Message = "❓ Status Unknown - Check Configuration" }
        }
    }
    
    # Add parameters and script to PowerShell instance
    $script:SsoCheckPowerShell.AddScript($ssoCheckScript).AddParameter("ProfileName", $profileName) | Out-Null
    
    # Start async execution
    $script:SsoCheckAsyncResult = $script:SsoCheckPowerShell.BeginInvoke()
    
    # Start timer to check for completion
    Start-SsoCheckProgressTimer
}

function Start-SsoCheckProgressTimer {
    if ($script:SsoCheckProgressTimer) {
        $script:SsoCheckProgressTimer.Stop()
    }
    
    $script:SsoCheckProgressTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SsoCheckProgressTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:SsoCheckProgressTimer.Add_Tick({
        if ($script:SsoCheckAsyncResult -and $script:SsoCheckAsyncResult.IsCompleted) {
            Complete-SsoCheckOperation
        } else {
            # Update progress indicator
            $dots = @(".", "..", "...", "")
            $script:SsoCheckDotIndex = if ($script:SsoCheckDotIndex -ge 3) { 0 } else { $script:SsoCheckDotIndex + 1 }
            $lblProfileStatus.Content = "Checking SSO status$($dots[$script:SsoCheckDotIndex])"
        }
    })
    $script:SsoCheckProgressTimer.Start()
    $script:SsoCheckDotIndex = 0
}

function Complete-SsoCheckOperation {
    try {
        # Stop the progress timer
        if ($script:SsoCheckProgressTimer) {
            $script:SsoCheckProgressTimer.Stop()
            $script:SsoCheckProgressTimer = $null
        }
        
        # Get results from background job
        $results = $script:SsoCheckPowerShell.EndInvoke($script:SsoCheckAsyncResult)
        
        if ($results) {
            $lblProfileStatus.Content = $results.Message
            
            if ($results.Success) {
                $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Green)
                $btnSsoLogin.Visibility = [System.Windows.Visibility]::Collapsed
                $btnSsoLogout.Visibility = [System.Windows.Visibility]::Visible
                
                # Update command framework based on permissions
                $profileName = $cmbProfile.Text.Trim()
                Update-CommandFrameworkPermissions $profileName
                
                # Auto-search instances when profile is active
                Start-AutoSearch $profileName
            } else {
                $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
                
                # Show SSO login button for SSO-related errors
                if ($results.Status -in @('Expired', 'LoginRequired')) {
                    $btnSsoLogin.Visibility = [System.Windows.Visibility]::Visible
                } else {
                    $btnSsoLogin.Visibility = [System.Windows.Visibility]::Collapsed
                }
                
                $btnSsoLogout.Visibility = [System.Windows.Visibility]::Collapsed
                
                Update-CommandFrameworkPermissions ""
                Stop-AutoRefresh
            }
        } else {
            $lblProfileStatus.Content = "❓ Status check failed"
            $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Orange)
        }
    } catch {
        $lblProfileStatus.Content = "❓ Status check error: $($_.Exception.Message)"
        $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Orange)
    } finally {
        # Reset check status button
        $btnCheckStatus.IsEnabled = $true
        
        # Cleanup background job
        Stop-SsoCheckJob
    }
}

function Stop-SsoCheckJob {
    try {
        if ($script:SsoCheckProgressTimer) {
            $script:SsoCheckProgressTimer.Stop()
            $script:SsoCheckProgressTimer = $null
        }
        
        if ($script:SsoCheckPowerShell) {
            $script:SsoCheckPowerShell.Stop()
            $script:SsoCheckPowerShell.Dispose()
            $script:SsoCheckPowerShell = $null
        }
        
        if ($script:SsoCheckRunspace) {
            $script:SsoCheckRunspace.Close()
            $script:SsoCheckRunspace.Dispose()
            $script:SsoCheckRunspace = $null
        }
        
        $script:SsoCheckAsyncResult = $null
    } catch {
        # Cleanup errors are non-critical
    }
}

function Search-EC2Instances {
    param(
        [string]$ProfileName,
        [bool]$IsAutoSearch = $false,
        [bool]$IsAutoRefresh = $false
    )
    
    if (-not $ProfileName) { return }
    
    if ($global:DebugMode) {
        Write-Host "[SEARCH] Starting EC2 search for profile: $ProfileName" -ForegroundColor Cyan
    }
    
    # Validate profile name for dangerous characters
    $dangerousChars = @('`', '$', '&', '|', ';', '<', '>', '"', "'", '\', '/', '(', ')')
    foreach ($char in $dangerousChars) {
        if ($ProfileName.IndexOf($char) -ge 0) {
            $lblStatus.Content = "⚠️ Invalid characters in profile name"
            return
        }
    }
    
    # Cancel any existing search job
    Stop-SearchJob
    
    # Test network connectivity first (quick check)
    $connectivityTest = Test-NetworkConnectivity
    if (-not $connectivityTest.IsConnected) {
        $lblStatus.Content = "❌ Network Error: $($connectivityTest.Message)"
        $lblInstanceCount.Content = "Connection required"
        return
    }
    
    # Update UI for search start
    if (-not $IsAutoRefresh) {
        $lblStatus.Content = if ($IsAutoSearch) { "Auto-searching instances..." } else { "Searching instances..." }
        $btnSearch.Content = "⏹️ Cancel Search"
    }
    
    # Create background runspace for search
    $script:SearchRunspace = [runspacefactory]::CreateRunspace()
    $script:SearchRunspace.Open()
    
    # Create PowerShell instance for background execution
    $script:SearchPowerShell = [powershell]::Create()
    $script:SearchPowerShell.Runspace = $script:SearchRunspace
    
    # Define the search script block
    $searchScript = {
        param($ProfileName, $IsAutoRefresh)
        
        $regions = @('us-east-1','us-west-2','ca-central-1')
        $allInstances = @()
        $hasNetworkError = $false
        $currentRegion = ""
        $completedRegions = @()
        $failedRegions = @()
        
        foreach ($region in $regions) {
            $currentRegion = $region
            
            $query = "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceId,State.Name,PrivateIpAddress,InstanceType,Platform,LaunchTime,KeyName,StateTransitionReason]"
            
            try {
                $result = & aws ec2 describe-instances --region $region --profile $ProfileName --query $query --output json --cli-read-timeout 30 --cli-connect-timeout 10 2>&1
                
                if ($LASTEXITCODE -eq 0 -and $result) {
                    $completedRegions += $region
                    
                    # Handle both String and Object[] results from AWS CLI
                    $jsonString = if ($result.GetType().Name -eq "String") { $result } else { $result -join "" }
                    
                    if ($jsonString.Trim() -ne "[]") {
                        try {
                            $instances = $jsonString | ConvertFrom-Json
                            if ($instances -and $instances.Count -gt 0) {
                                foreach ($instance in $instances) {
                                    # Calculate uptime for running instances
                                    $uptime = "N/A"
                                    $healthStatus = "❔ Unknown"
                                    
                                    if ($instance[2] -eq "running" -and $instance[6]) {
                                        try {
                                            $launchTime = [DateTime]::Parse($instance[6])
                                            $uptimeSpan = (Get-Date) - $launchTime
                                            if ($uptimeSpan.TotalDays -ge 1) {
                                                $uptime = "$([math]::Floor($uptimeSpan.TotalDays))d"
                                            } elseif ($uptimeSpan.TotalHours -ge 1) {
                                                $uptime = "$([math]::Floor($uptimeSpan.TotalHours))h"
                                            } else {
                                                $uptime = "$([math]::Floor($uptimeSpan.TotalMinutes))m"
                                            }
                                            
                                            # Assume healthy if running for more than 5 minutes
                                            if ($uptimeSpan.TotalMinutes -gt 5) {
                                                $healthStatus = "✅ OK"
                                            } else {
                                                $healthStatus = "⚠️ Starting"
                                            }
                                        } catch {
                                            $uptime = "Unknown"
                                        }
                                    } elseif ($instance[2] -eq "stopped") {
                                        $healthStatus = "⏹️ Stopped"
                                    } elseif ($instance[2] -eq "stopping") {
                                        $healthStatus = "⏸️ Stopping"
                                    } elseif ($instance[2] -eq "pending") {
                                        $healthStatus = "🔄 Starting"
                                    } elseif ($instance[2] -eq "terminated") {
                                        $healthStatus = "❌ Terminated"
                                    }
                                    
                                    # Determine platform
                                    $platform = if ($instance[5]) { 
                                        switch ($instance[5]) {
                                            "windows" { "🪟 Win" }
                                            "linux" { "🐧 Linux" }
                                            default { $instance[5] }
                                        }
                                    } else { "Unknown" }
                                    
                                    $allInstances += [PSCustomObject]@{
                                        Name = if ($instance[0]) { $instance[0] } else { "(no name)" }
                                        InstanceId = $instance[1]
                                        State = $instance[2]
                                        HealthStatus = $healthStatus
                                        PrivateIp = if ($instance[3]) { $instance[3] } else { "N/A" }
                                        Platform = $platform
                                        InstanceType = $instance[4]
                                        Region = $region
                                        Uptime = $uptime
                                        KeyName = if ($instance[7]) { $instance[7] } else { "N/A" }
                                        LaunchTime = $instance[6]
                                        StateReason = $instance[8]
                                    }
                                }
                            }
                        } catch {
                            $failedRegions += "$region (parse error)"
                        }
                    }
                } elseif ($LASTEXITCODE -ne 0) {
                    $failedRegions += $region
                    $errorOutput = $result -join " "
                    if ($errorOutput -match "timeout|network|connection|resolve|unreachable|ConnectTimeoutError|ReadTimeoutError") {
                        $hasNetworkError = $true
                        break
                    }
                }
            } catch {
                $failedRegions += "$region (exception)"
            }
        }
        
        # Return results
        return @{
            Instances = $allInstances
            HasNetworkError = $hasNetworkError
            LastRegion = $currentRegion
            CompletedRegions = $completedRegions
            FailedRegions = $failedRegions
            Success = $true
        }
    }
    
    # Add parameters and script to PowerShell instance
    $script:SearchPowerShell.AddScript($searchScript).AddParameter("ProfileName", $ProfileName).AddParameter("IsAutoRefresh", $IsAutoRefresh) | Out-Null
    
    # Start async execution
    $script:SearchAsyncResult = $script:SearchPowerShell.BeginInvoke()
    
    # Start timer to check for completion
    Start-SearchProgressTimer
}

function Start-SearchProgressTimer {
    if ($script:SearchProgressTimer) {
        $script:SearchProgressTimer.Stop()
    }
    
    $script:SearchProgressTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SearchProgressTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:SearchProgressTimer.Add_Tick({
        if ($script:SearchPowerShell) {
            $state = $script:SearchPowerShell.InvocationStateInfo.State
            if ($state -in @("Completed", "Failed", "Stopped")) {
                Complete-SearchOperation
            } else {
                # Update progress indicator
                $dots = @(".", "..", "...", "")
                $script:SearchDotIndex = if ($script:SearchDotIndex -ge 3) { 0 } else { $script:SearchDotIndex + 1 }
                $lblStatus.Content = "Searching instances$($dots[$script:SearchDotIndex])"
            }
        }
    })
    $script:SearchProgressTimer.Start()
    $script:SearchDotIndex = 0
}

function Complete-SearchOperation {
    try {
        # Stop the progress timer
        if ($script:SearchProgressTimer) {
            $script:SearchProgressTimer.Stop()
            $script:SearchProgressTimer = $null
        }
        
        # Check PowerShell state before calling EndInvoke
        if ($script:SearchPowerShell.InvocationStateInfo.State -eq "Completed" -and $script:SearchAsyncResult -and $script:SearchAsyncResult.IsCompleted) {
            try {
                # Get results from background job
                $results = $script:SearchPowerShell.EndInvoke($script:SearchAsyncResult)
                
                if ($results -and $results.Success) {
                    if ($results.HasNetworkError) {
                        $lblStatus.Content = "❌ Network timeout - Check connection"
                        $lblInstanceCount.Content = "Connection required"
                    } else {
                        # Store original items for filtering and update DataGrid
                        $global:OriginalItems = $results.Instances
                        $dgEC2.ItemsSource = $results.Instances
                        
                        # Auto-size columns to fit content
                        Resize-DataGridColumns
                        
                        # Update filter dropdowns with actual data from search results
                        Update-FilterDropdowns $results.Instances
                        
                        # Resize window based on results and column widths
                        Resize-WindowForResults $results.Instances.Count
                        
                        # Store last refresh time for elapsed calculation
                        $global:LastRefreshTime = Get-Date
                        $lblLastRefresh.Content = "(Last: just now)"
                        
                        # Show completion status with region details
                        $statusMsg = "Found $($results.Instances.Count) instances"
                        if ($results.FailedRegions -and $results.FailedRegions.Count -gt 0) {
                            $statusMsg += " (some regions failed)"
                        }
                        $lblStatus.Content = $statusMsg
                        $lblInstanceCount.Content = "$($results.Instances.Count) instances"
                    }
                } else {
                    $lblStatus.Content = "Search failed - Check connection"
                    $lblInstanceCount.Content = "0 instances"
                }
            } catch {
                $lblStatus.Content = "Search failed: $($_.Exception.Message)"
                $lblInstanceCount.Content = "0 instances"
            }
        } elseif ($script:SearchPowerShell.InvocationStateInfo.State -eq "Stopped") {
            $lblStatus.Content = "EC2 search cancelled"
            $lblInstanceCount.Content = "0 instances"
        } else {
            $lblStatus.Content = "Search failed - Invalid state"
            $lblInstanceCount.Content = "0 instances"
        }
    } catch {
        $lblStatus.Content = "Search failed: $($_.Exception.Message)"
        $lblInstanceCount.Content = "0 instances"
    } finally {
        # Reset search button
        $btnSearch.IsEnabled = $true
        $btnSearch.Content = "🔍 Search"
        
        # Cleanup background job
        Stop-SearchJob
    }
}

function Stop-SearchJob {
    try {
        if ($script:SearchProgressTimer) {
            $script:SearchProgressTimer.Stop()
            $script:SearchProgressTimer = $null
        }
        
        # Don't kill AWS processes as it interferes with SSH sessions
        
        if ($script:SearchPowerShell) {
            $script:SearchPowerShell.Stop()
            $script:SearchPowerShell.Dispose()
            $script:SearchPowerShell = $null
        }
        
        if ($script:SearchRunspace) {
            $script:SearchRunspace.Close()
            $script:SearchRunspace.Dispose()
            $script:SearchRunspace = $null
        }
        
        $script:SearchAsyncResult = $null
    } catch {
        # Cleanup errors are non-critical
    }
}

function Test-NetworkConnectivity {
    try {
        # Test multiple endpoints to ensure reliability
        $endpoints = @("8.8.8.8", "1.1.1.1", "aws.amazon.com")
        $ping = New-Object System.Net.NetworkInformation.Ping
        $timeout = 2000  # 2 seconds
        
        foreach ($endpoint in $endpoints) {
            try {
                $result = $ping.Send($endpoint, $timeout)
                if ($result.Status -eq "Success") {
                    return @{ IsConnected = $true; Message = "Connected" }
                }
            } catch {
                # Try next endpoint
                continue
            }
        }
        
        # If all endpoints fail, check if it's truly offline
        try {
            $networkAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.MediaType -ne "Unspecified" }
            if ($networkAdapters.Count -eq 0) {
                return @{ IsConnected = $false; Message = "No network connection" }
            } else {
                # Network adapters are up but ping failed - might be firewall/corporate network
                return @{ IsConnected = $true; Message = "Connected (limited connectivity)" }
            }
        } catch {
            # Fallback - assume connected if we can't determine adapter status
            return @{ IsConnected = $true; Message = "Connected (status unknown)" }
        }
    } catch {
        # If everything fails, assume connected to avoid blocking
        return @{ IsConnected = $true; Message = "Connected (test failed)" }
    } finally {
        if ($ping) { $ping.Dispose() }
    }
}

function Update-CommandFrameworkPermissions {
    param([string]$ProfileName)
    
    # This function is a placeholder for future command framework
    # Currently not implemented in modular version
    Write-Verbose "Command framework permissions update requested for profile: $ProfileName"
}

function Update-RecentProfiles {
    param([string]$ProfileName)
    
    if (-not $ProfileName) { return }
    
    try {
        $settings = Get-Settings
        
        # Initialize RecentProfiles if it doesn't exist
        if (-not $settings.RecentProfiles) {
            $settings | Add-Member -NotePropertyName 'RecentProfiles' -NotePropertyValue @() -Force
        }
        
        # Add to recent profiles (max 5)
        $recent = @($ProfileName)
        if ($settings.RecentProfiles) {
            $recent += $settings.RecentProfiles | Where-Object { $_ -ne $ProfileName } | Select-Object -First 4
        }
        
        $settings.RecentProfiles = $recent
        Set-Settings $settings
    } catch {
        Write-Warning "Failed to update recent profiles: $($_.Exception.Message)"
    }
}

function Start-SsoLogin {
    $profileName = $cmbProfile.Text.Trim()
    if (-not $profileName) {
        [System.Windows.MessageBox]::Show("Please select a profile first.", "SSO Login", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    try {
        $lblProfileStatus.Content = "Starting SSO login..."
        $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Orange)
        $btnSsoLogin.IsEnabled = $false
        
        # Start SSO login process with output capture
        $tempFile = [System.IO.Path]::GetTempFileName()
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "aws"
        $processInfo.Arguments = "sso login --profile $profileName"
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null
        
        # Monitor for URL in output and process completion
        Start-Job -ScriptBlock {
            param($ProcessId, $ProfileName)
            
            $ssoUrl = $null
            $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            
            if ($proc) {
                # Try to capture output while process is running
                Start-Sleep -Seconds 1
                try {
                    $output = $proc.StandardOutput.ReadToEnd()
                    if ($output -match "https://[^\s]+") {
                        $ssoUrl = $matches[0]
                    }
                } catch {
                    # Output capture failed, continue without URL
                }
                
                $proc.WaitForExit()
            }
            
            return @{ ProfileName = $ProfileName; Completed = $true; SsoUrl = $ssoUrl }
        } -ArgumentList $process.Id, $profileName | Out-Null
        
        # Start timer to check for completion
        Start-SsoLoginTimer
        
    } catch {
        $lblProfileStatus.Content = "SSO login failed: $($_.Exception.Message)"
        $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
        $btnSsoLogin.IsEnabled = $true
    }
}

function Start-SsoLoginTimer {
    if ($script:SsoLoginTimer) {
        $script:SsoLoginTimer.Stop()
    }
    
    $script:SsoLoginTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SsoLoginTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:SsoLoginTimer.Add_Tick({
        # Check if SSO login job completed
        $completedJobs = Get-Job | Where-Object { $_.State -eq "Completed" }
        if ($completedJobs) {
            $jobResult = $completedJobs | Receive-Job
            $completedJobs | Remove-Job
            $script:SsoLoginTimer.Stop()
            
            # Show URL if captured, otherwise show completion message
            if ($jobResult.SsoUrl) {
                $txtSsoUrl.Text = "Fallback URL: $($jobResult.SsoUrl)"
                $pnlSsoUrl.Visibility = [System.Windows.Visibility]::Visible
            } else {
                $txtSsoUrl.Text = "SSO login completed in browser"
                $pnlSsoUrl.Visibility = [System.Windows.Visibility]::Visible
            }
            
            # Check status after login
            Start-Sleep -Seconds 1
            Test-ProfileSsoStatus
            $btnSsoLogin.IsEnabled = $true
        }
    })
    $script:SsoLoginTimer.Start()
}

function Start-SsoLogout {
    $profileName = $cmbProfile.Text.Trim()
    if (-not $profileName) {
        [System.Windows.MessageBox]::Show("Please select a profile first.", "SSO Logout", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    # Warn user that this will log out ALL SSO sessions
    $result = [System.Windows.MessageBox]::Show(
        "WARNING: AWS CLI will log out of ALL SSO sessions, not just the selected profile ($profileName).`n`nThis will affect all AWS SSO profiles including those used in other applications like VS Code.`n`nDo you want to continue?", 
        "SSO Logout - All Sessions", 
        [System.Windows.MessageBoxButton]::YesNo, 
        [System.Windows.MessageBoxImage]::Warning
    )
    
    if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }
    
    try {
        $lblProfileStatus.Content = "Logging out of all SSO sessions..."
        $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Orange)
        $btnSsoLogout.IsEnabled = $false
        
        # Execute SSO logout (logs out ALL SSO sessions)
        $result = & aws sso logout 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $lblProfileStatus.Content = "❌ All SSO Sessions Logged Out"
            $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
            $btnSsoLogin.Visibility = [System.Windows.Visibility]::Visible
            $btnSsoLogout.Visibility = [System.Windows.Visibility]::Collapsed
            $pnlSsoUrl.Visibility = [System.Windows.Visibility]::Collapsed
        } else {
            $lblProfileStatus.Content = "Logout failed"
            $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
        }
        
    } catch {
        $lblProfileStatus.Content = "Logout error: $($_.Exception.Message)"
        $lblProfileStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
    } finally {
        $btnSsoLogout.IsEnabled = $true
    }
}

# Connection Management Functions
function Get-AvailablePort {
    param([int]$StartPort = 49152, [int]$EndPort = 65535)
    
    for ($port = $StartPort; $port -le $EndPort; $port++) {
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
            $listener.Start()
            $listener.Stop()
            return $port
        } catch {
            # Port in use, try next
        } finally {
            if ($listener) { $listener.Stop() }
        }
    }
    throw "No available ports in range $StartPort-$EndPort"
}

function Start-RDPConnection {
    param([string]$InstanceId, [string]$ProfileName)
    
    try {
        # Get instance region from current selection
        $selectedInstance = $global:dgEC2.SelectedItem
        $region = if ($selectedInstance) { $selectedInstance.Region } else { "us-east-1" }
        
        # Simple RDP connection like the working backup version
        $localPort = Get-Random -Minimum 13389 -Maximum 65000
        $sessionArgs = "ssm start-session --target $InstanceId --document-name AWS-StartPortForwardingSession --parameters portNumber=3389,localPortNumber=$localPort --region $region --profile $ProfileName"
        
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c aws $sessionArgs"
        Start-Process -FilePath "mstsc.exe" -ArgumentList "/v:127.0.0.1:$localPort"
        
        return @{
            Success = $true
            LocalPort = $localPort
            Message = "RDP connection established on port $localPort"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to start RDP connection: $($_.Exception.Message)"
        }
    }
}

function Start-SSHConnection {
    param([string]$InstanceId, [string]$ProfileName)
    
    try {
        # Get instance region from current selection
        $selectedInstance = $global:dgEC2.SelectedItem
        $region = if ($selectedInstance) { $selectedInstance.Region } else { "us-east-1" }
        
        # Simple SSH connection exactly like the working backup version
        $sessionArgs = "ssm start-session --target $InstanceId --region $region --profile $ProfileName"
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c aws $sessionArgs"
        
        return @{
            Success = $true
            Message = "SSH session started for instance $InstanceId"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to start SSH connection: $($_.Exception.Message)"
        }
    }
}

function Start-PortForward {
    param([string]$InstanceId, [int]$RemotePort, [string]$ProfileName)
    
    try {
        # Get instance region from current selection
        $selectedInstance = $global:dgEC2.SelectedItem
        $region = if ($selectedInstance) { $selectedInstance.Region } else { "us-east-1" }
        
        # Simple port forwarding like the working backup version
        $localPort = Get-Random -Minimum 13389 -Maximum 65000
        $sessionArgs = "ssm start-session --target $InstanceId --document-name AWS-StartPortForwardingSession --parameters portNumber=$RemotePort,localPortNumber=$localPort --region $region --profile $ProfileName"
        
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c aws $sessionArgs"
        
        return @{
            Success = $true
            LocalPort = $localPort
            RemotePort = $RemotePort
            Message = "Port forwarding established: localhost:$localPort -> ${InstanceId}:$RemotePort"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to start port forwarding: $($_.Exception.Message)"
        }
    }
}

function Invoke-SSMCommand {
    param(
        [string]$InstanceId,
        [string]$Command,
        [string]$DocumentName,
        [string]$ProfileName,
        [string]$InstanceName
    )
    
    try {
        # Get instance region from current selection
        $selectedInstance = $global:dgEC2.SelectedItem
        $region = if ($selectedInstance) { $selectedInstance.Region } else { "us-east-1" }
        
        $global:lblStatus.Content = "Executing command on $InstanceName..."
        
        # Execute SSM send-command
        $commandArgs = @(
            "ssm", "send-command",
            "--instance-ids", $InstanceId,
            "--document-name", $DocumentName,
            "--parameters", "commands='$Command'",
            "--region", $region,
            "--profile", $ProfileName,
            "--output", "json"
        )
        
        $result = & aws @commandArgs 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            try {
                $commandResult = $result | ConvertFrom-Json
                $commandId = $commandResult.Command.CommandId
                
                $global:lblStatus.Content = "✅ Command sent to $InstanceName - ID: $($commandId.Substring(0,8))..."
                
                # Show result notification
                [System.Windows.MessageBox]::Show(
                    "Command executed successfully!`n`nCommand ID: $commandId`n`nYou can check the results in the Connection Manager or AWS Console.", 
                    "Command Executed", 
                    [System.Windows.MessageBoxButton]::OK, 
                    [System.Windows.MessageBoxImage]::Information
                )
                
                return @{
                    Success = $true
                    CommandId = $commandId
                    Message = "Command executed successfully"
                }
            } catch {
                $global:lblStatus.Content = "✅ Command sent to $InstanceName (parsing failed)"
                return @{
                    Success = $true
                    Message = "Command sent but response parsing failed"
                }
            }
        } else {
            $errorMsg = if ($result) { $result -join " " } else { "Unknown error" }
            $global:lblStatus.Content = "❌ Command failed: $errorMsg"
            
            [System.Windows.MessageBox]::Show(
                "Command execution failed:`n`n$errorMsg", 
                "Command Failed", 
                [System.Windows.MessageBoxButton]::OK, 
                [System.Windows.MessageBoxImage]::Error
            )
            
            return @{
                Success = $false
                Message = $errorMsg
            }
        }
    } catch {
        $global:lblStatus.Content = "❌ Command error: $($_.Exception.Message)"
        return @{
            Success = $false
            Message = $_.Exception.Message
        }
    }
}

# Simplified connection management - no complex tracking
function Get-ActiveConnections {
    # Return empty array - no connection tracking to avoid interference
    return @()
}

# Add missing Test-AWSProfile function for test compatibility
function Test-AWSProfile {
    param([string]$ProfileName)
    if (-not $ProfileName) { return $false }
    
    try {
        $profiles = & aws configure list-profiles 2>$null
        return ($LASTEXITCODE -eq 0 -and $ProfileName -in ($profiles -split "`n" | Where-Object { $_.Trim() }))
    } catch {
        return $false
    }
}

Export-ModuleMember -Function Get-AwsProfiles, Test-ProfileSsoStatus, Search-EC2Instances, Test-NetworkConnectivity, Update-CommandFrameworkPermissions, Update-RecentProfiles, Stop-SearchJob, Stop-SsoCheckJob, Start-SsoLogin, Start-SsoLoginTimer, Start-SsoLogout, Get-AvailablePort, Start-RDPConnection, Start-SSHConnection, Start-PortForward, Invoke-SSMCommand, Get-ActiveConnections, Test-AWSProfile