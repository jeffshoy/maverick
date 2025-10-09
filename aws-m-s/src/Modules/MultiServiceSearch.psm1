# Multi-Service Search Module - Universal JSON-based service discovery

function Search-AWSService {
    param(
        [string]$ServiceKey,
        [string]$ProfileName
    )
    
    try {
        if ($global:DebugMode) {
            Write-Host "[MULTI-SERVICE] Starting search for $ServiceKey with profile $ProfileName" -ForegroundColor Cyan
        }
        
        # Update UI to show search in progress
        $global:btnSearch.Content = "⏹️ Cancel Search"
        $global:lblStatus.Content = "Searching $ServiceKey resources..."
        
        # Get the service tab to update
        $serviceTab = $global:tcServices.Items | Where-Object { $_.Tag -eq $ServiceKey } | Select-Object -First 1
        if (-not $serviceTab) {
            throw "Service tab not found for $ServiceKey"
        }
        
        # Load service configuration from JSON
        $configPath = "$PSScriptRoot\..\Config\aws-services.json"
        if (-not (Test-Path $configPath)) {
            throw "Service configuration file not found: $configPath"
        }
        
        $serviceConfig = Get-Content $configPath -Raw | ConvertFrom-Json
        $config = $serviceConfig.services.$ServiceKey
        
        if (-not $config) {
            throw "No configuration found for service: $ServiceKey"
        }
        
        # Use universal search function
        Search-UniversalAWSService -ServiceKey $ServiceKey -Config $config -ProfileName $ProfileName -ServiceTab $serviceTab
        
    } catch {
        if ($global:DebugMode) {
            Write-Host "[MULTI-SERVICE] Search failed for $ServiceKey`: $($_.Exception.Message)" -ForegroundColor Red
        }
        $global:lblStatus.Content = "❌ $ServiceKey search failed: $($_.Exception.Message)"
        
        # Show error in service tab
        if ($serviceTab) {
            $errorLabel = New-Object System.Windows.Controls.Label
            $errorLabel.Content = "Search failed: $($_.Exception.Message)"
            $errorLabel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
            $errorLabel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $errorLabel.Foreground = [System.Windows.Media.Brushes]::Red
            $serviceTab.Content = $errorLabel
        }
    } finally {
        # Reset search button
        $global:btnSearch.Content = "🔍 Search"
    }
}

function Search-UniversalAWSService {
    param(
        [string]$ServiceKey,
        [object]$Config,
        [string]$ProfileName,
        [object]$ServiceTab
    )
    
    try {
        $allResults = @()
        
        if ($Config.regions -and $Config.regions.Count -gt 0) {
            # Regional service
            foreach ($region in $Config.regions) {
                try {
                    $command = "aws $($Config.command) --region $region --profile $ProfileName --output json --cli-read-timeout 30"
                    $result = Invoke-Expression "$command 2>&1"
                    
                    if ($LASTEXITCODE -eq 0 -and $result) {
                        $data = $result | ConvertFrom-Json
                        $items = Get-DataFromPath -Data $data -Path $Config.dataPath
                        
                        if ($items) {
                            foreach ($item in $items) {
                                $obj = @{ Region = $region }
                                foreach ($field in $Config.fields) {
                                    $fieldValue = Get-FieldValue -Item $item -Field $field
                                    $fieldName = Get-FieldName -Field $field
                                    $obj[$fieldName] = $fieldValue
                                }
                                $allResults += [PSCustomObject]$obj
                            }
                        }
                    }
                } catch {
                    Write-Verbose "$ServiceKey search failed in region $region`: $($_.Exception.Message)"
                }
            }
        } else {
            # Global service
            try {
                $command = "aws $($Config.command) --profile $ProfileName --output json --cli-read-timeout 30"
                $result = Invoke-Expression "$command 2>&1"
                
                if ($LASTEXITCODE -eq 0 -and $result) {
                    $data = $result | ConvertFrom-Json
                    $items = Get-DataFromPath -Data $data -Path $Config.dataPath
                    
                    if ($items) {
                        foreach ($item in $items) {
                            $obj = @{}
                            foreach ($field in $Config.fields) {
                                $fieldValue = Get-FieldValue -Item $item -Field $field
                                $fieldName = Get-FieldName -Field $field
                                $obj[$fieldName] = $fieldValue
                            }
                            $allResults += [PSCustomObject]$obj
                        }
                    }
                }
            } catch {
                throw "$ServiceKey search failed: $($_.Exception.Message)"
            }
        }
        
        Update-ServiceTab -ServiceTab $ServiceTab -Data $allResults -ServiceName $Config.name
        $global:lblStatus.Content = "Found $($allResults.Count) $($Config.name.ToLower())"
        
    } catch {
        throw "Universal search failed for $ServiceKey`: $($_.Exception.Message)"
    }
}

