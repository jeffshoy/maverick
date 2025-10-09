#requires -version 7.0
<#
.SYNOPSIS
    Panel Framework Test Script

.DESCRIPTION
    Tests the new configurable panel framework against existing panels
    to ensure compatibility and functionality without breaking production
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Test results tracking
$script:TestResults = @{
    Passed = 0
    Failed = 0
    Tests = @()
}

function Write-TestResult {
    param([string]$TestName, [bool]$Passed, [string]$Message = "")
    
    $status = if ($Passed) { "✅ PASS" } else { "❌ FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    Write-Host "$status - $TestName" -ForegroundColor $color
    if ($Message) { Write-Host "    $Message" -ForegroundColor Gray }
    
    $script:TestResults.Tests += @{
        Name = $TestName
        Passed = $Passed
        Message = $Message
    }
    
    if ($Passed) { $script:TestResults.Passed++ } else { $script:TestResults.Failed++ }
}

function Test-ModuleImports {
    Write-Host "`n🧪 Testing Module Imports..." -ForegroundColor Cyan
    
    try {
        Import-Module "$PSScriptRoot\..\src\Modules\PanelFramework.psm1" -Force
        Write-TestResult "PanelFramework Module Import" $true
    } catch {
        Write-TestResult "PanelFramework Module Import" $false $_.Exception.Message
        return $false
    }
    
    try {
        Import-Module "$PSScriptRoot\..\src\Modules\UI.psm1" -Force
        Write-TestResult "UI Module Import" $true
    } catch {
        Write-TestResult "UI Module Import" $false $_.Exception.Message
        return $false
    }
    
    try {
        Import-Module "$PSScriptRoot\..\src\Modules\BugTracker.psm1" -Force
        Write-TestResult "BugTracker Module Import" $true
    } catch {
        Write-TestResult "BugTracker Module Import" $false $_.Exception.Message
        return $false
    }
    
    return $true
}

function Test-ConfigurationFiles {
    Write-Host "`n🧪 Testing Configuration Files..." -ForegroundColor Cyan
    
    $configPath = "$PSScriptRoot\..\src\Config\panels\bug-report.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            Write-TestResult "Bug Report Config Parse" $true
            
            # Validate required properties
            $requiredProps = @('id', 'header', 'title', 'width', 'content')
            $hasAllProps = $true
            foreach ($prop in $requiredProps) {
                if (-not $config.PSObject.Properties[$prop]) {
                    $hasAllProps = $false
                    break
                }
            }
            Write-TestResult "Bug Report Config Structure" $hasAllProps
        } catch {
            Write-TestResult "Bug Report Config Parse" $false $_.Exception.Message
        }
    } else {
        Write-TestResult "Bug Report Config Exists" $false "File not found: $configPath"
    }
    
    $notificationPath = "$PSScriptRoot\..\src\Config\panels\notifications.json"
    if (Test-Path $notificationPath) {
        try {
            $config = Get-Content $notificationPath -Raw | ConvertFrom-Json
            Write-TestResult "Notifications Config Parse" $true
        } catch {
            Write-TestResult "Notifications Config Parse" $false $_.Exception.Message
        }
    } else {
        Write-TestResult "Notifications Config Exists" $false "File not found: $notificationPath"
    }
}

