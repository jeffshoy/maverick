<#
.SYNOPSIS
    Resets Terminal Server (RDS) Grace Licensing Period to 120 days.
    Designed to run via AWS SSM Run Command (no interactive prompts).
.NOTES
    After reset the server will force-reboot automatically.
#>

$ErrorActionPreference = "Stop"

# --- Show current grace period ---
try {
    $tsSetting = Get-WmiObject -Namespace root\cimv2\terminalservices -Class Win32_TerminalServiceSetting
    $grace = (Invoke-WmiMethod -Path $tsSetting.__PATH -Name GetGracePeriodDays).DaysLeft
    Write-Output "Current RDS grace period days remaining: $grace"
} catch {
    Write-Output "WARNING: Could not query grace period - $_"
}

# --- P/Invoke for SeTakeOwnershipPrivilege ---
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Win32Api {
    public class NtDll {
        [DllImport("ntdll.dll", EntryPoint="RtlAdjustPrivilege")]
        public static extern int RtlAdjustPrivilege(ulong Privilege, bool Enable, bool CurrentThread, ref bool Enabled);
    }
}
"@

$enabled = $false
[void][Win32Api.NtDll]::RtlAdjustPrivilege(9, $true, $false, [ref]$enabled)

# --- Take ownership & grant Administrators full control ---
$regPath = "SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod"
$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    $regPath,
    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
    [System.Security.AccessControl.RegistryRights]::TakeOwnership
)
if (-not $key) { throw "Registry key not found: HKLM:\$regPath" }

$acl = $key.GetAccessControl()
$acl.SetOwner([System.Security.Principal.NTAccount]"Administrators")
$key.SetAccessControl($acl)

$rule = New-Object System.Security.AccessControl.RegistryAccessRule(
    "Administrators", "FullControl", "Allow"
)
$acl.SetAccessRule($rule)
$key.SetAccessControl($acl)

# --- Delete the key to reset grace period ---
Remove-Item "HKLM:\$regPath" -Recurse -Force
Write-Output "Grace period registry key deleted. Reset to 120 days."

# --- Verify ---
try {
    $tsSetting = Get-WmiObject -Namespace root\cimv2\terminalservices -Class Win32_TerminalServiceSetting
    $gracePost = (Invoke-WmiMethod -Path $tsSetting.__PATH -Name GetGracePeriodDays).DaysLeft
    Write-Output "Post-reset RDS grace period days remaining: $gracePost"
} catch {
    Write-Output "WARNING: Could not verify grace period - will confirm after reboot."
}

# --- Force reboot (kicks all users) ---
Write-Output "Forcing reboot in 5 seconds..."
shutdown /r /f /t 5
