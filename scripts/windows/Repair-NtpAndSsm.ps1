#Requires -Version 5.1

<#
.SYNOPSIS
    Fixes NTP time skew and restarts the SSM agent on remote Windows servers via WMI.
.DESCRIPTION
    Targets are defined at the top of the script. For each target, this script:
      1. Writes the AWS time server to the W32Time registry via StdRegProv WMI
      2. Restarts the W32Time service to pick up the new config
      3. Forces a time resync and verifies skew is within threshold
      4. Starts the AmazonSSMAgent service and confirms it is running
    Run from a domain-joined machine (e.g. SDSP-PONSDB001) as a domain user
    with local admin rights on the target servers.
.PARAMETER SkewThresholdSeconds
    Maximum acceptable time skew in seconds after resync. Default is 60.
.EXAMPLE
    .\Repair-NtpAndSsm.ps1
.EXAMPLE
    .\Repair-NtpAndSsm.ps1 -SkewThresholdSeconds 30
.NOTES
    Author: CloudOps SRE
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [int] $SkewThresholdSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Edit targets here ---
$targets = @(
    "SDSP-PONSAP001"
    "SDSP-PDC001"
    "SDSP-PONSOL001"
    "SDSP-PXSF001"
    "SDSP-PONSRP001"
    "SDSP-PONSJB001"
)
# -------------------------

$NtpServer  = "169.254.169.123,0x9"
$HKLM       = 2147483650
$w32RegPath = "SYSTEM\CurrentControlSet\Services\W32Time\Parameters"

foreach ($target in $targets) {
    Write-Output "`n=== $target ==="

    # 1. Write NTP registry values
    try {
        $reg = [wmiclass]"\\$target\root\default:StdRegProv"
        $r1 = $reg.SetStringValue($HKLM, $w32RegPath, "NtpServer", $NtpServer)
        $r2 = $reg.SetStringValue($HKLM, $w32RegPath, "Type", "NTP")
        if ($r1.ReturnValue -eq 0 -and $r2.ReturnValue -eq 0) {
            Write-Output "  [OK] Registry: NtpServer and Type written"
        } else {
            Write-Warning "  [WARN] Registry write returned NtpServer=$($r1.ReturnValue) Type=$($r2.ReturnValue)"
        }
    } catch {
        Write-Warning "  [FAIL] Registry write: $($_.Exception.Message)"
        continue
    }

    # 2. Restart W32Time service to pick up new config
    try {
        $w32svc = Get-WmiObject -ComputerName $target -Class Win32_Service -Filter "Name='w32time'" -ErrorAction Stop
        $w32svc.StopService()  | Out-Null
        Start-Sleep -Seconds 2
        $w32svc.StartService() | Out-Null
        Start-Sleep -Seconds 3
        Write-Output "  [OK] W32Time service restarted"
    } catch {
        Write-Warning "  [FAIL] W32Time restart: $($_.Exception.Message)"
        continue
    }

    # 3. Force resync
    try {
        $r = Invoke-WmiMethod -ComputerName $target -Class Win32_Process -Name Create -ArgumentList "w32tm /resync /force" -ErrorAction Stop
        if ($r.ReturnValue -eq 0) {
            Write-Output "  [OK] w32tm resync launched (PID $($r.ProcessId))"
        } else {
            Write-Warning "  [WARN] w32tm resync ReturnValue=$($r.ReturnValue)"
        }
        Start-Sleep -Seconds 5
    } catch {
        Write-Warning "  [FAIL] w32tm resync: $($_.Exception.Message)"
    }

    # 4. Verify time skew
    try {
        $os       = Get-WmiObject -ComputerName $target -Class Win32_OperatingSystem -ErrorAction Stop
        $remote   = [System.Management.ManagementDateTimeConverter]::ToDateTime($os.LocalDateTime).ToUniversalTime()
        $skew     = [math]::Round(($remote - [datetime]::UtcNow).TotalSeconds, 1)
        if ([math]::Abs($skew) -le $SkewThresholdSeconds) {
            Write-Output "  [OK] Time skew: ${skew}s (within ${SkewThresholdSeconds}s threshold)"
        } else {
            Write-Warning "  [WARN] Time skew still ${skew}s — SSM may not register. Skipping SSM restart."
            continue
        }
    } catch {
        Write-Warning "  [FAIL] Time check: $($_.Exception.Message)"
        continue
    }

    # 5. Start AmazonSSMAgent
    try {
        $ssmsvc = Get-WmiObject -ComputerName $target -Class Win32_Service -Filter "Name='AmazonSSMAgent'" -ErrorAction Stop
        if ($ssmsvc.State -eq 'Running') {
            $ssmsvc.StopService() | Out-Null
        }
        Start-Sleep -Seconds 5
        $r = $ssmsvc.StartService()
        if ($r.ReturnValue -eq 0) {
            Write-Output "  [OK] AmazonSSMAgent started"
        } else {
            Write-Warning "  [WARN] AmazonSSMAgent StartService returned $($r.ReturnValue)"
        }
        Start-Sleep -Seconds 2
    } catch {
        Write-Warning "  [FAIL] AmazonSSMAgent start: $($_.Exception.Message)"
        continue
    }

    # 6. Confirm service state
    try {
        $ssmsvc = Get-WmiObject -ComputerName $target -Class Win32_Service -Filter "Name='AmazonSSMAgent'" -ErrorAction Stop
        if ($ssmsvc.State -eq 'Running') {
            Write-Output "  [OK] AmazonSSMAgent State=$($ssmsvc.State)"
        } else {
            Write-Warning "  [WARN] AmazonSSMAgent State=$($ssmsvc.State) — may need manual check"
        }
    } catch {
        Write-Warning "  [FAIL] AmazonSSMAgent state check: $($_.Exception.Message)"
    }
}

Write-Output "`nDone. Verify SSM registration in the AWS console or via aws ssm describe-instance-information."
