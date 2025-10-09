#requires -version 7.0
<#
.SYNOPSIS
    AWS Command Framework Module - Service > Action > Resource dropdown system

.DESCRIPTION
    Recreates the pre-modular AWS Command Framework feature that allows users to
    build AWS CLI commands through Service > Action > Resource dropdowns with
    custom parameters, as shown in the v4.3.0 screenshot.
#>

Set-StrictMode -Version Latest

# Command framework data
$script:ServiceActionMap = @{
    'EC2' = @{
        'actions' = @('describe-instances', 'start-instances', 'stop-instances', 'reboot-instances', 'describe-security-groups', 'describe-key-pairs')
        'resources' = @('instances', 'security-groups', 'key-pairs', 'volumes', 'snapshots')
        'defaultParams' = '--region us-east-1'
    }
    'S3' = @{
        'actions' = @('list-buckets', 'list-objects', 'get-object', 'put-object', 'delete-object')
        'resources' = @('buckets', 'objects')
        'defaultParams' = ''
    }
    'RDS' = @{
        'actions' = @('describe-db-instances', 'describe-db-clusters', 'start-db-instance', 'stop-db-instance')
        'resources' = @('db-instances', 'db-clusters', 'db-snapshots')
        'defaultParams' = '--region us-east-1'
    }
    'Lambda' = @{
        'actions' = @('list-functions', 'get-function', 'invoke', 'update-function-code')
        'resources' = @('functions', 'layers', 'event-source-mappings')
        'defaultParams' = '--region us-east-1'
    }
    'IAM' = @{
        'actions' = @('list-users', 'list-roles', 'list-policies', 'get-user', 'get-role')
        'resources' = @('users', 'roles', 'policies', 'groups')
        'defaultParams' = ''
    }
    'VPC' = @{
        'actions' = @('describe-vpcs', 'describe-subnets', 'describe-route-tables', 'describe-internet-gateways')
        'resources' = @('vpcs', 'subnets', 'route-tables', 'internet-gateways')
        'defaultParams' = '--region us-east-1'
    }
    'CloudWatch' = @{
        'actions' = @('list-metrics', 'get-metric-statistics', 'describe-alarms')
        'resources' = @('metrics', 'alarms', 'dashboards')
        'defaultParams' = '--region us-east-1'
    }
    'SSM' = @{
        'actions' = @('describe-instance-information', 'send-command', 'list-commands', 'get-command-invocation')
        'resources' = @('instances', 'commands', 'parameters', 'documents')
        'defaultParams' = '--region us-east-1'
    }
}

function Initialize-CommandFramework {
    <#
    .SYNOPSIS
        Initialize the AWS Command Framework UI components
    #>
    param(
        [object]$ServiceComboBox,
        [object]$ActionComboBox,
        [object]$ResourceComboBox,
        [object]$ParametersTextBox,
        [object]$PreviewTextBox
    )
    
    # Store UI references
    $script:cmbService = $ServiceComboBox
    $script:cmbAction = $ActionComboBox
    $script:cmbResource = $ResourceComboBox
    $script:txtParameters = $ParametersTextBox
    $script:txtPreview = $PreviewTextBox
    
    # Populate service dropdown
    $script:cmbService.Items.Clear()
    foreach ($service in $script:ServiceActionMap.Keys | Sort-Object) {
        $script:cmbService.Items.Add($service) | Out-Null
    }
    
    # Set default selection
    if ($script:cmbService.Items.Count -gt 0) {
        $script:cmbService.SelectedIndex = 0
    }
}

function Update-ActionDropdown {
    <#
    .SYNOPSIS
        Update action dropdown based on selected service
    #>
    param([string]$SelectedService)
    
    if (-not $script:cmbAction) { return }
    
    $script:cmbAction.Items.Clear()
    
    if ($script:ServiceActionMap.ContainsKey($SelectedService)) {
        foreach ($action in $script:ServiceActionMap[$SelectedService].actions) {
            $script:cmbAction.Items.Add($action) | Out-Null
        }
        
        if ($script:cmbAction.Items.Count -gt 0) {
            $script:cmbAction.SelectedIndex = 0
        }
    }
}

function Update-ResourceDropdown {
    <#
    .SYNOPSIS
        Update resource dropdown based on selected service
    #>
    param([string]$SelectedService)
    
    if (-not $script:cmbResource) { return }
    
    $script:cmbResource.Items.Clear()
    
    if ($script:ServiceActionMap.ContainsKey($SelectedService)) {
        foreach ($resource in $script:ServiceActionMap[$SelectedService].resources) {
            $script:cmbResource.Items.Add($resource) | Out-Null
        }
        
        if ($script:cmbResource.Items.Count -gt 0) {
            $script:cmbResource.SelectedIndex = 0
        }
    }
}

