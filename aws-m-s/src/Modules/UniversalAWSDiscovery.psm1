# Universal AWS Service Discovery Module

function Start-UniversalAWSDiscovery {
    param([string]$ProfileName)
    
    try {
        Write-Host "[DISCOVERY] Starting universal AWS service discovery..." -ForegroundColor Cyan
        
        # Get all available AWS services from AWS CLI
        $allServices = Get-AllAWSServices -ProfileName $ProfileName
        
        # Test each service for accessibility
        $discoveredServices = @{}
        $totalServices = $allServices.Count
        $processedServices = 0
        
        foreach ($service in $allServices) {
            $processedServices++
            $progress = [math]::Round(($processedServices / $totalServices) * 100)
            
            Write-Host "[DISCOVERY] Testing $($service.ServiceName) ($processedServices/$totalServices)..." -ForegroundColor Yellow
            
            $testResult = Test-AWSServiceAccess -Service $service -ProfileName $ProfileName
            
            if ($testResult.Success) {
                $discoveredServices[$service.ServiceKey] = @{
                    Status = "Success"
                    ServiceName = $service.ServiceName
                    Icon = Get-ServiceIcon -ServiceKey $service.ServiceKey
                    ItemCount = $testResult.ItemCount
                    Command = $testResult.Command
                    DataPath = $testResult.DataPath
                    Fields = $testResult.Fields
                    Regions = $testResult.Regions
                }
            }
        }
        
        return @{
            Status = "Completed"
            DiscoveredServices = $discoveredServices
            TotalTested = $totalServices
            SuccessCount = $discoveredServices.Count
        }
        
    } catch {
        return @{
            Status = "Error"
            Message = $_.Exception.Message
            DiscoveredServices = @{}
        }
    }
}

function Get-AllAWSServices {
    param([string]$ProfileName)
    
    try {
        Write-Host "[DISCOVERY] Discovering all AWS services from CLI..." -ForegroundColor Cyan
        
        # Method 1: Parse AWS CLI help for available services
        $services = Get-ServicesFromCLIHelp
        
        # Method 2: If that fails, try service enumeration
        if ($services.Count -eq 0) {
            Write-Host "[DISCOVERY] CLI help parsing failed, trying service enumeration..." -ForegroundColor Yellow
            $services = Get-ServicesFromEnumeration -ProfileName $ProfileName
        }
        
        # Method 3: Fall back to comprehensive list
        if ($services.Count -eq 0) {
            Write-Host "[DISCOVERY] Enumeration failed, using comprehensive service list..." -ForegroundColor Yellow
            $services = Get-ComprehensiveAWSServiceList
        }
        
        Write-Host "[DISCOVERY] Found $($services.Count) AWS services to test" -ForegroundColor Green
        return $services | Sort-Object ServiceName
        
    } catch {
        Write-Verbose "Failed to get services: $($_.Exception.Message)"
        return Get-ComprehensiveAWSServiceList
    }
}

function Get-ServicesFromCLIHelp {
    try {
        $result = & aws help 2>&1
        if ($LASTEXITCODE -ne 0) { return @() }
        
        $services = @()
        $helpText = $result -join "`n"
        
        # Look for the "Available services:" section
        if ($helpText -match "(?s)Available services:(.*?)(?=\n\n|\nSee)") {
            $servicesSection = $matches[1]
            
            # Extract service names (typically lowercase with hyphens)
            $servicePattern = '\b[a-z][a-z0-9-]{2,}\b'
            $serviceMatches = [regex]::Matches($servicesSection, $servicePattern)
            
            $excludeWords = @('and', 'the', 'for', 'with', 'see', 'aws', 'help', 'more', 'information', 'command', 'service', 'available')
            
            foreach ($match in $serviceMatches) {
                $serviceName = $match.Value.Trim()
                if ($serviceName.Length -gt 2 -and $serviceName -notin $excludeWords) {
                    $services += @{
                        ServiceKey = ($serviceName.ToUpper() -replace '-', '')
                        ServiceName = (Get-Culture).TextInfo.ToTitleCase($serviceName -replace '-', ' ')
                        CLIName = $serviceName
                    }
                }
            }
        }
        
        return $services | Sort-Object ServiceName -Unique
    } catch {
        return @()
    }
}

