<#
.SYNOPSIS
    Read-only check of TLS 1.2 SChannel/.NET strong-crypto registry state.
.DESCRIPTION
    Reports the six registry values that Enable-Tls12.ps1 sets, the server's
    local timezone/clock, and whether a CloudOps-TLS12-Reboot scheduled task
    is currently pending. Makes no changes. Designed to run via AWS SSM
    Run Command (AWS-RunPowerShellScript) — output is KEY|value lines parsed
    by tls_enable.py's parse_kv().
.NOTES
    Companion to Enable-Tls12.ps1. Keep the registry paths/keys in sync
    between the two scripts.
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

$tls12 = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2'
$netFx = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'
$netFxWow = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319'

Write-Output "HOST|$($env:COMPUTERNAME)"
Write-Output "OS|$((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Output "TIMEZONE|$([System.TimeZoneInfo]::Local.Id)"
Write-Output "CLOCK_LOCAL|$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')"

$serverEnabled   = Get-RegValue -Path "$tls12\Server" -Name 'Enabled'
$serverDisabled  = Get-RegValue -Path "$tls12\Server" -Name 'DisabledByDefault'
$clientEnabled   = Get-RegValue -Path "$tls12\Client" -Name 'Enabled'
$clientDisabled  = Get-RegValue -Path "$tls12\Client" -Name 'DisabledByDefault'
$strongCrypto    = Get-RegValue -Path $netFx -Name 'SchUseStrongCrypto'
$strongCryptoWow = Get-RegValue -Path $netFxWow -Name 'SchUseStrongCrypto'

Write-Output "REG_SERVER_ENABLED|$serverEnabled"
Write-Output "REG_SERVER_DISABLEDBYDEFAULT|$serverDisabled"
Write-Output "REG_CLIENT_ENABLED|$clientEnabled"
Write-Output "REG_CLIENT_DISABLEDBYDEFAULT|$clientDisabled"
Write-Output "REG_NET_STRONGCRYPTO|$strongCrypto"
Write-Output "REG_NET_STRONGCRYPTO_WOW64|$strongCryptoWow"

$compliant = (
    $serverEnabled -eq 1 -and $serverDisabled -eq 0 -and
    $clientEnabled -eq 1 -and $clientDisabled -eq 0 -and
    $strongCrypto -eq 1 -and $strongCryptoWow -eq 1
)

$task = Get-ScheduledTask -TaskName 'CloudOps-TLS12-Reboot' -ErrorAction SilentlyContinue
if ($task) {
    $info = $task | Get-ScheduledTaskInfo
    Write-Output "TASK_EXISTS|true"
    Write-Output "TASK_NEXTRUN|$($info.NextRunTime)"
} else {
    Write-Output "TASK_EXISTS|false"
    Write-Output "TASK_NEXTRUN|N/A"
}

Write-Output "RESULT|$(if ($compliant) { 'COMPLIANT' } else { 'NON_COMPLIANT' })"
