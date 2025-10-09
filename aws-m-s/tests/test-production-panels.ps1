#requires -version 7.0
<#
.SYNOPSIS
    Production Panel Framework Integration Test
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "🧪 Production Panel Framework Integration Test" -ForegroundColor Cyan

# Test 1: Verify PanelFramework module loads
Write-Host "`n1. Testing PanelFramework module loading..." -ForegroundColor Yellow
try {
    Import-Module "$PSScriptRoot\..\src\Modules\PanelFramework.psm1" -Force
    Write-Host "   ✅ PanelFramework module loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "   ❌ Failed to load PanelFramework module: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test 2: Verify JSON configurations exist
Write-Host "`n2. Testing panel configuration files..." -ForegroundColor Yellow
$configFiles = @(
    "$PSScriptRoot\..\src\Config\panels\bug-report.json",
    "$PSScriptRoot\..\src\Config\panels\notifications.json",
    "$PSScriptRoot\..\src\Config\panels\connection-manager.json",
    "$PSScriptRoot\..\src\Config\panels\settings.json"
)

$configCount = 0
foreach ($configFile in $configFiles) {
    if (Test-Path $configFile) {
        try {
            $config = Get-Content $configFile -Raw | ConvertFrom-Json
            Write-Host "   ✅ $(Split-Path $configFile -Leaf): Valid JSON with $($config.content.Count) elements" -ForegroundColor Green
            $configCount++
        } catch {
            Write-Host "   ❌ $(Split-Path $configFile -Leaf): Invalid JSON - $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "   ❌ $(Split-Path $configFile -Leaf): File not found" -ForegroundColor Red
    }
}

# Test 3: Verify main application imports PanelFramework
Write-Host "`n3. Testing main application integration..." -ForegroundColor Yellow
$mainScript = "$PSScriptRoot\..\scripts\aws-ec2-management-studio-modular.ps1"
if (Test-Path $mainScript) {
    $content = Get-Content $mainScript -Raw
    if ($content -match "Import-Module.*PanelFramework\.psm1") {
        Write-Host "   ✅ Main application imports PanelFramework module" -ForegroundColor Green
    } else {
        Write-Host "   ❌ Main application missing PanelFramework import" -ForegroundColor Red
    }
    
    if ($content -match "New-ConfigurablePanel") {
        Write-Host "   ✅ Main application uses New-ConfigurablePanel function" -ForegroundColor Green
    } else {
        Write-Host "   ❌ Main application not using New-ConfigurablePanel" -ForegroundColor Red
    }
} else {
    Write-Host "   ❌ Main application script not found" -ForegroundColor Red
}

# Test 4: Test control creation without WPF window
Write-Host "`n4. Testing control creation..." -ForegroundColor Yellow
$testElements = @(
    @{ type = "label"; text = "Test Label"; bold = $true },
    @{ type = "textbox"; height = 25; multiline = $false },
    @{ type = "combobox"; width = 100; items = @("Item1", "Item2"); selectedIndex = 0 },
    @{ type = "button"; text = "Test Button"; width = 80; height = 25 }
)

$controlCount = 0
foreach ($element in $testElements) {
    try {
        $control = New-PanelControl -ElementConfig $element -DataContext @{}
        if ($control) {
            Write-Host "   ✅ $($element.type) control created successfully" -ForegroundColor Green
            $controlCount++
        } else {
            Write-Host "   ❌ $($element.type) control creation returned null" -ForegroundColor Red
        }
    } catch {
        Write-Host "   ❌ $($element.type) control failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Test 5: Verify BugTracker integration
Write-Host "`n5. Testing BugTracker integration..." -ForegroundColor Yellow
try {
    Import-Module "$PSScriptRoot\..\src\Modules\BugTracker.psm1" -Force
    $functions = Get-Command -Module BugTracker
    if ($functions) {
        Write-Host "   ✅ BugTracker module loaded with $($functions.Count) functions" -ForegroundColor Green
    } else {
        Write-Host "   ❌ BugTracker module has no exported functions" -ForegroundColor Red
    }
} catch {
    Write-Host "   ❌ Failed to load BugTracker module: $($_.Exception.Message)" -ForegroundColor Red
}

# Summary
Write-Host "`n📊 Production Integration Test Results:" -ForegroundColor Magenta
Write-Host "  Panel configurations: $configCount/4 valid" -ForegroundColor White
Write-Host "  Control types: $controlCount/4 working" -ForegroundColor White

$totalTests = 5
$passedTests = 0
if ($configCount -eq 4) { $passedTests++ }
if ($controlCount -eq 4) { $passedTests++ }
if ($content -match "PanelFramework") { $passedTests++ }
if ($content -match "New-ConfigurablePanel") { $passedTests++ }
if ($functions) { $passedTests++ }

$passRate = [math]::Round(($passedTests / $totalTests) * 100, 1)
Write-Host "  Overall: $passedTests/$totalTests tests passed ($passRate%)" -ForegroundColor $(if ($passRate -ge 90) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })

if ($passRate -ge 90) {
    Write-Host "`n🎉 Production integration ready!" -ForegroundColor Green
    Write-Host "✅ Panel Framework can be safely used in production" -ForegroundColor Green
} elseif ($passRate -ge 70) {
    Write-Host "`n⚠️ Production integration needs attention" -ForegroundColor Yellow
    Write-Host "🔧 Some components need fixes before production use" -ForegroundColor Yellow
} else {
    Write-Host "`n❌ Production integration not ready" -ForegroundColor Red
    Write-Host "🚫 Critical issues must be resolved before production use" -ForegroundColor Red
}