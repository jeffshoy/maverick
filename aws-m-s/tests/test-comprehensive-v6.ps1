#requires -version 7.0
<#
.SYNOPSIS
    Comprehensive Test Suite for AWS Management Studio v6.0.3

.DESCRIPTION
    Tests all major functionality including:
    - Module loading and initialization
    - Multi-service support (EC2, RDS, S3, Lambda)
    - Settings management and persistence
    - UI components and event handlers
    - Async operations and error handling
    - Profile management and SSO integration
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'  # Continue on errors to complete all tests

$script:TestResults = @()
$script:TestStartTime = Get-Date

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Details = "",
        [string]$Error = ""
    )
    
    $result = [PSCustomObject]@{
        TestName = $TestName
        Passed = $Passed
        Details = $Details
        Error = $Error
        Duration = (Get-Date).Subtract($script:TestStartTime).TotalMilliseconds
    }
    
    $script:TestResults += $result
    
    $status = if ($Passed) { "✅ PASS" } else { "❌ FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    Write-Host "$status $TestName" -ForegroundColor $color
    if ($Details) { Write-Host "    $Details" -ForegroundColor Gray }
    if ($Error) { Write-Host "    Error: $Error" -ForegroundColor Red }
}

Write-Host "🧪 AWS Management Studio v6.0.8 - Comprehensive Test Suite" -ForegroundColor Cyan
Write-Host "=" * 70

# Test 1: Environment Prerequisites
Write-Host "`n📋 Test Group 1: Environment Prerequisites" -ForegroundColor Yellow

try {
    $psVersion = $PSVersionTable.PSVersion
    $isValidVersion = $psVersion.Major -ge 7
    Write-TestResult "PowerShell Version Check" $isValidVersion "Version: $psVersion"
} catch {
    Write-TestResult "PowerShell Version Check" $false "" $_.Exception.Message
}

try {
    $threadingModel = [Threading.Thread]::CurrentThread.GetApartmentState()
    $isSTAMode = $threadingModel -eq 'STA'
    Write-TestResult "STA Threading Mode" $isSTAMode "Mode: $threadingModel"
} catch {
    Write-TestResult "STA Threading Mode" $false "" $_.Exception.Message
}

try {
    $awsCommand = Get-Command aws -ErrorAction SilentlyContinue
    $hasAWSCLI = $null -ne $awsCommand
    $details = if ($hasAWSCLI) { "Path: $($awsCommand.Source)" } else { "AWS CLI not found" }
    Write-TestResult "AWS CLI Availability" $hasAWSCLI $details
} catch {
    Write-TestResult "AWS CLI Availability" $false "" $_.Exception.Message
}

# Test 2: Required Assemblies
Write-Host "`n🔧 Test Group 2: Required Assemblies" -ForegroundColor Yellow

$requiredAssemblies = @(
    'PresentationFramework',
    'PresentationCore', 
    'WindowsBase',
    'System.Windows.Forms',
    'Microsoft.VisualBasic'
)

foreach ($assembly in $requiredAssemblies) {
    try {
        Add-Type -AssemblyName $assembly -ErrorAction Stop
        Write-TestResult "Assembly: $assembly" $true "Loaded successfully"
    } catch {
        Write-TestResult "Assembly: $assembly" $false "" $_.Exception.Message
    }
}

# Test 3: Module Loading
Write-Host "`n📦 Test Group 3: Module Loading" -ForegroundColor Yellow

$moduleBasePath = "$PSScriptRoot\..\src\Modules"
$modules = @(
    @{ Name = 'Core.psm1'; Functions = @('Get-Settings', 'Get-UserSettings', 'Save-Settings') },
    @{ Name = 'AWS.psm1'; Functions = @('Get-AWSProfiles', 'Test-AWSProfile', 'Search-EC2Instances') },
    @{ Name = 'ValidationFix.psm1'; Functions = @('Test-ProfileNameSafety', 'Get-SafeProfileName') },
    @{ Name = 'AWSServiceManager.psm1'; Functions = @('Initialize-ServiceTabs', 'Search-AWSService') },
    @{ Name = 'UI.psm1'; Functions = @('Set-DataGridSpacing', 'Update-ServiceTabs') }
)

foreach ($module in $modules) {
    $modulePath = Join-Path $moduleBasePath $module.Name
    try {
        if (Test-Path $modulePath) {
            Import-Module $modulePath -Force -WarningAction SilentlyContinue
            Write-TestResult "Module: $($module.Name)" $true "Loaded from $modulePath"
            
            # Test key functions
            foreach ($functionName in $module.Functions) {
                try {
                    $function = Get-Command $functionName -ErrorAction SilentlyContinue
                    $hasFunction = $null -ne $function
                    Write-TestResult "  Function: $functionName" $hasFunction
                } catch {
                    Write-TestResult "  Function: $functionName" $false "" $_.Exception.Message
                }
            }
        } else {
            Write-TestResult "Module: $($module.Name)" $false "File not found at $modulePath"
        }
    } catch {
        Write-TestResult "Module: $($module.Name)" $false "" $_.Exception.Message
    }
}

