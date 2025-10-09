#requires -version 7.0
<#
.SYNOPSIS
    Simple Post-Cleanup Validation Test

.DESCRIPTION
    Fast validation test that avoids hanging issues
#>

param([switch]$ShowProgress)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ($ShowProgress) {
    Write-Host "🧪 Simple Post-Cleanup Validation..." -ForegroundColor Cyan
}

$results = @()
$startTime = Get-Date

# Test 1: PowerShell Environment
try {
    $psVersion = $PSVersionTable.PSVersion
    $threadingModel = [Threading.Thread]::CurrentThread.GetApartmentState()
    
    if ($psVersion.Major -ge 7 -and $threadingModel -eq 'STA') {
        $results += @{ Test = "PowerShell Environment"; Status = "PASS"; Details = "PowerShell $psVersion in STA mode" }
        if ($ShowProgress) { Write-Host "   ✅ PowerShell Environment: PASS" -ForegroundColor Green }
    } else {
        $results += @{ Test = "PowerShell Environment"; Status = "WARN"; Details = "PowerShell $psVersion, Threading: $threadingModel" }
        if ($ShowProgress) { Write-Host "   ⚠️ PowerShell Environment: WARN" -ForegroundColor Yellow }
    }
} catch {
    $results += @{ Test = "PowerShell Environment"; Status = "FAIL"; Details = $_.Exception.Message }
    if ($ShowProgress) { Write-Host "   ❌ PowerShell Environment: FAIL" -ForegroundColor Red }
}

# Test 2: AWS CLI
try {
    $awsCommand = Get-Command aws -ErrorAction SilentlyContinue
    if ($awsCommand) {
        $results += @{ Test = "AWS CLI"; Status = "PASS"; Details = "Found at $($awsCommand.Source)" }
        if ($ShowProgress) { Write-Host "   ✅ AWS CLI: PASS" -ForegroundColor Green }
    } else {
        $results += @{ Test = "AWS CLI"; Status = "FAIL"; Details = "AWS CLI not found in PATH" }
        if ($ShowProgress) { Write-Host "   ❌ AWS CLI: FAIL" -ForegroundColor Red }
    }
} catch {
    $results += @{ Test = "AWS CLI"; Status = "FAIL"; Details = $_.Exception.Message }
    if ($ShowProgress) { Write-Host "   ❌ AWS CLI: FAIL" -ForegroundColor Red }
}

# Test 3: Core Module Functions (without loading all modules)
try {
    $scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    $modulePath = Join-Path (Split-Path -Parent $scriptPath) "src\Modules"
    
    # Test just Core module
    $coreModule = Join-Path $modulePath "Core.psm1"
    if (Test-Path $coreModule) {
        Import-Module $coreModule -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        
        if (Get-Command Get-DefaultSettings -ErrorAction SilentlyContinue) {
            $defaultSettings = Get-DefaultSettings
            if ($defaultSettings -and $defaultSettings.SchemaVersion) {
                $results += @{ Test = "Core Functions"; Status = "PASS"; Details = "Settings schema v$($defaultSettings.SchemaVersion)" }
                if ($ShowProgress) { Write-Host "   ✅ Core Functions: PASS" -ForegroundColor Green }
            } else {
                $results += @{ Test = "Core Functions"; Status = "FAIL"; Details = "Invalid settings structure" }
                if ($ShowProgress) { Write-Host "   ❌ Core Functions: FAIL" -ForegroundColor Red }
            }
        } else {
            $results += @{ Test = "Core Functions"; Status = "FAIL"; Details = "Get-DefaultSettings not available" }
            if ($ShowProgress) { Write-Host "   ❌ Core Functions: FAIL" -ForegroundColor Red }
        }
    } else {
        $results += @{ Test = "Core Functions"; Status = "FAIL"; Details = "Core module not found" }
        if ($ShowProgress) { Write-Host "   ❌ Core Functions: FAIL" -ForegroundColor Red }
    }
} catch {
    $results += @{ Test = "Core Functions"; Status = "FAIL"; Details = $_.Exception.Message }
    if ($ShowProgress) { Write-Host "   ❌ Core Functions: FAIL" -ForegroundColor Red }
}