function Get-ServicesFromEnumeration {
    param([string]$ProfileName)
    
    try {
        # Try to enumerate services by testing common service patterns
        $services = @()
        
        # Get list of all AWS service prefixes by trying 'aws <service> help'
        $commonServices = @(
            'ec2', 's3', 's3api', 'rds', 'lambda', 'iam', 'ecs', 'eks', 'sns', 'sqs',
            'cloudformation', 'route53', 'cloudwatch', 'logs', 'dynamodb', 'elasticache',
            'redshift', 'apigateway', 'cognito-idp', 'secretsmanager', 'ssm', 'cloudfront',
            'elasticbeanstalk', 'autoscaling', 'elbv2', 'kinesis', 'firehose', 'glue',
            'athena', 'emr', 'sagemaker', 'batch', 'stepfunctions', 'events', 'codecommit',
            'codebuild', 'codepipeline', 'codedeploy', 'xray', 'inspector2', 'guardduty',
            'macie2', 'configservice', 'cloudtrail', 'organizations', 'workspaces',
            'connect', 'chime', 'pinpoint', 'ses', 'workmail', 'directconnect',
            'globalaccelerator', 'shield', 'wafv2', 'acm', 'kms', 'backup', 'storagegateway',
            'fsx', 'efs', 'datasync', 'snowball', 'mediaconvert', 'medialive', 'mediastore',
            'rekognition', 'textract', 'comprehend', 'translate', 'polly', 'transcribe',
            'lexv2-models', 'personalize', 'forecast', 'frauddetector', 'kendra', 'braket',
            'iot', 'iotanalytics', 'iotevents', 'greengrassv2', 'timestream-query', 'qldb',
            'docdb', 'neptune', 'keyspaces', 'memorydb', 'opensearch', 'mwaa', 'appflow'
        )
        
        foreach ($serviceCLI in $commonServices) {
            try {
                # Test if service exists by trying help
                $helpResult = & aws $serviceCLI help 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $serviceKey = ($serviceCLI.ToUpper() -replace '-', '')
                    $serviceName = (Get-Culture).TextInfo.ToTitleCase($serviceCLI -replace '-', ' ')
                    
                    $services += @{
                        ServiceKey = $serviceKey
                        ServiceName = $serviceName
                        CLIName = $serviceCLI
                    }
                }
            } catch {
                # Service doesn't exist or not accessible
                continue
            }
        }
        
        return $services | Sort-Object ServiceName
    } catch {
        return @()
    }
}

