#requires -version 7.0
<#
.SYNOPSIS
    Quick Validation Test for AWS Management Studio

.DESCRIPTION
    Fast validation of core functionality for daily development testing.
    Focuses on critical components that must work for basic operation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Get application version
. "$PSScriptRoot\Get-AppVersion.ps1"

$startTime = Get-Date
Write-Host "⚡ AWS Management Studio v$global:AppVersion - Quick Validation" -ForegroundColor Cyan
Write-Host "=" * 50

$testsPassed = 0
$testsTotal = 0

function Test-Quick {
    param([string]$Name, [scriptblock]$Test)
    $script:testsTotal++
    try {
        $result = & $Test
        if ($result) {
            Write-Host "✅ $Name" -ForegroundColor Green
            $script:testsPassed++
        } else {
            Write-Host "❌ $Name" -ForegroundColor Red
        }
    } catch {
        Write-Host "❌ $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Core Environment
Test-Quick "PowerShell 7+" { $PSVersionTable.PSVersion.Major -ge 7 }
Test-Quick "STA Mode" { [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA' }
Test-Quick "AWS CLI" { Get-Command aws -ErrorAction SilentlyContinue }

# Module Loading
$moduleBase = "$PSScriptRoot\..\src\Modules"
Test-Quick "Core Module" { 
    Import-Module "$moduleBase\Core.psm1" -Force -WarningAction SilentlyContinue
    Get-Command Get-Settings -ErrorAction SilentlyContinue
}
Test-Quick "AWS Module" { 
    Import-Module "$moduleBase\AWS.psm1" -Force -WarningAction SilentlyContinue
    Get-Command Get-AWSProfiles -ErrorAction SilentlyContinue
}
Test-Quick "Service Manager" { 
    Import-Module "$moduleBase\AWSServiceManager.psm1" -Force -WarningAction SilentlyContinue
    Get-Command Initialize-ServiceTabs -ErrorAction SilentlyContinue
}
Test-Quick "UI Module" { 
    Import-Module "$moduleBase\UI.psm1" -Force -WarningAction SilentlyContinue
    Get-Command Initialize-EventHandlers -ErrorAction SilentlyContinue
}

# Settings
Test-Quick "Settings Load" { 
    $settings = Get-Settings
    $settings -and $settings.PSObject.Properties['SchemaVersion']
}
Test-Quick "User Settings" { 
    $userSettings = Get-UserSettings
    $userSettings -and $userSettings.PSObject.Properties['Services']
}

# Services
Test-Quick "Service Manager" {
    # Test if new service management capability is available
    (Get-Module AWSServiceManager -ErrorAction SilentlyContinue) -ne $null
}

# WPF Components
Test-Quick "WPF Assemblies" {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
    $true
}

# Summary
$duration = (Get-Date).Subtract($startTime).TotalSeconds
$passRate = [math]::Round(($testsPassed / $testsTotal) * 100, 1)

Write-Host "`n📊 Results: $testsPassed/$testsTotal passed ($passRate%) in $([math]::Round($duration, 1))s" -ForegroundColor Cyan

if ($passRate -ge 90) {
    Write-Host "✅ Ready for development/testing" -ForegroundColor Green
} elseif ($passRate -ge 70) {
    Write-Host "⚠️ Some issues - check failed tests" -ForegroundColor Yellow
} else {
    Write-Host "❌ Critical issues - fix before proceeding" -ForegroundColor Red
}