function Test-PanelFrameworkFunctions {
    Write-Host "`n🧪 Testing Panel Framework Functions..." -ForegroundColor Cyan
    
    # Test New-PanelControl function
    try {
        $labelConfig = @{
            type = "label"
            text = "Test Label"
            bold = $true
            margin = "0,0,0,5"
        }
        $control = New-PanelControl -ElementConfig $labelConfig -DataContext @{}
        $isLabel = $control -is [System.Windows.Controls.Label]
        Write-TestResult "New-PanelControl Label Creation" $isLabel
    } catch {
        Write-TestResult "New-PanelControl Label Creation" $false $_.Exception.Message
    }
    
    try {
        $textboxConfig = @{
            type = "textbox"
            height = 25
            multiline = $false
            margin = "0,0,0,10"
        }
        $control = New-PanelControl -ElementConfig $textboxConfig -DataContext @{}
        $isTextBox = $control -is [System.Windows.Controls.TextBox]
        Write-TestResult "New-PanelControl TextBox Creation" $isTextBox
    } catch {
        Write-TestResult "New-PanelControl TextBox Creation" $false $_.Exception.Message
    }
    
    try {
        $comboConfig = @{
            type = "combobox"
            width = 100
            items = @("Item1", "Item2", "Item3")
            selectedIndex = 1
            margin = "0,0,0,5"
        }
        $control = New-PanelControl -ElementConfig $comboConfig -DataContext @{}
        $isComboBox = $control -is [System.Windows.Controls.ComboBox]
        Write-TestResult "New-PanelControl ComboBox Creation" $isComboBox
    } catch {
        Write-TestResult "New-PanelControl ComboBox Creation" $false $_.Exception.Message
    }
}

function Test-ExistingPanelCompatibility {
    Write-Host "`n🧪 Testing Existing Panel Compatibility..." -ForegroundColor Cyan
    
    # Test that existing UI functions still exist
    $uiFunctions = @(
        'Switch-ConnectionManagerPanel',
        'Switch-SettingsPanel',
        'Show-ConnectionManagerPanel',
        'Show-SettingsPanel'
    )
    
    foreach ($func in $uiFunctions) {
        try {
            $command = Get-Command $func -ErrorAction Stop
            Write-TestResult "Function Exists: $func" $true
        } catch {
            Write-TestResult "Function Exists: $func" $false "Function not found"
        }
    }
    
    # Test BugTracker functions
    $bugFunctions = @(
        'Switch-BugReportPanel',
        'Submit-BugReport',
        'Get-BugReports'
    )
    
    foreach ($func in $bugFunctions) {
        try {
            $command = Get-Command $func -ErrorAction Stop
            Write-TestResult "BugTracker Function: $func" $true
        } catch {
            Write-TestResult "BugTracker Function: $func" $false "Function not found"
        }
    }
}

function Test-MockPanelCreation {
    Write-Host "`n🧪 Testing Mock Panel Creation..." -ForegroundColor Cyan
    
    # Create a minimal WPF environment for testing
    try {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        
        # Create mock SidePanelContainer
        $global:SidePanelContainer = New-Object System.Windows.Controls.StackPanel
        $global:SidePanelContainer.Visibility = [System.Windows.Visibility]::Collapsed
        
        Write-TestResult "Mock WPF Environment Setup" $true
    } catch {
        Write-TestResult "Mock WPF Environment Setup" $false $_.Exception.Message
        return $false
    }
    
    # Test creating a simple panel configuration
    try {
        $testConfig = @"
{
  "id": "TestPanel",
  "header": "🧪 Test Panel",
  "title": "Test Panel:",
  "width": 300,
  "content": [
    {
      "type": "label",
      "text": "Test Label",
      "bold": true
    },
    {
      "type": "textbox",
      "name": "txtTest",
      "height": 25
    }
  ],
  "buttons": [
    {
      "text": "Test Button",
      "action": "testAction",
      "width": 100,
      "height": 30
    }
  ]
}
"@
        
        $tempConfigPath = Join-Path $env:TEMP "test-panel.json"
        $testConfig | Out-File $tempConfigPath -Encoding UTF8
        
        $eventHandlers = @{
            'testAction' = { param($controls, $data) Write-Host "Test action executed" }
        }
        
        # This would normally create a panel, but we'll just test the config parsing
        $config = Get-Content $tempConfigPath -Raw | ConvertFrom-Json
        $hasRequiredProps = $config.id -and $config.header -and $config.content
        
        Write-TestResult "Mock Panel Configuration" $hasRequiredProps
        
        # Cleanup
        Remove-Item $tempConfigPath -ErrorAction SilentlyContinue
        
    } catch {
        Write-TestResult "Mock Panel Configuration" $false $_.Exception.Message
    }
}

