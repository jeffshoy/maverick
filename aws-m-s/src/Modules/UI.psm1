# UI module - Event handlers and UI functions

# Validation constants for inline validation
$script:DangerousChars = @('`', '$', '&', '|', ';', '<', '>', '"', "'", '\', '/', '(', ')')

function Initialize-EventHandlers {
    # Check if essential UI elements are available
    if (-not $global:btnRefreshProfiles -or -not $global:btnCheckStatus -or -not $global:btnSearch) {
        Write-Warning "Essential UI elements not available for event handler initialization"
        return
    }
    
    # Initialize filter dropdowns first
    try { Initialize-FilterDropdowns } catch { Write-Warning "Filter dropdown initialization failed: $($_.Exception.Message)" }
    
    # Initialize name filter placeholder
    try { Initialize-NameFilterPlaceholder } catch { Write-Warning "Name filter placeholder initialization failed: $($_.Exception.Message)" }
    
    # Add validation to text input fields
    try { Initialize-InputValidation } catch { Write-Warning "Input validation initialization failed: $($_.Exception.Message)" }
    
    # Initialize search history and favorites
    try { Initialize-SearchHistoryAndFavorites } catch { Write-Warning "Search history initialization failed: $($_.Exception.Message)" }
    
    # Profile events
    if ($global:btnRefreshProfiles) { $global:btnRefreshProfiles.Add_Click({ Get-AwsProfiles }) }
    if ($global:btnCheckStatus) { $global:btnCheckStatus.Add_Click({ Test-ProfileSsoStatus }) }
    if ($global:btnSsoLogin) { $global:btnSsoLogin.Add_Click({ Start-SsoLogin }) }
    if ($global:btnSsoLogout) { $global:btnSsoLogout.Add_Click({ Start-SsoLogout }) }
    
    # Service tab change events
    if ($global:tcServices) {
        $global:tcServices.Add_SelectionChanged({
            try {
                if ($global:tcServices.SelectedItem -and $global:tcServices.SelectedItem.Tag) {
                    $serviceKey = $global:tcServices.SelectedItem.Tag
                    Set-CurrentService -ServiceKey $serviceKey
                    
                    # Update search button text based on selected service
                    $serviceConfig = Get-ServiceConfig -ServiceKey $serviceKey
                    if ($serviceConfig) {
                        $global:btnSearch.Content = "🔍 Search $($serviceConfig.Name)"
                    }
                } elseif ($global:tcServices.SelectedItem -and $global:tcServices.SelectedItem.Name -eq 'tabEC2') {
                    # Handle EC2 tab specifically
                    Set-CurrentService -ServiceKey 'EC2'
                    $global:btnSearch.Content = "🔍 Search Instances"
                }
            } catch {
                Write-Verbose "Service tab change error: $($_.Exception.Message)"
            }
        })
    }
    
    # Search events - service-aware search
    if ($global:btnSearch) {
        $global:btnSearch.Add_Click({
            if ($global:btnSearch.Content -like "🔍 Search*") {
                $profileName = if ($global:cmbProfile) { $global:cmbProfile.Text.Trim() } else { "" }
                if ($profileName) {
                    # Get current service from selected tab
                    $currentService = 'EC2'  # Default
                    if ($global:tcServices -and $global:tcServices.SelectedItem -and $global:tcServices.SelectedItem.Tag) {
                        $currentService = $global:tcServices.SelectedItem.Tag
                    }
                    
                    if ($currentService -eq 'EC2') {
                        Search-EC2Instances -ProfileName $profileName
                    } else {
                        try {
                            Search-AWSService -ServiceKey $currentService -ProfileName $profileName
                        } catch {
                            if ($global:lblStatus) { $global:lblStatus.Content = "Search failed for $currentService" }
                        }
                    }
                }
            } else {
                # Cancel search
                Stop-SearchJob
                try { Stop-AllServiceSearchJobs } catch { }
                if ($global:btnSearch) {
                    $global:btnSearch.IsEnabled = $true
                    $global:btnSearch.Content = "🔍 Search Instances"
                }
                if ($global:lblStatus) { $global:lblStatus.Content = "Search cancelled" }
            }
        })
    }
    
    # History and favorites events
    $cmbSearchHistory.Add_SelectionChanged({ 
        try {
            Apply-SearchFromHistory
        } catch {
            Write-Verbose "History selection error: $($_.Exception.Message)"
        }
    })
    $cmbFavorites.Add_SelectionChanged({ Apply-SearchFromFavorite })
    $btnAddFavorite.Add_Click({ Show-AddFavoriteDialog })
    $btnRemoveFavorite.Add_Click({ Show-RemoveFavoriteDialog })
    
    # Filter events with debounced search history capture - with defensive programming
    $txtNameFilter.Add_TextChanged({ 
        try {
            # Always try to apply filters when text changes
            Set-InstanceFilters
            Start-SearchHistoryTimer
        } catch {
            # Prevent TextStore crashes during text input
            Write-Verbose "Text filter error: $($_.Exception.Message)"
        }
    })
    $cmbStateFilter.Add_SelectionChanged({ 
        try {
            if ($global:dgEC2 -and $global:OriginalItems) {
                Set-InstanceFilters
            }
        } catch {
            # Prevent filter crashes
        }
    })
    $cmbTypeFilter.Add_SelectionChanged({ 
        try {
            if ($global:dgEC2 -and $global:OriginalItems) {
                Set-InstanceFilters
            }
        } catch {
            # Prevent filter crashes
        }
    })
    
    # Auto-refresh events
    $chkAutoRefresh.Add_Checked({ Start-AutoRefresh })
    $chkAutoRefresh.Add_Unchecked({ Stop-AutoRefresh })
    
    # Connection management events
    $miRDPConnection.Add_Click({ Start-InstanceRDPConnection })
    $miSSHConnection.Add_Click({ Start-InstanceSSHConnection })
    $miPortForward.Add_Click({ Show-PortForwardDialog })
    $miSendCommand.Add_Click({ Show-SendCommandDialog })
    
    # Connection manager button event
    if ($global:btnConnectionManager) { 
        $global:btnConnectionManager.Add_Click({ Switch-ConnectionManagerPanel }) 
        Write-Verbose "Connection manager button event registered"
    }
    
    # Settings button event
    if ($global:btnSettings) { 
        $global:btnSettings.Add_Click({ 
            Write-Host "Settings button clicked!" -ForegroundColor Green
            Switch-SettingsPanel 
        }) 
        Write-Verbose "Settings button event registered"
    } else {
        Write-Warning "Settings button not found - cannot register event handler"
    }
}

function Initialize-NameFilterPlaceholder {
    # Set initial watermark
    Set-TextBoxWatermark $txtNameFilter "Filter by instance name..."
}

function Set-TextBoxWatermark {
    param($TextBox, $WatermarkText)
    
    $TextBox.Text = $WatermarkText
    $TextBox.Foreground = [System.Windows.Media.Brushes]::Gray
    
    $TextBox.Add_GotFocus({
        if ($TextBox.Text -eq $WatermarkText) {
            $TextBox.Text = ""
            $TextBox.Foreground = [System.Windows.Media.Brushes]::Black
        }
    }.GetNewClosure())
    
    $TextBox.Add_LostFocus({
        if ($TextBox.Text -eq "") {
            $TextBox.Text = $WatermarkText
            $TextBox.Foreground = [System.Windows.Media.Brushes]::Gray
        }
    }.GetNewClosure())
}

function Initialize-FilterDropdowns {
    # Initialize state filter with placeholder
    $cmbStateFilter.Items.Clear()
    $cmbStateFilter.Items.Add("-- Instance States --") | Out-Null
    $cmbStateFilter.Items.Add("All States") | Out-Null
    $cmbStateFilter.Items.Add("running") | Out-Null
    $cmbStateFilter.Items.Add("stopped") | Out-Null
    $cmbStateFilter.Items.Add("stopping") | Out-Null
    $cmbStateFilter.Items.Add("pending") | Out-Null
    $cmbStateFilter.Items.Add("terminated") | Out-Null
    $cmbStateFilter.SelectedIndex = 0
    
    # Initialize type filter with placeholder
    $cmbTypeFilter.Items.Clear()
    $cmbTypeFilter.Items.Add("-- Instance Types --") | Out-Null
    $cmbTypeFilter.Items.Add("All Types") | Out-Null
    $cmbTypeFilter.Items.Add("t3.micro") | Out-Null
    $cmbTypeFilter.Items.Add("t3.small") | Out-Null
    $cmbTypeFilter.Items.Add("t3.medium") | Out-Null
    $cmbTypeFilter.Items.Add("t3.large") | Out-Null
    $cmbTypeFilter.Items.Add("m5.large") | Out-Null
    $cmbTypeFilter.Items.Add("m5.xlarge") | Out-Null
    $cmbTypeFilter.Items.Add("m5a.large") | Out-Null
    $cmbTypeFilter.Items.Add("m5a.xlarge") | Out-Null
    $cmbTypeFilter.Items.Add("m5a.2xlarge") | Out-Null
    $cmbTypeFilter.Items.Add("c5a.xlarge") | Out-Null
    $cmbTypeFilter.Items.Add("c5a.2xlarge") | Out-Null
    $cmbTypeFilter.SelectedIndex = 0
}

function Set-ComboBoxWatermark {
    param($ComboBox, $WatermarkText)
    
    $ComboBox.Text = $WatermarkText
    $ComboBox.Foreground = [System.Windows.Media.Brushes]::Gray
    
    $ComboBox.Add_GotFocus({
        if ($ComboBox.Text -eq $WatermarkText) {
            $ComboBox.Text = ""
            $ComboBox.Foreground = [System.Windows.Media.Brushes]::Black
        }
    }.GetNewClosure())
    
    $ComboBox.Add_LostFocus({
        if ($ComboBox.Text -eq "" -and $ComboBox.SelectedIndex -lt 0) {
            $ComboBox.Text = $WatermarkText
            $ComboBox.Foreground = [System.Windows.Media.Brushes]::Gray
        }
    }.GetNewClosure())
}

function Set-InstanceFilters {
    # Defensive check - ensure we have valid UI elements
    if (-not $global:dgEC2) { 
        Write-Verbose "DataGrid not available for filtering"
        return 
    }
    
    # Get current items from DataGrid if OriginalItems not set
    if (-not $global:OriginalItems -and $global:dgEC2.ItemsSource) {
        try {
            $global:OriginalItems = @($global:dgEC2.ItemsSource)
            Write-Verbose "Initialized OriginalItems from DataGrid with $($global:OriginalItems.Count) items"
        } catch {
            # If conversion fails, initialize as empty array
            $global:OriginalItems = @()
            Write-Verbose "Failed to initialize OriginalItems from DataGrid"
        }
    }
    
    # Ensure OriginalItems is always an array
    if (-not $global:OriginalItems) {
        $global:OriginalItems = @()
    }
    
    if ($global:OriginalItems.Count -eq 0) { 
        Write-Verbose "No items available for filtering"
        return 
    }
    
    try {
        # Safely get text content
        $nameFilter = ""
        if ($txtNameFilter -and $txtNameFilter.Text) {
            $nameFilter = $txtNameFilter.Text.Trim()
        }
        
        $stateFilter = $cmbStateFilter.SelectedItem
        $typeFilter = $cmbTypeFilter.SelectedItem
        
        # Handle placeholder text in filters
        if ($stateFilter -eq "-- Instance States --" -or -not $stateFilter) { $stateFilter = "All States" }
        if ($typeFilter -eq "-- Instance Types --" -or -not $typeFilter) { $typeFilter = "All Types" }
        
        # Handle placeholder text and make case-insensitive
        if ($nameFilter -eq "Filter by instance name...") {
            $nameFilter = ""
        }
        # Make name filter case-insensitive by converting to lowercase
        if ($nameFilter -ne "") {
            $nameFilter = $nameFilter.ToLower()
        }
        
        # Apply filters to original items - ensure we have valid items to filter
        if (-not $global:OriginalItems -or $global:OriginalItems.Count -eq 0) {
            return
        }
        
        # Ensure we're working with a proper array
        $itemsToFilter = @($global:OriginalItems)
        if ($itemsToFilter.Count -eq 0) {
            return
        }
        
        # Apply filters - if no filters are active, return all items
        if ($nameFilter -eq "" -and $stateFilter -eq "All States" -and $typeFilter -eq "All Types") {
            $filteredItems = $itemsToFilter
        } else {
            $filteredItems = @($itemsToFilter | Where-Object {
                try {
                    # Name/ID filter - case insensitive matching
                    $nameMatch = $true
                    if ($nameFilter -ne "") {
                        $nameMatch = $false
                        if ($_.Name -and $_.Name.ToLower() -like "*$nameFilter*") {
                            $nameMatch = $true
                        } elseif ($_.InstanceId -and $_.InstanceId.ToLower() -like "*$nameFilter*") {
                            $nameMatch = $true
                        }
                    }
                    
                    # State filter
                    $stateMatch = $true
                    if ($stateFilter -and $stateFilter -ne "All States") {
                        $stateMatch = ($_.State -and $_.State -eq $stateFilter)
                    }
                    
                    # Type filter
                    $typeMatch = $true
                    if ($typeFilter -and $typeFilter -ne "All Types") {
                        $typeMatch = ($_.InstanceType -and $_.InstanceType -eq $typeFilter)
                    }
                    
                    # Return true only if all filters match
                    return ($nameMatch -and $stateMatch -and $typeMatch)
                } catch {
                    # If filtering fails for an item, exclude it
                    return $false
                }
            })
        }
        
        # Update DataGrid with filtered results - use proper collection binding
        if ($global:dgEC2) {
            # Only update if the filtered results are different from current display
            $currentCount = if ($global:dgEC2.Items) { $global:dgEC2.Items.Count } else { 0 }
            
            if ($currentCount -ne $filteredItems.Count) {
                # Clear and rebind to prevent virtualization issues
                $global:dgEC2.ItemsSource = $null
                $global:dgEC2.Items.Clear()
                
                # Force layout update before setting new source
                $global:dgEC2.UpdateLayout()
                
                # Set new items source
                $global:dgEC2.ItemsSource = $filteredItems
                
                # Force another layout update to ensure proper display
                $global:dgEC2.UpdateLayout()
            }
            
            Write-Verbose "Applied filters: $($filteredItems.Count) of $($global:OriginalItems.Count) items match"
        
            # Update count display
            if ($global:lblInstanceCount) {
                if ($filteredItems.Count -eq $global:OriginalItems.Count) {
                    $global:lblInstanceCount.Content = "$($filteredItems.Count) instances"
                } else {
                    $global:lblInstanceCount.Content = "$($filteredItems.Count) of $($global:OriginalItems.Count) instances"
                }
            }
        }
    } catch {
        # Handle filter errors with logging
        Write-Verbose "Filter error: $($_.Exception.Message)"
    }
}

function Update-FilterDropdowns {
    param([array]$Instances)
    
    if (-not $Instances -or $Instances.Count -eq 0) { return }
    
    # Defensive checks for UI elements
    if (-not $cmbStateFilter -or -not $cmbTypeFilter) { return }
    
    try {
        # Store current selections
        $currentState = $cmbStateFilter.SelectedItem
        $currentType = $cmbTypeFilter.SelectedItem
        
        # Update state filter with actual states from results
        $uniqueStates = @($Instances | Where-Object { $_.State } | Select-Object -ExpandProperty State -Unique | Sort-Object)
        $cmbStateFilter.Items.Clear()
        $cmbStateFilter.Items.Add("All States") | Out-Null
        foreach ($state in $uniqueStates) {
            if ($state) {
                $cmbStateFilter.Items.Add($state) | Out-Null
            }
        }
        
        # Update type filter with actual types from results
        $uniqueTypes = @($Instances | Where-Object { $_.InstanceType } | Select-Object -ExpandProperty InstanceType -Unique | Sort-Object)
        $cmbTypeFilter.Items.Clear()
        $cmbTypeFilter.Items.Add("All Types") | Out-Null
        foreach ($type in $uniqueTypes) {
            if ($type) {
                $cmbTypeFilter.Items.Add($type) | Out-Null
            }
        }
    } catch {
        # If dropdown update fails, silently continue
        return
    }
    
    # Restore selections if they still exist
    if ($currentState -and $cmbStateFilter.Items.Contains($currentState)) {
        $cmbStateFilter.SelectedItem = $currentState
    } else {
        $cmbStateFilter.SelectedIndex = 0
    }
    
    if ($currentType -and $cmbTypeFilter.Items.Contains($currentType)) {
        $cmbTypeFilter.SelectedItem = $currentType
    } else {
        $cmbTypeFilter.SelectedIndex = 0
    }
}

function Update-PermissionTreeView {
    $tvPermissions.Items.Clear()
    
    foreach ($service in ($script:PermissionMonitorData.Services | Sort-Object)) {
        $serviceStatus = $script:PermissionMonitorData.ServiceStatus[$service]
        $serviceItem = New-Object System.Windows.Controls.TreeViewItem
        
        $icon = switch ($serviceStatus.Status) {
            'Pending' { '🔴' }
            'InProgress' { '🟡' }
            'Completed' { '🟢' }
            'Failed' { '❌' }
            default { '❔' }
        }
        
        $serviceItem.Foreground = switch ($serviceStatus.Status) {
            'Pending' { [System.Windows.Media.Brushes]::Red }
            'InProgress' { [System.Windows.Media.Brushes]::Orange }
            'Completed' { [System.Windows.Media.Brushes]::Green }
            'Failed' { [System.Windows.Media.Brushes]::Red }
            default { [System.Windows.Media.Brushes]::Gray }
        }
        
        $serviceItem.Header = "$icon $service"
        $serviceItem.Tag = $service
        
        if ($serviceStatus.Verbs.Count -gt 0) {
            foreach ($verb in ($serviceStatus.Verbs.Keys | Sort-Object)) {
                $verbItem = New-Object System.Windows.Controls.TreeViewItem
                $verbItem.Header = "  • $verb"
                $verbItem.Tag = "$service-$verb"
                $verbItem.Foreground = [System.Windows.Media.Brushes]::DarkGreen
                $serviceItem.Items.Add($verbItem) | Out-Null
            }
        }
        
        $tvPermissions.Items.Add($serviceItem) | Out-Null
    }
}

function Show-LoadingProgress {
    param([string]$Message = "Loading...")
    $lblStatus.Content = $Message
}

function Hide-LoadingProgress {
    $lblStatus.Content = "Ready"
}

function Start-AutoRefresh {
    if ($script:AutoRefreshTimer) {
        $script:AutoRefreshTimer.Stop()
    }
    
    $refreshInterval = 120  # 2 minutes default
    
    $script:AutoRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AutoRefreshTimer.Interval = [TimeSpan]::FromSeconds($refreshInterval)
    $script:AutoRefreshTimer.Add_Tick({
        try {
            $profileName = $cmbProfile.Text.Trim()
            if ($profileName -and $chkAutoRefresh.IsChecked) {
                Search-EC2Instances -ProfileName $profileName -IsAutoRefresh $true
            }
        } catch {
            # Auto-refresh errors are non-critical
        }
    })
    $script:AutoRefreshTimer.Start()
    
    $chkAutoRefresh.Content = "Auto Refresh ($refreshInterval`s)"
}

function Stop-AutoRefresh {
    if ($script:AutoRefreshTimer) {
        $script:AutoRefreshTimer.Stop()
        $script:AutoRefreshTimer = $null
    }
}

function Start-AutoSearch {
    param([string]$ProfileName)
    
    if (-not $ProfileName) { return }
    
    Search-EC2Instances -ProfileName $ProfileName -IsAutoSearch $true
    
    if ($chkAutoRefresh.IsChecked) {
        Start-AutoRefresh
    }
}

function Initialize-SearchHistoryAndFavorites {
    Update-SearchHistoryDropdown
    Update-FavoritesDropdown
}

function Update-SearchHistoryDropdown {
    $cmbSearchHistory.Items.Clear()
    $cmbSearchHistory.Items.Add("-- Recent Searches --") | Out-Null
    
    $history = Get-SearchHistory
    if ($history.Count -gt 0) {
        foreach ($item in $history) {
            $cmbSearchHistory.Items.Add($item) | Out-Null
        }
    }
    $cmbSearchHistory.SelectedIndex = 0
}

function Update-FavoritesDropdown {
    $cmbFavorites.Items.Clear()
    $cmbFavorites.Items.Add("-- Saved Searches --") | Out-Null
    
    $favorites = Get-Favorites
    if ($favorites.Count -gt 0) {
        foreach ($favorite in $favorites) {
            $cmbFavorites.Items.Add($favorite.Name) | Out-Null
        }
    }
    $cmbFavorites.SelectedIndex = 0
}

function Initialize-InputValidation {
    # Add real-time validation to name filter textbox
    if ($global:txtNameFilter) {
        $global:txtNameFilter.Add_TextChanged({
            $text = $global:txtNameFilter.Text
            
            # Skip validation for placeholder text
            if ($text -eq "Filter by instance name..." -or $text -eq "") {
                $global:txtNameFilter.Background = "White"
                return
            }
            
            # Inline validation - check for dangerous characters
            $isValid = $true
            foreach ($char in $script:DangerousChars) {
                if ($text.IndexOf($char) -ge 0) {
                    $isValid = $false
                    break
                }
            }
            
            # Update UI based on validation
            if (-not $isValid) {
                $global:txtNameFilter.Background = [System.Windows.Media.Brushes]::LightPink
                $global:lblStatus.Content = "⚠️ Invalid characters detected in filter"
                $global:lblStatus.Foreground = [System.Windows.Media.Brushes]::Red
            } else {
                $global:txtNameFilter.Background = [System.Windows.Media.Brushes]::White
                if ($global:lblStatus.Content -like "*Invalid characters*") {
                    $global:lblStatus.Content = "Ready"
                    $global:lblStatus.Foreground = [System.Windows.Media.Brushes]::Black
                }
            }
        })
    }
    
    # Add validation to profile ComboBox (editable)
    if ($global:cmbProfile) {
        # Use SelectionChanged for dropdown selections
        $global:cmbProfile.Add_SelectionChanged({
            $text = $global:cmbProfile.Text
            if ($text -and $text -ne "") {
                # Inline validation - check for dangerous characters
                $isValid = $true
                foreach ($char in $script:DangerousChars) {
                    if ($text.IndexOf($char) -ge 0) {
                        $isValid = $false
                        break
                    }
                }
                
                # Update UI based on validation
                if (-not $isValid) {
                    $global:cmbProfile.Background = [System.Windows.Media.Brushes]::LightPink
                    $global:lblProfileStatus.Content = "⚠️ Invalid characters in profile name"
                    $global:lblProfileStatus.Foreground = [System.Windows.Media.Brushes]::Red
                } else {
                    $global:cmbProfile.Background = [System.Windows.Media.Brushes]::White
                    if ($global:lblProfileStatus.Content -like "*Invalid characters*") {
                        $global:lblProfileStatus.Content = "Select a profile to check SSO status"
                        $global:lblProfileStatus.Foreground = [System.Windows.Media.Brushes]::Gray
                    }
                }
            }
        })
        
        # Use LostFocus for manual typing validation
        $global:cmbProfile.Add_LostFocus({
            $text = $global:cmbProfile.Text
            if ($text -and $text -ne "") {
                # Inline validation - check for dangerous characters
                $isValid = $true
                foreach ($char in $script:DangerousChars) {
                    if ($text.IndexOf($char) -ge 0) {
                        $isValid = $false
                        break
                    }
                }
                
                # Update UI based on validation
                if (-not $isValid) {
                    $global:cmbProfile.Background = [System.Windows.Media.Brushes]::LightPink
                    $global:lblProfileStatus.Content = "⚠️ Invalid characters in profile name"
                    $global:lblProfileStatus.Foreground = [System.Windows.Media.Brushes]::Red
                } else {
                    $global:cmbProfile.Background = [System.Windows.Media.Brushes]::White
                    if ($global:lblProfileStatus.Content -like "*Invalid characters*") {
                        $global:lblProfileStatus.Content = "Select a profile to check SSO status"
                        $global:lblProfileStatus.Foreground = [System.Windows.Media.Brushes]::Gray
                    }
                }
            }
        })
    }
    
    Write-Verbose "Input validation system initialized with real-time feedback for filter and profile fields"
}

function Get-CurrentSearchTerm {
    if (-not $txtNameFilter -or -not $txtNameFilter.Text) {
        return $null
    }
    
    $searchTerm = $txtNameFilter.Text.Trim()
    if ($searchTerm -eq "Filter by instance name..." -or $searchTerm -eq "") {
        return $null
    }
    
    # Inline validation - check for dangerous characters
    foreach ($char in $script:DangerousChars) {
        if ($searchTerm.IndexOf($char) -ge 0) {
            # Validation handled by UI feedback, no console warnings needed
            return $null
        }
    }
    
    # Length check
    if ($searchTerm.Length -gt 255) {
        # Validation handled by UI feedback, no console warnings needed
        return $null
    }
    
    return $searchTerm
}

function Apply-SearchFromHistory {
    if ($cmbSearchHistory.SelectedIndex -le 0) { return }
    
    $selectedTerm = $cmbSearchHistory.SelectedItem
    if ($selectedTerm -eq "-- Recent Searches --") { return }
    
    $txtNameFilter.Text = $selectedTerm
    $txtNameFilter.Foreground = [System.Windows.Media.Brushes]::Black
    # Force apply filters regardless of data state
    Set-InstanceFilters
    $cmbSearchHistory.SelectedIndex = 0
}

function Apply-SearchFromFavorite {
    if ($cmbFavorites.SelectedIndex -le 0) { return }
    
    $favoriteName = $cmbFavorites.SelectedItem
    if ($favoriteName -eq "-- Saved Searches --") { return }
    
    $favorites = Get-Favorites
    $favorite = $favorites | Where-Object { $_.Name -eq $favoriteName } | Select-Object -First 1
    
    if ($favorite) {
        # Apply search term
        if ($favorite.SearchTerm) {
            $txtNameFilter.Text = $favorite.SearchTerm
            $txtNameFilter.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Black)
        }
        
        # Apply state filter
        if ($favorite.StateFilter -and $cmbStateFilter.Items.Contains($favorite.StateFilter)) {
            $cmbStateFilter.SelectedItem = $favorite.StateFilter
        }
        
        # Apply type filter
        if ($favorite.TypeFilter -and $cmbTypeFilter.Items.Contains($favorite.TypeFilter)) {
            $cmbTypeFilter.SelectedItem = $favorite.TypeFilter
        }
        
        Set-InstanceFilters
    }
    $cmbFavorites.SelectedIndex = 0
}