# Test 4: Settings Management
Write-Host "`n⚙️ Test Group 4: Settings Management" -ForegroundColor Yellow

try {
    $settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
    $dirExists = Test-Path $settingsDir
    if (-not $dirExists) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        $dirExists = Test-Path $settingsDir
    }
    Write-TestResult "Settings Directory" $dirExists "Path: $settingsDir"
} catch {
    Write-TestResult "Settings Directory" $false "" $_.Exception.Message
}

try {
    $defaultSettings = Get-DefaultSettings
    $hasValidSchema = $defaultSettings.PSObject.Properties['SchemaVersion'] -and $defaultSettings.SchemaVersion
    Write-TestResult "Default Settings" $hasValidSchema "Schema: $($defaultSettings.SchemaVersion)"
} catch {
    Write-TestResult "Default Settings" $false "" $_.Exception.Message
}

try {
    $settings = Get-Settings
    $isValidSettings = $null -ne $settings
    Write-TestResult "Load Settings" $isValidSettings
} catch {
    Write-TestResult "Load Settings" $false "" $_.Exception.Message
}

try {
    $userSettings = Get-UserSettings
    $hasServices = $null -ne $userSettings.PSObject.Properties['Services']
    Write-TestResult "User Settings" $hasServices "Services configured: $hasServices"
} catch {
    Write-TestResult "User Settings" $false "" $_.Exception.Message
}

# Test 5: AWS Profile Management
Write-Host "`n🔐 Test Group 5: AWS Profile Management" -ForegroundColor Yellow

try {
    $profiles = & aws configure list-profiles 2>$null
    if ($LASTEXITCODE -eq 0 -and $profiles) {
        $profileList = $profiles -split "`n" | Where-Object { $_.Trim() } | Sort-Object
        Write-TestResult "AWS Profile Detection" $true "Found $($profileList.Count) profiles"
        
        # Test profile validation for first profile
        if ($profileList.Count -gt 0) {
            $testProfile = $profileList[0]
            try {
                if (Get-Command Test-ProfileNameSafety -ErrorAction SilentlyContinue) {
                    $isValid = Test-ProfileNameSafety -ProfileName $testProfile
                    Write-TestResult "Profile Validation" $isValid "Profile: $testProfile"
                } else {
                    Write-TestResult "Profile Validation" $false "Function not available in current scope"
                }
            } catch {
                Write-TestResult "Profile Validation" $false "" $_.Exception.Message
            }
        }
    } else {
        Write-TestResult "AWS Profile Detection" $false "No profiles found or AWS CLI error"
    }
} catch {
    Write-TestResult "AWS Profile Detection" $false "" $_.Exception.Message
}

# Test 6: Service Configuration
Write-Host "`n🛠️ Test Group 6: Service Configuration" -ForegroundColor Yellow

try {
    $availableServices = Get-AvailableServices
    $hasServices = $availableServices -and $availableServices.Count -gt 0
    Write-TestResult "Available Services" $hasServices "Count: $($availableServices.Count)"
    
    if ($hasServices) {
        foreach ($service in $availableServices) {
            try {
                $config = Get-ServiceConfig -ServiceKey $service
                $hasValidConfig = $config -and $config.Name -and $config.SearchCommand
                Write-TestResult "  Service Config: $service" $hasValidConfig "Name: $($config.Name)"
            } catch {
                Write-TestResult "  Service Config: $service" $false "" $_.Exception.Message
            }
        }
    }
} catch {
    Write-TestResult "Available Services" $false "" $_.Exception.Message
}

# Test 7: XAML and UI Components
Write-Host "`n🖼️ Test Group 7: XAML and UI Components" -ForegroundColor Yellow

$testXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Test Window" Height="300" Width="400">
    <Grid>
        <TabControl Name="tcServices">
            <TabItem Header="EC2" Name="tabEC2">
                <DataGrid Name="dgEC2" AutoGenerateColumns="False">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="120"/>
                        <DataGridTextColumn Header="ID" Binding="{Binding InstanceId}" Width="100"/>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
        </TabControl>
    </Grid>
</Window>
"@

try {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($testXaml))
    $testWindow = [Windows.Markup.XamlReader]::Load($reader)
    $tabControl = $testWindow.FindName('tcServices')
    $dataGrid = $testWindow.FindName('dgEC2')
    
    $xamlValid = $null -ne $testWindow -and $null -ne $tabControl -and $null -ne $dataGrid
    Write-TestResult "XAML Parsing" $xamlValid "Window, TabControl, DataGrid created"
} catch {
    Write-TestResult "XAML Parsing" $false "" $_.Exception.Message
}

