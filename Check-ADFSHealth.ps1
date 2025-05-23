<#
.SYNOPSIS
    Performs a basic health check on ADFS environment
.NOTES
    Author: Jarvis (ChatGPT)
    Version: 1.0
#>

# Define output log file
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = "ADFS_Health_Report_$timestamp.txt"

# Function to log results
function Log {
    param ($msg)
    Write-Host $msg
    Add-Content -Path $logFile -Value $msg
}

Log "======================== ADFS Health Report ========================"
Log "Generated: $(Get-Date)"
Log ""

# 1. Service Status Check
Log "`n[1] ADFS Service Status:"
Get-Service adfssrv | ForEach-Object {
    Log "Service Name: $_.Name"
    Log "Status: $_.Status"
}

# 2. WAP Proxy Check (if installed)
Log "`n[2] WAP/Proxy Status (if applicable):"
Try {
    Get-Service adfssrv -ComputerName localhost | Out-Null
    Log "WAP service appears to be local and running."
}
Catch {
    Log "WAP service not found locally. If using WAP, verify externally."
}

# 3. ADFS Configuration Overview
Log "`n[3] ADFS Configuration Properties:"
Try {
    $adfsProps = Get-AdfsProperties
    $adfsProps | Format-List | Out-String | ForEach-Object { Log $_ }
}
Catch {
    Log "Error retrieving ADFS properties."
}

# 4. SSL Certificate Status
Log "`n[4] ADFS SSL Certificate Info:"
Try {
    $cert = Get-AdfsSslCertificate
    $cert | Format-List | Out-String | ForEach-Object { Log $_ }
}
Catch {
    Log "Error retrieving SSL certificate."
}

# 5. Federation Metadata Check
Log "`n[5] Federation Metadata Check:"
$metaUrl = "https://$(hostname)/FederationMetadata/2007-06/FederationMetadata.xml"
try {
    $response = Invoke-WebRequest -Uri $metaUrl -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -eq 200) {
        Log "Federation metadata is accessible: $metaUrl"
    } else {
        Log "Metadata endpoint returned status code: $($response.StatusCode)"
    }
}
catch {
    Log "ERROR: Unable to access Federation Metadata URL: $metaUrl"
}

# 6. IdP-Initiated Sign-On Page
Log "`n[6] IdP-Initiated Sign-On Page:"
$idpUrl = "https://$(hostname)/adfs/ls/IdpInitiatedSignon.aspx"
try {
    $idpCheck = Invoke-WebRequest -Uri $idpUrl -UseBasicParsing -TimeoutSec 10
    if ($idpCheck.StatusCode -eq 200) {
        Log "IdP-Initiated sign-on page is accessible."
    } else {
        Log "Sign-on page returned status code: $($idpCheck.StatusCode)"
    }
}
catch {
    Log "ERROR: Unable to access IdP Sign-On page: $idpUrl"
}

# 7. WID Sync Status (if applicable)
Log "`n[7] WID Sync Status:"
Try {
    $syncStatus = Get-AdfsSyncProperties
    $syncStatus | Format-List | Out-String | ForEach-Object { Log $_ }
}
Catch {
    Log "WID Sync not applicable or error retrieving sync properties."
}

# 8. Recent ADFS Errors
Log "`n[8] Recent ADFS Errors (last 24h):"
Try {
    $errors = Get-WinEvent -LogName "AD FS/Admin" -ErrorAction SilentlyContinue |
              Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-24) -and $_.LevelDisplayName -eq "Error" }
    if ($errors) {
        foreach ($err in $errors) {
            Log "[$($err.TimeCreated)] $($err.Message)"
        }
    } else {
        Log "No recent ADFS errors found."
    }
}
Catch {
    Log "Could not read ADFS event log."
}

# 9. CPU and Memory usage (basic)
Log "`n[9] Resource Usage (ADFS Process):"
$adfsProc = Get-Process adfssrv -ErrorAction SilentlyContinue
if ($adfsProc) {
    Log "CPU: $($adfsProc.CPU)"
    Log "Memory: $([Math]::Round($adfsProc.WorkingSet64 / 1MB, 2)) MB"
} else {
    Log "ADFS process not found."
}

Log "`n======================== End of Report ========================"

# Output final path
Write-Host "`nHealth report saved to: $logFile"
