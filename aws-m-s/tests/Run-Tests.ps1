#requires -version 7.0
<#
.SYNOPSIS
    Test Runner for AWS Management Studio

.DESCRIPTION
    Centralized test runner that can execute different test suites:
    - Quick: Fast validation for daily development
    - Comprehensive: Full feature testing
    - Integration: End-to-end testing with AWS
    - All: Run all test suites

.PARAMETER TestSuite
    Which test suite to run: Quick, Comprehensive, Integration, All

.PARAMETER OutputFormat
    Output format: Console, JSON, HTML

.EXAMPLE
    .\Run-Tests.ps1 -TestSuite Quick
    .\Run-Tests.ps1 -TestSuite Comprehensive -OutputFormat JSON
#>

param(
    [ValidateSet('Quick', 'Comprehensive', 'Basic', 'Simple', 'Discovery', 'Validation', 'All')]
    [string]$TestSuite = 'Quick',
    
    [ValidateSet('Console', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Get application version
. "$PSScriptRoot\Get-AppVersion.ps1"

$script:TestSuites = @{
    'Quick' = @{
        Script = 'test-quick.ps1'
        Description = 'Fast validation for daily development'
        EstimatedTime = '5 seconds'
    }
    'Comprehensive' = @{
        Script = 'test-comprehensive.ps1'
        Description = 'Full feature testing and validation'
        EstimatedTime = '30-60 seconds'
    }
    'Basic' = @{
        Script = 'test-basic.ps1'
        Description = 'Basic modular architecture validation'
        EstimatedTime = '10 seconds'
    }
    'Simple' = @{
        Script = 'test-simple.ps1'
        Description = 'Simple validation without AWS CLI dependencies'
        EstimatedTime = '3 seconds'
    }
    'Discovery' = @{
        Script = 'test-service-discovery.ps1'
        Description = 'Validate service discovery system'
        EstimatedTime = '5 seconds'
    }
    'Validation' = @{
        Script = 'test-validation.ps1'
        Description = 'Test service validation (API call optimization)'
        EstimatedTime = '3 seconds'
    }
}

function Write-Header {
    param([string]$Title)
    Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
}

function Run-TestSuite {
    param([string]$SuiteName)
    
    $suite = $script:TestSuites[$SuiteName]
    if (-not $suite) {
        Write-Host "❌ Unknown test suite: $SuiteName" -ForegroundColor Red
        return $false
    }
    
    $scriptPath = Join-Path $PSScriptRoot $suite.Script
    if (-not (Test-Path $scriptPath)) {
        Write-Host "❌ Test script not found: $scriptPath" -ForegroundColor Red
        return $false
    }
    
    Write-Header "Running $SuiteName Test Suite"
    Write-Host "Description: $($suite.Description)" -ForegroundColor Gray
    Write-Host "Estimated Time: $($suite.EstimatedTime)" -ForegroundColor Gray
    Write-Host "Script: $($suite.Script)" -ForegroundColor Gray
    
    $startTime = Get-Date
    
    try {
        # Execute test script
        & $scriptPath
        $duration = (Get-Date).Subtract($startTime).TotalSeconds
        Write-Host "`n✅ $SuiteName test suite completed in $([math]::Round($duration, 1)) seconds" -ForegroundColor Green
        return $true
    } catch {
        $duration = (Get-Date).Subtract($startTime).TotalSeconds
        Write-Host "`n❌ $SuiteName test suite failed after $([math]::Round($duration, 1)) seconds" -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Main execution
$overallStartTime = Get-Date

Write-Header "AWS Management Studio v$global:AppVersion - Test Runner"
Write-Host "Test Suite: $TestSuite" -ForegroundColor White
Write-Host "Output Format: $OutputFormat" -ForegroundColor White
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host "Threading Mode: $([Threading.Thread]::CurrentThread.GetApartmentState())" -ForegroundColor Gray

$results = @()

if ($TestSuite -eq 'All') {
    # Run all test suites
    foreach ($suiteName in @('Simple', 'Basic', 'Quick', 'Discovery', 'Validation', 'Comprehensive')) {
        $success = Run-TestSuite -SuiteName $suiteName
        $results += @{
            Suite = $suiteName
            Success = $success
            Timestamp = Get-Date
        }
    }
} else {
    # Run single test suite
    $success = Run-TestSuite -SuiteName $TestSuite
    $results += @{
        Suite = $TestSuite
        Success = $success
        Timestamp = Get-Date
    }
}

# Summary
$totalDuration = (Get-Date).Subtract($overallStartTime).TotalSeconds
$successResults = @($results | Where-Object { $_.Success })
$successCount = $successResults.Count
$totalCount = $results.Count

Write-Header "Test Execution Summary"
Write-Host "Total Suites Run: $totalCount" -ForegroundColor White
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $($totalCount - $successCount)" -ForegroundColor Red
Write-Host "Total Duration: $([math]::Round($totalDuration, 1)) seconds" -ForegroundColor Cyan

# Output results in requested format
switch ($OutputFormat) {
    'JSON' {
        $tempDir = Join-Path $env:TEMP "AWS-EC2-Management-Studio-Tests"
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
        $outputFile = Join-Path $tempDir "test-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $results | ConvertTo-Json -Depth 3 | Out-File -FilePath $outputFile -Encoding UTF8
        if ($global:DebugMode -or $DebugPreference -ne 'SilentlyContinue') {
            Write-Host "`n📄 Results exported to: $outputFile" -ForegroundColor Cyan
        }
        
        # Update TEST_RESULTS.md and cleanup
        try {
            $updateSuccess = Update-TestResultsFile -ResultsFile $outputFile
            
            if ($updateSuccess) {
                Remove-Item $outputFile -Force
                if ($global:DebugMode -or $DebugPreference -ne 'SilentlyContinue') {
                    Write-Host "📝 TEST_RESULTS.md updated and temp file cleaned" -ForegroundColor Green
                }
            } else {
                Write-Warning "TEST_RESULTS.md update failed - keeping temp file: $outputFile"
            }
        } catch {
            Write-Warning "Failed to update TEST_RESULTS.md: $($_.Exception.Message) - keeping temp file: $outputFile"
        }
    }
    'HTML' {
        $tempDir = Join-Path $env:TEMP "AWS-EC2-Management-Studio-Tests"
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
        $outputFile = Join-Path $tempDir "test-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
        $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>AWS Management Studio Test Results</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background: #f0f0f0; padding: 10px; border-radius: 5px; }
        .success { color: green; }
        .failure { color: red; }
        .summary { background: #e8f4f8; padding: 10px; margin: 10px 0; border-radius: 5px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>AWS Management Studio v$global:AppVersion - Test Results</h1>
        <p>Generated: $(Get-Date)</p>
        <p>Test Suite: $TestSuite</p>
    </div>
    <div class="summary">
        <h2>Summary</h2>
        <p>Total Suites: $totalCount</p>
        <p>Successful: <span class="success">$successCount</span></p>
        <p>Failed: <span class="failure">$($totalCount - $successCount)</span></p>
        <p>Duration: $([math]::Round($totalDuration, 1)) seconds</p>
    </div>
    <h2>Results</h2>
    <ul>
"@
        foreach ($result in $results) {
            $status = if ($result.Success) { "success" } else { "failure" }
            $icon = if ($result.Success) { "✅" } else { "❌" }
            $html += "        <li class=`"$status`">$icon $($result.Suite) - $($result.Timestamp)</li>`n"
        }
        $html += @"
    </ul>
</body>
</html>
"@
        $html | Out-File -FilePath $outputFile -Encoding UTF8
        if ($global:DebugMode -or $DebugPreference -ne 'SilentlyContinue') {
            Write-Host "`n📄 HTML report exported to: $outputFile" -ForegroundColor Cyan
            Write-Host "💡 Temp files in: $tempDir (manual cleanup required)" -ForegroundColor Yellow
        }
    }
}

# Exit with appropriate code
if ($successCount -eq $totalCount) {
    Write-Host "`n✅ All test suites passed successfully!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n❌ Some test suites failed. Review results above." -ForegroundColor Red
    exit 1
}