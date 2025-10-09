# AWS Service Manager - Dynamic service tabs and global search
# Provides tabbed interface for different AWS services with dynamic content

# Service configuration - expandable list of AWS services
$script:AvailableServices = @{
    'EC2' = @{
        Name = 'EC2 Instances'
        Icon = '🖥️'
        Description = 'Virtual servers and compute instances'
        SearchCommand = 'describe-instances'
        Regions = @('us-east-1', 'us-west-2', 'ca-central-1')
        RequiredPermissions = @('ec2:DescribeInstances')
        Enabled = $true
    }
    'RDS' = @{
        Name = 'RDS Databases'
        Icon = '🗄️'
        Description = 'Relational database instances'
        SearchCommand = 'describe-db-instances'
        Regions = @('us-east-1', 'us-west-2', 'ca-central-1')
        RequiredPermissions = @('rds:DescribeDBInstances')
        Enabled = $true
    }
    'S3' = @{
        Name = 'S3 Buckets'
        Icon = '🪣'
        Description = 'Object storage buckets'
        SearchCommand = 'list-buckets'
        Regions = @('global')  # S3 list-buckets is global
        RequiredPermissions = @('s3:ListAllMyBuckets')
        Enabled = $true
    }
    'Lambda' = @{
        Name = 'Lambda Functions'
        Icon = 'λ'
        Description = 'Serverless compute functions'
        SearchCommand = 'list-functions'
        Regions = @('us-east-1', 'us-west-2', 'ca-central-1')
        RequiredPermissions = @('lambda:ListFunctions')
        Enabled = $true
    }
    'ELB' = @{
        Name = 'Load Balancers'
        Icon = '⚖️'
        Description = 'Application and network load balancers'
        SearchCommand = 'describe-load-balancers'
        Regions = @('us-east-1', 'us-west-2', 'ca-central-1')
        RequiredPermissions = @('elasticloadbalancing:DescribeLoadBalancers')
        Enabled = $true
    }
    'CloudFormation' = @{
        Name = 'CloudFormation'
        Icon = '📚'
        Description = 'Infrastructure as code stacks'
        SearchCommand = 'describe-stacks'
        Regions = @('us-east-1', 'us-west-2', 'ca-central-1')
        RequiredPermissions = @('cloudformation:DescribeStacks')
        Enabled = $true
    }
}

# Current active service
$script:CurrentService = 'EC2'
$script:ServiceTabs = @{}
$script:ServiceSearchJobs = @{}

function Initialize-ServiceTabs {
    param([object]$TabControl)
    
    if (-not $TabControl) {
        Write-Warning "TabControl is null, skipping service tab initialization"
        return
    }
    
    try {
        # Don't clear existing tabs - the EC2 tab is already there
        # Just add additional service tabs
        
        # Get user's enabled services from settings
        $userSettings = Get-UserSettings
        $enabledServices = if ($userSettings.PSObject.Properties['Services']) { $userSettings.Services } else { @('RDS', 'S3', 'Lambda') }
        
        # Create tabs for enabled services (skip EC2 as it already exists)
        foreach ($serviceKey in $enabledServices) {
            if ($serviceKey -ne 'EC2' -and $script:AvailableServices.ContainsKey($serviceKey)) {
                $service = $script:AvailableServices[$serviceKey]
                $tab = New-ServiceTab -ServiceKey $serviceKey -ServiceConfig $service
                $TabControl.Items.Add($tab) | Out-Null
                $script:ServiceTabs[$serviceKey] = $tab
            }
        }
        
        # EC2 is the default current service
        $script:CurrentService = 'EC2'
        
    } catch {
        Write-Warning "Service tab initialization failed: $($_.Exception.Message)"
    }
}

function New-ServiceTab {
    param([string]$ServiceKey, [hashtable]$ServiceConfig)
    
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = "$($ServiceConfig.Icon) $($ServiceConfig.Name)"
    $tab.Tag = $ServiceKey
    $tab.ToolTip = $ServiceConfig.Description
    
    # Create tab content grid
    $grid = New-Object System.Windows.Controls.Grid
    
    # Add row definitions
    $headerRow = New-Object System.Windows.Controls.RowDefinition
    $headerRow.Height = [System.Windows.GridLength]::Auto
    $contentRow = New-Object System.Windows.Controls.RowDefinition
    $contentRow.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    
    $grid.RowDefinitions.Add($headerRow) | Out-Null
    $grid.RowDefinitions.Add($contentRow) | Out-Null
    
    # Service-specific header
    $header = New-Object System.Windows.Controls.Label
    $header.Content = "Search and manage $($ServiceConfig.Name.ToLower())"
    $header.FontWeight = [System.Windows.FontWeights]::Bold
    $header.Margin = New-Object System.Windows.Thickness(10, 5, 10, 5)
    [System.Windows.Controls.Grid]::SetRow($header, 0)
    
    # Create service-specific DataGrid
    $dataGrid = New-ServiceDataGrid -ServiceKey $ServiceKey
    [System.Windows.Controls.Grid]::SetRow($dataGrid, 1)
    
    $grid.Children.Add($header) | Out-Null
    $grid.Children.Add($dataGrid) | Out-Null
    
    $tab.Content = $grid
    return $tab
}