function Start-SearchHistoryTimer {
    try {
        $currentTerm = Get-CurrentSearchTerm
        
        # Only start timer if search term actually changed
        if ($currentTerm -eq $script:LastSearchTerm) { return }
        
        # Stop existing timer if running
        if ($script:SearchHistoryTimer) {
            $script:SearchHistoryTimer.Stop()
        }
        
        # Update last search term
        $script:LastSearchTerm = $currentTerm
        
        # Start new 3-second timer
        $script:SearchHistoryTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:SearchHistoryTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:SearchHistoryTimer.Add_Tick({
            try {
                Capture-SearchHistory
                $script:SearchHistoryTimer.Stop()
            } catch {
                # Prevent timer crashes
            }
        })
        $script:SearchHistoryTimer.Start()
    } catch {
        # Prevent timer initialization crashes
    }
}

function Capture-SearchHistory {
    $searchTerm = Get-CurrentSearchTerm
    if ($searchTerm) {
        Add-SearchHistory $searchTerm
        Update-SearchHistoryDropdown
    }
}

function Show-AddFavoriteDialog {
    $searchTerm = Get-CurrentSearchTerm
    $stateFilter = if ($cmbStateFilter.SelectedItem -ne "All States") { $cmbStateFilter.SelectedItem } else { "" }
    $typeFilter = if ($cmbTypeFilter.SelectedItem -ne "All Types") { $cmbTypeFilter.SelectedItem } else { "" }
    
    if (-not $searchTerm -and -not $stateFilter -and -not $typeFilter) {
        [System.Windows.MessageBox]::Show("Please set some search criteria before adding to favorites.", "Add Favorite", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    $favoriteName = [Microsoft.VisualBasic.Interaction]::InputBox("Enter a name for this favorite search:", "Add Favorite", "")
    if ($favoriteName.Trim()) {
        Add-Favorite -Name $favoriteName.Trim() -SearchTerm $searchTerm -StateFilter $stateFilter -TypeFilter $typeFilter
        Update-FavoritesDropdown
        $lblStatus.Content = "Added favorite: $($favoriteName.Trim())"
    }
}

function Show-RemoveFavoriteDialog {
    $favorites = Get-Favorites
    if ($favorites.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No favorites to remove.", "Remove Favorite", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    # Create side panel content
    $grid = New-Object System.Windows.Controls.Grid
    
    # Add rows
    for ($i = 0; $i -lt ($favorites.Count + 2); $i++) {
        $row = New-Object System.Windows.Controls.RowDefinition
        $row.Height = "Auto"
        $grid.RowDefinitions.Add($row)
    }
    
    # Title
    $title = New-Object System.Windows.Controls.Label
    $title.Content = "Select favorite to remove:"
    $title.FontWeight = "Bold"
    $title.Margin = "10"
    [System.Windows.Controls.Grid]::SetRow($title, 0)
    $grid.Children.Add($title)
    
    # Create button for each favorite
    for ($i = 0; $i -lt $favorites.Count; $i++) {
        $favPanel = New-Object System.Windows.Controls.StackPanel
        $favPanel.Orientation = "Horizontal"
        $favPanel.Margin = "10,5"
        
        $favLabel = New-Object System.Windows.Controls.Label
        $favLabel.Content = $favorites[$i].Name
        $favLabel.Width = 200
        $favLabel.VerticalAlignment = "Center"
        
        $removeBtn = New-Object System.Windows.Controls.Button
        $removeBtn.Content = "Remove"
        $removeBtn.Width = 60
        $removeBtn.Height = 25
        $removeBtn.Tag = $favorites[$i].Name
        $removeBtn.Add_Click({
            $favName = $this.Tag
            $confirmResult = [System.Windows.MessageBox]::Show("Remove favorite '$favName'?", "Confirm Remove", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($confirmResult -eq [System.Windows.MessageBoxResult]::Yes) {
                Remove-Favorite -Name $favName
                Update-FavoritesDropdown
                $lblStatus.Content = "Removed favorite: $favName"
                # Refresh the panel
                Show-RemoveFavoriteDialog
            }
        })
        
        $favPanel.Children.Add($favLabel)
        $favPanel.Children.Add($removeBtn)
        
        [System.Windows.Controls.Grid]::SetRow($favPanel, $i + 1)
        $grid.Children.Add($favPanel)
    }
    
    # Add to side panel
    Add-SidePanel -Title "Remove Favorites" -Content $grid -Width 300
}

function Start-InstanceRDPConnection {
    $selectedInstance = $dgEC2.SelectedItem
    if (-not $selectedInstance) {
        $lblStatus.Content = "⚠️ Please select an instance first"
        return
    }
    
    $profileName = $cmbProfile.Text.Trim()
    if (-not $profileName) {
        $lblStatus.Content = "⚠️ Please select a profile first"
        return
    }
    
    if ($selectedInstance.State -ne "running") {
        $lblStatus.Content = "⚠️ Instance must be running for RDP connection"
        return
    }
    
    # Auto-open connection manager BEFORE starting connection if enabled
    $userSettings = Get-UserSettings
    if ($userSettings.General.AutoOpenConnectionManager -and $global:SidePanelContainer.Visibility -ne [System.Windows.Visibility]::Visible) {
        Switch-ConnectionManagerPanel
    }
    
    $lblStatus.Content = "Starting RDP connection to $($selectedInstance.Name)..."
    
    try {
        $result = Start-RDPConnection -InstanceId $selectedInstance.InstanceId -ProfileName $profileName
        
        if ($result.Success) {
            $lblStatus.Content = "✅ RDP connection established on port $($result.LocalPort) - Client opened"
            
            # Track this as an RDP connection for proper display
            if (-not $global:RDPConnections) { $global:RDPConnections = @{} }
            $global:RDPConnections[$selectedInstance.InstanceId] = @{
                InstanceId = $selectedInstance.InstanceId
                InstanceName = $selectedInstance.Name
                LocalPort = $result.LocalPort
                StartTime = Get-Date
            }
            
            # Auto-refresh if panel is open
            if ($userSettings.General.AutoOpenConnectionManager -and $global:SidePanelContainer.Visibility -eq [System.Windows.Visibility]::Visible) {
                $refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
                $refreshTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
                $refreshTimer.Add_Tick({
                    Update-ConnectionList
                    $refreshTimer.Stop()
                }.GetNewClosure())
                $refreshTimer.Start()
            }
            # Reset status bar after 5 seconds
            Start-StatusResetTimer
        } else {
            $lblStatus.Content = "❌ RDP connection failed: $($result.Message)"
        }
    } catch {
        $lblStatus.Content = "❌ RDP connection error: $($_.Exception.Message)"
    }
}

function Start-InstanceSSHConnection {
    $selectedInstance = $global:dgEC2.SelectedItem
    if (-not $selectedInstance) {
        $global:lblStatus.Content = "⚠️ Please select an instance first"
        return
    }
    
    $profileName = $global:cmbProfile.Text.Trim()
    if (-not $profileName) {
        $global:lblStatus.Content = "⚠️ Please select a profile first"
        return
    }
    
    if ($selectedInstance.State -ne "running") {
        $global:lblStatus.Content = "⚠️ Instance must be running for SSH connection"
        return
    }
    
    # Enhanced SSO validation - test actual SSM permissions
    $global:lblStatus.Content = "Validating SSO and SSM permissions..."
    try {
        # Test SSM permissions specifically (this will fail with KMS error if SSO is expired)
        $testResult = & aws ssm describe-instance-information --max-items 1 --profile $profileName --region $($selectedInstance.Region) --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errorMsg = $testResult -join " "
            if ($errorMsg -match "KMS|SSO.*expired|Token.*expired|InvalidToken") {
                $global:lblStatus.Content = "❌ SSO session expired - Please refresh SSO login"
                [System.Windows.MessageBox]::Show("Your SSO session has expired or lacks SSM permissions.`n`nPlease:`n1. Click 'Check Status' to refresh`n2. Use 'SSO Login' if needed`n3. Try SSH connection again", "SSO Session Issue", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return
            } else {
                $global:lblStatus.Content = "❌ SSM permissions check failed - Check profile permissions"
                [System.Windows.MessageBox]::Show("SSM permissions test failed. Please verify your profile has SSM permissions.", "Permission Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return
            }
        }
    } catch {
        $global:lblStatus.Content = "❌ SSO validation failed - Please check your profile"
        return
    }
    
    # Auto-open connection manager BEFORE starting connection if enabled
    $userSettings = Get-UserSettings
    if ($userSettings.General.AutoOpenConnectionManager -and $global:SidePanelContainer.Visibility -ne [System.Windows.Visibility]::Visible) {
        Switch-ConnectionManagerPanel
    }
    
    $global:lblStatus.Content = "Starting SSH connection to $($selectedInstance.Name)..."
    
    try {
        $result = Start-SSHConnection -InstanceId $selectedInstance.InstanceId -ProfileName $profileName
        
        if ($result.Success) {
            $global:lblStatus.Content = "✅ SSH session started - Check terminal window"
            # Auto-refresh if panel is open
            if ($userSettings.General.AutoOpenConnectionManager -and $global:SidePanelContainer.Visibility -eq [System.Windows.Visibility]::Visible) {
                $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action]{
                    Start-Sleep -Milliseconds 1500
                    Update-ConnectionList
                })
            }
            Start-StatusResetTimer
        } else {
            $global:lblStatus.Content = "❌ SSH connection failed: $($result.Message)"
        }
    } catch {
        $global:lblStatus.Content = "❌ SSH connection error: $($_.Exception.Message)"
    }
}

function Show-SendCommandDialog {
    $selectedInstance = $dgEC2.SelectedItem
    if (-not $selectedInstance) {
        [System.Windows.MessageBox]::Show("Please select an instance first.", "Send Command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    $profileName = $cmbProfile.Text.Trim()
    if (-not $profileName) {
        [System.Windows.MessageBox]::Show("Please select a profile first.", "Send Command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    if ($selectedInstance.State -ne "running") {
        [System.Windows.MessageBox]::Show("Instance must be in 'running' state for command execution.", "Send Command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    # Create side panel content
    $grid = New-Object System.Windows.Controls.Grid
    
    # Add rows
    for ($i = 0; $i -lt 8; $i++) {
        $row = New-Object System.Windows.Controls.RowDefinition
        $row.Height = "Auto"
        $grid.RowDefinitions.Add($row)
    }
    
    # Title
    $title = New-Object System.Windows.Controls.Label
    $title.Content = "Select command to execute:"
    $title.FontWeight = "Bold"
    $title.Margin = "10"
    [System.Windows.Controls.Grid]::SetRow($title, 0)
    $grid.Children.Add($title)
    
    # Common commands dropdown
    $commonCommands = @(
        @{Name="System Info"; Command="Get-ComputerInfo | Select-Object WindowsProductName, TotalPhysicalMemory, CsProcessors"; Document="AWS-RunPowerShellScript"},
        @{Name="Disk Usage"; Command="Get-WmiObject -Class Win32_LogicalDisk | Select-Object DeviceID, @{Name='Size(GB)';Expression={[math]::Round($_.Size/1GB,2)}}, @{Name='FreeSpace(GB)';Expression={[math]::Round($_.FreeSpace/1GB,2)}}"; Document="AWS-RunPowerShellScript"},
        @{Name="Running Services"; Command="Get-Service | Where-Object {$_.Status -eq 'Running'} | Select-Object Name, Status | Sort-Object Name"; Document="AWS-RunPowerShellScript"},
        @{Name="Network Config"; Command="Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway"; Document="AWS-RunPowerShellScript"},
        @{Name="Event Log Errors"; Command="Get-EventLog -LogName System -EntryType Error -Newest 10 | Select-Object TimeGenerated, Source, Message"; Document="AWS-RunPowerShellScript"},
        @{Name="Linux - System Info"; Command="uname -a && df -h && free -h"; Document="AWS-RunShellScript"},
        @{Name="Linux - Process List"; Command="ps aux --sort=-%cpu | head -20"; Document="AWS-RunShellScript"}
    )
    
    $cmbCommands = New-Object System.Windows.Controls.ComboBox
    $cmbCommands.Margin = "10,5"
    $cmbCommands.Height = 25
    $cmbCommands.Items.Add("Select a command...") | Out-Null
    foreach ($cmd in $commonCommands) {
        $cmbCommands.Items.Add($cmd.Name) | Out-Null
    }
    $cmbCommands.SelectedIndex = 0
    [System.Windows.Controls.Grid]::SetRow($cmbCommands, 1)
    $grid.Children.Add($cmbCommands)
    
    # Custom command section
    $customLabel = New-Object System.Windows.Controls.Label
    $customLabel.Content = "Or enter custom command:"
    $customLabel.Margin = "10,10,10,5"
    [System.Windows.Controls.Grid]::SetRow($customLabel, 2)
    $grid.Children.Add($customLabel)
    
    $txtCustomCommand = New-Object System.Windows.Controls.TextBox
    $txtCustomCommand.Margin = "10,0,10,5"
    $txtCustomCommand.Height = 60
    $txtCustomCommand.AcceptsReturn = $true
    $txtCustomCommand.TextWrapping = "Wrap"
    $txtCustomCommand.VerticalScrollBarVisibility = "Auto"
    [System.Windows.Controls.Grid]::SetRow($txtCustomCommand, 3)
    $grid.Children.Add($txtCustomCommand)
    
    # Document type selection
    $docLabel = New-Object System.Windows.Controls.Label
    $docLabel.Content = "Document type:"
    $docLabel.Margin = "10,5,10,0"
    [System.Windows.Controls.Grid]::SetRow($docLabel, 4)
    $grid.Children.Add($docLabel)
    
    $cmbDocument = New-Object System.Windows.Controls.ComboBox
    $cmbDocument.Margin = "10,0,10,5"
    $cmbDocument.Height = 25
    $cmbDocument.Items.Add("AWS-RunPowerShellScript") | Out-Null
    $cmbDocument.Items.Add("AWS-RunShellScript") | Out-Null
    $cmbDocument.SelectedIndex = 0
    [System.Windows.Controls.Grid]::SetRow($cmbDocument, 5)
    $grid.Children.Add($cmbDocument)
    
    # Execute button
    $btnExecute = New-Object System.Windows.Controls.Button
    $btnExecute.Content = "Execute Command"
    $btnExecute.Margin = "10,10,10,5"
    $btnExecute.Height = 30
    $btnExecute.Add_Click({
        $command = ""
        $document = $cmbDocument.SelectedItem
        
        if ($cmbCommands.SelectedIndex -gt 0) {
            $selectedCmd = $commonCommands[$cmbCommands.SelectedIndex - 1]
            $command = $selectedCmd.Command
            $document = $selectedCmd.Document
        } elseif ($txtCustomCommand.Text.Trim()) {
            $command = $txtCustomCommand.Text.Trim()
        }
        
        if ($command) {
            Invoke-SSMCommand -InstanceId $selectedInstance.InstanceId -Command $command -DocumentName $document -ProfileName $profileName -InstanceName $selectedInstance.Name
        } else {
            [System.Windows.MessageBox]::Show("Please select a command or enter a custom command.", "No Command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
    })
    [System.Windows.Controls.Grid]::SetRow($btnExecute, 6)
    $grid.Children.Add($btnExecute)
    
    # Update command text when dropdown changes
    $cmbCommands.Add_SelectionChanged({
        if ($cmbCommands.SelectedIndex -gt 0) {
            $selectedCmd = $commonCommands[$cmbCommands.SelectedIndex - 1]
            $txtCustomCommand.Text = $selectedCmd.Command
            $cmbDocument.SelectedItem = $selectedCmd.Document
        }
    })
    
    # Add to side panel
    Add-SidePanel -Title "Send Command - $($selectedInstance.Name)" -Content $grid -Width 400
}

function Show-PortForwardDialog {
    $selectedInstance = $dgEC2.SelectedItem
    if (-not $selectedInstance) {
        [System.Windows.MessageBox]::Show("Please select an instance first.", "Port Forward", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    $profileName = $cmbProfile.Text.Trim()
    if (-not $profileName) {
        [System.Windows.MessageBox]::Show("Please select a profile first.", "Port Forward", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    if ($selectedInstance.State -ne "running") {
        [System.Windows.MessageBox]::Show("Instance must be in 'running' state for port forwarding.", "Port Forward", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    # Create side panel content
    $grid = New-Object System.Windows.Controls.Grid
    
    # Add rows
    for ($i = 0; $i -lt 10; $i++) {
        $row = New-Object System.Windows.Controls.RowDefinition
        $row.Height = "Auto"
        $grid.RowDefinitions.Add($row)
    }
    
    # Title
    $title = New-Object System.Windows.Controls.Label
    $title.Content = "Select port to forward:"
    $title.FontWeight = "Bold"
    $title.Margin = "10"
    [System.Windows.Controls.Grid]::SetRow($title, 0)
    $grid.Children.Add($title)
    
    # Common port buttons
    $commonPorts = @(
        @{Port=3306; Name="MySQL"},
        @{Port=5432; Name="PostgreSQL"},
        @{Port=1433; Name="SQL Server"},
        @{Port=6379; Name="Redis"},
        @{Port=27017; Name="MongoDB"},
        @{Port=8080; Name="HTTP Alt"},
        @{Port=9200; Name="Elasticsearch"}
    )
    
    for ($i = 0; $i -lt $commonPorts.Count; $i++) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = "$($commonPorts[$i].Port) ($($commonPorts[$i].Name))"
        $btn.Margin = "10,5"
        $btn.Height = 30
        $btn.Tag = $commonPorts[$i].Port
        $btn.Add_Click({
            Start-PortForwardConnection -RemotePort $this.Tag -Instance $selectedInstance -ProfileName $profileName
        })
        [System.Windows.Controls.Grid]::SetRow($btn, $i + 1)
        $grid.Children.Add($btn)
    }
    
    # Custom port section
    $customLabel = New-Object System.Windows.Controls.Label
    $customLabel.Content = "Or enter custom port:"
    $customLabel.Margin = "10,10,10,5"
    [System.Windows.Controls.Grid]::SetRow($customLabel, 8)
    $grid.Children.Add($customLabel)
    
    $customTextBox = New-Object System.Windows.Controls.TextBox
    $customTextBox.Margin = "10,0,10,5"
    $customTextBox.Height = 25
    [System.Windows.Controls.Grid]::SetRow($customTextBox, 9)
    $grid.Children.Add($customTextBox)
    
    # OK button for custom port
    $okBtn = New-Object System.Windows.Controls.Button
    $okBtn.Content = "Start Port Forward"
    $okBtn.Margin = "10,5"
    $okBtn.Height = 30
    $okBtn.Add_Click({
        $customPort = $customTextBox.Text.Trim()
        if ($customPort -and [int]::TryParse($customPort, [ref]$null)) {
            $port = [int]$customPort
            if ($port -gt 0 -and $port -le 65535) {
                Start-PortForwardConnection -RemotePort $port -Instance $selectedInstance -ProfileName $profileName
            } else {
                [System.Windows.MessageBox]::Show("Please enter a valid port number (1-65535).", "Invalid Port", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            }
        } else {
            [System.Windows.MessageBox]::Show("Please enter a valid port number.", "Invalid Port", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
    })
    [System.Windows.Controls.Grid]::SetRow($okBtn, 10)
    $grid.Children.Add($okBtn)
    
    # Add to side panel
    Add-SidePanel -Title "Port Forward - $($selectedInstance.Name)" -Content $grid -Width 320
}

function Show-ActiveConnectionsDialog {
    Show-ConnectionManagerPanel
}

# Phase 1: Basic Connection Manager Panel Functions (UI Only - No Background Processing)
function Switch-ConnectionManagerPanel {
    # Use the global window variable directly
    $window = $global:window
    
    if ($global:SidePanelContainer.Visibility -eq [System.Windows.Visibility]::Visible) {
        # Hide panel and restore window width
        $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Collapsed
        $global:SidePanelContainer.Children.Clear()
        if ($window) { $window.Width = $window.Width - 420 }  # Remove panel width
        $global:btnConnectionManager.Content = "🔗 Connections"
        $global:btnConnectionManager.Background = [System.Windows.Media.Brushes]::LightGray
    } else {
        # Show panel and expand window width
        Show-ConnectionManagerPanel
        if ($window) { $window.Width = $window.Width + 420 }  # Add panel width
        $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Visible
        $global:btnConnectionManager.Content = "🔗 Active"
        $global:btnConnectionManager.Background = [System.Windows.Media.Brushes]::LightGreen
    }
}

function Show-ConnectionManagerPanel {
    # Clear existing panels
    $global:SidePanelContainer.Children.Clear()
    
    # Create connection manager panel - Fixed width to prevent blocking
    $panel = New-Object System.Windows.Controls.GroupBox
    $panel.Header = "🔗 Connection Manager"
    $panel.Width = 400
    $panel.MaxWidth = 400
    $panel.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
    $panel.Padding = New-Object System.Windows.Thickness(10)
    
    # Create panel content grid
    $grid = New-Object System.Windows.Controls.Grid
    
    # Add row definitions
    $row1 = New-Object System.Windows.Controls.RowDefinition
    $row1.Height = [System.Windows.GridLength]::Auto
    $row2 = New-Object System.Windows.Controls.RowDefinition
    $row2.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $row3 = New-Object System.Windows.Controls.RowDefinition
    $row3.Height = [System.Windows.GridLength]::Auto
    
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)
    $grid.RowDefinitions.Add($row3)
    
    # Header with close button
    $headerGrid = New-Object System.Windows.Controls.Grid
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = [System.Windows.GridLength]::Auto
    $headerGrid.ColumnDefinitions.Add($col1)
    $headerGrid.ColumnDefinitions.Add($col2)
    
    $headerLabel = New-Object System.Windows.Controls.Label
    $headerLabel.Content = "Active Connections:"
    $headerLabel.FontWeight = [System.Windows.FontWeights]::Bold
    [System.Windows.Controls.Grid]::SetColumn($headerLabel, 0)
    
    $closeButton = New-Object System.Windows.Controls.Button
    $closeButton.Content = "✕"
    $closeButton.Width = 30
    $closeButton.Height = 25
    $closeButton.Margin = New-Object System.Windows.Thickness(5, 0, 0, 0)
    $closeButton.ToolTip = "Close connection manager"
    [System.Windows.Controls.Grid]::SetColumn($closeButton, 1)
    
    # Add close button event handler
    $closeButton.Add_Click({
        $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Collapsed
        $global:btnConnectionManager.Content = "🔗 Connections"
        $global:btnConnectionManager.Background = [System.Windows.Media.Brushes]::LightGray
    }.GetNewClosure())
    
    $headerGrid.Children.Add($headerLabel)
    $headerGrid.Children.Add($closeButton)
    [System.Windows.Controls.Grid]::SetRow($headerGrid, 0)
    
    # DataGrid for connections (static for Phase 1)
    $dataGrid = New-Object System.Windows.Controls.DataGrid
    $dataGrid.Name = "dgConnections"
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true
    $dataGrid.GridLinesVisibility = [System.Windows.Controls.DataGridGridLinesVisibility]::All
    $dataGrid.HeadersVisibility = [System.Windows.Controls.DataGridHeadersVisibility]::All
    $dataGrid.Margin = New-Object System.Windows.Thickness(0, 10, 0, 10)
    
    # Auto-sizing columns to fit content
    $nameColumn = New-Object System.Windows.Controls.DataGridTextColumn
    $nameColumn.Header = "Instance"
    $nameColumn.Width = [System.Windows.Controls.DataGridLength]::SizeToHeader
    $nameColumn.Binding = New-Object System.Windows.Data.Binding("InstanceName")
    
    $typeColumn = New-Object System.Windows.Controls.DataGridTextColumn
    $typeColumn.Header = "Type"
    $typeColumn.Width = [System.Windows.Controls.DataGridLength]::SizeToHeader
    $typeColumn.Binding = New-Object System.Windows.Data.Binding("ConnectionType")
    
    $statusColumn = New-Object System.Windows.Controls.DataGridTextColumn
    $statusColumn.Header = "Status"
    $statusColumn.Width = [System.Windows.Controls.DataGridLength]::SizeToHeader
    $statusColumn.Binding = New-Object System.Windows.Data.Binding("Status")
    
    # Phase 3: Add Stop button column
    $actionColumn = New-Object System.Windows.Controls.DataGridTemplateColumn
    $actionColumn.Header = "Action"
    $actionColumn.Width = 60
    
    $template = New-Object System.Windows.DataTemplate
    $factory = New-Object System.Windows.FrameworkElementFactory([System.Windows.Controls.Button])
    $factory.SetValue([System.Windows.Controls.Button]::ContentProperty, "Stop")
    $factory.SetValue([System.Windows.Controls.Button]::WidthProperty, 50.0)
    $factory.SetValue([System.Windows.Controls.Button]::HeightProperty, 22.0)
    $factory.SetValue([System.Windows.Controls.Button]::FontSizeProperty, 10.0)
    $factory.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $connection = $sender.DataContext
        if ($connection -and $connection.SessionId) {
            Stop-ConnectionSession -SessionId $connection.SessionId -InstanceName $connection.InstanceName
        }
    })
    $template.VisualTree = $factory
    $actionColumn.CellTemplate = $template
    
    $dataGrid.Columns.Add($nameColumn)
    $dataGrid.Columns.Add($typeColumn)
    $dataGrid.Columns.Add($statusColumn)
    $dataGrid.Columns.Add($actionColumn)
    
    # Phase 2: Set empty data initially using ArrayList for proper DataGrid binding
    $placeholderData = New-Object System.Collections.ArrayList
    $placeholderData.Add([PSCustomObject]@{ InstanceName = "Loading..."; ConnectionType = "connections"; Status = "" }) | Out-Null
    $dataGrid.ItemsSource = $placeholderData
    
    [System.Windows.Controls.Grid]::SetRow($dataGrid, 1)
    
    # Phase 3: Enhanced button panel with status check and auto-open toggle
    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = [System.Windows.Controls.Orientation]::Vertical
    $buttonPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $buttonPanel.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
    
    # Button row
    $buttonRow = New-Object System.Windows.Controls.StackPanel
    $buttonRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttonRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    
    $refreshButton = New-Object System.Windows.Controls.Button
    $refreshButton.Content = "🔄 Refresh"
    $refreshButton.Width = 70
    $refreshButton.Height = 25
    $refreshButton.Margin = New-Object System.Windows.Thickness(2, 0, 2, 0)
    $refreshButton.Add_Click({
        Update-ConnectionList
    }.GetNewClosure())
    
    # Phase 3: Add status check button
    $statusCheckButton = New-Object System.Windows.Controls.Button
    $statusCheckButton.Content = "🔍 Status"
    $statusCheckButton.Width = 70
    $statusCheckButton.Height = 25
    $statusCheckButton.Margin = New-Object System.Windows.Thickness(2, 0, 2, 0)
    $statusCheckButton.Add_Click({
        Check-ConnectionStatus
    }.GetNewClosure())
    
    $buttonRow.Children.Add($refreshButton)
    $buttonRow.Children.Add($statusCheckButton)
    
    # Toggle options row
    $toggleRow = New-Object System.Windows.Controls.StackPanel
    $toggleRow.Orientation = [System.Windows.Controls.Orientation]::Vertical
    $toggleRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $toggleRow.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
    
    # Auto-open toggle
    $autoOpenCheckBox = New-Object System.Windows.Controls.CheckBox
    $autoOpenCheckBox.Content = "Auto-open on new connections"
    $autoOpenCheckBox.FontSize = 10
    $autoOpenCheckBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $autoOpenCheckBox.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $autoOpenCheckBox.Margin = New-Object System.Windows.Thickness(0, 0, 0, 3)
    
    # Set initial state from user settings
    $userSettings = Get-UserSettings
    $autoOpenCheckBox.IsChecked = $userSettings.General.AutoOpenConnectionManager
    
    $autoOpenCheckBox.Add_Checked({
        $userSettings = Get-UserSettings
        $userSettings.General.AutoOpenConnectionManager = $true
        Set-UserSettings $userSettings
    }.GetNewClosure())
    
    $autoOpenCheckBox.Add_Unchecked({
        $userSettings = Get-UserSettings
        $userSettings.General.AutoOpenConnectionManager = $false
        Set-UserSettings $userSettings
    }.GetNewClosure())
    
    # Session filter toggle
    $sessionFilterCheckBox = New-Object System.Windows.Controls.CheckBox
    $sessionFilterCheckBox.Content = "Show only my sessions"
    $sessionFilterCheckBox.FontSize = 10
    $sessionFilterCheckBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $sessionFilterCheckBox.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $sessionFilterCheckBox.IsChecked = $true  # Default to showing only user's sessions
    $sessionFilterCheckBox.ToolTip = "Uncheck to see all users' SSM sessions (useful for reviewing send-command results)"
    
    $sessionFilterCheckBox.Add_Checked({
        Update-ConnectionList
    }.GetNewClosure())
    
    $sessionFilterCheckBox.Add_Unchecked({
        Update-ConnectionList
    }.GetNewClosure())
    
    $toggleRow.Children.Add($autoOpenCheckBox)
    $toggleRow.Children.Add($sessionFilterCheckBox)
    
    $statusLabel = New-Object System.Windows.Controls.Label
    $statusLabel.Name = "lblConnectionStatus"
    $statusLabel.Content = "Phase 3: Manual management ready"
    $statusLabel.FontSize = 10
    $statusLabel.Foreground = [System.Windows.Media.Brushes]::Gray
    $statusLabel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    
    $buttonPanel.Children.Add($buttonRow)
    $buttonPanel.Children.Add($toggleRow)
    $buttonPanel.Children.Add($statusLabel)
    [System.Windows.Controls.Grid]::SetRow($buttonPanel, 2)
    
    # Add all elements to grid
    $grid.Children.Add($headerGrid)
    $grid.Children.Add($dataGrid)
    $grid.Children.Add($buttonPanel)
    
    # Set grid as panel content
    $panel.Content = $grid
    
    # Add panel directly to side panel container
    $global:SidePanelContainer.Children.Add($panel)
    
    # Phase 2: Load actual connection data after panel is created
    try {
        $connectionData = Get-StaticConnectionList
        Write-Verbose "Retrieved connection data type: $($connectionData.GetType().Name), Count: $($connectionData.Count)"
        
        # Force conversion to proper collection for DataGrid
        $dataCollection = New-Object System.Collections.ArrayList
        foreach ($item in $connectionData) {
            $dataCollection.Add($item) | Out-Null
        }
        
        $dataGrid.ItemsSource = $null  # Clear first to prevent binding issues
        $dataGrid.ItemsSource = $dataCollection
        
        # Auto-size columns after data is loaded
        $dataGrid.UpdateLayout()
        foreach ($column in $dataGrid.Columns) {
            if ($column.Width.UnitType -eq [System.Windows.Controls.DataGridLengthUnitType]::SizeToHeader) {
                $column.Width = [System.Windows.Controls.DataGridLength]::SizeToCells
            }
        }
        
        Write-Verbose "Loaded $($dataCollection.Count) connections into panel"
    } catch {
        # If loading fails, show error message
        Write-Verbose "Failed to load initial connection data: $($_.Exception.Message)"
        $errorData = New-Object System.Collections.ArrayList
        $errorData.Add([PSCustomObject]@{ 
            InstanceName = "Error:"; 
            ConnectionType = $_.Exception.Message; 
            Status = "";
            SessionId = "";
            StartTime = "";
            Duration = "";
            Target = ""
        }) | Out-Null
        $dataGrid.ItemsSource = $errorData
    }
}


function Add-SidePanel {
    param([string]$Title, [object]$Content, [int]$Width = 300)
    
    # Store original window width if not already stored
    if (-not $script:OriginalWindowWidth) {
        $script:OriginalWindowWidth = $window.Width
    }
    
    # Create docked panel within main window
    $dockPanel = New-Object System.Windows.Controls.Border
    $dockPanel.Width = $Width
    $dockPanel.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::WhiteSmoke)
    $dockPanel.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Gray)
    $dockPanel.BorderThickness = "1,0,0,0"
    
    # Create header with title and close button
    $headerGrid = New-Object System.Windows.Controls.Grid
    $headerGrid.Height = 30
    $headerGrid.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::LightGray)
    
    $titleLabel = New-Object System.Windows.Controls.Label
    $titleLabel.Content = $Title
    $titleLabel.FontWeight = "Bold"
    $titleLabel.VerticalAlignment = "Center"
    $titleLabel.Margin = "10,0,0,0"
    
    $closeButton = New-Object System.Windows.Controls.Button
    $closeButton.Content = "✕"
    $closeButton.Width = 25
    $closeButton.Height = 25
    $closeButton.HorizontalAlignment = "Right"
    $closeButton.VerticalAlignment = "Center"
    $closeButton.Margin = "0,0,5,0"
    $closeButton.Add_Click({
        Remove-SidePanel $dockPanel
        if ($Title -eq "Connection Manager") {
            $btnConnectionManager.Content = "🔗 Connections"
        }
    }.GetNewClosure())
    
    $headerGrid.Children.Add($titleLabel)
    $headerGrid.Children.Add($closeButton)
    
    # Create main panel content
    $panelGrid = New-Object System.Windows.Controls.Grid
    $panelGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height="Auto"}))
    $panelGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height="*"}))
    
    [System.Windows.Controls.Grid]::SetRow($headerGrid, 0)
    [System.Windows.Controls.Grid]::SetRow($Content, 1)
    
    $panelGrid.Children.Add($headerGrid)
    $panelGrid.Children.Add($Content)
    
    $dockPanel.Child = $panelGrid
    
    # Expand main window to accommodate panel
    $window.Width = $script:OriginalWindowWidth + $Width
    
    # Add to main window's side panel container
    $global:SidePanelContainer.Children.Add($dockPanel)
    $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Visible
    
    # Track panel
    if (-not $script:ActivePanels) { $script:ActivePanels = @() }
    $script:ActivePanels += @{ Panel = $dockPanel; Title = $Title; Width = $Width }
    
    return $dockPanel
}

function Remove-SidePanel {
    param([object]$Panel)
    
    try {
        # Get panel info before removing
        $panelInfo = $script:ActivePanels | Where-Object { $_.Panel -eq $Panel } | Select-Object -First 1
        
        # Remove from main window
        $global:SidePanelContainer.Children.Remove($Panel)
        
        # Shrink main window by panel width
        if ($panelInfo) {
            $window.Width = $window.Width - $panelInfo.Width
        }
        
        # Hide container if no panels left
        if ($global:SidePanelContainer.Children.Count -eq 0) {
            $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Collapsed
            # Restore original window width
            if ($script:OriginalWindowWidth) {
                $window.Width = $script:OriginalWindowWidth
            }
        }
        
        # Remove from tracking and update button
        if ($script:ActivePanels) {
            if ($panelInfo -and $panelInfo.Title -eq "Connection Manager") {
                $btnConnectionManager.Content = "🔗 Connections"
            }
            $script:ActivePanels = $script:ActivePanels | Where-Object { $_.Panel -ne $Panel }
        }
    } catch {
        # Panel removal errors are non-critical
    }
}

function Start-PortForwardConnection {
    param([int]$RemotePort, [object]$Instance, [string]$ProfileName)
    
    $lblStatus.Content = "Starting port forward to $($Instance.Name):$RemotePort..."
    
    try {
        $result = Start-PortForward -InstanceId $Instance.InstanceId -RemotePort $RemotePort -ProfileName $ProfileName
        
        if ($result.Success) {
            $lblStatus.Content = "Port forward active: localhost:$($result.LocalPort)"
        } else {
            $lblStatus.Content = "Port forward failed: $($result.Message)"
        }
    } catch {
        $lblStatus.Content = "Port forward error: $($_.Exception.Message)"
    }
}

function Update-AllPanelPositions {
    if ($script:ActivePanels -and -not $script:UpdatingPanelPosition) {
        $script:UpdatingPanelPosition = $true
        try {
            $currentLeft = [double]($window.Left) + [double]($window.Width) - 5
            foreach ($panel in $script:ActivePanels) {
                if ($panel -and -not $panel.IsClosed) {
                    $panel.Left = $currentLeft
                    $panel.Top = [double]($window.Top)
                    $panel.Height = [double]($window.Height)
                    $currentLeft += [double]($panel.Width)
                }
            }
        } finally {
            $script:UpdatingPanelPosition = $false
        }
    }
}

function Start-ConnectionMonitoring {
    # Completely disabled - no monitoring to prevent SSH interference
    Write-Verbose "Connection monitoring disabled to prevent SSH session interference"
    return
}

function Start-StatusResetTimer {
    # Stop existing timer if running
    if ($script:StatusResetTimer) {
        $script:StatusResetTimer.Stop()
        $script:StatusResetTimer = $null
    }
    
    $script:StatusResetTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:StatusResetTimer.Interval = [TimeSpan]::FromSeconds(5)  # Reset after 5 seconds
    $script:StatusResetTimer.Add_Tick({
        try {
            # Reset status to show instance results or ready state
            if ($global:OriginalItems -and $global:OriginalItems.Count -gt 0) {
                $lblStatus.Content = "Found $($global:OriginalItems.Count) instances"
            } else {
                $lblStatus.Content = "Ready"
            }
            
            # Stop the timer
            $script:StatusResetTimer.Stop()
            $script:StatusResetTimer = $null
        } catch {
            # Reset errors are non-critical
        }
    })

    $script:StatusResetTimer.Start()
}

function Stop-StatusResetTimer {
    if ($script:StatusResetTimer) {
        $script:StatusResetTimer.Stop()
        $script:StatusResetTimer = $null
    }
}

function Resize-DataGridColumns {
    try {
        # Auto-size all columns to fit content and header
        foreach ($column in $dgEC2.Columns) {
            $column.Width = [System.Windows.Controls.DataGridLength]::SizeToCells
        }
        
        # Force DataGrid to update layout
        $dgEC2.UpdateLayout()
        
        # Wait for layout to complete
        Start-Sleep -Milliseconds 100
    } catch {
        # Auto-sizing errors are non-critical
    }
}

function Resize-WindowForResults {
    param([int]$ResultCount)
    
    # Disable automatic window resizing to prevent display issues
    # The user can manually resize the window as needed
    Write-Verbose "Skipping automatic window resize for $ResultCount results to prevent display issues"
    return
}

function Update-ConnectionManagerPanel {
    if ($global:DebugMode) { Write-Host "[DEBUG] Refresh-ConnectionManagerPanel called" -ForegroundColor Magenta }
    
    # Find the existing connection manager panel
    $connectionManagerPanel = $script:ActivePanels | Where-Object { $_.Title -eq "Connection Manager" } | Select-Object -First 1
    if (-not $connectionManagerPanel) {
        if ($global:DebugMode) { Write-Host "[DEBUG] No connection manager panel found to refresh" -ForegroundColor Yellow }
        return
    }
    
    if ($global:DebugMode) { Write-Host "[DEBUG] Removing and recreating connection manager panel" -ForegroundColor Magenta }
    
    # Remove and recreate the panel for now (simpler approach)
    Remove-SidePanel $connectionManagerPanel.Panel
    Show-ConnectionManagerPanel
    return
    
    try {
        # Get current connections
        $connections = Get-ActiveConnections
        
        # Find the main grid in the panel content
        $mainGrid = $connectionManagerPanel.Content
        if (-not $mainGrid) {
            return
        }
        
        # Update the connection count in status panel (row 2)
        $statusPanel = $mainGrid.Children | Where-Object { [System.Windows.Controls.Grid]::GetRow($_) -eq 2 } | Select-Object -First 1
        if ($statusPanel) {
            $countLabel = $statusPanel.Children | Where-Object { $_.GetType().Name -eq "Label" -and $_.HorizontalAlignment -eq "Left" } | Select-Object -First 1
            if ($countLabel) {
                $countLabel.Content = "$($connections.Count) active connections"
            }
        }
        
        # Update the data grid or no connections label (row 1)
        $contentRow = $mainGrid.Children | Where-Object { [System.Windows.Controls.Grid]::GetRow($_) -eq 1 } | Select-Object -First 1
        if ($contentRow) {
            # Remove existing content
            $mainGrid.Children.Remove($contentRow)
            
            if ($connections.Count -eq 0) {
                # Add "no connections" label
                $noConnectionsLabel = New-Object System.Windows.Controls.Label
                $noConnectionsLabel.Content = "No active connections."
                $noConnectionsLabel.Margin = "10"
                $noConnectionsLabel.HorizontalAlignment = "Center"
                $noConnectionsLabel.VerticalAlignment = "Center"
                [System.Windows.Controls.Grid]::SetRow($noConnectionsLabel, 1)
                $mainGrid.Children.Add($noConnectionsLabel)
            } else {
                # Create new DataGrid with updated data
                $dataGrid = New-Object System.Windows.Controls.DataGrid
                $dataGrid.Margin = "10,5"
                $dataGrid.AutoGenerateColumns = $false
                $dataGrid.IsReadOnly = $true
                $dataGrid.GridLinesVisibility = "All"
                $dataGrid.HeadersVisibility = "All"
                $dataGrid.CanUserResizeColumns = $true
                
                # Define columns
                $typeColumn = New-Object System.Windows.Controls.DataGridTextColumn
                $typeColumn.Header = "Type"
                $typeColumn.Binding = New-Object System.Windows.Data.Binding("ConnectionType")
                $typeColumn.Width = 70
                $dataGrid.Columns.Add($typeColumn)
                
                $instanceColumn = New-Object System.Windows.Controls.DataGridTextColumn
                $instanceColumn.Header = "Instance"
                $instanceColumn.Binding = New-Object System.Windows.Data.Binding("InstanceName")
                $instanceColumn.Width = 180
                $dataGrid.Columns.Add($instanceColumn)
                
                $portColumn = New-Object System.Windows.Controls.DataGridTextColumn
                $portColumn.Header = "Port"
                $portColumn.Binding = New-Object System.Windows.Data.Binding("LocalPort")
                $portColumn.Width = 60
                $dataGrid.Columns.Add($portColumn)
                
                $durationColumn = New-Object System.Windows.Controls.DataGridTextColumn
                $durationColumn.Header = "Duration"
                $durationColumn.Binding = New-Object System.Windows.Data.Binding("DurationText")
                $durationColumn.Width = 70
                $dataGrid.Columns.Add($durationColumn)
                
                # Add action column with stop button
                $actionColumn = New-Object System.Windows.Controls.DataGridTemplateColumn
                $actionColumn.Header = "Action"
                $actionColumn.Width = 60
                
                $template = New-Object System.Windows.DataTemplate
                $factory = New-Object System.Windows.FrameworkElementFactory([System.Windows.Controls.Button])
                $factory.SetValue([System.Windows.Controls.Button]::ContentProperty, "Stop")
                $factory.SetValue([System.Windows.Controls.Button]::WidthProperty, 50.0)
                $factory.SetValue([System.Windows.Controls.Button]::HeightProperty, 25.0)
                $factory.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
                    param($sender, $e)
                    $connection = $sender.DataContext
                    if ($connection -and $connection.ConnectionId) {
                        & (Get-Module AWS).NewBoundScriptBlock({ Stop-Connection -ConnectionId $args[0] }) $connection.ConnectionId
                    }
                })
                $template.VisualTree = $factory
                $actionColumn.CellTemplate = $template
                $dataGrid.Columns.Add($actionColumn)
                
                # Prepare data with duration text - ensure it's always an array
                $connectionData = @($connections | ForEach-Object {
                    [PSCustomObject]@{
                        ConnectionType = $_.ConnectionType
                        InstanceName = $_.InstanceName
                        LocalPort = $_.LocalPort
                        DurationText = "$([math]::Floor($_.Duration.TotalMinutes))m"
                        ConnectionId = $_.ConnectionId
                    }
                })
                
                $dataGrid.ItemsSource = $connectionData
                [System.Windows.Controls.Grid]::SetRow($dataGrid, 1)
                $mainGrid.Children.Add($dataGrid)
            }
        }
    } catch {
        # If refresh fails, fall back to full panel recreation
        Show-ConnectionManagerPanel
    }
}

function Stop-ConnectionMonitoring {
    if ($script:ConnectionMonitorTimer) {
        $script:ConnectionMonitorTimer.Stop()
        $script:ConnectionMonitorTimer = $null
    }
    
    # Cleanup any active connection tests
    if ($script:ActiveConnectionTests) {
        foreach ($test in $script:ActiveConnectionTests.Values) {
            try {
                $test.PowerShell.Stop()
                $test.PowerShell.Dispose()
                $test.Runspace.Close()
                $test.Runspace.Dispose()
            } catch {
                # Cleanup errors are non-critical
            }
        }
        $script:ActiveConnectionTests = @{}
    }
    
    if ($script:ConnectionTestsInProgress) {
        $script:ConnectionTestsInProgress = @{}
    }
}

function Update-ConnectionStatus {
    # Disabled to prevent SSH interference
    return $false
}

function Start-ConnectionTest {
    param([string]$ConnectionId, [hashtable]$Connection)
    
    # Disabled to prevent SSH interference
    return
}

function Test-ConnectionTestResults {
    # Disabled to prevent SSH interference
    return $false
}

# Phase 2: Static Connection Display Functions
function Get-StaticConnectionList {
    # Get current connections using simple AWS CLI calls (no background monitoring)
    try {
        $profileName = $global:cmbProfile.Text.Trim()
        if (-not $profileName -or $profileName -eq "") {
            Write-Verbose "No profile selected for connection list"
            $result = New-Object System.Collections.ArrayList
            $result.Add([PSCustomObject]@{ 
                InstanceName = "No profile"; 
                ConnectionType = "selected"; 
                Status = "Select profile first";
                SessionId = "";
                StartTime = "";
                Duration = "";
                Target = ""
            }) | Out-Null
            return $result
        }
        
        Write-Verbose "Getting connections for profile: $profileName"
        
        # Simple AWS CLI call to get SSM sessions
        Write-Verbose "Calling AWS CLI: aws ssm describe-sessions --state Active --profile $profileName"
        $sessions = & aws ssm describe-sessions --state "Active" --profile $profileName --output json 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose "AWS CLI failed with exit code $LASTEXITCODE. Output: $sessions"
            $errorMsg = if ($sessions) { $sessions -join " " } else { "Unknown AWS CLI error" }
            $result = New-Object System.Collections.ArrayList
            $result.Add([PSCustomObject]@{ 
                InstanceName = "AWS CLI Error"; 
                ConnectionType = "Exit code: $LASTEXITCODE"; 
                Status = $errorMsg;
                SessionId = "";
                StartTime = "";
                Duration = "";
                Target = ""
            }) | Out-Null
            return $result
        }
        
        if (-not $sessions -or $sessions.Trim() -eq "") {
            Write-Verbose "No session data returned from AWS CLI"
            $result = New-Object System.Collections.ArrayList
            $result.Add([PSCustomObject]@{ 
                InstanceName = "No active"; 
                ConnectionType = "connections"; 
                Status = "";
                SessionId = "";
                StartTime = "";
                Duration = "";
                Target = ""
            }) | Out-Null
            return $result
        }
        
        Write-Verbose "Parsing JSON response: $($sessions.Length) characters"
        try {
            $sessionData = $sessions | ConvertFrom-Json
        } catch {
            Write-Verbose "JSON parsing failed: $($_.Exception.Message)"
            $result = New-Object System.Collections.ArrayList
            $result.Add([PSCustomObject]@{ 
                InstanceName = "JSON Parse Error"; 
                ConnectionType = $_.Exception.Message; 
                Status = "";
                SessionId = "";
                StartTime = "";
                Duration = "";
                Target = ""
            }) | Out-Null
            return $result
        }
        
        if (-not $sessionData.Sessions -or $sessionData.Sessions.Count -eq 0) {
            Write-Verbose "No active sessions found in response"
            $result = New-Object System.Collections.ArrayList
            $result.Add([PSCustomObject]@{ InstanceName = "No active"; ConnectionType = "connections"; Status = ""; SessionId = ""; StartTime = ""; Duration = ""; Target = "" }) | Out-Null
            return $result
        }
        
        Write-Verbose "Found $($sessionData.Sessions.Count) active sessions"
        
        # Check session filter setting from UI
        $showOnlyMySessionsCheckBox = $null
        try {
            # Find the session filter checkbox in the connection manager panel
            foreach ($child in $global:SidePanelContainer.Children) {
                if ($child -is [System.Windows.Controls.GroupBox] -and $child.Header -eq "🔗 Connection Manager") {
                    $grid = $child.Content
                    if ($grid -is [System.Windows.Controls.Grid]) {
                        foreach ($gridChild in $grid.Children) {
                            if ($gridChild -is [System.Windows.Controls.StackPanel] -and [System.Windows.Controls.Grid]::GetRow($gridChild) -eq 2) {
                                foreach ($stackChild in $gridChild.Children) {
                                    if ($stackChild -is [System.Windows.Controls.StackPanel] -and $stackChild.Orientation -eq [System.Windows.Controls.Orientation]::Vertical) {
                                        foreach ($toggleChild in $stackChild.Children) {
                                            if ($toggleChild -is [System.Windows.Controls.CheckBox] -and $toggleChild.Content -eq "Show only my sessions") {
                                                $showOnlyMySessionsCheckBox = $toggleChild
                                                break
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Verbose "Could not find session filter checkbox, defaulting to user sessions only"
        }
        
        # Determine if we should filter by current user
        $filterByCurrentUser = $true  # Default to filtering
        if ($showOnlyMySessionsCheckBox -and $showOnlyMySessionsCheckBox.IsChecked -eq $false) {
            $filterByCurrentUser = $false
        }
        
        # Get current user for filtering
        $currentUser = $env:USERNAME
        if ($filterByCurrentUser) {
            Write-Verbose "Filtering sessions for current user: $currentUser"
        } else {
            Write-Verbose "Showing all users' sessions (filter disabled)"
        }
        
        # Convert sessions to display format using ArrayList
        $connections = New-Object System.Collections.ArrayList
        foreach ($session in $sessionData.Sessions) {
            # Filter to only show current user's sessions if enabled
            if ($filterByCurrentUser -and $session.SessionId -and $session.SessionId -notlike "*$currentUser*") {
                Write-Verbose "Skipping session for different user: $($session.SessionId)"
                continue
            }
            
            # Skip sessions without required properties
            if (-not $session.SessionId -or -not $session.Target) {
                Write-Verbose "Skipping session with missing properties"
                continue
            }
            $connectionType = "SSM"
            if ($session.DocumentName -eq "AWS-StartPortForwardingSession") {
                # Check if this is a tracked RDP connection
                $isRDP = $false
                if ($global:RDPConnections -and $global:RDPConnections.ContainsKey($session.Target)) {
                    $isRDP = $true
                    if ($global:DebugMode) { Write-Host "[DEBUG] Found tracked RDP connection for $($session.Target)" -ForegroundColor Green }
                }
                
                $connectionType = if ($isRDP) { "RDP" } else { "Port Forward" }
            } elseif ($session.DocumentName -eq "AWS-StartSSHSession") {
                $connectionType = "SSH"
            }
            
            $instanceName = $session.Target
            if ($session.Target -match "i-[a-f0-9]+") {
                # Try to get instance name from current results
                if ($global:OriginalItems) {
                    $instance = $global:OriginalItems | Where-Object { $_.InstanceId -eq $session.Target } | Select-Object -First 1
                    if ($instance -and $instance.Name) {
                        $instanceName = $instance.Name
                    }
                }
            }
            
            # Phase 3: Enhanced connection details
            $startTime = if ($session.StartDate) { [DateTime]$session.StartDate } else { Get-Date }
            $duration = (Get-Date) - $startTime
            $durationText = if ($duration.TotalHours -ge 1) {
                "$([math]::Floor($duration.TotalHours))h $($duration.Minutes)m"
            } else {
                "$($duration.Minutes)m $($duration.Seconds)s"
            }
            
            # Add user info if showing all sessions
            $displayName = $instanceName
            if (-not $filterByCurrentUser -and $session.SessionId) {
                # Extract username from session ID if possible
                if ($session.SessionId -match "([^-]+)-[0-9a-f]+$") {
                    $sessionUser = $matches[1]
                    if ($sessionUser -ne $currentUser) {
                        $displayName = "$instanceName ($sessionUser)"
                    }
                }
            }
            
            $connectionObj = [PSCustomObject]@{
                InstanceName = $displayName
                ConnectionType = $connectionType
                Status = $session.Status
                SessionId = $session.SessionId
                StartTime = $session.StartDate
                Duration = $durationText
                Target = $session.Target
            }
            $connections.Add($connectionObj) | Out-Null
            Write-Verbose "Added connection: $($connectionObj.InstanceName) - $($connectionObj.ConnectionType)"
        }
        
        # Return ArrayList directly - ensure we have at least one item
        if ($connections.Count -eq 0) {
            $connections.Add([PSCustomObject]@{
                InstanceName = "No active"
                ConnectionType = "connections"
                Status = ""
                SessionId = ""
                StartTime = ""
                Duration = ""
                Target = ""
            }) | Out-Null
        }
        
        Write-Verbose "Returning $($connections.Count) processed connections"
        return $connections
    } catch {
        Write-Verbose "Exception in Get-StaticConnectionList: $($_.Exception.Message)"
        Write-Verbose "Exception details: $($_.Exception.GetType().Name) at line $($_.InvocationInfo.ScriptLineNumber)"
        $result = New-Object System.Collections.ArrayList
        $result.Add([PSCustomObject]@{ 
            InstanceName = "Exception:"; 
            ConnectionType = $_.Exception.Message; 
            Status = "Line: $($_.InvocationInfo.ScriptLineNumber)";
            SessionId = "";
            StartTime = "";
            Duration = "";
            Target = ""
        }) | Out-Null
        return $result
    }
}

function Update-ConnectionList {
    # Manual refresh of connection list (Phase 2 - no automatic updates)
    try {
        Write-Verbose "Starting manual connection list refresh"
        
        # Get updated connection data first
        $connectionData = Get-StaticConnectionList
        Write-Verbose "Retrieved $($connectionData.Count) connection items"
        
        # Recreate the connection manager panel with updated data
        # This is simpler and more reliable than trying to update individual elements
        if ($global:SidePanelContainer.Children.Count -gt 0) {
            $global:SidePanelContainer.Children.Clear()
            Show-ConnectionManagerPanel
        }
        
        Write-Verbose "Connection list refreshed successfully"
    } catch {
        Write-Warning "Failed to refresh connection list: $($_.Exception.Message)"
        # Show error in status bar
        if ($global:lblStatus) {
            $global:lblStatus.Content = "❌ Connection refresh failed: $($_.Exception.Message)"
        }
    }
}

# Phase 3: Manual Connection Management Functions
function Stop-ConnectionSession {
    param(
        [string]$SessionId,
        [string]$InstanceName
    )
    
    try {
        Write-Verbose "Stopping connection session: $SessionId for $InstanceName"
        
        # Update status
        if ($global:lblStatus) {
            $global:lblStatus.Content = "Stopping connection to $InstanceName..."
        }
        
        # Get current profile
        $profileName = $global:cmbProfile.Text.Trim()
        if (-not $profileName) {
            throw "No profile selected"
        }
        
        # Stop the session using AWS CLI
        $result = & aws ssm terminate-session --session-id $SessionId --profile $profileName --output json 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Verbose "Session terminated successfully"
            if ($global:lblStatus) {
                $global:lblStatus.Content = "✅ Connection to $InstanceName stopped"
            }
            
            # Clean up RDP connection tracking if this was an RDP session
            if ($global:RDPConnections) {
                $instanceId = $null
                foreach ($key in $global:RDPConnections.Keys) {
                    if ($global:RDPConnections[$key].InstanceName -eq $InstanceName) {
                        $instanceId = $key
                        break
                    }
                }
                if ($instanceId) {
                    $global:RDPConnections.Remove($instanceId)
                    if ($global:DebugMode) { Write-Host "[DEBUG] Cleaned up RDP tracking for $InstanceName" -ForegroundColor Yellow }
                }
            }
            
            # Auto-refresh the connection list after 2 seconds using non-blocking timer
            $refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
            $refreshTimer.Interval = [TimeSpan]::FromSeconds(2)
            $refreshTimer.Add_Tick({
                Update-ConnectionList
                $refreshTimer.Stop()
            }.GetNewClosure())
            $refreshTimer.Start()
        } else {
            $errorMsg = if ($result) { $result -join " " } else { "Unknown error" }
            Write-Warning "Failed to stop session: $errorMsg"
            if ($global:lblStatus) {
                $global:lblStatus.Content = "❌ Failed to stop connection: $errorMsg"
            }
        }
    } catch {
        Write-Warning "Error stopping connection: $($_.Exception.Message)"
        if ($global:lblStatus) {
            $global:lblStatus.Content = "❌ Error stopping connection: $($_.Exception.Message)"
        }
    }
}

function Test-ConnectionStatus {
    # Phase 3: Simple immediate refresh
    try {
        if ($global:lblStatus) {
            $global:lblStatus.Content = "🔄 Refreshing connections..."
        }
        
        # Simple immediate refresh
        Refresh-ConnectionList
        
        if ($global:lblStatus) {
            $global:lblStatus.Content = "✅ Connection status refreshed"
        }
    } catch {
        if ($global:lblStatus) {
            $global:lblStatus.Content = "❌ Status refresh failed: $($_.Exception.Message)"
        }
    }
}

function Switch-SettingsPanel {
    try {
        Write-Host "[DEBUG] Switch-SettingsPanel called" -ForegroundColor Cyan
        
        # Use the global window variable directly
        $window = $global:window
        Write-Host "[DEBUG] Window: $($window -ne $null)" -ForegroundColor Cyan
        Write-Host "[DEBUG] SidePanelContainer: $($global:SidePanelContainer -ne $null)" -ForegroundColor Cyan
        
        if (-not $global:SidePanelContainer) {
            Write-Host "[ERROR] SidePanelContainer is null!" -ForegroundColor Red
            return
        }
        
        # Check if settings panel is already open
        $existingPanel = $global:SidePanelContainer.Children | Where-Object { $_.Tag -eq "Settings" }
        Write-Host "[DEBUG] Existing panel: $($existingPanel -ne $null)" -ForegroundColor Cyan
    
        
        if ($existingPanel) {
            Write-Host "[DEBUG] Closing existing settings panel" -ForegroundColor Cyan
            # Close settings panel
            $global:SidePanelContainer.Children.Remove($existingPanel)
            if ($window) { $window.Width = $window.Width - 350 }
            $global:btnSettings.Background = [System.Windows.Media.Brushes]::LightGray
            
            # Hide container if no panels left
            if ($global:SidePanelContainer.Children.Count -eq 0) {
                $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Collapsed
            }
        } else {
            Write-Host "[DEBUG] Opening new settings panel" -ForegroundColor Cyan
            # Show settings panel
            Show-SettingsPanel
            Write-Host "[DEBUG] Show-SettingsPanel completed" -ForegroundColor Cyan
            if ($window) { $window.Width = $window.Width + 350 }
            $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Visible
            $global:btnSettings.Background = [System.Windows.Media.Brushes]::Orange
        }
    } catch {
        Write-Host "[ERROR] Switch-SettingsPanel failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[ERROR] Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    }
}

function Show-SettingsPanel {
    # Create settings panel
    $panel = New-Object System.Windows.Controls.GroupBox
    $panel.Header = "⚙️ User Settings"
    $panel.Width = 330
    $panel.MaxWidth = 330
    $panel.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
    $panel.Padding = New-Object System.Windows.Thickness(10)
    $panel.Tag = "Settings"
    
    # Create panel content grid
    $grid = New-Object System.Windows.Controls.Grid
    
    # Add row definitions
    $row1 = New-Object System.Windows.Controls.RowDefinition
    $row1.Height = [System.Windows.GridLength]::Auto
    $row2 = New-Object System.Windows.Controls.RowDefinition
    $row2.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $row3 = New-Object System.Windows.Controls.RowDefinition
    $row3.Height = [System.Windows.GridLength]::Auto
    
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)
    $grid.RowDefinitions.Add($row3)
    
    # Header with close button
    $headerGrid = New-Object System.Windows.Controls.Grid
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = [System.Windows.GridLength]::Auto
    $headerGrid.ColumnDefinitions.Add($col1)
    $headerGrid.ColumnDefinitions.Add($col2)
    
    $headerLabel = New-Object System.Windows.Controls.Label
    $headerLabel.Content = "UI Preferences:"
    $headerLabel.FontWeight = [System.Windows.FontWeights]::Bold
    [System.Windows.Controls.Grid]::SetColumn($headerLabel, 0)
    
    $closeButton = New-Object System.Windows.Controls.Button
    $closeButton.Content = "✕"
    $closeButton.Width = 30
    $closeButton.Height = 25
    $closeButton.Margin = New-Object System.Windows.Thickness(5, 0, 0, 0)
    $closeButton.ToolTip = "Close settings panel"
    [System.Windows.Controls.Grid]::SetColumn($closeButton, 1)
    
    $closeButton.Add_Click({
        Switch-SettingsPanel
    }.GetNewClosure())
    
    $headerGrid.Children.Add($headerLabel)
    $headerGrid.Children.Add($closeButton)
    [System.Windows.Controls.Grid]::SetRow($headerGrid, 0)
    
    # Settings content
    $settingsStack = New-Object System.Windows.Controls.StackPanel
    $settingsStack.Margin = New-Object System.Windows.Thickness(0, 10, 0, 10)
    
    # AWS Services Section
    $servicesGroup = New-Object System.Windows.Controls.GroupBox
    $servicesGroup.Header = "AWS Services"
    $servicesGroup.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    $servicesGroup.Padding = New-Object System.Windows.Thickness(10)
    
    $servicesStack = New-Object System.Windows.Controls.StackPanel
    
    # Load available services from JSON configuration
    $availableServices = @()
    try {
        $configPath = "$PSScriptRoot\..\Config\aws-services.json"
        if (Test-Path $configPath) {
            $serviceConfig = Get-Content $configPath -Raw | ConvertFrom-Json
            foreach ($serviceKey in $serviceConfig.services.PSObject.Properties.Name) {
                $service = $serviceConfig.services.$serviceKey
                $availableServices += @{
                    Key = $serviceKey
                    Name = $service.name
                    Icon = $service.icon
                    Default = $service.enabled
                }
            }
        } else {
            # Fallback to hardcoded list if JSON not found
            $availableServices = @(
                @{Key='EC2'; Name='EC2 Instances'; Icon='🖥️'; Default=$true},
                @{Key='RDS'; Name='RDS Databases'; Icon='🗄️'; Default=$true},
                @{Key='S3'; Name='S3 Buckets'; Icon='🪣'; Default=$true},
                @{Key='Lambda'; Name='Lambda Functions'; Icon='⚡'; Default=$true}
            )
        }
    } catch {
        Write-Verbose "Failed to load service configuration: $($_.Exception.Message)"
        # Fallback to basic services
        $availableServices = @(
            @{Key='EC2'; Name='EC2 Instances'; Icon='🖥️'; Default=$true}
        )
    }
    
    # Get current user settings
    $userSettings = Get-UserSettings
    $enabledServices = if ($userSettings.PSObject.Properties['Services']) { $userSettings.Services } else { @('EC2', 'RDS', 'S3', 'Lambda') }
    
    foreach ($service in $availableServices) {
        $checkbox = New-Object System.Windows.Controls.CheckBox
        $checkbox.Content = "$($service.Icon) $($service.Name)"
        $checkbox.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
        $checkbox.Tag = $service.Key
        $checkbox.IsChecked = $service.Key -in $enabledServices
        $servicesStack.Children.Add($checkbox)
    }
    

    
    $servicesGroup.Content = $servicesStack
    $settingsStack.Children.Add($servicesGroup)
    
    # Background Discovery Status Section
    $discoveryGroup = New-Object System.Windows.Controls.GroupBox
    $discoveryGroup.Header = "Background Service Discovery"
    $discoveryGroup.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    $discoveryGroup.Padding = New-Object System.Windows.Thickness(10)
    
    $discoveryStack = New-Object System.Windows.Controls.StackPanel
    
    # Get discovery status
    $cacheData = Get-ServiceCache
    $statusLabel = New-Object System.Windows.Controls.Label
    $statusLabel.FontSize = 11
    
    if ($cacheData -and $cacheData.lastUpdated) {
        $lastUpdate = [DateTime]::Parse($cacheData.lastUpdated)
        $timeSince = (Get-Date) - $lastUpdate
        
        if ($timeSince.TotalMinutes -lt 1) {
            $timeText = "$([math]::Floor($timeSince.TotalSeconds)) seconds ago"
        } elseif ($timeSince.TotalHours -lt 1) {
            $timeText = "$([math]::Floor($timeSince.TotalMinutes)) minutes ago"
        } else {
            $timeText = "$([math]::Floor($timeSince.TotalHours)) hours ago"
        }
        
        $statusText = "✅ Last scan: $timeText\n📊 Found: $($cacheData.count) accessible services"
        if ($cacheData.totalCount -and $cacheData.totalCount -gt $cacheData.count) {
            $statusText += " (of $($cacheData.totalCount) total)"
        }
        if ($cacheData.profileName) {
            $statusText += "\n👤 Profile: $($cacheData.profileName)"
        }
    } else {
        $statusText = "🔄 Initial discovery in progress...\n⏱️ Next check: Every hour"
    }
    
    $statusLabel.Content = $statusText
    $statusLabel.Foreground = [System.Windows.Media.Brushes]::DarkGreen
    
    $discoveryStack.Children.Add($statusLabel)
    $discoveryGroup.Content = $discoveryStack
    $settingsStack.Children.Add($discoveryGroup)
    
    # DataGrid Spacing Section
    $spacingGroup = New-Object System.Windows.Controls.GroupBox
    $spacingGroup.Header = "DataGrid Column Spacing"
    $spacingGroup.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    $spacingGroup.Padding = New-Object System.Windows.Thickness(10)
    
    $spacingStack = New-Object System.Windows.Controls.StackPanel
    
    # Spacing options
    $compactRadio = New-Object System.Windows.Controls.RadioButton
    $compactRadio.Content = "Compact (+5px)"
    $compactRadio.GroupName = "Spacing"
    $compactRadio.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
    $compactRadio.Tag = "Compact"
    
    $balancedRadio = New-Object System.Windows.Controls.RadioButton
    $balancedRadio.Content = "Balanced (+10px) - Current"
    $balancedRadio.GroupName = "Spacing"
    $balancedRadio.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
    $balancedRadio.IsChecked = $true
    $balancedRadio.Tag = "Balanced"
    
    $comfyRadio = New-Object System.Windows.Controls.RadioButton
    $comfyRadio.Content = "Comfortable (+15px)"
    $comfyRadio.GroupName = "Spacing"
    $comfyRadio.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
    $comfyRadio.Tag = "Comfortable"
    
    $spacingStack.Children.Add($compactRadio)
    $spacingStack.Children.Add($balancedRadio)
    $spacingStack.Children.Add($comfyRadio)
    
    # Set initial default selection
    $balancedRadio.IsChecked = $true
    
    # Override with saved settings if available
    try {
        $currentSpacing = 'Balanced'
        if ($userSettings.PSObject.Properties['SpacingType']) { 
            $currentSpacing = $userSettings.SpacingType 
        }
        if ($currentSpacing -eq 'Compact') {
            $compactRadio.IsChecked = $true
        } elseif ($currentSpacing -eq 'Comfortable') {
            $comfyRadio.IsChecked = $true
        }
    } catch {
        # Default is already set above
    }
    
    $spacingGroup.Content = $spacingStack
    $settingsStack.Children.Add($spacingGroup)
    [System.Windows.Controls.Grid]::SetRow($settingsStack, 1)
    
    # Button panel
    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttonPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $buttonPanel.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
    
    $applyButton = New-Object System.Windows.Controls.Button
    $applyButton.Content = "Apply Settings"
    $applyButton.Width = 100
    $applyButton.Height = 30
    $applyButton.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    
    $discoverButton = New-Object System.Windows.Controls.Button
    $discoverButton.Content = "🔧 Configure Services"
    $discoverButton.Width = 130
    $discoverButton.Height = 30
    $discoverButton.ToolTip = "Open service picker to select from available AWS services"
    
    $buttonPanel.Children.Add($applyButton)
    $buttonPanel.Children.Add($discoverButton)
    
    # REMOVED: Progress section no longer needed with background discovery
    # JUSTIFICATION: Background discovery eliminates need for progress tracking UI
    
    $applyButton.Add_Click({
        # Get selected services
        $selectedServices = @()
        foreach ($child in $servicesStack.Children) {
            if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) {
                $selectedServices += $child.Tag
            }
        }
        
            # Get selected spacing option
        $selectedSpacing = "Balanced"  # Default
        if ($compactRadio.IsChecked) { 
            $selectedSpacing = "Compact" 
        } elseif ($comfyRadio.IsChecked) { 
            $selectedSpacing = "Comfortable" 
        }
        
        # Save service settings
        $userSettings = Get-UserSettings
        $userSettings.Services = $selectedServices
        Set-UserSettings $userSettings
        
        # Apply spacing immediately (safe column width changes only)
        try {
            Set-DataGridSpacing -SpacingType $selectedSpacing
        } catch {
            Write-Warning "Failed to apply spacing: $($_.Exception.Message)"
        }
        
        # Save spacing preference to user settings
        try {
            $userSettings = Get-UserSettings
            $userSettings | Add-Member -NotePropertyName 'SpacingType' -NotePropertyValue $selectedSpacing -Force
            Set-UserSettings $userSettings
        } catch {
            Write-Warning "Failed to save spacing preference: $($_.Exception.Message)"
        }
        
        # Refresh service tabs
        Update-ServiceTabs
        
        $global:lblStatus.Content = "✅ Settings applied: $($selectedServices.Count) services, $selectedSpacing spacing"
    }.GetNewClosure())
    
    $discoverButton.Add_Click({
        # REPLACED: Old on-demand discovery with background service picker
        # JUSTIFICATION: Background discovery eliminates UI blocking and provides instant service access
        try {
            $serviceGroups = Get-ServiceGroups
            if (-not $serviceGroups -or $serviceGroups.Count -eq 0) {
                # Trigger background discovery if no cache available
                Initialize-BackgroundServiceDiscovery
                [System.Windows.MessageBox]::Show("Service discovery is running in the background.\nServices will be available shortly.", "Background Discovery", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            } else {
                # Show service picker with cached data
                Show-ServicePickerDialog -ServiceGroups $serviceGroups
            }
        } catch {
            [System.Windows.MessageBox]::Show("Service discovery failed: $($_.Exception.Message)", "Discovery Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
    }.GetNewClosure())
    
    [System.Windows.Controls.Grid]::SetRow($buttonPanel, 2)
    
    # Add all elements to grid
    $grid.Children.Add($headerGrid)
    $grid.Children.Add($settingsStack)
    $grid.Children.Add($buttonPanel)
    
    # Set grid as panel content
    $panel.Content = $grid
    
    # Add panel to side panel container
    $global:SidePanelContainer.Children.Add($panel)
}

function Set-DataGridSpacing {
    param([string]$SpacingType)
    
    try {
        Write-Verbose "Applying $SpacingType spacing (column widths only - padding is fixed in XAML)"
        
        # Calculate new column widths based on spacing type
        $nameWidth = 120      # Base width
        $instanceIdWidth = 100
        $stateWidth = 80      # Base width
        $healthWidth = 80     # Base width
        $ipWidth = 100
        $platformWidth = 70
        $typeWidth = 90
        $regionWidth = 80
        $uptimeWidth = 60
        
        switch ($SpacingType) {
            "Compact" {
                # Reduce all widths by 10px for compact view
                $nameWidth = 110
                $instanceIdWidth = 90
                $stateWidth = 70
                $healthWidth = 70
                $ipWidth = 90
                $platformWidth = 60
                $typeWidth = 80
                $regionWidth = 70
                $uptimeWidth = 50
            }
            "Comfortable" {
                # Increase all widths by 15px for comfortable view
                $nameWidth = 135
                $instanceIdWidth = 115
                $stateWidth = 95
                $healthWidth = 95
                $ipWidth = 115
                $platformWidth = 85
                $typeWidth = 105
                $regionWidth = 95
                $uptimeWidth = 75
            }
            # "Balanced" uses the default values above
        }
        
        # Apply new widths to DataGrid columns
        if ($global:dgEC2 -and $global:dgEC2.Columns -and $global:dgEC2.Columns.Count -ge 9) {
            try {
                $global:dgEC2.Columns[0].Width = $nameWidth        # Name
                $global:dgEC2.Columns[1].Width = $instanceIdWidth  # Instance ID
                $global:dgEC2.Columns[2].Width = $stateWidth       # State
                $global:dgEC2.Columns[3].Width = $healthWidth      # Health
                $global:dgEC2.Columns[4].Width = $ipWidth          # IP Address
                $global:dgEC2.Columns[5].Width = $platformWidth    # Platform
                $global:dgEC2.Columns[6].Width = $typeWidth        # Type
                $global:dgEC2.Columns[7].Width = $regionWidth      # Region
                $global:dgEC2.Columns[8].Width = $uptimeWidth      # Uptime
                
                # Force layout update
                $global:dgEC2.UpdateLayout()
                
                Write-Verbose "Successfully applied $SpacingType column widths"
                $global:lblStatus.Content = "✅ $SpacingType spacing applied to all columns"
            } catch {
                Write-Verbose "Column width update failed: $($_.Exception.Message)"
                $global:lblStatus.Content = "⚠️ Column spacing partially applied"
            }
        } else {
            Write-Verbose "DataGrid not ready for column width updates"
            $global:lblStatus.Content = "⚠️ DataGrid not ready - try after searching for instances"
        }
        
    } catch {
        Write-Warning "Failed to apply DataGrid spacing: $($_.Exception.Message)"
        $global:lblStatus.Content = "❌ Spacing update failed: $($_.Exception.Message)"
    }
}

function Update-ServiceTabs {
    try {
        $userSettings = Get-UserSettings
        $enabledServices = @('EC2', 'RDS', 'S3', 'Lambda')
        
        # Check if Services property exists using proper PowerShell syntax
        $hasServicesProperty = $false
        try {
            if ($userSettings -and $userSettings.Services) {
                $hasServicesProperty = $true
            }
        } catch {
            $hasServicesProperty = $false
        }
        
        if ($hasServicesProperty) {
            $enabledServices = $userSettings.Services
        }
        
        # Remove existing service tabs (keep EC2)
        $tabsToRemove = @()
        foreach ($tab in $global:tcServices.Items) {
            if ($tab.Name -ne 'tabEC2') {
                $tabsToRemove += $tab
            }
        }
        foreach ($tab in $tabsToRemove) {
            $global:tcServices.Items.Remove($tab)
        }
        
        # Add enabled service tabs
        foreach ($serviceKey in $enabledServices) {
            if ($serviceKey -ne 'EC2') {
                $tab = New-Object System.Windows.Controls.TabItem
                $tab.Header = Get-ServiceDisplayName $serviceKey
                $tab.Tag = $serviceKey
                
                $label = New-Object System.Windows.Controls.Label
                $label.Content = "Select profile and click Search to find $serviceKey resources"
                $label.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
                $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $tab.Content = $label
                
                $global:tcServices.Items.Add($tab) | Out-Null
            }
        }
        
        Write-Verbose "Updated service tabs: $($enabledServices -join ', ')"
    } catch {
        Write-Warning "Failed to update service tabs: $($_.Exception.Message)"
    }
}

function Get-ServiceDisplayName {
    param([string]$ServiceKey)
    
    $serviceMap = @{
        'EC2' = '🖥️ EC2 Instances'
        'RDS' = '🗄️ RDS Databases'
        'S3' = '🪣 S3 Buckets'
        'Lambda' = '⚡ Lambda Functions'
        'ECS' = '📦 ECS Services'
        'EKS' = '☸️ EKS Clusters'
        'CloudFormation' = '📋 CloudFormation'
        'IAM' = '👤 IAM Users/Roles'
        'VPC' = '🌐 VPC Networks'
        'Route53' = '🌍 Route53 Domains'
    }
    
    return if ($serviceMap.ContainsKey($ServiceKey)) { $serviceMap[$ServiceKey] } else { $ServiceKey }
}

function Get-DiscoveryStatusText {
    # Helper function to get formatted discovery status
    try {
        $cacheData = Get-ServiceCache
        if ($cacheData -and $cacheData.lastUpdated) {
            $lastUpdate = [DateTime]::Parse($cacheData.lastUpdated)
            $timeSince = (Get-Date) - $lastUpdate
            
            if ($timeSince.TotalMinutes -lt 1) {
                return "$([math]::Floor($timeSince.TotalSeconds)) seconds ago"
            } elseif ($timeSince.TotalHours -lt 1) {
                return "$([math]::Floor($timeSince.TotalMinutes)) minutes ago"
            } else {
                return "$([math]::Floor($timeSince.TotalHours)) hours ago"
            }
        }
        return "Never"
    } catch {
        return "Unknown"
    }
}

function Show-ServicePickerDialog {
    param([hashtable]$ServiceGroups)
    
    # REPLACED: Complex service discovery UI with simple service picker
    # JUSTIFICATION: Background discovery provides organized service groups for easy selection
    try {
        # Create service picker window
        $pickerWindow = New-Object System.Windows.Window
        $pickerWindow.Title = "AWS Service Configuration"
        $pickerWindow.Width = 500
        $pickerWindow.Height = 600
        $pickerWindow.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
        $pickerWindow.Owner = [System.Windows.Window]::GetWindow($global:SidePanelContainer)
        
        # Create main grid
        $mainGrid = New-Object System.Windows.Controls.Grid
        $mainGrid.Margin = New-Object System.Windows.Thickness(20)
        
        # Add rows
        $headerRow = New-Object System.Windows.Controls.RowDefinition
        $headerRow.Height = [System.Windows.GridLength]::Auto
        $contentRow = New-Object System.Windows.Controls.RowDefinition
        $contentRow.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $buttonRow = New-Object System.Windows.Controls.RowDefinition
        $buttonRow.Height = [System.Windows.GridLength]::Auto
        
        $mainGrid.RowDefinitions.Add($headerRow)
        $mainGrid.RowDefinitions.Add($contentRow)
        $mainGrid.RowDefinitions.Add($buttonRow)
        
        # Header
        $header = New-Object System.Windows.Controls.Label
        $header.Content = "🔧 Select AWS Services to Enable"
        $header.FontSize = 16
        $header.FontWeight = [System.Windows.FontWeights]::Bold
        $header.Margin = New-Object System.Windows.Thickness(0, 0, 0, 20)
        [System.Windows.Controls.Grid]::SetRow($header, 0)
        
        # Service tree view
        $treeView = New-Object System.Windows.Controls.TreeView
        $treeView.Margin = New-Object System.Windows.Thickness(0, 0, 0, 20)
        [System.Windows.Controls.Grid]::SetRow($treeView, 1)
        
        # Get cache data to show permission status
        $cacheData = Get-ServiceCache
        $hasPermissionData = $cacheData -and $cacheData.profileName
        
        # Populate tree view with service groups
        foreach ($groupName in $ServiceGroups.Keys) {
            if ($ServiceGroups[$groupName] -and $ServiceGroups[$groupName].Count -gt 0) {
                $groupItem = New-Object System.Windows.Controls.TreeViewItem
                $groupItem.Header = "📁 $groupName ($($ServiceGroups[$groupName].Count) services)"
                $groupItem.IsExpanded = $true
                
                foreach ($service in $ServiceGroups[$groupName]) {
                    $serviceItem = New-Object System.Windows.Controls.CheckBox
                    
                    # Show permission status if available
                    if ($hasPermissionData) {
                        $serviceItem.Content = "✅ $service (accessible)"
                        $serviceItem.ToolTip = "Service is accessible with current profile: $($cacheData.profileName)"
                    } else {
                        $serviceItem.Content = "🔧 $service"
                        $serviceItem.ToolTip = "Permission status unknown - select profile to check access"
                    }
                    
                    $serviceItem.Margin = New-Object System.Windows.Thickness(20, 2, 0, 2)
                    $serviceItem.Tag = $service
                    
                    # Check if service is currently enabled
                    $userSettings = Get-UserSettings
                    $enabledServices = if ($userSettings.PSObject.Properties['Services']) { $userSettings.Services } else { @('EC2', 'RDS', 'S3', 'Lambda') }
                    $serviceItem.IsChecked = $service.ToUpper() -in $enabledServices
                    
                    $groupItem.Items.Add($serviceItem)
                }
                
                $treeView.Items.Add($groupItem)
            }
        }
        
        # Add permission status header with discovery info
        if ($hasPermissionData) {
            $header.Content = "🔧 Select AWS Services to Enable (Profile: $($cacheData.profileName))"
        } else {
            $header.Content = "🔧 Select AWS Services to Enable (No profile selected)"
        }
        
        # Add discovery status info
        $statusInfo = New-Object System.Windows.Controls.Label
        $statusInfo.FontSize = 10
        $statusInfo.Foreground = [System.Windows.Media.Brushes]::Gray
        $statusInfo.Margin = New-Object System.Windows.Thickness(0, -10, 0, 10)
        
        if ($cacheData -and $cacheData.lastUpdated) {
            $lastUpdate = [DateTime]::Parse($cacheData.lastUpdated)
            $timeSince = (Get-Date) - $lastUpdate
            
            if ($timeSince.TotalMinutes -lt 1) {
                $timeText = "$([math]::Floor($timeSince.TotalSeconds)) seconds ago"
            } elseif ($timeSince.TotalHours -lt 1) {
                $timeText = "$([math]::Floor($timeSince.TotalMinutes)) minutes ago"
            } else {
                $timeText = "$([math]::Floor($timeSince.TotalHours)) hours ago"
            }
            
            $statusInfo.Content = "📡 Background discovery: $($cacheData.count) services found $timeText (hourly checks)"
        } else {
            $statusInfo.Content = "📡 Background discovery: Running initial scan..."
        }
        
        [System.Windows.Controls.Grid]::SetRow($statusInfo, 0)
        $mainGrid.Children.Add($statusInfo)
        
        # Button panel
        $buttonPanel = New-Object System.Windows.Controls.StackPanel
        $buttonPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $buttonPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        [System.Windows.Controls.Grid]::SetRow($buttonPanel, 2)
        
        $saveButton = New-Object System.Windows.Controls.Button
        $saveButton.Content = "💾 Save Configuration"
        $saveButton.Width = 150
        $saveButton.Height = 35
        $saveButton.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        
        $cancelButton = New-Object System.Windows.Controls.Button
        $cancelButton.Content = "Cancel"
        $cancelButton.Width = 80
        $cancelButton.Height = 35
        
        $buttonPanel.Children.Add($saveButton)
        $buttonPanel.Children.Add($cancelButton)
        
        # Event handlers
        $saveButton.Add_Click({
            # Collect selected services
            $selectedServices = @()
            foreach ($groupItem in $treeView.Items) {
                foreach ($serviceItem in $groupItem.Items) {
                    if ($serviceItem -is [System.Windows.Controls.CheckBox] -and $serviceItem.IsChecked) {
                        $selectedServices += $serviceItem.Tag.ToUpper()
                    }
                }
            }
            
            # Save to user settings
            $userSettings = Get-UserSettings
            $userSettings.Services = $selectedServices
            Set-UserSettings $userSettings
            
            # Update service tabs
            Update-ServiceTabs
            
            $global:lblStatus.Content = "✅ Service configuration saved: $($selectedServices.Count) services enabled"
            $pickerWindow.Close()
        }.GetNewClosure())
        
        $cancelButton.Add_Click({
            $pickerWindow.Close()
        }.GetNewClosure())
        
        # Add elements to grid (header already added above with status)
        $mainGrid.Children.Add($header)
        $mainGrid.Children.Add($treeView)
        $mainGrid.Children.Add($buttonPanel)
        
        $pickerWindow.Content = $mainGrid
        $pickerWindow.ShowDialog()
        
    } catch {
        [System.Windows.MessageBox]::Show("Service picker failed: $($_.Exception.Message)", "Picker Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
}

# Alias for backward compatibility
function Apply-InstanceFilters {
    Set-InstanceFilters
}

Export-ModuleMember -Function Initialize-EventHandlers, Initialize-NameFilterPlaceholder, Initialize-FilterDropdowns, Set-InstanceFilters, Apply-InstanceFilters, Update-FilterDropdowns, Update-PermissionTreeView, Show-LoadingProgress, Hide-LoadingProgress, Start-AutoRefresh, Stop-AutoRefresh, Start-AutoSearch, Initialize-SearchHistoryAndFavorites, Update-SearchHistoryDropdown, Update-FavoritesDropdown, Start-SearchHistoryTimer, Show-RemoveFavoriteDialog, Start-InstanceRDPConnection, Start-InstanceSSHConnection, Show-SendCommandDialog, Show-PortForwardDialog, Show-ActiveConnectionsDialog, Add-SidePanel, Remove-SidePanel, Start-PortForwardConnection, Switch-ConnectionManagerPanel, Show-ConnectionManagerPanel, Update-AllPanelPositions, Initialize-InputValidation, Start-ConnectionMonitoring, Stop-ConnectionMonitoring, Update-ConnectionStatus, Start-StatusResetTimer, Stop-StatusResetTimer, Start-ConnectionTest, Test-ConnectionTestResults, Update-ConnectionManagerPanel, Resize-WindowForResults, Resize-DataGridColumns, Get-StaticConnectionList, Update-ConnectionList, Stop-ConnectionSession, Test-ConnectionStatus, Switch-SettingsPanel, Show-SettingsPanel, Set-DataGridSpacing, Update-ServiceTabs, Get-ServiceDisplayName, Show-ServicePickerDialog, Get-DiscoveryStatusText