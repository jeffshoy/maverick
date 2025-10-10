#requires -version 7.0
<#
.SYNOPSIS
    Test SMB Share Integration
.DESCRIPTION
    Validates SMB module loading and basic functionality
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n=== SMB Share Integration Test ===" -ForegroundColor Cyan
Write-Host "Testing SMB module integration...`n" -ForegroundColor Yellow

$testsPassed = 0
$testsFailed = 0
$testsWarning = 0

function Test-Item {
    param(
        [string]$Name,
        [scriptblock]$Test,
        [string]$Category = "General"
    )
    
    try {
        Write-Host "[$Category] Testing: $Name..." -NoNewline
        $result = & $Test
        if ($result -eq $false) {
            Write-Host " FAILED" -ForegroundColor Red
            $script:testsFailed++
            return $false
        }
        Write-Host " PASSED" -ForegroundColor Green
        $script:testsPassed++
        return $true
    } catch {
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $script:testsFailed++
        return $false
    }
}

# Test 1: Module file exists
Test-Item "SMB module file exists" {
    Test-Path "$PSScriptRoot\..\src\Modules\SMBShareIntegration.psm1"
} "Prerequisites"

# Test 2: Module loads without errors
Test-Item "SMB module loads" {
    try {
        Import-Module "$PSScriptRoot\..\src\Modules\SMBShareIntegration.psm1" -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Host "`n  Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
} "Module Loading"

# Test 3: Required functions exported (public API only)
$requiredFunctions = @(
    'Test-SMBShareAvailability',
    'Save-BugReportToSMB',
    'Get-BugReportsFromSMB',
    'Move-BugReportStatus',
    'Write-SMBLog',
    'Send-UsageAnalytics',
    'Get-SMBShareStatus',
    'Set-SMBShareConfiguration'
)

foreach ($func in $requiredFunctions) {
    Test-Item "Function $func exists" {
        $null -ne (Get-Command $func -ErrorAction SilentlyContinue)
    } "Function Export"
}

# Test 4: Configuration panel JSON exists
Test-Item "SMB config panel JSON exists" {
    Test-Path "$PSScriptRoot\..\src\Config\panels\smb-config.json"
} "Configuration"

# Test 5: Panel JSON is valid
Test-Item "SMB config panel JSON is valid" {
    try {
        $json = Get-Content "$PSScriptRoot\..\src\Config\panels\smb-config.json" -Raw | ConvertFrom-Json
        return ($null -ne $json.id -and $json.id -eq "SMBConfiguration")
    } catch {
        return $false
    }
} "Configuration"

# Test 6: Configuration file can be created
Test-Item "SMB configuration can be set" {
    try {
        # Initialize-SMBShareConfig is internal, test via Set-SMBShareConfiguration
        $testPath = "\\test\\share"
        Set-SMBShareConfiguration -BasePath $testPath -Enabled $false
        return $true
    } catch {
        Write-Host "`n  Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
} "Functionality"

# Test 7: Get configuration status
Test-Item "Get SMB configuration status" {
    try {
        $status = Get-SMBShareStatus
        return ($null -ne $status)
    } catch {
        Write-Host "`n  Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
} "Functionality"

# Test 8: Set configuration (test mode)
Test-Item "Set SMB configuration" {
    try {
        Set-SMBShareConfiguration -BasePath "\\test\path" -Enabled $false
        $status = Get-SMBShareStatus
        return ($status.BasePath -eq "\\test\path" -and $status.Enabled -eq $false)
    } catch {
        Write-Host "`n  Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
} "Functionality"

# Test 9: Test availability (should fail for test path)
Test-Item "Test SMB availability (expect false for test path)" {
    try {
        $available = Test-SMBShareAvailability -Force
        # Should return false for non-existent test path
        return ($available -eq $false)
    } catch {
        # Exception is acceptable for non-existent path
        return $true
    }
} "Functionality"

# Test 10: Main script syntax check
Test-Item "Main script syntax valid" {
    try {
        $null = [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content -Raw "$PSScriptRoot\..\scripts\aws-management-studio.ps1"), 
            [ref]$null
        )
        return $true
    } catch {
        Write-Host "`n  Syntax error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
} "Integration"

# Test 11: Check module import in main script
Test-Item "SMB module imported in main script" {
    $content = Get-Content "$PSScriptRoot\..\scripts\aws-management-studio.ps1" -Raw
    return ($content -match 'Import-Module.*SMBShareIntegration\.psm1')
} "Integration"

# Test 12: Check menu item in XAML
Test-Item "SMB menu item in XAML" {
    $content = Get-Content "$PSScriptRoot\..\scripts\aws-management-studio.ps1" -Raw
    return ($content -match 'Name="miSMBConfig"')
} "Integration"

# Test 13: Check menu handler exists
Test-Item "SMB menu handler exists" {
    $content = Get-Content "$PSScriptRoot\..\scripts\aws-management-studio.ps1" -Raw
    return ($content -match '\$script:miSMBConfig\.Add_Click')
} "Integration"

# Summary
Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan
Write-Host "Passed:  $testsPassed" -ForegroundColor Green
Write-Host "Failed:  $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { "Red" } else { "Gray" })
Write-Host "Warning: $testsWarning" -ForegroundColor $(if ($testsWarning -gt 0) { "Yellow" } else { "Gray" })

if ($testsFailed -eq 0) {
    Write-Host "`n✅ All tests passed! SMB integration is ready." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n❌ Some tests failed. Review errors above." -ForegroundColor Red
    exit 1
}