function Build-AWSCommand {
    <#
    .SYNOPSIS
        Build AWS CLI command from current selections
    #>
    param(
        [string]$Service,
        [string]$Action,
        [string]$Resource,
        [string]$AdditionalParams = "",
        [string]$ProfileName = ""
    )
    
    if (-not $Service -or -not $Action) {
        return ""
    }
    
    # Build base command
    $command = "aws $($Service.ToLower()) $Action"
    
    # Add default parameters for service
    if ($script:ServiceActionMap.ContainsKey($Service)) {
        $defaultParams = $script:ServiceActionMap[$Service].defaultParams
        if ($defaultParams) {
            $command += " $defaultParams"
        }
    }
    
    # Add profile if specified
    if ($ProfileName) {
        $command += " --profile $ProfileName"
    }
    
    # Add additional parameters
    if ($AdditionalParams.Trim()) {
        $command += " $($AdditionalParams.Trim())"
    }
    
    # Add output format
    $command += " --output json"
    
    return $command
}

function Update-CommandPreview {
    <#
    .SYNOPSIS
        Update the command preview text
    #>
    if (-not $script:txtPreview) { return }
    
    $service = if ($script:cmbService.SelectedItem) { $script:cmbService.SelectedItem.ToString() } else { "" }
    $action = if ($script:cmbAction.SelectedItem) { $script:cmbAction.SelectedItem.ToString() } else { "" }
    $resource = if ($script:cmbResource.SelectedItem) { $script:cmbResource.SelectedItem.ToString() } else { "" }
    $params = if ($script:txtParameters.Text) { $script:txtParameters.Text } else { "" }
    
    # Get profile from global variable if available
    $profileName = ""
    if ($global:cmbProfile -and $global:cmbProfile.Text) {
        $profileName = $global:cmbProfile.Text.Trim()
    }
    
    $command = Build-AWSCommand -Service $service -Action $action -Resource $resource -AdditionalParams $params -ProfileName $profileName
    $script:txtPreview.Text = $command
}

function Execute-AWSCommand {
    <#
    .SYNOPSIS
        Execute the built AWS command and return results
    #>
    param([string]$Command)
    
    if (-not $Command.Trim()) {
        return @{ Success = $false; Message = "No command to execute"; Output = "" }
    }
    
    try {
        Write-Verbose "Executing AWS command: $Command"
        
        # Execute command with timeout
        $result = Invoke-Expression "$Command 2>&1"
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            return @{
                Success = $true
                Message = "Command executed successfully"
                Output = $result
                ExitCode = $exitCode
            }
        } else {
            return @{
                Success = $false
                Message = "Command failed with exit code $exitCode"
                Output = $result
                ExitCode = $exitCode
            }
        }
    } catch {
        return @{
            Success = $false
            Message = "Command execution error: $($_.Exception.Message)"
            Output = ""
            ExitCode = -1
        }
    }
}

function Format-CommandOutput {
    <#
    .SYNOPSIS
        Format AWS command output for display
    #>
    param([object]$CommandResult)
    
    if (-not $CommandResult.Success) {
        return "❌ Error: $($CommandResult.Message)`n`nOutput:`n$($CommandResult.Output)"
    }
    
    $output = $CommandResult.Output
    
    # Try to format JSON output
    if ($output -and $output.ToString().Trim().StartsWith('{') -or $output.ToString().Trim().StartsWith('[')) {
        try {
            $jsonObject = $output | ConvertFrom-Json
            $formattedJson = $jsonObject | ConvertTo-Json -Depth 10
            return "✅ Success`n`nFormatted Output:`n$formattedJson"
        } catch {
            # If JSON parsing fails, return raw output
        }
    }
    
    return "✅ Success`n`nOutput:`n$output"
}

function Get-ServiceActions {
    <#
    .SYNOPSIS
        Get available actions for a service
    #>
    param([string]$ServiceName)
    
    if ($script:ServiceActionMap.ContainsKey($ServiceName)) {
        return $script:ServiceActionMap[$ServiceName].actions
    }
    return @()
}

function Get-ServiceResources {
    <#
    .SYNOPSIS
        Get available resources for a service
    #>
    param([string]$ServiceName)
    
    if ($script:ServiceActionMap.ContainsKey($ServiceName)) {
        return $script:ServiceActionMap[$ServiceName].resources
    }
    return @()
}

Export-ModuleMember -Function Initialize-CommandFramework, Update-ActionDropdown, Update-ResourceDropdown, Build-AWSCommand, Update-CommandPreview, Execute-AWSCommand, Format-CommandOutput, Get-ServiceActions, Get-ServiceResources