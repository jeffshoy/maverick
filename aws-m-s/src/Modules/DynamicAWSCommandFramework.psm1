#requires -version 7.0
<#
.SYNOPSIS
    Dynamic AWS Command Framework - Auto-discovery using AWS CLI help

.DESCRIPTION
    Leverages existing service discovery and AWS CLI help to dynamically build
    Service > Action > Resource mappings for the command framework.
#>

Set-StrictMode -Version Latest

$script:ServiceMappingsPath = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF\aws-service-mappings.json'
$script:CachedMappings = $null

function Get-AWSServices {
    <#
    .SYNOPSIS
        Get all AWS services using CLI help
    #>
    try {
        $result = & aws help 2>&1
        if ($LASTEXITCODE -ne 0) { return @() }
        
        # Parse services from help output
        $services = @()
        $inServicesSection = $false
        
        foreach ($line in $result) {
            if ($line -match "AVAILABLE SERVICES") {
                $inServicesSection = $true
                continue
            }
            if ($inServicesSection -and $line -match "^\s*o\s+(\w+)") {
                $services += $matches[1]
            }
            if ($inServicesSection -and $line -match "^[A-Z]") {
                break
            }
        }
        
        return $services | Sort-Object
    } catch {
        return @('ec2', 's3', 'rds', 'lambda', 'iam', 'vpc', 'cloudwatch', 'ssm')
    }
}

function Get-ServiceActions {
    <#
    .SYNOPSIS
        Get actions for a specific service using CLI help
    #>
    param([string]$ServiceName)
    
    try {
        $result = & aws $ServiceName help 2>&1
        if ($LASTEXITCODE -ne 0) { return @() }
        
        $actions = @()
        $inCommandsSection = $false
        
        foreach ($line in $result) {
            if ($line -match "AVAILABLE COMMANDS") {
                $inCommandsSection = $true
                continue
            }
            if ($inCommandsSection -and $line -match "^\s*o\s+([\w-]+)") {
                $actions += $matches[1]
            }
            if ($inCommandsSection -and $line -match "^[A-Z]") {
                break
            }
        }
        
        return $actions | Sort-Object
    } catch {
        return @()
    }
}

function Build-ServiceMappings {
    <#
    .SYNOPSIS
        Build comprehensive service mappings using discovery
    #>
    param([string]$ProfileName = "")
    
    Write-Verbose "Building dynamic service mappings..."
    
    # Get services from existing discovery or AWS CLI
    $discoveredServices = @()
    try {
        if (Get-Command Get-TrulyUniversalServices -ErrorAction SilentlyContinue) {
            $discoveryResult = Get-TrulyUniversalServices -ProfileName $ProfileName
            if ($discoveryResult.DiscoveredServices) {
                $discoveredServices = $discoveryResult.DiscoveredServices.Keys
            }
        }
    } catch {
        Write-Verbose "Service discovery not available, using CLI help"
    }
    
    if ($discoveredServices.Count -eq 0) {
        $discoveredServices = Get-AWSServices
    }
    
    $mappings = @{
        metadata = @{
            generated = Get-Date
            profile = $ProfileName
            version = "dynamic-1.0"
        }
        services = @{}
    }
    
    # Build mappings for discovered services
    foreach ($service in $discoveredServices | Select-Object -First 20) {
        Write-Verbose "Processing service: $service"
        
        $actions = Get-ServiceActions -ServiceName $service
        if ($actions.Count -eq 0) { continue }
        
        # Categorize actions
        $getActions = $actions | Where-Object { $_ -match '^(describe|get|list)' }
        $setActions = $actions | Where-Object { $_ -match '^(create|put|start|stop|update|modify)' }
        $deleteActions = $actions | Where-Object { $_ -match '^(delete|terminate|remove)' }
        
        $mappings.services[$service] = @{
            actions = @{
                read = $getActions
                write = $setActions
                delete = $deleteActions
                all = $actions
            }
            hasRegion = -not ($service -in @('iam', 's3', 'route53', 'cloudfront'))
            defaultParams = if ($service -in @('iam', 's3', 'route53')) { "" } else { "--region us-east-1" }
        }
    }
    
    return $mappings
}

