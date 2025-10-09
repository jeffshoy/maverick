#requires -version 7.0

# Background AWS Service Discovery Module
# Maintains cached service list with automatic updates

$script:ServiceCacheFile = Join-Path $env:APPDATA 'AWS-Management-Studio\service-cache.json'
$script:ServiceGroupsFile = Join-Path $env:APPDATA 'AWS-Management-Studio\service-groups.json'

function Initialize-BackgroundServiceDiscovery {
    # Start background timer to check for service updates
    $script:ServiceTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ServiceTimer.Interval = [TimeSpan]::FromHours(1) # Check every hour to reduce API calls
    $script:ServiceTimer.Add_Tick({ Update-ServiceCacheIfNeeded })
    $script:ServiceTimer.Start()
    
    # Initial check on startup
    Update-ServiceCacheIfNeeded
}

function Confirm-ServicePermission {
    param([string]$ServiceName, [string]$ProfileName)
    
    # JUSTIFICATION: Quick permission test prevents showing inaccessible services
    # Uses minimal AWS CLI calls with short timeouts to avoid blocking
    try {
        # Map service names to simple test commands
        $testCommand = switch ($ServiceName) {
            'ec2' { 'describe-regions --max-items 1' }
            's3' { 'list-buckets --max-items 1' }
            'rds' { 'describe-db-instances --max-items 1' }
            'lambda' { 'list-functions --max-items 1' }
            'iam' { 'list-users --max-items 1' }
            'cloudformation' { 'describe-stacks --max-items 1' }
            'ecs' { 'list-clusters --max-items 1' }
            'eks' { 'list-clusters --max-items 1' }
            'sns' { 'list-topics --max-items 1' }
            'sqs' { 'list-queues --max-items 1' }
            default { "$ServiceName help" } # Fallback to help command
        }
        
        # Quick permission test with 5-second timeout
        $result = & aws $ServiceName $testCommand --profile $ProfileName --cli-read-timeout 5 --cli-connect-timeout 3 2>&1
        
        # Success if exit code is 0 and no access denied errors
        return ($LASTEXITCODE -eq 0 -and $result -notmatch 'AccessDenied|Forbidden|UnauthorizedOperation')
    } catch {
        return $false
    }
}

function Get-CurrentProfile {
    # Get current profile from UI if available
    try {
        if ($global:cmbProfile -and $global:cmbProfile.Text) {
            return $global:cmbProfile.Text.Trim()
        }
    } catch {
        # UI not available
    }
    return $null
}

function Get-PriorityServices {
    # Returns list of commonly used AWS services that should be tested first
    # JUSTIFICATION: Prioritizes services most SREs use daily to provide faster, more relevant results
    return @(
        'ec2',           # Virtual servers - most common
        's3',            # Object storage - very common
        'rds',           # Databases - common for apps
        'lambda',        # Serverless functions - increasingly common
        'iam',           # Identity management - essential
        'cloudformation', # Infrastructure as code - common
        'ecs',           # Container service - common
        'eks',           # Kubernetes service - growing
        'sns',           # Notifications - common
        'sqs',           # Message queues - common
        'cloudwatch',    # Monitoring - essential
        'logs',          # Log management - essential
        'dynamodb'       # NoSQL database - common
    )
}

function Update-ServicePermissions {
    param([string]$ProfileName)
    
    # JUSTIFICATION: Allows manual refresh when profile changes
    # Forces permission recheck for new profile
    try {
        # Clear cache to force refresh with new profile
        if (Test-Path $script:ServiceCacheFile) {
            Remove-Item $script:ServiceCacheFile -Force
        }
        if (Test-Path $script:ServiceGroupsFile) {
            Remove-Item $script:ServiceGroupsFile -Force
        }
        
        # Trigger immediate update with new profile
        Update-ServiceCacheIfNeeded
        
        return $true
    } catch {
        return $false
    }
}