function Get-ComprehensiveAWSServiceList {
    # Comprehensive list of AWS services with their CLI names
    return @(
        @{ServiceKey='EC2'; ServiceName='EC2 Instances'; CLIName='ec2'},
        @{ServiceKey='S3'; ServiceName='S3 Storage'; CLIName='s3api'},
        @{ServiceKey='RDS'; ServiceName='RDS Databases'; CLIName='rds'},
        @{ServiceKey='LAMBDA'; ServiceName='Lambda Functions'; CLIName='lambda'},
        @{ServiceKey='IAM'; ServiceName='IAM Identity'; CLIName='iam'},
        @{ServiceKey='VPC'; ServiceName='VPC Networking'; CLIName='ec2'},
        @{ServiceKey='ECS'; ServiceName='ECS Containers'; CLIName='ecs'},
        @{ServiceKey='EKS'; ServiceName='EKS Kubernetes'; CLIName='eks'},
        @{ServiceKey='CLOUDFORMATION'; ServiceName='CloudFormation Stacks'; CLIName='cloudformation'},
        @{ServiceKey='ROUTE53'; ServiceName='Route53 DNS'; CLIName='route53'},
        @{ServiceKey='SNS'; ServiceName='SNS Notifications'; CLIName='sns'},
        @{ServiceKey='SQS'; ServiceName='SQS Queues'; CLIName='sqs'},
        @{ServiceKey='CLOUDWATCH'; ServiceName='CloudWatch Monitoring'; CLIName='cloudwatch'},
        @{ServiceKey='LOGS'; ServiceName='CloudWatch Logs'; CLIName='logs'},
        @{ServiceKey='DYNAMODB'; ServiceName='DynamoDB Tables'; CLIName='dynamodb'},
        @{ServiceKey='ELASTICACHE'; ServiceName='ElastiCache Clusters'; CLIName='elasticache'},
        @{ServiceKey='REDSHIFT'; ServiceName='Redshift Clusters'; CLIName='redshift'},
        @{ServiceKey='APIGATEWAY'; ServiceName='API Gateway'; CLIName='apigateway'},
        @{ServiceKey='COGNITO'; ServiceName='Cognito Identity'; CLIName='cognito-idp'},
        @{ServiceKey='SECRETSMANAGER'; ServiceName='Secrets Manager'; CLIName='secretsmanager'},
        @{ServiceKey='SYSTEMS-MANAGER'; ServiceName='Systems Manager'; CLIName='ssm'},
        @{ServiceKey='CLOUDFRONT'; ServiceName='CloudFront CDN'; CLIName='cloudfront'},
        @{ServiceKey='ELASTICBEANSTALK'; ServiceName='Elastic Beanstalk'; CLIName='elasticbeanstalk'},
        @{ServiceKey='AUTOSCALING'; ServiceName='Auto Scaling'; CLIName='autoscaling'},
        @{ServiceKey='ELB'; ServiceName='Load Balancers'; CLIName='elbv2'},
        @{ServiceKey='KINESIS'; ServiceName='Kinesis Streams'; CLIName='kinesis'},
        @{ServiceKey='FIREHOSE'; ServiceName='Kinesis Firehose'; CLIName='firehose'},
        @{ServiceKey='GLUE'; ServiceName='AWS Glue'; CLIName='glue'},
        @{ServiceKey='ATHENA'; ServiceName='Amazon Athena'; CLIName='athena'},
        @{ServiceKey='EMR'; ServiceName='EMR Clusters'; CLIName='emr'},
        @{ServiceKey='SAGEMAKER'; ServiceName='SageMaker'; CLIName='sagemaker'},
        @{ServiceKey='BATCH'; ServiceName='AWS Batch'; CLIName='batch'},
        @{ServiceKey='STEPFUNCTIONS'; ServiceName='Step Functions'; CLIName='stepfunctions'},
        @{ServiceKey='EVENTBRIDGE'; ServiceName='EventBridge'; CLIName='events'},
        @{ServiceKey='CODECOMMIT'; ServiceName='CodeCommit'; CLIName='codecommit'},
        @{ServiceKey='CODEBUILD'; ServiceName='CodeBuild'; CLIName='codebuild'},
        @{ServiceKey='CODEPIPELINE'; ServiceName='CodePipeline'; CLIName='codepipeline'},
        @{ServiceKey='CODEDEPLOY'; ServiceName='CodeDeploy'; CLIName='codedeploy'},
        @{ServiceKey='XRAY'; ServiceName='X-Ray Tracing'; CLIName='xray'},
        @{ServiceKey='INSPECTOR'; ServiceName='Inspector Security'; CLIName='inspector2'},
        @{ServiceKey='GUARDDUTY'; ServiceName='GuardDuty Security'; CLIName='guardduty'},
        @{ServiceKey='MACIE'; ServiceName='Amazon Macie'; CLIName='macie2'},
        @{ServiceKey='CONFIG'; ServiceName='AWS Config'; CLIName='configservice'},
        @{ServiceKey='CLOUDTRAIL'; ServiceName='CloudTrail Logging'; CLIName='cloudtrail'},
        @{ServiceKey='ORGANIZATIONS'; ServiceName='AWS Organizations'; CLIName='organizations'},
        @{ServiceKey='WORKSPACES'; ServiceName='WorkSpaces'; CLIName='workspaces'},
        @{ServiceKey='CONNECT'; ServiceName='Amazon Connect'; CLIName='connect'},
        @{ServiceKey='CHIME'; ServiceName='Amazon Chime'; CLIName='chime'},
        @{ServiceKey='PINPOINT'; ServiceName='Amazon Pinpoint'; CLIName='pinpoint'},
        @{ServiceKey='SES'; ServiceName='Simple Email Service'; CLIName='ses'},
        @{ServiceKey='WORKMAIL'; ServiceName='WorkMail'; CLIName='workmail'},
        @{ServiceKey='DIRECTCONNECT'; ServiceName='Direct Connect'; CLIName='directconnect'},
        @{ServiceKey='TRANSIT-GATEWAY'; ServiceName='Transit Gateway'; CLIName='ec2'},
        @{ServiceKey='GLOBALACCELERATOR'; ServiceName='Global Accelerator'; CLIName='globalaccelerator'},
        @{ServiceKey='SHIELD'; ServiceName='AWS Shield'; CLIName='shield'},
        @{ServiceKey='WAF'; ServiceName='AWS WAF'; CLIName='wafv2'},
        @{ServiceKey='CERTIFICATE-MANAGER'; ServiceName='Certificate Manager'; CLIName='acm'},
        @{ServiceKey='KMS'; ServiceName='Key Management Service'; CLIName='kms'},
        @{ServiceKey='BACKUP'; ServiceName='AWS Backup'; CLIName='backup'},
        @{ServiceKey='STORAGE-GATEWAY'; ServiceName='Storage Gateway'; CLIName='storagegateway'},
        @{ServiceKey='FSX'; ServiceName='Amazon FSx'; CLIName='fsx'},
        @{ServiceKey='EFS'; ServiceName='Elastic File System'; CLIName='efs'},
        @{ServiceKey='DATASYNC'; ServiceName='DataSync'; CLIName='datasync'},
        @{ServiceKey='SNOWBALL'; ServiceName='AWS Snowball'; CLIName='snowball'},
        @{ServiceKey='MEDIACONVERT'; ServiceName='MediaConvert'; CLIName='mediaconvert'},
        @{ServiceKey='MEDIALIVE'; ServiceName='MediaLive'; CLIName='medialive'},
        @{ServiceKey='MEDIASTORE'; ServiceName='MediaStore'; CLIName='mediastore'},
        @{ServiceKey='REKOGNITION'; ServiceName='Amazon Rekognition'; CLIName='rekognition'},
        @{ServiceKey='TEXTRACT'; ServiceName='Amazon Textract'; CLIName='textract'},
        @{ServiceKey='COMPREHEND'; ServiceName='Amazon Comprehend'; CLIName='comprehend'},
        @{ServiceKey='TRANSLATE'; ServiceName='Amazon Translate'; CLIName='translate'},
        @{ServiceKey='POLLY'; ServiceName='Amazon Polly'; CLIName='polly'},
        @{ServiceKey='TRANSCRIBE'; ServiceName='Amazon Transcribe'; CLIName='transcribe'},
        @{ServiceKey='LEX'; ServiceName='Amazon Lex'; CLIName='lexv2-models'},
        @{ServiceKey='PERSONALIZE'; ServiceName='Amazon Personalize'; CLIName='personalize'},
        @{ServiceKey='FORECAST'; ServiceName='Amazon Forecast'; CLIName='forecast'},
        @{ServiceKey='FRAUDDETECTOR'; ServiceName='Fraud Detector'; CLIName='frauddetector'},
        @{ServiceKey='KENDRA'; ServiceName='Amazon Kendra'; CLIName='kendra'},
        @{ServiceKey='BRAKET'; ServiceName='Amazon Braket'; CLIName='braket'},
        @{ServiceKey='IOTCORE'; ServiceName='IoT Core'; CLIName='iot'},
        @{ServiceKey='IOTANALYTICS'; ServiceName='IoT Analytics'; CLIName='iotanalytics'},
        @{ServiceKey='IOTEVENTS'; ServiceName='IoT Events'; CLIName='iotevents'},
        @{ServiceKey='GREENGRASS'; ServiceName='IoT Greengrass'; CLIName='greengrassv2'},
        @{ServiceKey='TIMESTREAM'; ServiceName='Amazon Timestream'; CLIName='timestream-query'},
        @{ServiceKey='QLDB'; ServiceName='Amazon QLDB'; CLIName='qldb'},
        @{ServiceKey='DOCUMENTDB'; ServiceName='DocumentDB'; CLIName='docdb'},
        @{ServiceKey='NEPTUNE'; ServiceName='Amazon Neptune'; CLIName='neptune'},
        @{ServiceKey='KEYSPACES'; ServiceName='Amazon Keyspaces'; CLIName='keyspaces'},
        @{ServiceKey='MEMORYDB'; ServiceName='MemoryDB for Redis'; CLIName='memorydb'},
        @{ServiceKey='OPENSEARCH'; ServiceName='OpenSearch Service'; CLIName='opensearch'},
        @{ServiceKey='MWAA'; ServiceName='Managed Airflow'; CLIName='mwaa'},
        @{ServiceKey='APPFLOW'; ServiceName='Amazon AppFlow'; CLIName='appflow'},
        @{ServiceKey='APPINTEGRATIONS'; ServiceName='AppIntegrations'; CLIName='appintegrations'},
        @{ServiceKey='EVENTBRIDGE'; ServiceName='EventBridge'; CLIName='events'},
        @{ServiceKey='SCHEDULER'; ServiceName='EventBridge Scheduler'; CLIName='scheduler'}
    )
}