function Get-CachedServiceMappings {
    <#
    .SYNOPSIS
        Get cached service mappings or build new ones
    #>
    param([string]$ProfileName = "", [switch]$ForceRefresh)
    
    if ($script:CachedMappings -and -not $ForceRefresh) {
        return $script:CachedMappings
    }
    
    # Try to load from cache file
    if ((Test-Path $script:ServiceMappingsPath) -and -not $ForceRefresh) {
        try {
            $cached = Get-Content $script:ServiceMappingsPath -Raw | ConvertFrom-Json
            $cacheAge = (Get-Date) - [DateTime]$cached.metadata.generated
            
            if ($cacheAge.TotalHours -lt 24) {
                $script:CachedMappings = $cached
                return $cached
            }
        } catch {
            Write-Verbose "Failed to load cached mappings"
        }
    }
    
    # Build new mappings
    $mappings = Build-ServiceMappings -ProfileName $ProfileName
    
    # Cache to file
    try {
        $mappingsDir = Split-Path $script:ServiceMappingsPath
        if (-not (Test-Path $mappingsDir)) {
            New-Item -ItemType Directory -Path $mappingsDir -Force | Out-Null
        }
        $mappings | ConvertTo-Json -Depth 10 | Set-Content $script:ServiceMappingsPath -Encoding UTF8
    } catch {
        Write-Verbose "Failed to cache mappings: $($_.Exception.Message)"
    }
    
    $script:CachedMappings = $mappings
    return $mappings
}

function Get-ServiceActionsForFramework {
    <#
    .SYNOPSIS
        Get actions for command framework dropdown
    #>
    param([string]$ServiceName, [string]$ActionType = "all")
    
    $mappings = Get-CachedServiceMappings
    
    if ($mappings.services.ContainsKey($ServiceName)) {
        $serviceActions = $mappings.services[$ServiceName].actions
        
        switch ($ActionType) {
            "read" { return $serviceActions.read }
            "write" { return $serviceActions.write }
            "delete" { return $serviceActions.delete }
            default { return $serviceActions.all }
        }
    }
    
    return @()
}

function Get-DiscoveredServices {
    <#
    .SYNOPSIS
        Get list of discovered services for dropdowns
    #>
    $mappings = Get-CachedServiceMappings
    return $mappings.services.Keys | Sort-Object
}

function Build-DynamicAWSCommand {
    <#
    .SYNOPSIS
        Build AWS command using dynamic mappings
    #>
    param(
        [string]$Service,
        [string]$Action,
        [string]$AdditionalParams = "",
        [string]$ProfileName = ""
    )
    
    $mappings = Get-CachedServiceMappings
    
    if (-not $mappings.services.ContainsKey($Service)) {
        return ""
    }
    
    $serviceConfig = $mappings.services[$Service]
    
    # Build command
    $command = "aws $($Service.ToLower()) $Action"
    
    # Add default parameters
    if ($serviceConfig.defaultParams) {
        $command += " $($serviceConfig.defaultParams)"
    }
    
    # Add profile
    if ($ProfileName) {
        $command += " --profile $ProfileName"
    }
    
    # Add additional parameters
    if ($AdditionalParams.Trim()) {
        $command += " $($AdditionalParams.Trim())"
    }
    
    $command += " --output json"
    
    return $command
}

function Refresh-ServiceMappings {
    <#
    .SYNOPSIS
        Force refresh of service mappings
    #>
    param([string]$ProfileName = "")
    
    Write-Verbose "Refreshing service mappings..."
    $script:CachedMappings = $null
    
    if (Test-Path $script:ServiceMappingsPath) {
        Remove-Item $script:ServiceMappingsPath -Force -ErrorAction SilentlyContinue
    }
    
    return Get-CachedServiceMappings -ProfileName $ProfileName -ForceRefresh
}

Export-ModuleMember -Function Get-CachedServiceMappings, Get-ServiceActionsForFramework, Get-DiscoveredServices, Build-DynamicAWSCommand, Refresh-ServiceMappings