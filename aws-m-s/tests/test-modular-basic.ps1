#requires -version 7.0
<#
.SYNOPSIS
    Basic Test Script for AWS EC2 Management Studio - Modular Version

.DESCRIPTION
    Tests core functionality of the modular version:
    - Module loading
    - Settings management
    - AWS profile detection
    - Basic UI initialization
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$startTime = Get-Date
Write-Host "🧪 Testing AWS EC2 Management Studio - Modular Version" -ForegroundColor Cyan
Write-Host "=" * 60

# Test 1: Check PowerShell version and threading
Write-Host "Test 1: PowerShell Environment" -ForegroundColor Yellow
Write-Host "  PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Host "  Threading Model: $([Threading.Thread]::CurrentThread.GetApartmentState())"

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning "  ⚠️  Not running in STA mode - WPF may not work properly"
    Write-Host "  💡 Run with: pwsh -STA -File test-modular-basic.ps1"
} else {
    Write-Host "  ✅ STA mode - Good for WPF" -ForegroundColor Green
}

# Test 2: Check AWS CLI availability
Write-Host "`nTest 2: AWS CLI Availability" -ForegroundColor Yellow
$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
if ($awsCommand) {
    Write-Host "  ✅ AWS CLI found at: $($awsCommand.Source)" -ForegroundColor Green
    try {
        $awsVersion = & aws --version 2>&1
        Write-Host "  📋 Version: $awsVersion"
    } catch {
        Write-Host "  ⚠️  Could not get AWS CLI version" -ForegroundColor Orange
    }
} else {
    Write-Host "  ❌ AWS CLI not found in PATH" -ForegroundColor Red
    Write-Host "  💡 Install AWS CLI v2 to use this application"
}

# Test 3: Check required assemblies
Write-Host "`nTest 3: Required Assemblies" -ForegroundColor Yellow
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
        Write-Host "  ✅ $assembly loaded" -ForegroundColor Green
    } catch {
        Write-Host "  ❌ Failed to load $assembly" -ForegroundColor Red
    }
}

# Test 4: Settings directory and file structure
Write-Host "`nTest 4: Settings Management" -ForegroundColor Yellow
$settingsDir = Join-Path $env:APPDATA 'AWS-EC2-Management-Studio-WPF'
Write-Host "  📁 Settings Directory: $settingsDir"

if (-not (Test-Path $settingsDir)) {
    try {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        Write-Host "  ✅ Created settings directory" -ForegroundColor Green
    } catch {
        Write-Host "  ❌ Failed to create settings directory" -ForegroundColor Red
    }
} else {
    Write-Host "  ✅ Settings directory exists" -ForegroundColor Green
}

# Test 5: Module loading
Write-Host "`nTest 5: Module Loading" -ForegroundColor Yellow
$moduleDir = "$PSScriptRoot\Modules"
$modules = @('Core.psm1', 'AWS.psm1', 'UI.psm1')

foreach ($module in $modules) {
    $modulePath = Join-Path $moduleDir $module
    if (Test-Path $modulePath) {
        try {
            Import-Module $modulePath -Force -WarningAction SilentlyContinue
            Write-Host "  ✅ $module loaded successfully" -ForegroundColor Green
        } catch {
            Write-Host "  ❌ Failed to load $module`: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "  ❌ $module not found at $modulePath" -ForegroundColor Red
    }
}

# Test 6: Settings functions
Write-Host "`nTest 6: Settings Functions" -ForegroundColor Yellow
try {
    $defaultSettings = Get-DefaultSettings
    Write-Host "  ✅ Get-DefaultSettings works" -ForegroundColor Green
    Write-Host "  📋 Schema Version: $($defaultSettings.SchemaVersion)"
    
    $settings = Get-Settings
    Write-Host "  ✅ Get-Settings works" -ForegroundColor Green
    
    $userSettings = Get-UserSettings
    Write-Host "  ✅ Get-UserSettings works" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Settings functions failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 7: AWS Profile Detection
Write-Host "`nTest 7: AWS Profile Detection" -ForegroundColor Yellow
try {
    $profiles = & aws configure list-profiles 2>$null
    if ($LASTEXITCODE -eq 0 -and $profiles) {
        $profileList = $profiles -split "`n" | Where-Object { $_.Trim() } | Sort-Object
        Write-Host "  ✅ Found $($profileList.Count) AWS profiles:" -ForegroundColor Green
        foreach ($profile in $profileList) {
            Write-Host "    • $profile"
        }
    } else {
        Write-Host "  ⚠️  No AWS profiles configured" -ForegroundColor Orange
        Write-Host "  💡 Run 'aws configure sso' to set up profiles"
    }
} catch {
    Write-Host "  ❌ Failed to get AWS profiles: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 8: Basic XAML parsing
Write-Host "`nTest 8: XAML Parsing Test" -ForegroundColor Yellow
$testXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Test Window" Height="300" Width="400">
    <Grid>
        <Label Name="lblTest" Content="Test Label"/>
    </Grid>
</Window>
"@

try {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($testXaml))
    $testWindow = [Windows.Markup.XamlReader]::Load($reader)
    $testLabel = $testWindow.FindName('lblTest')
    
    if ($testLabel -and $testLabel.Content -eq "Test Label") {
        Write-Host "  ✅ XAML parsing works correctly" -ForegroundColor Green
    } else {
        Write-Host "  ❌ XAML parsing failed - element not found" -ForegroundColor Red
    }
} catch {
    Write-Host "  ❌ XAML parsing failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Summary
Write-Host "`n" + "=" * 60
Write-Host "🏁 Basic Test Summary" -ForegroundColor Cyan

$readyToRun = $true
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "❌ Must run in STA mode for WPF" -ForegroundColor Red
    $readyToRun = $false
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "⚠️  AWS CLI not available - limited functionality" -ForegroundColor Orange
}

if ($readyToRun) {
    Write-Host "✅ Basic requirements met - Ready to test full application" -ForegroundColor Green
    Write-Host "💡 Run: pwsh -STA -File aws-ec2-management-studio-modular.ps1" -ForegroundColor Cyan
} else {
    Write-Host "❌ Requirements not met - Fix issues before running" -ForegroundColor Red
}

Write-Host "`n⏱️  Test completed in $([math]::Round((Get-Date).Subtract($startTime).TotalSeconds, 2)) seconds" -ForegroundColor Cyan