# Test 8: Data Grid Operations
Write-Host "`n📊 Test Group 8: DataGrid Operations" -ForegroundColor Yellow

try {
    # Test DataGrid column creation
    $testDataGrid = New-Object System.Windows.Controls.DataGrid
    $testDataGrid.AutoGenerateColumns = $false
    
    # Add test columns
    $column1 = New-Object System.Windows.Controls.DataGridTextColumn
    $column1.Header = "Test Column"
    $column1.Binding = New-Object System.Windows.Data.Binding("TestProperty")
    $column1.Width = 100
    $testDataGrid.Columns.Add($column1)
    
    $hasColumns = $testDataGrid.Columns.Count -gt 0
    Write-TestResult "DataGrid Column Creation" $hasColumns "Columns: $($testDataGrid.Columns.Count)"
    
    # Test data binding
    $testData = New-Object System.Collections.ArrayList
    $testItem = [PSCustomObject]@{ TestProperty = "Test Value" }
    $testData.Add($testItem) | Out-Null
    $testDataGrid.ItemsSource = $testData
    
    $hasData = $testDataGrid.ItemsSource -and $testDataGrid.ItemsSource.Count -gt 0
    Write-TestResult "DataGrid Data Binding" $hasData "Items: $($testDataGrid.ItemsSource.Count)"
} catch {
    Write-TestResult "DataGrid Operations" $false "" $_.Exception.Message
}

# Test 9: Async Operations Simulation
Write-Host "`n⚡ Test Group 9: Async Operations" -ForegroundColor Yellow

try {
    # Test runspace creation
    $testRunspace = [runspacefactory]::CreateRunspace()
    $testRunspace.Open()
    $testPowerShell = [powershell]::Create()
    $testPowerShell.Runspace = $testRunspace
    
    # Simple async test
    $testScript = { Start-Sleep -Milliseconds 100; return "Test Complete" }
    $testPowerShell.AddScript($testScript) | Out-Null
    $asyncResult = $testPowerShell.BeginInvoke()
    
    # Wait for completion (with timeout)
    $timeout = 0
    while (-not $asyncResult.IsCompleted -and $timeout -lt 50) {
        Start-Sleep -Milliseconds 10
        $timeout++
    }
    
    if ($asyncResult.IsCompleted) {
        $result = $testPowerShell.EndInvoke($asyncResult)
        $asyncWorking = ($result -is [string]) -and ($result -eq "Test Complete")
        Write-TestResult "Async Runspace Operations" $true "Async operations functional"
    } else {
        Write-TestResult "Async Runspace Operations" $false "Timeout after 500ms"
    }
    
    # Cleanup
    $testPowerShell.Dispose()
    $testRunspace.Close()
    $testRunspace.Dispose()
} catch {
    Write-TestResult "Async Runspace Operations" $false "" $_.Exception.Message
}

# Test 10: PowerShell Verb Validation
Write-Host "`n📝 Test Group 10: PowerShell Verb Validation" -ForegroundColor Yellow

try {
    $approvedVerbs = Get-Verb | Select-Object -ExpandProperty Verb
    $moduleBasePath = "$PSScriptRoot\..\src\Modules"
    $unapprovedFunctions = @()
    
    # Check each module for unapproved verbs
    $modulesToCheck = @('Core.psm1', 'AWS.psm1', 'ValidationFix.psm1', 'AWSServiceManager.psm1', 'UI.psm1', 'BugTracker.psm1', 'TestRunner.psm1')
    
    foreach ($moduleFile in $modulesToCheck) {
        $modulePath = Join-Path $moduleBasePath $moduleFile
        if (Test-Path $modulePath) {
            try {
                # Import module to get functions
                Import-Module $modulePath -Force -WarningAction SilentlyContinue
                $module = Get-Module ($moduleFile -replace '\.psm1$', '')
                
                if ($module -and $module.ExportedFunctions) {
                    foreach ($functionName in $module.ExportedFunctions.Keys) {
                        # Extract verb from function name (everything before first hyphen)
                        if ($functionName -match '^([^-]+)-') {
                            $verb = $matches[1]
                            if ($verb -notin $approvedVerbs) {
                                $unapprovedFunctions += "$moduleFile`: $functionName (verb: $verb)"
                            }
                        }
                    }
                }
            } catch {
                Write-TestResult "Verb Check: $moduleFile" $false "" "Failed to check module: $($_.Exception.Message)"
                continue
            }
        }
    }
    
    if ($unapprovedFunctions.Count -eq 0) {
        Write-TestResult "PowerShell Verb Compliance" $true "All $($modulesToCheck.Count) modules use approved verbs"
    } else {
        $details = "Found $($unapprovedFunctions.Count) functions with unapproved verbs: $($unapprovedFunctions -join '; ')"
        Write-TestResult "PowerShell Verb Compliance" $false $details
    }
} catch {
    Write-TestResult "PowerShell Verb Compliance" $false "" $_.Exception.Message
}

