#requires -version 7.0
<#
.SYNOPSIS
    Simple Panel Framework Test
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "🧪 Simple Panel Framework Test" -ForegroundColor Cyan

# Import module
try {
    Import-Module "$PSScriptRoot\..\src\Modules\PanelFramework.psm1" -Force
    Write-Host "✅ PanelFramework module loaded" -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to load module: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test New-PanelControl function
Write-Host "`n🔧 Testing New-PanelControl function..." -ForegroundColor Yellow

$testConfigs = @(
    @{ type = "label"; text = "Test Label"; bold = $true },
    @{ type = "textbox"; height = 25; margin = "0,0,0,10" },
    @{ type = "combobox"; width = 100; items = @("Item1", "Item2"); selectedIndex = 0 }
)

$successCount = 0
foreach ($config in $testConfigs) {
    try {
        $control = New-PanelControl -ElementConfig $config -DataContext @{}
        if ($control) {
            Write-Host "  ✅ $($config.type) control created successfully" -ForegroundColor Green
            $successCount++
        } else {
            Write-Host "  ❌ $($config.type) control creation returned null" -ForegroundColor Red
        }
    } catch {
        Write-Host "  ❌ $($config.type) control failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n📊 Test Results:" -ForegroundColor Magenta
Write-Host "  Controls tested: $($testConfigs.Count)" -ForegroundColor White
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Failed: $($testConfigs.Count - $successCount)" -ForegroundColor Red

$passRate = [math]::Round(($successCount / $testConfigs.Count) * 100, 1)
Write-Host "  Pass rate: $passRate%" -ForegroundColor $(if ($passRate -ge 90) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })

if ($passRate -ge 90) {
    Write-Host "`n🎉 Panel Framework is working correctly!" -ForegroundColor Green
} else {
    Write-Host "`n⚠️ Panel Framework needs attention" -ForegroundColor Yellow
}