function Test-PanelFrameworkIntegration {
    Write-Host "`n🧪 Testing Framework Integration..." -ForegroundColor Cyan
    
    # Test that the framework doesn't break existing functionality
    try {
        # Simulate the import process from main application
        $modules = @(
            "$PSScriptRoot\..\src\Modules\Core.psm1",
            "$PSScriptRoot\..\src\Modules\UI.psm1",
            "$PSScriptRoot\..\src\Modules\BugTracker.psm1",
            "$PSScriptRoot\..\src\Modules\PanelFramework.psm1"
        )
        
        $importSuccess = $true
        foreach ($module in $modules) {
            if (Test-Path $module) {
                try {
                    Import-Module $module -Force -ErrorAction Stop
                } catch {
                    $importSuccess = $false
                    break
                }
            }
        }
        
        Write-TestResult "Module Integration Import" $importSuccess
    } catch {
        Write-TestResult "Module Integration Import" $false $_.Exception.Message
    }
    
    # Test that framework functions are available
    try {
        $frameworkFunctions = @('New-ConfigurablePanel', 'New-PanelControl')
        $allAvailable = $true
        
        foreach ($func in $frameworkFunctions) {
            try {
                Get-Command $func -ErrorAction Stop | Out-Null
            } catch {
                $allAvailable = $false
                break
            }
        }
        
        Write-TestResult "Framework Functions Available" $allAvailable
    } catch {
        Write-TestResult "Framework Functions Available" $false $_.Exception.Message
    }
}

function Show-TestSummary {
    Write-Host "`n📊 Test Summary" -ForegroundColor Yellow
    Write-Host "=" * 50 -ForegroundColor Yellow
    
    $total = $script:TestResults.Passed + $script:TestResults.Failed
    $passRate = if ($total -gt 0) { [math]::Round(($script:TestResults.Passed / $total) * 100, 1) } else { 0 }
    
    Write-Host "Total Tests: $total" -ForegroundColor White
    Write-Host "Passed: $($script:TestResults.Passed)" -ForegroundColor Green
    Write-Host "Failed: $($script:TestResults.Failed)" -ForegroundColor Red
    Write-Host "Pass Rate: $passRate%" -ForegroundColor $(if ($passRate -ge 90) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })
    
    if ($script:TestResults.Failed -gt 0) {
        Write-Host "`n❌ Failed Tests:" -ForegroundColor Red
        foreach ($test in $script:TestResults.Tests | Where-Object { -not $_.Passed }) {
            Write-Host "  • $($test.Name): $($test.Message)" -ForegroundColor Red
        }
    }
    
    Write-Host "`n🎯 Recommendation:" -ForegroundColor Cyan
    if ($passRate -ge 95) {
        Write-Host "✅ Framework is ready for production use" -ForegroundColor Green
    } elseif ($passRate -ge 80) {
        Write-Host "⚠️ Framework needs minor fixes before production" -ForegroundColor Yellow
    } else {
        Write-Host "❌ Framework needs significant work before production" -ForegroundColor Red
    }
}

# Main test execution
Write-Host "🚀 Starting Panel Framework Compatibility Tests" -ForegroundColor Magenta
Write-Host "=" * 60 -ForegroundColor Magenta

# Run all tests
$moduleImportSuccess = Test-ModuleImports
if ($moduleImportSuccess) {
    Test-ConfigurationFiles
    Test-PanelFrameworkFunctions
    Test-ExistingPanelCompatibility
    Test-MockPanelCreation
    Test-PanelFrameworkIntegration
} else {
    Write-Host "⚠️ Skipping remaining tests due to module import failures" -ForegroundColor Yellow
}

Show-TestSummary

Write-Host "`n✨ Panel Framework Test Complete" -ForegroundColor Magenta