# Universal AWS Service Discovery Module - Background Integration
# REPLACED: Old on-demand discovery with background caching system
# JUSTIFICATION: Eliminates UI blocking, progress bars, and provides instant service access

function Start-UniversalAWSDiscovery {
    param([string]$ProfileName)
    
    # DEPRECATED: This function is replaced by background service discovery
    # Return cached results instead of performing live discovery
    try {
        $serviceCache = Get-ServiceCache
        if ($serviceCache -and $serviceCache.services) {
            $discoveredServices = @{}
            foreach ($service in $serviceCache.services) {
                $serviceKey = ($service.ToUpper() -replace '-', '')
                $discoveredServices[$serviceKey] = @{
                    Status = "Cached"
                    ServiceName = (Get-Culture).TextInfo.ToTitleCase($service -replace '-', ' ')
                    Icon = Get-ServiceIcon -ServiceKey $serviceKey
                    ItemCount = 0
                    Command = $service
                    DataPath = ""
                    Fields = @("Name", "Id")
                    Regions = @('us-east-1', 'us-west-2', 'ca-central-1')
                }
            }
            
            return @{
                Status = "Completed"
                DiscoveredServices = $discoveredServices
                TotalTested = $serviceCache.services.Count
                SuccessCount = $discoveredServices.Count
            }
        }
        
        # Fallback to basic service list if cache not available
        return @{
            Status = "Fallback"
            DiscoveredServices = @{}
            TotalTested = 0
            SuccessCount = 0
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
    
    # REPLACED: Complex discovery logic with simple cache lookup
    # JUSTIFICATION: Background discovery handles service enumeration automatically
    try {
        $serviceCache = Get-ServiceCache
        if ($serviceCache -and $serviceCache.services) {
            $services = @()
            foreach ($service in $serviceCache.services) {
                $serviceKey = ($service.ToUpper() -replace '-', '')
                $services += @{
                    ServiceKey = $serviceKey
                    ServiceName = (Get-Culture).TextInfo.ToTitleCase($service -replace '-', ' ')
                    CLIName = $service
                }
            }
            return $services | Sort-Object ServiceName
        }
        
        # Fallback to basic list if cache not available
        return Get-ComprehensiveAWSServiceList
        
    } catch {
        return Get-ComprehensiveAWSServiceList
    }
}

# REMOVED: Get-ServicesFromCLIHelp - replaced by background discovery
# JUSTIFICATION: Background service discovery handles CLI parsing automatically

# REMOVED: Get-ServicesFromEnumeration - replaced by background discovery
# JUSTIFICATION: Background service discovery uses botocore data for comprehensive service list

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

# REMOVED: Get-TrulyUniversalServices - replaced by background discovery
# JUSTIFICATION: Background service discovery provides comprehensive service list without UI blocking

function Get-ServicePickerData {
    # NEW: Provides organized service data for UI picker
    # JUSTIFICATION: Replaces complex discovery with simple cache-based service organization
    try {
        $serviceGroups = Get-ServiceGroups
        if ($serviceGroups) {
            return $serviceGroups
        }
        
        # Fallback to basic grouping if cache not available
        $serviceCache = Get-ServiceCache
        if ($serviceCache -and $serviceCache.services) {
            return New-ServiceGroupsByCategory -Services $serviceCache.services
        }
        
        # Final fallback to empty groups
        return @{}
        
    } catch {
        return @{}
    }
}

Export-ModuleMember -Function Start-UniversalAWSDiscovery, Get-AllAWSServices, Get-ServicePickerData, Test-AWSServiceAccess, Get-ComprehensiveAWSServiceList, Get-ServiceIcon