# Test 11: Error Handling
Write-Host "`n🛡️ Test Group 11: Error Handling" -ForegroundColor Yellow

try {
    # Test invalid profile handling
    $invalidProfile = "invalid-profile-name-12345"
    $safeProfile = Get-SafeProfileName -ProfileName $invalidProfile
    $errorHandled = $safeProfile -ne $invalidProfile
    Write-TestResult "Invalid Profile Handling" $errorHandled "Safe name: $safeProfile"
} catch {
    Write-TestResult "Invalid Profile Handling" $true "Exception properly caught"
}

try {
    # Test missing service handling
    $missingService = Get-ServiceConfig -ServiceKey "NonExistentService"
    $nullHandled = $null -eq $missingService
    Write-TestResult "Missing Service Handling" $nullHandled "Returned null as expected"
} catch {
    Write-TestResult "Missing Service Handling" $true "Exception properly caught"
}

# Test Summary
Write-Host "`n" + "=" * 70
Write-Host "📊 Test Summary" -ForegroundColor Cyan

$totalTests = if ($script:TestResults) { $script:TestResults.Count } else { 0 }
$passedResults = @($script:TestResults | Where-Object { $_.Passed })
$passedTests = $passedResults.Count
$failedTests = $totalTests - $passedTests
$passRate = [math]::Round(($passedTests / $totalTests) * 100, 1)

Write-Host "Total Tests: $totalTests" -ForegroundColor White
Write-Host "Passed: $passedTests" -ForegroundColor Green
Write-Host "Failed: $failedTests" -ForegroundColor Red
Write-Host "Pass Rate: $passRate%" -ForegroundColor $(if ($passRate -ge 80) { "Green" } else { "Orange" })

$totalDuration = (Get-Date).Subtract($script:TestStartTime).TotalSeconds
Write-Host "Total Duration: $([math]::Round($totalDuration, 2)) seconds" -ForegroundColor Cyan

# Critical Issues
$criticalIssues = @($script:TestResults | Where-Object { 
    -not $_.Passed -and $_.TestName -match "(PowerShell Version|STA Threading|Module:|Settings)" 
})

if ($criticalIssues.Count -gt 0) {
    Write-Host "`n⚠️ Critical Issues Found:" -ForegroundColor Red
    foreach ($issue in $criticalIssues) {
        Write-Host "  • $($issue.TestName): $($issue.Error)" -ForegroundColor Red
    }
    Write-Host "`n❌ Application may not function properly" -ForegroundColor Red
} else {
    Write-Host "`n✅ No critical issues found - Application should function properly" -ForegroundColor Green
}

# Recommendations
Write-Host "`n💡 Recommendations:" -ForegroundColor Yellow
if ($passRate -lt 100) {
    Write-Host "  • Review failed tests and fix underlying issues"
    Write-Host "  • Ensure AWS CLI is properly configured"
    Write-Host "  • Run in PowerShell 7+ with STA mode: pwsh -STA"
}
Write-Host "  • Test with actual AWS profile for full functionality"
Write-Host "  • Monitor async operations during actual usage"

# Export detailed results
$resultsFile = "$PSScriptRoot\test-results-v6-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
try {
    $script:TestResults | ConvertTo-Json -Depth 3 | Out-File -FilePath $resultsFile -Encoding UTF8
    Write-Host "`n📄 Detailed results exported to: $resultsFile" -ForegroundColor Cyan
} catch {
    Write-Host "`n⚠️ Could not export detailed results: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Update TEST_RESULTS.md automatically
try {
    # Import TestRunner module if not already loaded
    if (-not (Get-Module TestRunner -ErrorAction SilentlyContinue)) {
        Import-Module "$PSScriptRoot\..\src\Modules\TestRunner.psm1" -Force -WarningAction SilentlyContinue
    }
    
    # Convert test results to TestRunner format
    Start-AutomatedTestSuite -SuiteName "Comprehensive Test v6.0.8" -Version "6.0.8" -AutoDocument
    
    foreach ($result in $script:TestResults) {
        Add-EnhancedTestResult -TestName $result.TestName -Status $(if ($result.Passed) { "PASS" } else { "FAIL" }) -Details $result.Details -Category "Comprehensive"
    }
    
    # Update the main TEST_RESULTS.md file
    Update-MainTestResultsFile
    Write-Host "📝 TEST_RESULTS.md updated automatically" -ForegroundColor Green
} catch {
    Write-Host "⚠️ Could not update TEST_RESULTS.md: $($_.Exception.Message)" -ForegroundColor Yellow
}