function New-ServiceDataGrid {
    param([string]$ServiceKey)
    
    $dataGrid = New-Object System.Windows.Controls.DataGrid
    $dataGrid.Name = "dg$ServiceKey"
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true
    $dataGrid.GridLinesVisibility = [System.Windows.Controls.DataGridGridLinesVisibility]::All
    $dataGrid.HeadersVisibility = [System.Windows.Controls.DataGridHeadersVisibility]::All
    $dataGrid.Margin = New-Object System.Windows.Thickness(10)
    
    # Create service-specific columns
    switch ($ServiceKey) {
        'EC2' {
            Add-DataGridColumn $dataGrid "Name" "Name" 120
            Add-DataGridColumn $dataGrid "Instance ID" "InstanceId" 100
            Add-DataGridColumn $dataGrid "State" "State" 70
            Add-DataGridColumn $dataGrid "Type" "InstanceType" 90
            Add-DataGridColumn $dataGrid "Region" "Region" 80
        }
        'RDS' {
            Add-DataGridColumn $dataGrid "DB Name" "DBInstanceIdentifier" 150
            Add-DataGridColumn $dataGrid "Engine" "Engine" 80
            Add-DataGridColumn $dataGrid "Status" "DBInstanceStatus" 80
            Add-DataGridColumn $dataGrid "Class" "DBInstanceClass" 100
            Add-DataGridColumn $dataGrid "Region" "Region" 80
        }
        'S3' {
            Add-DataGridColumn $dataGrid "Bucket Name" "Name" 200
            Add-DataGridColumn $dataGrid "Creation Date" "CreationDate" 120
            Add-DataGridColumn $dataGrid "Region" "Region" 100
        }
        'Lambda' {
            Add-DataGridColumn $dataGrid "Function Name" "FunctionName" 180
            Add-DataGridColumn $dataGrid "Runtime" "Runtime" 100
            Add-DataGridColumn $dataGrid "Last Modified" "LastModified" 120
            Add-DataGridColumn $dataGrid "Region" "Region" 80
        }
        'ELB' {
            Add-DataGridColumn $dataGrid "Load Balancer" "LoadBalancerName" 180
            Add-DataGridColumn $dataGrid "Type" "Type" 80
            Add-DataGridColumn $dataGrid "State" "State" 80
            Add-DataGridColumn $dataGrid "Region" "Region" 80
        }
        'CloudFormation' {
            Add-DataGridColumn $dataGrid "Stack Name" "StackName" 180
            Add-DataGridColumn $dataGrid "Status" "StackStatus" 120
            Add-DataGridColumn $dataGrid "Creation Time" "CreationTime" 120
            Add-DataGridColumn $dataGrid "Region" "Region" 80
        }
    }
    
    # Initialize with empty ArrayList to prevent "Object[] Array" display
    $emptyList = New-Object System.Collections.ArrayList
    $emptyItem = [PSCustomObject]@{}
    
    # Add service-specific empty message
    switch ($ServiceKey) {
        'RDS' { 
            $emptyItem | Add-Member -NotePropertyName 'DBInstanceIdentifier' -NotePropertyValue 'Select profile and search for RDS instances'
            $emptyItem | Add-Member -NotePropertyName 'Engine' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'DBInstanceStatus' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'DBInstanceClass' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
        }
        'S3' {
            $emptyItem | Add-Member -NotePropertyName 'Name' -NotePropertyValue 'Select profile and search for S3 buckets'
            $emptyItem | Add-Member -NotePropertyName 'CreationDate' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
        }
        'Lambda' {
            $emptyItem | Add-Member -NotePropertyName 'FunctionName' -NotePropertyValue 'Select profile and search for Lambda functions'
            $emptyItem | Add-Member -NotePropertyName 'Runtime' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'LastModified' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
        }
        'ELB' {
            $emptyItem | Add-Member -NotePropertyName 'LoadBalancerName' -NotePropertyValue 'Select profile and search for Load Balancers'
            $emptyItem | Add-Member -NotePropertyName 'Type' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'State' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
        }
        'CloudFormation' {
            $emptyItem | Add-Member -NotePropertyName 'StackName' -NotePropertyValue 'Select profile and search for CloudFormation stacks'
            $emptyItem | Add-Member -NotePropertyName 'StackStatus' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'CreationTime' -NotePropertyValue ''
            $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
        }
    }
    
    $emptyList.Add($emptyItem) | Out-Null
    $dataGrid.ItemsSource = $emptyList
    
    return $dataGrid
}

function Add-DataGridColumn {
    param([object]$DataGrid, [string]$Header, [string]$Binding, [int]$Width)
    
    $column = New-Object System.Windows.Controls.DataGridTextColumn
    $column.Header = $Header
    $column.Binding = New-Object System.Windows.Data.Binding($Binding)
    $column.Width = $Width
    $DataGrid.Columns.Add($column) | Out-Null
}