# Test 4: Validation Functions
try {
    $validationModule = Join-Path $modulePath "ValidationFix.psm1"
    if (Test-Path $validationModule) {
        Import-Module $validationModule -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        
        if (Get-Command Get-ValidationResult -ErrorAction SilentlyContinue) {
            $validResult = Get-ValidationResult -InputText "test-instance"
            
            if ($validResult -and $validResult.IsValid -eq $true) {
                $results += @{ Test = "Input Validation"; Status = "PASS"; Details = "Valid input correctly accepted" }
                if ($ShowProgress) { Write-Host "   ✅ Input Validation: PASS" -ForegroundColor Green }
            } else {
                $results += @{ Test = "Input Validation"; Status = "FAIL"; Details = "Valid input incorrectly rejected" }
                if ($ShowProgress) { Write-Host "   ❌ Input Validation: FAIL" -ForegroundColor Red }
            }
        } else {
            $results += @{ Test = "Input Validation"; Status = "FAIL"; Details = "Get-ValidationResult not available" }
            if ($ShowProgress) { Write-Host "   ❌ Input Validation: FAIL" -ForegroundColor Red }
        }
    } else {
        $results += @{ Test = "Input Validation"; Status = "FAIL"; Details = "ValidationFix module not found" }
        if ($ShowProgress) { Write-Host "   ❌ Input Validation: FAIL" -ForegroundColor Red }
    }
} catch {
    $results += @{ Test = "Input Validation"; Status = "FAIL"; Details = $_.Exception.Message }
    if ($ShowProgress) { Write-Host "   ❌ Input Validation: FAIL" -ForegroundColor Red }
}

# Test 5: Memory Usage
try {
    $beforeGC = [System.GC]::GetTotalMemory($false)
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    $afterGC = [System.GC]::GetTotalMemory($true)
    
    $memoryMB = [math]::Round($afterGC / 1MB, 2)
    
    if ($memoryMB -lt 500) {
        $results += @{ Test = "Memory Usage"; Status = "PASS"; Details = "$memoryMB MB memory usage" }
        if ($ShowProgress) { Write-Host "   ✅ Memory Usage: PASS ($memoryMB MB)" -ForegroundColor Green }
    } else {
        $results += @{ Test = "Memory Usage"; Status = "WARN"; Details = "$memoryMB MB memory usage (high)" }
        if ($ShowProgress) { Write-Host "   ⚠️ Memory Usage: WARN ($memoryMB MB)" -ForegroundColor Yellow }
    }
} catch {
    $results += @{ Test = "Memory Usage"; Status = "FAIL"; Details = $_.Exception.Message }
    if ($ShowProgress) { Write-Host "   ❌ Memory Usage: FAIL" -ForegroundColor Red }
}

$duration = (Get-Date) - $startTime

# Display summary
if ($ShowProgress) {
    $passCount = @($results | Where-Object { $_.Status -eq "PASS" }).Count
    $failCount = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
    $warnCount = @($results | Where-Object { $_.Status -eq "WARN" }).Count
    $successRate = if ($results.Count -gt 0) { [math]::Round(($passCount / $results.Count) * 100, 1) } else { 0 }
    
    Write-Host "`n📊 Simple Validation Summary:" -ForegroundColor Cyan
    Write-Host "   Total Tests: $($results.Count)" -ForegroundColor White
    Write-Host "   Passed: $passCount" -ForegroundColor Green
    Write-Host "   Failed: $failCount" -ForegroundColor Red
    Write-Host "   Warnings: $warnCount" -ForegroundColor Yellow
    Write-Host "   Success Rate: $successRate%" -ForegroundColor Cyan
    Write-Host "   Duration: $([math]::Round($duration.TotalSeconds, 2))s" -ForegroundColor White
    
    if ($failCount -eq 0) {
        Write-Host "`n✅ System ready for optimization!" -ForegroundColor Green
    } else {
        Write-Host "`n⚠️ Some issues found - review before optimization" -ForegroundColor Yellow
    }
}

# Return results
return @{
    Results = $results
    Summary = @{
        TotalTests = $results.Count
        PassedTests = @($results | Where-Object { $_.Status -eq "PASS" }).Count
        FailedTests = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
        WarningTests = @($results | Where-Object { $_.Status -eq "WARN" }).Count
        SuccessRate = if ($results.Count -gt 0) { [math]::Round(((@($results | Where-Object { $_.Status -eq "PASS" }).Count) / $results.Count) * 100, 1) } else { 0 }
    }
    Duration = $duration
    Success = (@($results | Where-Object { $_.Status -eq "FAIL" }).Count -eq 0)
}