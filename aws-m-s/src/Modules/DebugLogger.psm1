#requires -version 7.0
<#
.SYNOPSIS
    Debug Logger Module for AWS Management Studio

.DESCRIPTION
    Provides debug logging capabilities and test result capture
#>

Set-StrictMode -Version Latest

# Global debug log storage
$script:DebugLogs = @()
$script:TestResults = @()
$script:LogFile = $null

function Initialize-DebugLogger {
    <#
    .SYNOPSIS
        Initialize debug logging system
    #>
    $script:LogFile = Join-Path $env:TEMP "AWS-Management-Studio-Debug-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Write-DebugLog "Debug logging initialized" "INFO"
}

function Write-DebugLog {
    <#
    .SYNOPSIS
        Write debug log entry
    #>
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Source = "Application"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = @{
        Timestamp = $timestamp
        Level = $Level
        Source = $Source
        Message = $Message
    }
    
    $script:DebugLogs += $logEntry
    
    # Also write to file if available
    if ($script:LogFile) {
        try {
            "[$timestamp] [$Level] [$Source] $Message" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
        } catch {
            # File logging is non-critical
        }
    }
}

function Get-DebugLogs {
    <#
    .SYNOPSIS
        Get all debug logs
    #>
    return $script:DebugLogs
}

function Clear-DebugLogs {
    <#
    .SYNOPSIS
        Clear debug logs
    #>
    $script:DebugLogs = @()
    Write-DebugLog "Debug logs cleared" "INFO"
}