function Search-AWSService {
    param(
        [string]$ServiceKey,
        [string]$ProfileName,
        [bool]$IsAutoRefresh = $false
    )
    
    Write-DebugLog "[SEARCH-START] Starting search for service: $ServiceKey, Profile: $ProfileName" "INFO" "AWSServiceManager"
    
    if (-not $ProfileName -or -not $script:AvailableServices.ContainsKey($ServiceKey)) {
        Write-DebugLog "[SEARCH-START] Invalid parameters - ProfileName: '$ProfileName', ServiceKey exists: $($script:AvailableServices.ContainsKey($ServiceKey))" "WARNING" "AWSServiceManager"
        return
    }
    
    $service = $script:AvailableServices[$ServiceKey]
    Write-DebugLog "[SEARCH-START] Service config loaded: $($service.Name)" "INFO" "AWSServiceManager"
    
    # Cancel existing search for this service
    Stop-ServiceSearchJob -ServiceKey $ServiceKey
    Write-DebugLog "[SEARCH-START] Existing search job stopped for $ServiceKey" "INFO" "AWSServiceManager"
    
    # Update status
    if (-not $IsAutoRefresh) {
        $global:lblStatus.Content = "Searching $($service.Name.ToLower())..."
        Write-DebugLog "[SEARCH-START] Status updated for $ServiceKey" "INFO" "AWSServiceManager"
    }
    
    try {
        # Create background search job
        Write-DebugLog "[SEARCH-START] Creating runspace for $ServiceKey" "INFO" "AWSServiceManager"
        $script:ServiceSearchJobs[$ServiceKey] = @{
            Runspace = [runspacefactory]::CreateRunspace()
            PowerShell = $null
            AsyncResult = $null
            Timer = $null
        }
        
        $script:ServiceSearchJobs[$ServiceKey].Runspace.Open()
        Write-DebugLog "[SEARCH-START] Runspace opened for $ServiceKey" "INFO" "AWSServiceManager"
        
        $script:ServiceSearchJobs[$ServiceKey].PowerShell = [powershell]::Create()
        $script:ServiceSearchJobs[$ServiceKey].PowerShell.Runspace = $script:ServiceSearchJobs[$ServiceKey].Runspace
        Write-DebugLog "[SEARCH-START] PowerShell instance created for $ServiceKey" "INFO" "AWSServiceManager"
        
        # Create service-specific search script
        $searchScript = Get-ServiceSearchScript -ServiceKey $ServiceKey
        Write-DebugLog "[SEARCH-START] Search script retrieved for $ServiceKey" "INFO" "AWSServiceManager"
        
        # Add script and parameters
        $script:ServiceSearchJobs[$ServiceKey].PowerShell.AddScript($searchScript).AddParameter("ProfileName", $ProfileName).AddParameter("ServiceConfig", $service) | Out-Null
        Write-DebugLog "[SEARCH-START] Script and parameters added for $ServiceKey" "INFO" "AWSServiceManager"
        
        # Start async execution
        try {
            $script:ServiceSearchJobs[$ServiceKey].AsyncResult = $script:ServiceSearchJobs[$ServiceKey].PowerShell.BeginInvoke()
            Write-DebugLog "[SEARCH-START] BeginInvoke completed for $ServiceKey. AsyncResult: $($script:ServiceSearchJobs[$ServiceKey].AsyncResult -ne $null)" "INFO" "AWSServiceManager"
            
            if (-not $script:ServiceSearchJobs[$ServiceKey].AsyncResult) {
                Write-DebugLog "[SEARCH-START] BeginInvoke returned null AsyncResult for $ServiceKey" "ERROR" "AWSServiceManager"
                throw "BeginInvoke returned null AsyncResult"
            }
        } catch {
            Write-DebugLog "[SEARCH-START] BeginInvoke failed for $ServiceKey`: $($_.Exception.Message)" "ERROR" "AWSServiceManager"
            throw
        }
        
        # Only start timer if AsyncResult is valid
        if ($script:ServiceSearchJobs[$ServiceKey].AsyncResult) {
            Start-ServiceSearchTimer -ServiceKey $ServiceKey
            Write-DebugLog "[SEARCH-START] Progress timer started for $ServiceKey" "INFO" "AWSServiceManager"
        } else {
            Write-DebugLog "[SEARCH-START] Skipping timer start - AsyncResult is null for $ServiceKey" "ERROR" "AWSServiceManager"
            throw "Cannot start timer with null AsyncResult"
        }
        
    } catch {
        Write-DebugLog "[SEARCH-START] Exception during search setup for $ServiceKey`: $($_.Exception.Message)" "ERROR" "AWSServiceManager"
        Write-DebugLog "[SEARCH-START] Exception type: $($_.Exception.GetType().Name)" "ERROR" "AWSServiceManager"
        
        # Cleanup on error
        Stop-ServiceSearchJob -ServiceKey $ServiceKey
        
        $global:lblStatus.Content = "$($service.Name) search failed to start: $($_.Exception.Message)"
    }
}