function Test-AWSServiceAccess {
    param([hashtable]$Service, [string]$ProfileName)
    
    try {
        # Determine the best list command for this service
        $listCommands = Get-ServiceListCommands -Service $Service
        
        foreach ($commandInfo in $listCommands) {
            try {
                $regions = if ($commandInfo.IsGlobal) { @('') } else { @('us-east-1') }
                
                foreach ($region in $regions) {
                    $command = if ($region) {
                        "aws $($commandInfo.Command) --region $region --profile $ProfileName --max-items 1 --output json --cli-read-timeout 15"
                    } else {
                        "aws $($commandInfo.Command) --profile $ProfileName --max-items 1 --output json --cli-read-timeout 15"
                    }
                    
                    $result = Invoke-Expression "$command 2>&1"
                    
                    if ($LASTEXITCODE -eq 0 -and $result) {
                        # Success! Parse the response to understand the structure
                        try {
                            $jsonData = $result | ConvertFrom-Json
                            $analysis = Analyze-ServiceResponse -JsonData $jsonData -Service $Service
                            
                            return @{
                                Success = $true
                                Command = $commandInfo.Command
                                DataPath = $analysis.DataPath
                                Fields = $analysis.Fields
                                Regions = if ($commandInfo.IsGlobal) { @() } else { @('us-east-1', 'us-west-2', 'ca-central-1') }
                                ItemCount = $analysis.ItemCount
                            }
                        } catch {
                            # JSON parsing failed, but command succeeded
                            return @{
                                Success = $true
                                Command = $commandInfo.Command
                                DataPath = ""
                                Fields = @("Name", "Id")
                                Regions = if ($commandInfo.IsGlobal) { @() } else { @('us-east-1', 'us-west-2', 'ca-central-1') }
                                ItemCount = 1
                            }
                        }
                    }
                }
            } catch {
                continue  # Try next command
            }
        }
        
        return @{ Success = $false; Error = "No accessible commands found" }
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Get-ServiceListCommands {
    param([hashtable]$Service)
    
    $cliName = $Service.CLIName
    
    # Common list command patterns for AWS services
    $commonPatterns = @(
        @{ Command = "$cliName list-$($Service.ServiceKey.ToLower())s"; IsGlobal = $false },
        @{ Command = "$cliName list-$($Service.ServiceKey.ToLower() -replace 's$', '')s"; IsGlobal = $false },
        @{ Command = "$cliName describe-$($Service.ServiceKey.ToLower())s"; IsGlobal = $false },
        @{ Command = "$cliName describe-$($Service.ServiceKey.ToLower() -replace 's$', '')s"; IsGlobal = $false },
        @{ Command = "$cliName list"; IsGlobal = $false },
        @{ Command = "$cliName describe"; IsGlobal = $false }
    )
    
    # Service-specific overrides
    $serviceSpecific = @{
        'EC2' = @(@{ Command = "ec2 describe-instances"; IsGlobal = $false })
        'S3' = @(@{ Command = "s3api list-buckets"; IsGlobal = $true })
        'IAM' = @(@{ Command = "iam list-users"; IsGlobal = $true })
        'ROUTE53' = @(@{ Command = "route53 list-hosted-zones"; IsGlobal = $true })
        'CLOUDFRONT' = @(@{ Command = "cloudfront list-distributions"; IsGlobal = $true })
        'LAMBDA' = @(@{ Command = "lambda list-functions"; IsGlobal = $false })
        'RDS' = @(@{ Command = "rds describe-db-instances"; IsGlobal = $false })
        'DYNAMODB' = @(@{ Command = "dynamodb list-tables"; IsGlobal = $false })
        'SNS' = @(@{ Command = "sns list-topics"; IsGlobal = $false })
        'SQS' = @(@{ Command = "sqs list-queues"; IsGlobal = $false })
        'ECS' = @(@{ Command = "ecs list-clusters"; IsGlobal = $false })
        'EKS' = @(@{ Command = "eks list-clusters"; IsGlobal = $false })
    }
    
    if ($serviceSpecific.ContainsKey($Service.ServiceKey)) {
        return $serviceSpecific[$Service.ServiceKey]
    }
    
    return $commonPatterns
}

function Analyze-ServiceResponse {
    param([object]$JsonData, [hashtable]$Service)
    
    # Find the main data array in the response
    $dataPath = ""
    $fields = @()
    $itemCount = 0
    
    # Look for common array properties
    $arrayProperties = @()
    foreach ($prop in $JsonData.PSObject.Properties) {
        if ($prop.Value -is [array] -and $prop.Value.Count -gt 0) {
            $arrayProperties += @{
                Name = $prop.Name
                Count = $prop.Value.Count
                FirstItem = $prop.Value[0]
            }
        }
    }
    
    if ($arrayProperties.Count -gt 0) {
        # Use the largest array as the main data source
        $mainArray = $arrayProperties | Sort-Object Count -Descending | Select-Object -First 1
        $dataPath = $mainArray.Name
        $itemCount = $mainArray.Count
        
        # Extract field names from the first item
        if ($mainArray.FirstItem -and $mainArray.FirstItem.PSObject.Properties) {
            $fields = $mainArray.FirstItem.PSObject.Properties.Name | Select-Object -First 5
        }
    }
    
    # Fallback field names if none found
    if ($fields.Count -eq 0) {
        $fields = @("Name", "Id", "Status", "Type", "Region")
    }
    
    return @{
        DataPath = $dataPath
        Fields = $fields
        ItemCount = $itemCount
    }
}

function Get-ServiceIcon {
    param([string]$ServiceKey)
    
    $iconMap = @{
        'EC2' = '🖥️'; 'S3' = '🪣'; 'RDS' = '🗄️'; 'LAMBDA' = '⚡'; 'IAM' = '👤'
        'VPC' = '🌐'; 'ECS' = '📦'; 'EKS' = '☸️'; 'CLOUDFORMATION' = '📋'; 'ROUTE53' = '🌍'
        'SNS' = '📢'; 'SQS' = '📬'; 'CLOUDWATCH' = '📊'; 'LOGS' = '📝'; 'DYNAMODB' = '🗃️'
        'ELASTICACHE' = '⚡'; 'REDSHIFT' = '🏢'; 'APIGATEWAY' = '🚪'; 'COGNITO' = '🔐'
        'SECRETSMANAGER' = '🔑'; 'SYSTEMS-MANAGER' = '⚙️'; 'CLOUDFRONT' = '🌐'
        'ELASTICBEANSTALK' = '🌱'; 'AUTOSCALING' = '📈'; 'ELB' = '⚖️'; 'KINESIS' = '🌊'
        'GLUE' = '🔗'; 'ATHENA' = '🔍'; 'EMR' = '🏭'; 'SAGEMAKER' = '🤖'; 'BATCH' = '📦'
        'STEPFUNCTIONS' = '🔄'; 'EVENTBRIDGE' = '📡'; 'CODECOMMIT' = '📚'; 'CODEBUILD' = '🔨'
        'CODEPIPELINE' = '🚀'; 'CODEDEPLOY' = '📤'; 'XRAY' = '🔬'; 'INSPECTOR' = '🔍'
        'GUARDDUTY' = '🛡️'; 'MACIE' = '🔒'; 'CONFIG' = '📋'; 'CLOUDTRAIL' = '👣'
        'ORGANIZATIONS' = '🏢'; 'WORKSPACES' = '💻'; 'CONNECT' = '☎️'; 'SES' = '📧'
        'KMS' = '🔐'; 'BACKUP' = '💾'; 'EFS' = '📁'; 'FSX' = '🗂️'
    }
    
    return if ($iconMap.ContainsKey($ServiceKey)) { $iconMap[$ServiceKey] } else { '🔧' }
}

# Add function to get truly universal service discovery
function Get-TrulyUniversalServices {
    param([string]$ProfileName)
    
    Write-Host "[UNIVERSAL] Starting truly universal AWS service discovery..." -ForegroundColor Magenta
    
    # Step 1: Get all services from AWS CLI
    $allServices = Get-AllAWSServices -ProfileName $ProfileName
    Write-Host "[UNIVERSAL] Found $($allServices.Count) potential services" -ForegroundColor Cyan
    
    # Step 2: Test each service with multiple command patterns
    $workingServices = @{}
    $totalServices = $allServices.Count
    $processedServices = 0
    
    foreach ($service in $allServices) {
        $processedServices++
        $progress = [math]::Round(($processedServices / $totalServices) * 100)
        
        Write-Host "[UNIVERSAL] Testing $($service.ServiceName) ($processedServices/$totalServices - $progress%)..." -ForegroundColor Yellow
        
        $testResult = Test-AWSServiceAccess -Service $service -ProfileName $ProfileName
        
        if ($testResult.Success) {
            $workingServices[$service.ServiceKey] = @{
                Status = "Success"
                ServiceName = $service.ServiceName
                CLIName = $service.CLIName
                Icon = Get-ServiceIcon -ServiceKey $service.ServiceKey
                ItemCount = $testResult.ItemCount
                Command = $testResult.Command
                DataPath = $testResult.DataPath
                Fields = $testResult.Fields
                Regions = $testResult.Regions
                Discovered = $true
            }
            Write-Host "[UNIVERSAL] ✅ $($service.ServiceName) - $($testResult.ItemCount) items" -ForegroundColor Green
        } else {
            Write-Host "[UNIVERSAL] ❌ $($service.ServiceName) - $($testResult.Error)" -ForegroundColor Red
        }
    }
    
    Write-Host "[UNIVERSAL] Discovery complete: $($workingServices.Count)/$totalServices services accessible" -ForegroundColor Magenta
    
    return @{
        Status = "Completed"
        DiscoveredServices = $workingServices
        TotalTested = $totalServices
        SuccessCount = $workingServices.Count
        SuccessRate = [math]::Round(($workingServices.Count / $totalServices) * 100, 1)
    }
}

Export-ModuleMember -Function Start-UniversalAWSDiscovery, Get-TrulyUniversalServices, Get-AllAWSServices, Test-AWSServiceAccess, Get-ComprehensiveAWSServiceList