function Export-DebugLogsToJson {
    <#
    .SYNOPSIS
        Export debug logs to JSON file
    #>
    param([string]$FilePath)
    
    try {
        $exportData = @{
            ExportTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            LogCount = $script:DebugLogs.Count
            Logs = $script:DebugLogs
        }
        
        $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $FilePath -Encoding UTF8
        Write-DebugLog "Debug logs exported to $FilePath" "INFO"
        return $true
    } catch {
        Write-DebugLog "Failed to export logs: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Export-DebugLogsToHtml {
    <#
    .SYNOPSIS
        Export debug logs to HTML file
    #>
    param([string]$FilePath)
    
    try {
        $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>AWS Management Studio - Debug Logs</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; }
        .header { background: #0078d4; color: white; padding: 15px; border-radius: 5px; }
        .log-entry { margin: 5px 0; padding: 8px; border-left: 4px solid #ccc; background: #f9f9f9; }
        .INFO { border-left-color: #28a745; }
        .WARN { border-left-color: #ffc107; background: #fff3cd; }
        .ERROR { border-left-color: #dc3545; background: #f8d7da; }
        .DEBUG { border-left-color: #6c757d; }
        .timestamp { color: #666; font-size: 0.9em; }
        .level { font-weight: bold; padding: 2px 6px; border-radius: 3px; font-size: 0.8em; }
        .level.INFO { background: #d4edda; color: #155724; }
        .level.WARN { background: #fff3cd; color: #856404; }
        .level.ERROR { background: #f8d7da; color: #721c24; }
        .level.DEBUG { background: #e2e3e5; color: #383d41; }
    </style>
</head>
<body>
    <div class="header">
        <h1>AWS Management Studio - Debug Logs</h1>
        <p>Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Total Entries: $($script:DebugLogs.Count)</p>
    </div>
    <div class="logs">
"@
        
        foreach ($log in $script:DebugLogs) {
            $html += @"
        <div class="log-entry $($log.Level)">
            <span class="timestamp">$($log.Timestamp)</span>
            <span class="level $($log.Level)">$($log.Level)</span>
            <strong>[$($log.Source)]</strong> $($log.Message)
        </div>
"@
        }
        
        $html += @"
    </div>
</body>
</html>
"@
        
        $html | Out-File -FilePath $FilePath -Encoding UTF8
        Write-DebugLog "Debug logs exported to HTML: $FilePath" "INFO"
        return $true
    } catch {
        Write-DebugLog "Failed to export HTML logs: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Start-TestCapture {
    <#
    .SYNOPSIS
        Start capturing test results
    #>
    $script:TestResults = @()
    Write-DebugLog "Test capture started" "INFO" "TestRunner"
}

function Add-TestResult {
    <#
    .SYNOPSIS
        Add test result
    #>
    param(
        [string]$TestName,
        [string]$Status,
        [string]$Message = "",
        [object]$Details = $null
    )
    
    $result = @{
        TestName = $TestName
        Status = $Status
        Message = $Message
        Details = $Details
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    }
    
    $script:TestResults += $result
    Write-DebugLog "Test: $TestName - $Status - $Message" "INFO" "TestRunner"
}

function Get-TestResults {
    <#
    .SYNOPSIS
        Get all test results
    #>
    return $script:TestResults
}

function Export-TestResults {
    <#
    .SYNOPSIS
        Export test results to JSON and HTML
    #>
    param([string]$BasePath)
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $jsonPath = "$BasePath-TestResults-$timestamp.json"
    $htmlPath = "$BasePath-TestResults-$timestamp.html"
    
    # Export JSON
    try {
        $exportData = @{
            TestRun = @{
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                TotalTests = $script:TestResults.Count
                PassedTests = ($script:TestResults | Where-Object { $_.Status -eq "PASS" }).Count
                FailedTests = ($script:TestResults | Where-Object { $_.Status -eq "FAIL" }).Count
                WarningTests = ($script:TestResults | Where-Object { $_.Status -eq "WARN" }).Count
            }
            Results = $script:TestResults
        }
        
        $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-DebugLog "Test results exported to JSON: $jsonPath" "INFO" "TestRunner"
    } catch {
        Write-DebugLog "Failed to export test JSON: $($_.Exception.Message)" "ERROR" "TestRunner"
    }
    
    # Export HTML
    try {
        $passCount = ($script:TestResults | Where-Object { $_.Status -eq "PASS" }).Count
        $failCount = ($script:TestResults | Where-Object { $_.Status -eq "FAIL" }).Count
        $warnCount = ($script:TestResults | Where-Object { $_.Status -eq "WARN" }).Count
        
        $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>AWS Management Studio - Test Results</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; }
        .header { background: #0078d4; color: white; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .summary { display: flex; gap: 20px; margin-bottom: 20px; }
        .summary-card { padding: 15px; border-radius: 5px; text-align: center; flex: 1; }
        .pass { background: #d4edda; color: #155724; }
        .fail { background: #f8d7da; color: #721c24; }
        .warn { background: #fff3cd; color: #856404; }
        .test-result { margin: 10px 0; padding: 10px; border-radius: 5px; border-left: 4px solid #ccc; }
        .test-result.PASS { border-left-color: #28a745; background: #f8fff9; }
        .test-result.FAIL { border-left-color: #dc3545; background: #fff8f8; }
        .test-result.WARN { border-left-color: #ffc107; background: #fffef8; }
        .test-name { font-weight: bold; margin-bottom: 5px; }
        .test-status { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 0.8em; font-weight: bold; }
        .test-status.PASS { background: #28a745; color: white; }
        .test-status.FAIL { background: #dc3545; color: white; }
        .test-status.WARN { background: #ffc107; color: #212529; }
        .timestamp { color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <div class="header">
        <h1>AWS Management Studio - Test Results</h1>
        <p>Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Total Tests: $($script:TestResults.Count)</p>
    </div>
    
    <div class="summary">
        <div class="summary-card pass">
            <h3>$passCount</h3>
            <p>Passed</p>
        </div>
        <div class="summary-card fail">
            <h3>$failCount</h3>
            <p>Failed</p>
        </div>
        <div class="summary-card warn">
            <h3>$warnCount</h3>
            <p>Warnings</p>
        </div>
    </div>
    
    <div class="results">
"@
        
        foreach ($result in $script:TestResults) {
            $html += @"
        <div class="test-result $($result.Status)">
            <div class="test-name">$($result.TestName)</div>
            <span class="test-status $($result.Status)">$($result.Status)</span>
            <span class="timestamp">$($result.Timestamp)</span>
            $(if ($result.Message) { "<p>$($result.Message)</p>" })
        </div>
"@
        }
        
        $html += @"
    </div>
</body>
</html>
"@
        
        $html | Out-File -FilePath $htmlPath -Encoding UTF8
        Write-DebugLog "Test results exported to HTML: $htmlPath" "INFO" "TestRunner"
    } catch {
        Write-DebugLog "Failed to export test HTML: $($_.Exception.Message)" "ERROR" "TestRunner"
    }
    
    return @{
        JsonPath = $jsonPath
        HtmlPath = $htmlPath
    }
}

# Initialize on module load
Initialize-DebugLogger

Export-ModuleMember -Function Initialize-DebugLogger, Write-DebugLog, Get-DebugLogs, Clear-DebugLogs, Export-DebugLogsToJson, Export-DebugLogsToHtml, Start-TestCapture, Add-TestResult, Get-TestResults, Export-TestResults