function Get-DataFromPath {
    param([object]$Data, [string]$Path)
    
    if (-not $Path -or $Path -eq "") {
        return $Data
    }
    
    # Handle simple property access
    $parts = $Path -split '\.' 
    $current = $Data
    
    foreach ($part in $parts) {
        if ($part -match '\[\]$') {
            # Array access
            $prop = $part -replace '\[\]$', ''
            if ($current.$prop) {
                $current = $current.$prop
            } else {
                return $null
            }
        } else {
            # Simple property
            if ($current.$part) {
                $current = $current.$part
            } else {
                return $null
            }
        }
    }
    
    return $current
}

function Get-FieldValue {
    param([object]$Item, [string]$Field)
    
    if ($Field -match '\[\?') {
        # Complex JMESPath query - simplified handling
        if ($Field -like "*Tags*Name*") {
            # Handle Name tag extraction
            if ($Item.Tags) {
                $nameTag = $Item.Tags | Where-Object { $_.Key -eq "Name" } | Select-Object -First 1
                return if ($nameTag) { $nameTag.Value } else { "N/A" }
            }
        }
        return "N/A"
    } else {
        # Simple field access
        $parts = $Field -split '\.'
        $current = $Item
        
        foreach ($part in $parts) {
            if ($current.$part) {
                $current = $current.$part
            } else {
                return "N/A"
            }
        }
        
        return $current
    }
}

function Get-FieldName {
    param([string]$Field)
    
    # Extract simple field name for display
    if ($Field -like "*Tags*Name*") {
        return "Name"
    }
    
    $parts = $Field -split '\.'
    return $parts[-1] -replace '\[.*\]', ''
}



function Update-ServiceTab {
    param([object]$ServiceTab, [array]$Data, [string]$ServiceName)
    
    if ($Data.Count -eq 0) {
        $noDataLabel = New-Object System.Windows.Controls.Label
        $noDataLabel.Content = "No $ServiceName found"
        $noDataLabel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $noDataLabel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $noDataLabel.Foreground = [System.Windows.Media.Brushes]::Gray
        $ServiceTab.Content = $noDataLabel
    } else {
        # Create DataGrid for results
        $dataGrid = New-Object System.Windows.Controls.DataGrid
        $dataGrid.AutoGenerateColumns = $true
        $dataGrid.IsReadOnly = $true
        $dataGrid.Margin = New-Object System.Windows.Thickness(10)
        $dataGrid.GridLinesVisibility = [System.Windows.Controls.DataGridGridLinesVisibility]::All
        $dataGrid.HeadersVisibility = [System.Windows.Controls.DataGridHeadersVisibility]::All
        $dataGrid.ItemsSource = $Data
        $ServiceTab.Content = $dataGrid
    }
}

function Stop-AllServiceSearchJobs {
    # Placeholder for stopping background jobs
    Write-Verbose "Stopping all service search jobs"
}

Export-ModuleMember -Function Search-AWSService, Stop-AllServiceSearchJobs