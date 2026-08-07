<#
.SYNOPSIS
    Enables TLS 1.2 (SChannel server/client) and .NET strong crypto, then
    schedules a one-time reboot for 5:00 AM server-local time.
.DESCRIPTION
    Idempotent: reads current registry state first. If all six values are
    already correct, makes no changes and schedules no reboot (RESULT|
    ALREADY_COMPLIANT). Otherwise creates any missing parent keys, sets the
    six values, then registers a self-deleting Scheduled Task
    (CloudOps-TLS12-Reboot) that reboots the box at the next 5:00 AM local
    time (tomorrow if within 10 minutes of today's 5:00 AM or already past
    it). The reboot itself is deferred — this script does not reboot
    immediately.

    Designed to run via AWS SSM Run Command (AWS-RunPowerShellScript).
    Output is KEY|value lines parsed by tls_enable.py's parse_kv().
.NOTES
    Companion to Check-Tls12.ps1. Keep the registry paths/keys in sync
    between the two scripts. Cancelling a pending reboot is handled by
    tls_enable.py sending a small inline Unregister-ScheduledTask command —
    it does not reuse this file, since it must not touch the registry.
#>

$ErrorActionPreference = "Stop"

function Get-RegValue {
    param([string] $Path, [string] $Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch {
        return $null
    }
}

function Set-RegValueIfChanged {
    param([string] $Path, [string] $Name, [int] $Value)
    # New-Item -Force on a key that already exists recreates it, wiping any
    # other values already set on that key. Only create it if it's actually
    # missing, and only touch this one value.
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    $current = Get-RegValue -Path $Path -Name $Name
    if ($current -eq $Value) {
        return $false
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord
    return $true
}

$tls12 = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2'
$netFx = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'
$netFxWow = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319'
$taskName = 'CloudOps-TLS12-Reboot'
$helperDir = 'C:\ProgramData\CloudOps'
$helperPath = Join-Path $helperDir 'Invoke-Tls12Reboot.ps1'
$logPath = Join-Path $helperDir 'tls12-reboot.log'

Write-Output "HOST|$($env:COMPUTERNAME)"
Write-Output "TIMEZONE|$([System.TimeZoneInfo]::Local.Id)"
Write-Output "CLOCK_LOCAL|$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')"

# --- Pre-check: is this already fully compliant? ---
$preCompliant = (
    (Get-RegValue -Path "$tls12\Server" -Name 'Enabled') -eq 1 -and
    (Get-RegValue -Path "$tls12\Server" -Name 'DisabledByDefault') -eq 0 -and
    (Get-RegValue -Path "$tls12\Client" -Name 'Enabled') -eq 1 -and
    (Get-RegValue -Path "$tls12\Client" -Name 'DisabledByDefault') -eq 0 -and
    (Get-RegValue -Path $netFx -Name 'SchUseStrongCrypto') -eq 1 -and
    (Get-RegValue -Path $netFxWow -Name 'SchUseStrongCrypto') -eq 1
)

if ($preCompliant) {
    Write-Output "CHANGED|0"
    Write-Output "TASK|skipped"
    Write-Output "RESULT|ALREADY_COMPLIANT"
    exit 0
}

# --- Apply: create any missing parent keys, set only values that differ ---
$changed = 0
if (Set-RegValueIfChanged -Path "$tls12\Server" -Name 'Enabled'            -Value 1) { $changed++ }
if (Set-RegValueIfChanged -Path "$tls12\Server" -Name 'DisabledByDefault'  -Value 0) { $changed++ }
if (Set-RegValueIfChanged -Path "$tls12\Client" -Name 'Enabled'            -Value 1) { $changed++ }
if (Set-RegValueIfChanged -Path "$tls12\Client" -Name 'DisabledByDefault'  -Value 0) { $changed++ }
if (Set-RegValueIfChanged -Path $netFx          -Name 'SchUseStrongCrypto' -Value 1) { $changed++ }
if (Set-RegValueIfChanged -Path $netFxWow       -Name 'SchUseStrongCrypto' -Value 1) { $changed++ }

Write-Output "CHANGED|$changed"

# --- Compute next 5:00 AM local, at least 10 minutes out ---
$now = Get-Date
$when = $now.Date.AddHours(5)
if ($when -le $now.AddMinutes(10)) {
    $when = $when.AddDays(1)
}
Write-Output "REBOOT_AT|$($when.ToString('yyyy-MM-ddTHH:mm:ss'))"

# --- Write self-deleting reboot helper ---
New-Item -Path $helperDir -ItemType Directory -Force | Out-Null
$helperContent = @"
`$logPath = '$logPath'
"`$(Get-Date -Format o) - TLS 1.2 scheduled reboot firing" | Add-Content -Path `$logPath
shutdown.exe /r /f /t 300 /c "CloudOps: rebooting to finalize TLS 1.2 enablement" /d p:2:4
Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
"`$(Get-Date -Format o) - shutdown issued, task unregistered" | Add-Content -Path `$logPath
"@
Set-Content -Path $helperPath -Value $helperContent -Encoding UTF8 -Force

# --- Register (or replace) the one-time scheduled task ---
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`""
$trigger = New-ScheduledTaskTrigger -Once -At $when
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null

if ($existingTask) {
    Write-Output "TASK|replaced"
} else {
    Write-Output "TASK|created"
}

Write-Output "RESULT|APPLIED"
