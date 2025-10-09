#requires -version 7.0
<#
.SYNOPSIS
    Test Azure DevOps Integration Module

.DESCRIPTION
    Validates AzDo integration functionality including:
    - Module loading and configuration
    - Version comparison logic
    - Connectivity testing (mock)
    - Update detection logic
#>

param(
    [switch]$Verbose
)

if ($Verbose) { $VerbosePreference = "Continue" }

Write-Host "🧪 Testing AzDo Integration Module..." -ForegroundColor Cyan

# Import the module
try {
    $modulePath = Join-Path $PSScriptRoot "..\src\Modules\AzDoIntegration.psm1"
    Import-Module $modulePath -Force
    Write-Host "✅ Module imported successfully" -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to import module: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test 1: Version comparison
Write-Host "`n📋 Testing version comparison..." -ForegroundColor Yellow

$tests = @(
    @{ V1 = "6.2.5"; V2 = "6.2.4"; Expected = 1; Description = "Newer version" },
    @{ V1 = "6.2.4"; V2 = "6.2.5"; Expected = -1; Description = "Older version" },
    @{ V1 = "6.2.5"; V2 = "6.2.5"; Expected = 0; Description = "Same version" }
)

$passed = 0
foreach ($test in $tests) {
    $result = Compare-Versions -Version1 $test.V1 -Version2 $test.V2
    if ($result -eq $test.Expected) {
        Write-Host "  ✅ $($test.Description): $($test.V1) vs $($test.V2) = $result" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  ❌ $($test.Description): Expected $($test.Expected), got $result" -ForegroundColor Red
    }
}

# Test 2: Configuration management
Write-Host "`n🔧 Testing configuration management..." -ForegroundColor Yellow

try {
    Set-AzDoConfiguration -Organization "test-org" -Project "test-project" -Repository "test-repo"
    $config = Get-AzDoConfiguration
    
    if ($config.Organization -eq "test-org" -and $config.Project -eq "test-project") {
        Write-Host "  ✅ Configuration set and retrieved successfully" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  ❌ Configuration mismatch" -ForegroundColor Red
    }
} catch {
    Write-Host "  ❌ Configuration test failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 3: Current version management
Write-Host "`n📦 Testing version management..." -ForegroundColor Yellow

try {
    $originalVersion = Get-CurrentVersion
    Set-CurrentVersion -Version "6.3.0"
    $newVersion = Get-CurrentVersion
    
    if ($newVersion -eq "6.3.0") {
        Write-Host "  ✅ Version updated successfully: $newVersion" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  ❌ Version update failed" -ForegroundColor Red
    }
    
    # Restore original version
    Set-CurrentVersion -Version $originalVersion
} catch {
    Write-Host "  ❌ Version management test failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 4: Connectivity testing (without actual network calls)
Write-Host "`n🌐 Testing connectivity functions..." -ForegroundColor Yellow

try {
    # Test without configuration (should fail gracefully)
    Set-AzDoConfiguration -Organization "" -Project "" -Repository ""
    $azDoTest = Test-AzDoConnectivity
    
    if (-not $azDoTest.Connected -and $azDoTest.Error) {
        Write-Host "  ✅ AzDo connectivity test handles missing config correctly" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  ❌ AzDo connectivity test should fail with empty config" -ForegroundColor Red
    }
    
    $smbTest = Test-SMBConnectivity
    if (-not $smbTest.Connected) {
        Write-Host "  ✅ SMB connectivity test handles missing config correctly" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  ❌ SMB connectivity test should fail with empty config" -ForegroundColor Red
    }
} catch {
    Write-Host "  ❌ Connectivity test failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 5: Update status function
Write-Host "`n🔄 Testing update status..." -ForegroundColor Yellow

try {
    $updateStatus = Get-UpdateStatus
    
    if ($updateStatus.AzDo -and $updateStatus.SMB -and $updateStatus.Update -and $updateStatus.Timestamp) {
        Write-Host "  ✅ Update status structure is correct" -ForegroundColor Green
        Write-Host "    - AzDo Connected: $($updateStatus.AzDo.Connected)" -ForegroundColor Gray
        Write-Host "    - SMB Connected: $($updateStatus.SMB.Connected)" -ForegroundColor Gray
        Write-Host "    - Update Available: $($updateStatus.Update.UpdateAvailable)" -ForegroundColor Gray
        $passed++
    } else {
        Write-Host "  ❌ Update status structure is incomplete" -ForegroundColor Red
    }
} catch {
    Write-Host "  ❌ Update status test failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Summary
Write-Host "`n📊 Test Results:" -ForegroundColor Cyan
Write-Host "Passed: $passed/6 tests" -ForegroundColor $(if ($passed -eq 6) { "Green" } else { "Yellow" })

if ($passed -eq 6) {
    Write-Host "🎉 All tests passed! AzDo integration module is ready." -ForegroundColor Green
    exit 0
} else {
    Write-Host "⚠️  Some tests failed. Review implementation." -ForegroundColor Yellow
    exit 1
}