function Update-ServiceCacheIfNeeded {
    try {
        $awsVersion = (aws --version 2>&1) -split ' ' | Select-Object -First 1
        $cacheData = Get-ServiceCache
        
        if (-not $cacheData -or $cacheData.awsVersion -ne $awsVersion) {
            Start-Job -ScriptBlock {
                param($CacheFile, $GroupsFile, $AwsVersion, $ProfileName)
                
                # Discover services using botocore data
                $botocoreDir = (Get-Command aws).Source | Split-Path | Join-Path -ChildPath '..\Lib\site-packages\botocore\data'
                if (Test-Path $botocoreDir) {
                    $allServices = Get-ChildItem $botocoreDir -Directory | 
                        Where-Object { $_.Name -match '^[a-z0-9-]+$' } |
                        Select-Object -ExpandProperty Name | Sort-Object
                    
                    # Test permissions prioritizing common services first
                    $accessibleServices = @()
                    if ($ProfileName) {
                        # Priority services - test these first
                        $priorityServices = Get-PriorityServices
                        $otherServices = $allServices | Where-Object { $_ -notin $priorityServices }
                        
                        # Test priority services first
                        foreach ($service in $priorityServices) {
                            if ($service -in $allServices -and (Confirm-ServicePermission -ServiceName $service -ProfileName $ProfileName)) {
                                $accessibleServices += $service
                            }
                        }
                        
                        # Only test other services if we have time/need
                        # Limit to prevent excessive API calls
                        $maxOtherServices = 20
                        $testedOther = 0
                        foreach ($service in $otherServices) {
                            if ($testedOther -ge $maxOtherServices) { break }
                            if (Confirm-ServicePermission -ServiceName $service -ProfileName $ProfileName) {
                                $accessibleServices += $service
                            }
                            $testedOther++
                        }
                    } else {
                        $accessibleServices = $allServices
                    }
                    
                    $cacheData = @{
                        services = $accessibleServices
                        allServices = $allServices
                        awsVersion = $AwsVersion
                        profileName = $ProfileName
                        lastUpdated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        count = $accessibleServices.Count
                        totalCount = $allServices.Count
                    }
                    
                    # Save cache
                    $cacheData | ConvertTo-Json -Depth 3 | Set-Content $CacheFile
                    
                    # Create service groups with accessible services only
                    $groups = New-ServiceGroupsByCategory -Services $accessibleServices
                    $groups | ConvertTo-Json -Depth 3 | Set-Content $GroupsFile
                }
            } -ArgumentList $script:ServiceCacheFile, $script:ServiceGroupsFile, $awsVersion, (Get-CurrentProfile)
        }
    } catch {
        # Silent failure - don't interrupt user
    }
}

function Get-ServiceCache {
    if (Test-Path $script:ServiceCacheFile) {
        try {
            return Get-Content $script:ServiceCacheFile | ConvertFrom-Json
        } catch {
            return $null
        }
    }
    return $null
}

function Get-ServiceGroups {
    if (Test-Path $script:ServiceGroupsFile) {
        try {
            return Get-Content $script:ServiceGroupsFile | ConvertFrom-Json
        } catch {
            return $null
        }
    }
    return $null
}

function New-ServiceGroupsByCategory {
    param([string[]]$Services)
    
    $groups = @{
        'Compute' = @('ec2', 'lambda', 'ecs', 'eks', 'batch', 'lightsail')
        'Storage' = @('s3', 'ebs', 'efs', 'fsx', 'glacier', 'backup')
        'Database' = @('rds', 'dynamodb', 'redshift', 'documentdb', 'neptune')
        'Networking' = @('vpc', 'route53', 'cloudfront', 'elb', 'apigateway')
        'Security' = @('iam', 'kms', 'secrets-manager', 'acm', 'waf')
        'Management' = @('cloudformation', 'cloudwatch', 'cloudtrail', 'config')
        'Analytics' = @('athena', 'glue', 'kinesis', 'quicksight', 'emr')
        'Integration' = @('sns', 'sqs', 'eventbridge', 'step-functions')
    }
    
    $categorized = @{}
    foreach ($category in $groups.Keys) {
        $categorized[$category] = $Services | Where-Object { $_ -in $groups[$category] }
    }
    
    # Add uncategorized services
    $allCategorized = $groups.Values | ForEach-Object { $_ }
    $categorized['Other'] = $Services | Where-Object { $_ -notin $allCategorized }
    
    return $categorized
}

function Stop-BackgroundServiceDiscovery {
    if ($script:ServiceTimer) {
        $script:ServiceTimer.Stop()
        $script:ServiceTimer = $null
    }
}

Export-ModuleMember -Function Initialize-BackgroundServiceDiscovery, Get-ServiceCache, Get-ServiceGroups, Stop-BackgroundServiceDiscovery, New-ServiceGroupsByCategory, Confirm-ServicePermission, Update-ServicePermissions, Get-PriorityServices