function Get-ServiceSearchScript {
    param([string]$ServiceKey)
    
    switch ($ServiceKey) {
        'EC2' {
            return {
                param($ProfileName, $ServiceConfig)
                
                $regions = $ServiceConfig.Regions
                $allItems = @()
                
                foreach ($region in $regions) {
                    try {
                        $query = "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceId,State.Name,InstanceType,LaunchTime]"
                        $result = & aws ec2 describe-instances --region $region --profile $ProfileName --query $query --output json --cli-read-timeout 30 2>&1
                        
                        if ($LASTEXITCODE -eq 0 -and $result) {
                            $instances = $result | ConvertFrom-Json
                            if ($instances -and $instances.Count -gt 0) {
                                foreach ($instance in $instances) {
                                    if ($instance -and $instance.Count -ge 5) {
                                        $allItems += [PSCustomObject]@{
                                            Name = if ($instance[0]) { $instance[0] } else { "(no name)" }
                                            InstanceId = $instance[1]
                                            State = $instance[2]
                                            InstanceType = $instance[3]
                                            LaunchTime = $instance[4]
                                            Region = $region
                                        }
                                    }
                                }
                            }
                        }
                    } catch {
                        # Continue with other regions
                    }
                }
                
                return @{ Success = $true; Items = $allItems; ServiceKey = 'EC2' }
            }
        }
        'RDS' {
            return {
                param($ProfileName, $ServiceConfig)
                
                # Enhanced debug logging for RDS search
                Write-Host "[RDS-SEARCH] Starting RDS search with profile: $ProfileName" -ForegroundColor Cyan
                
                $regions = $ServiceConfig.Regions
                $allItems = @()
                
                Write-Host "[RDS-SEARCH] Searching regions: $($regions -join ', ')" -ForegroundColor Cyan
                
                foreach ($region in $regions) {
                    try {
                        Write-Host "[RDS-SEARCH] Searching region: $region" -ForegroundColor Cyan
                        
                        $result = & aws rds describe-db-instances --region $region --profile $ProfileName --output json --cli-read-timeout 30 2>&1
                        
                        Write-Host "[RDS-SEARCH] AWS CLI exit code: $LASTEXITCODE" -ForegroundColor Cyan
                        Write-Host "[RDS-SEARCH] Result type: $($result.GetType().Name)" -ForegroundColor Cyan
                        Write-Host "[RDS-SEARCH] Result length: $($result.Length)" -ForegroundColor Cyan
                        
                        if ($LASTEXITCODE -eq 0 -and $result -and $result -ne "null") {
                            $jsonString = if ($result.GetType().Name -eq "String") { $result } else { $result -join "" }
                            
                            Write-Host "[RDS-SEARCH] JSON string length: $($jsonString.Length)" -ForegroundColor Cyan
                            
                            if ($jsonString.Trim() -ne "" -and $jsonString.Trim() -ne "null") {
                                Write-Host "[RDS-SEARCH] Parsing JSON for region: $region" -ForegroundColor Cyan
                                
                                $data = $jsonString | ConvertFrom-Json
                                
                                Write-Host "[RDS-SEARCH] JSON parsed. DBInstances count: $($data.DBInstances.Count)" -ForegroundColor Cyan
                                
                                if ($data.DBInstances -and $data.DBInstances.Count -gt 0) {
                                    foreach ($db in $data.DBInstances) {
                                        $allItems += [PSCustomObject]@{
                                            DBInstanceIdentifier = if ($db.DBInstanceIdentifier) { $db.DBInstanceIdentifier } else { "Unknown" }
                                            Engine = if ($db.Engine) { $db.Engine } else { "Unknown" }
                                            DBInstanceStatus = if ($db.DBInstanceStatus) { $db.DBInstanceStatus } else { "Unknown" }
                                            DBInstanceClass = if ($db.DBInstanceClass) { $db.DBInstanceClass } else { "Unknown" }
                                            Region = $region
                                        }
                                    }
                                    Write-Host "[RDS-SEARCH] Added $($data.DBInstances.Count) instances from region: $region" -ForegroundColor Cyan
                                } else {
                                    Write-Host "[RDS-SEARCH] No DB instances found in region: $region" -ForegroundColor Yellow
                                }
                            } else {
                                Write-Host "[RDS-SEARCH] Empty or null JSON response for region: $region" -ForegroundColor Yellow
                            }
                        } else {
                            Write-Host "[RDS-SEARCH] AWS CLI failed for region $region. Exit code: $LASTEXITCODE" -ForegroundColor Red
                            if ($result) {
                                Write-Host "[RDS-SEARCH] Error output: $result" -ForegroundColor Red
                            }
                        }
                    } catch {
                        Write-Host "[RDS-SEARCH] Exception in region $region`: $($_.Exception.Message)" -ForegroundColor Red
                        Write-Host "[RDS-SEARCH] Exception type: $($_.Exception.GetType().Name)" -ForegroundColor Red
                    }
                }
                
                Write-Host "[RDS-SEARCH] Search completed. Total items found: $($allItems.Count)" -ForegroundColor Cyan
                
                $result = @{ Success = $true; Items = $allItems; ServiceKey = 'RDS' }
                Write-Host "[RDS-SEARCH] Returning result with Success: $($result.Success), Items: $($result.Items.Count)" -ForegroundColor Cyan
                
                return $result
            }
        }
        'S3' {
            return {
                param($ProfileName, $ServiceConfig)
                
                $allItems = @()
                
                try {
                    $result = & aws s3api list-buckets --profile $ProfileName --output json --cli-read-timeout 30 2>&1
                    
                    if ($LASTEXITCODE -eq 0 -and $result) {
                        $data = $result | ConvertFrom-Json
                        if ($data -and $data.Buckets -and $data.Buckets.Count -gt 0) {
                            foreach ($bucket in $data.Buckets) {
                                if ($bucket -and $bucket.Name) {
                                    # Get bucket region
                                    $region = "Unknown"
                                    try {
                                        $locationResult = & aws s3api get-bucket-location --bucket $bucket.Name --profile $ProfileName --output json 2>$null
                                        if ($LASTEXITCODE -eq 0 -and $locationResult) {
                                            $location = $locationResult | ConvertFrom-Json
                                            $region = if ($location.LocationConstraint) { $location.LocationConstraint } else { "us-east-1" }
                                        }
                                    } catch {
                                        # Use default region if location check fails
                                    }
                                    
                                    $allItems += [PSCustomObject]@{
                                        Name = $bucket.Name
                                        CreationDate = $bucket.CreationDate
                                        Region = $region
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    # S3 access failed
                }
                
                return @{ Success = $true; Items = $allItems; ServiceKey = 'S3' }
            }
        }
        'Lambda' {
            return {
                param($ProfileName, $ServiceConfig)
                
                $regions = $ServiceConfig.Regions
                $allItems = @()
                
                foreach ($region in $regions) {
                    try {
                        $result = & aws lambda list-functions --region $region --profile $ProfileName --output json --cli-read-timeout 30 2>&1
                        
                        if ($LASTEXITCODE -eq 0 -and $result) {
                            $data = $result | ConvertFrom-Json
                            if ($data -and $data.Functions -and $data.Functions.Count -gt 0) {
                                foreach ($func in $data.Functions) {
                                    if ($func -and $func.FunctionName) {
                                        $allItems += [PSCustomObject]@{
                                            FunctionName = $func.FunctionName
                                            Runtime = $func.Runtime
                                            LastModified = $func.LastModified
                                            Region = $region
                                        }
                                    }
                                }
                            }
                        }
                    } catch {
                        # Continue with other regions
                    }
                }
                
                return @{ Success = $true; Items = $allItems; ServiceKey = 'Lambda' }
            }
        }
        'ELB' {
            return {
                param($ProfileName, $ServiceConfig)
                
                $regions = $ServiceConfig.Regions
                $allItems = @()
                
                foreach ($region in $regions) {
                    try {
                        # Get both ALB/NLB and Classic ELB
                        $result = & aws elbv2 describe-load-balancers --region $region --profile $ProfileName --output json --cli-read-timeout 30 2>&1
                        
                        if ($LASTEXITCODE -eq 0 -and $result) {
                            $data = $result | ConvertFrom-Json
                            if ($data -and $data.LoadBalancers -and $data.LoadBalancers.Count -gt 0) {
                                foreach ($lb in $data.LoadBalancers) {
                                    if ($lb -and $lb.LoadBalancerName) {
                                        $allItems += [PSCustomObject]@{
                                            LoadBalancerName = $lb.LoadBalancerName
                                            Type = $lb.Type
                                            State = if ($lb.State -and $lb.State.Code) { $lb.State.Code } else { "Unknown" }
                                            Region = $region
                                        }
                                    }
                                }
                            }
                        }
                    } catch {
                        # Continue with other regions
                    }
                }
                
                return @{ Success = $true; Items = $allItems; ServiceKey = 'ELB' }
            }
        }
        'CloudFormation' {
            return {
                param($ProfileName, $ServiceConfig)
                
                $regions = $ServiceConfig.Regions
                $allItems = @()
                
                foreach ($region in $regions) {
                    try {
                        $result = & aws cloudformation describe-stacks --region $region --profile $ProfileName --output json --cli-read-timeout 30 2>&1
                        
                        if ($LASTEXITCODE -eq 0 -and $result) {
                            $data = $result | ConvertFrom-Json
                            if ($data -and $data.Stacks -and $data.Stacks.Count -gt 0) {
                                foreach ($stack in $data.Stacks) {
                                    if ($stack -and $stack.StackName) {
                                        $allItems += [PSCustomObject]@{
                                            StackName = $stack.StackName
                                            StackStatus = $stack.StackStatus
                                            CreationTime = $stack.CreationTime
                                            Region = $region
                                        }
                                    }
                                }
                            }
                        }
                    } catch {
                        # Continue with other regions
                    }
                }
                
                return @{ Success = $true; Items = $allItems; ServiceKey = 'CloudFormation' }
            }
        }
        default {
            return {
                param($ProfileName, $ServiceConfig)
                return @{ Success = $false; Items = @(); ServiceKey = $ServiceKey }
            }
        }
    }
}

function Start-ServiceSearchTimer {
    param([string]$ServiceKey)
    
    Write-DebugLog "[SEARCH-TIMER] Starting timer for service: $ServiceKey" "INFO" "AWSServiceManager"
    
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
        try {
            $job = $script:ServiceSearchJobs[$ServiceKey]
            if ($job -and $job.PowerShell) {
                $state = $job.PowerShell.InvocationStateInfo.State
                
                # Only log state changes to avoid spam
                if (-not $job.LastLoggedState -or $job.LastLoggedState -ne $state) {
                    Write-DebugLog "[SEARCH-TIMER] State change for $ServiceKey`: $state" "INFO" "AWSServiceManager"
                    $job.LastLoggedState = $state
                }
                
                if ($state -in @("Completed", "Failed", "Stopped")) {
                    Write-DebugLog "[SEARCH-TIMER] Final state reached for $ServiceKey`: $state. Calling completion." "INFO" "AWSServiceManager"
                    Complete-ServiceSearchOperation -ServiceKey $ServiceKey
                }
            } else {
                Write-DebugLog "[SEARCH-TIMER] Job or PowerShell is null for $ServiceKey" "WARNING" "AWSServiceManager"
            }
        } catch {
            Write-DebugLog "[SEARCH-TIMER] Timer exception for $ServiceKey`: $($_.Exception.Message)" "ERROR" "AWSServiceManager"
            # Timer error - stop the timer and cleanup
            if ($script:ServiceSearchJobs.ContainsKey($ServiceKey)) {
                Stop-ServiceSearchJob -ServiceKey $ServiceKey
            }
        }
    }.GetNewClosure())
    
    $script:ServiceSearchJobs[$ServiceKey].Timer = $timer
    $timer.Start()
    
    Write-DebugLog "[SEARCH-TIMER] Timer started for service: $ServiceKey" "INFO" "AWSServiceManager"
}

function Complete-ServiceSearchOperation {
    param([string]$ServiceKey)
    
    try {
        Write-DebugLog "[SEARCH-COMPLETE] Starting completion for service: $ServiceKey" "INFO" "AWSServiceManager"
        
        $job = $script:ServiceSearchJobs[$ServiceKey]
        if (-not $job -or -not $job.PowerShell) { 
            Write-DebugLog "[SEARCH-COMPLETE] Job or PowerShell is null for $ServiceKey" "WARNING" "AWSServiceManager"
            return 
        }
        
        Write-DebugLog "[SEARCH-COMPLETE] PowerShell state: $($job.PowerShell.InvocationStateInfo.State)" "INFO" "AWSServiceManager"
        Write-DebugLog "[SEARCH-COMPLETE] AsyncResult completed: $($job.AsyncResult.IsCompleted)" "INFO" "AWSServiceManager"
        
        # Stop timer first
        if ($job.Timer) {
            $job.Timer.Stop()
            Write-DebugLog "[SEARCH-COMPLETE] Timer stopped for $ServiceKey" "INFO" "AWSServiceManager"
        }
        
        # Check if PowerShell is in a valid state for EndInvoke
        if ($job.PowerShell.InvocationStateInfo.State -eq "Completed" -and $job.AsyncResult -and $job.AsyncResult.IsCompleted) {
            try {
                Write-DebugLog "[SEARCH-COMPLETE] Calling EndInvoke for $ServiceKey" "INFO" "AWSServiceManager"
                
                # Get results with error handling
                $results = $job.PowerShell.EndInvoke($job.AsyncResult)
                
                Write-DebugLog "[SEARCH-COMPLETE] EndInvoke completed for $ServiceKey. Results type: $($results.GetType().Name)" "INFO" "AWSServiceManager"
                
                if ($results -and $results.Success) {
                    Write-DebugLog "[SEARCH-COMPLETE] Search successful for $ServiceKey. Items count: $($results.Items.Count)" "INFO" "AWSServiceManager"
                    
                    # Update the appropriate DataGrid
                    Update-ServiceDataGrid -ServiceKey $ServiceKey -Items $results.Items
                    
                    # Update status
                    $service = $script:AvailableServices[$ServiceKey]
                    $global:lblStatus.Content = "Found $($results.Items.Count) $($service.Name.ToLower())"
                    
                    # Update instance count if this is the current service
                    if ($ServiceKey -eq $script:CurrentService) {
                        $global:lblInstanceCount.Content = "$($results.Items.Count) items"
                    }
                } else {
                    Write-DebugLog "[SEARCH-COMPLETE] Search failed for $ServiceKey. Results: $($results | ConvertTo-Json -Depth 2)" "WARNING" "AWSServiceManager"
                    $service = $script:AvailableServices[$ServiceKey]
                    $global:lblStatus.Content = "$($service.Name) search failed: No results returned"
                }
            } catch {
                Write-DebugLog "[SEARCH-COMPLETE] EndInvoke exception for $ServiceKey`: $($_.Exception.Message)" "ERROR" "AWSServiceManager"
                Write-DebugLog "[SEARCH-COMPLETE] Exception type: $($_.Exception.GetType().Name)" "ERROR" "AWSServiceManager"
                Write-DebugLog "[SEARCH-COMPLETE] Stack trace: $($_.ScriptStackTrace)" "ERROR" "AWSServiceManager"
                
                $service = $script:AvailableServices[$ServiceKey]
                $global:lblStatus.Content = "$($service.Name) search failed: $($_.Exception.Message)"
            }
        } elseif ($job.PowerShell.InvocationStateInfo.State -eq "Failed") {
            Write-DebugLog "[SEARCH-COMPLETE] PowerShell execution failed for $ServiceKey" "ERROR" "AWSServiceManager"
            
            # Check for PowerShell errors
            if ($job.PowerShell.Streams.Error.Count -gt 0) {
                foreach ($error in $job.PowerShell.Streams.Error) {
                    Write-DebugLog "[SEARCH-COMPLETE] PowerShell error: $($error.ToString())" "ERROR" "AWSServiceManager"
                }
            }
            
            $service = $script:AvailableServices[$ServiceKey]
            $global:lblStatus.Content = "$($service.Name) search failed: PowerShell execution failed"
        } elseif ($job.PowerShell.InvocationStateInfo.State -eq "Stopped") {
            Write-DebugLog "[SEARCH-COMPLETE] PowerShell execution stopped for $ServiceKey" "INFO" "AWSServiceManager"
            $service = $script:AvailableServices[$ServiceKey]
            $global:lblStatus.Content = "$($service.Name) search cancelled"
        } else {
            $isCompletedStatus = if ($job.AsyncResult) { $job.AsyncResult.IsCompleted } else { 'N/A' }
            Write-DebugLog "[SEARCH-COMPLETE] Invalid state for EndInvoke - State: $($job.PowerShell.InvocationStateInfo.State), AsyncResult: $($job.AsyncResult -ne $null), IsCompleted: $isCompletedStatus" "WARNING" "AWSServiceManager"
            
            # Handle null AsyncResult case
            if (-not $job.AsyncResult) {
                Write-DebugLog "[SEARCH-COMPLETE] AsyncResult is null for $ServiceKey - search likely failed during initialization" "ERROR" "AWSServiceManager"
                $service = $script:AvailableServices[$ServiceKey]
                $global:lblStatus.Content = "$($service.Name) search failed: Job initialization failed"
            } else {
                $service = $script:AvailableServices[$ServiceKey]
                $global:lblStatus.Content = "$($service.Name) search failed: Invalid state"
            }
        }
    } catch {
        Write-DebugLog "[SEARCH-COMPLETE] Outer exception for $ServiceKey`: $($_.Exception.Message)" "ERROR" "AWSServiceManager"
        Write-DebugLog "[SEARCH-COMPLETE] Outer exception type: $($_.Exception.GetType().Name)" "ERROR" "AWSServiceManager"
        
        $service = $script:AvailableServices[$ServiceKey]
        $global:lblStatus.Content = "$($service.Name) search failed: $($_.Exception.Message)"
    } finally {
        Write-DebugLog "[SEARCH-COMPLETE] Starting cleanup for $ServiceKey" "INFO" "AWSServiceManager"
        # Cleanup
        Stop-ServiceSearchJob -ServiceKey $ServiceKey
        Write-DebugLog "[SEARCH-COMPLETE] Cleanup completed for $ServiceKey" "INFO" "AWSServiceManager"
    }
}

function Update-ServiceDataGrid {
    param([string]$ServiceKey, [array]$Items)
    
    try {
        # Handle EC2 specially since it uses the existing dgEC2
        if ($ServiceKey -eq 'EC2') {
            if ($global:dgEC2) {
                $global:dgEC2.ItemsSource = $null
                if ($Items -and $Items.Count -gt 0) {
                    # Use ArrayList for proper WPF data binding
                    $arrayList = New-Object System.Collections.ArrayList
                    foreach ($item in $Items) {
                        $arrayList.Add($item) | Out-Null
                    }
                    $global:dgEC2.ItemsSource = $arrayList
                    $global:OriginalItems = $arrayList
                } else {
                    # Show empty message with proper ArrayList
                    $emptyList = New-Object System.Collections.ArrayList
                    $emptyItem = [PSCustomObject]@{
                        Name = 'No EC2 instances found'
                        InstanceId = ''
                        State = ''
                        InstanceType = ''
                        Region = ''
                    }
                    $emptyList.Add($emptyItem) | Out-Null
                    $global:dgEC2.ItemsSource = $emptyList
                    $global:OriginalItems = $emptyList
                }
            }
            return
        }
        
        # Find the DataGrid for other services
        $tab = $script:ServiceTabs[$ServiceKey]
        if (-not $tab) { return }
        
        $grid = $tab.Content
        $dataGrid = $grid.Children | Where-Object { $_.Name -eq "dg$ServiceKey" } | Select-Object -First 1
        
        if ($dataGrid) {
            # Clear and set ItemsSource properly
            $dataGrid.ItemsSource = $null
            
            if ($Items -and $Items.Count -gt 0) {
                # Use ArrayList for better WPF compatibility
                $arrayList = New-Object System.Collections.ArrayList
                foreach ($item in $Items) {
                    $arrayList.Add($item) | Out-Null
                }
                $dataGrid.ItemsSource = $arrayList
            } else {
                # Show empty message
                $emptyList = New-Object System.Collections.ArrayList
                $emptyItem = [PSCustomObject]@{}
                # Add properties based on service type
                switch ($ServiceKey) {
                    'RDS' { 
                        $emptyItem | Add-Member -NotePropertyName 'DBInstanceIdentifier' -NotePropertyValue 'No RDS instances found'
                        $emptyItem | Add-Member -NotePropertyName 'Engine' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'DBInstanceStatus' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'DBInstanceClass' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
                    }
                    'S3' {
                        $emptyItem | Add-Member -NotePropertyName 'Name' -NotePropertyValue 'No S3 buckets found'
                        $emptyItem | Add-Member -NotePropertyName 'CreationDate' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
                    }
                    'Lambda' {
                        $emptyItem | Add-Member -NotePropertyName 'FunctionName' -NotePropertyValue 'No Lambda functions found'
                        $emptyItem | Add-Member -NotePropertyName 'Runtime' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'LastModified' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
                    }
                    'ELB' {
                        $emptyItem | Add-Member -NotePropertyName 'LoadBalancerName' -NotePropertyValue 'No Load Balancers found'
                        $emptyItem | Add-Member -NotePropertyName 'Type' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'State' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
                    }
                    'CloudFormation' {
                        $emptyItem | Add-Member -NotePropertyName 'StackName' -NotePropertyValue 'No CloudFormation stacks found'
                        $emptyItem | Add-Member -NotePropertyName 'StackStatus' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'CreationTime' -NotePropertyValue ''
                        $emptyItem | Add-Member -NotePropertyName 'Region' -NotePropertyValue ''
                    }
                }
                $emptyList.Add($emptyItem) | Out-Null
                $dataGrid.ItemsSource = $emptyList
            }
            
            # Store items globally for filtering if this is current service
            if ($ServiceKey -eq $script:CurrentService) {
                $global:OriginalItems = $Items
            }
        }
    } catch {
        Write-Warning "Failed to update DataGrid for $ServiceKey`: $($_.Exception.Message)"
    }
}

function Stop-ServiceSearchJob {
    param([string]$ServiceKey)
    
    if (-not $script:ServiceSearchJobs.ContainsKey($ServiceKey)) { return }
    
    $job = $script:ServiceSearchJobs[$ServiceKey]
    
    try {
        # Stop timer first
        if ($job.Timer) {
            $job.Timer.Stop()
            $job.Timer = $null
        }
        
        # Stop PowerShell execution
        if ($job.PowerShell) {
            try {
                $job.PowerShell.Stop()
            } catch {
                # PowerShell stop can fail if already stopped
            }
            
            try {
                $job.PowerShell.Dispose()
            } catch {
                # Dispose can fail if already disposed
            }
            $job.PowerShell = $null
        }
        
        # Close and dispose runspace
        if ($job.Runspace) {
            try {
                $job.Runspace.Close()
            } catch {
                # Close can fail if already closed
            }
            
            try {
                $job.Runspace.Dispose()
            } catch {
                # Dispose can fail if already disposed
            }
            $job.Runspace = $null
        }
        
        # Clear AsyncResult
        $job.AsyncResult = $null
        
    } catch {
        # Cleanup errors are non-critical but log them
        Write-Verbose "Cleanup error for $ServiceKey`: $($_.Exception.Message)"
    }
    
    # Remove from jobs collection
    $script:ServiceSearchJobs.Remove($ServiceKey)
}

function Stop-AllServiceSearchJobs {
    # Create array copy to avoid modification during enumeration
    $serviceKeys = @($script:ServiceSearchJobs.Keys)
    foreach ($serviceKey in $serviceKeys) {
        Stop-ServiceSearchJob -ServiceKey $serviceKey
    }
}

function Set-CurrentService {
    param([string]$ServiceKey)
    
    $script:CurrentService = $ServiceKey
    
    # Update global items for filtering - with defensive programming
    try {
        $tab = $script:ServiceTabs[$ServiceKey]
        if ($tab -and $tab.Content) {
            $grid = $tab.Content
            if ($grid -and $grid.Children) {
                $dataGrid = $grid.Children | Where-Object { $_.Name -eq "dg$ServiceKey" } | Select-Object -First 1
                if ($dataGrid -and $dataGrid.ItemsSource) {
                    try {
                        $global:OriginalItems = @($dataGrid.ItemsSource)
                        if ($global:lblInstanceCount) {
                            $global:lblInstanceCount.Content = "$($global:OriginalItems.Count) items"
                        }
                    } catch {
                        # If array conversion fails, initialize as empty
                        $global:OriginalItems = @()
                    }
                }
            }
        }
    } catch {
        # If service switching fails, ensure OriginalItems is still valid
        if (-not $global:OriginalItems) {
            $global:OriginalItems = @()
        }
    }
    
    # Update UI labels for current service
    try {
        $service = $script:AvailableServices[$ServiceKey]
        if ($service) {
            Update-ServiceLabels -ServiceConfig $service
        }
    } catch {
        # Label update errors are non-critical
    }
}

function Update-ServiceLabels {
    param([hashtable]$ServiceConfig)
    
    # Update section headers based on current service
    if ($global:ProfileSectionHeader) {
        $global:ProfileSectionHeader.Content = "AWS Profile Management"
    }
    
    if ($global:SearchSectionHeader) {
        $global:SearchSectionHeader.Content = "AWS $($ServiceConfig.Name) Management"
    }
    
    if ($global:ResultsSectionHeader) {
        $global:ResultsSectionHeader.Content = "AWS $($ServiceConfig.Name)"
    }
    
    # Update search button text
    if ($global:btnSearch) {
        $global:btnSearch.Content = "🔍 Search $($ServiceConfig.Name)"
    }
}

function Get-AvailableServices {
    return $script:AvailableServices.Keys | Sort-Object
}

function Get-ServiceConfig {
    param([string]$ServiceKey)
    
    return $script:AvailableServices[$ServiceKey]
}

function Get-CurrentService {
    return $script:CurrentService
}

Export-ModuleMember -Function Initialize-ServiceTabs, New-ServiceTab, Search-AWSService, Stop-AllServiceSearchJobs, Set-CurrentService, Update-ServiceLabels, Get-AvailableServices, Get-ServiceConfig, Get-CurrentService, Get-ServiceSearchScript