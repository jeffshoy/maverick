#Requires -Modules DnsServer

<#
.SYNOPSIS
    Removes DNS A record(s) matching a hostname or IP from an MS DNS zone.
.DESCRIPTION
    Companion to change-dns-ms.ps1 (which handles IP migration, not deletion). Used during
    server decommissions to clean up internal DNS (e.g. aspgov.pri) once an instance has been
    stopped/terminated and its DNS record is no longer needed.

    Looks up matching records by -HostName and/or -IPAddress (at least one required) in the
    given zone, reports what it found, and — after confirmation — removes them via
    Remove-DnsServerResourceRecord. Supports -WhatIf/-Confirm per team standard; nothing is
    removed without an explicit prompt unless -Force is passed.

    All actions are logged to a timestamped log file alongside standard console output.
.PARAMETER Zone
    The DNS zone to search (e.g. aspgov.pri).
.PARAMETER Server
    The DNS server hosting the authoritative zone (e.g. inf-svrdc001).
.PARAMETER HostName
    Hostname to match (e.g. WGAR-PC2GWB001). Optional if -IPAddress is given.
.PARAMETER IPAddress
    IPv4 address to match. Optional if -HostName is given.
.PARAMETER Force
    Skip the per-record confirmation prompt.
.EXAMPLE
    .\Remove-DnsRecord.ps1 -Zone aspgov.pri -Server inf-svrdc001 -HostName WGAR-PC2GWB001 -WhatIf
.EXAMPLE
    .\Remove-DnsRecord.ps1 -Zone aspgov.pri -Server inf-svrdc001 -HostName WGAR-PC2GWB001
.NOTES
    Author: CloudOps SRE
    Date: 2026-07-16
    Requires RSAT DnsServer module. Does not touch Azure DNS (aspgov.com) or NetBox —
    those remain manual portal steps; see runbooks/legacy-server-decommission.md.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Zone,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Server,

    [string] $HostName,

    [string] $IPAddress,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $HostName -and -not $IPAddress) {
    Write-Error "At least one of -HostName or -IPAddress must be specified."
    exit 1
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = "remove-dnsrecord_$($HostName -replace '[^\w-]', '_')_$timestamp.log"

function Write-Log {
    param([string] $Message)
    $line = "[$( Get-Date -Format 'yyyyMMdd-HHmmss')] $Message"
    Write-Host $line
    $line | Out-File -Append $logFile
}

try {
    $records = Get-DnsServerResourceRecord -ZoneName $Zone -ComputerName $Server -ErrorAction Stop |
        Where-Object {
            ($HostName -and $_.HostName -eq $HostName) -or
            ($IPAddress -and $_.RecordData.IPv4Address -and $_.RecordData.IPv4Address.ToString() -eq $IPAddress)
        }
} catch {
    Write-Error "Failed to query zone '$Zone' on server '$Server': $($_.Exception.Message)"
    exit 1
}

if (-not $records) {
    Write-Log "No matching records found in zone '$Zone' on '$Server' for HostName='$HostName' IPAddress='$IPAddress'."
    exit 0
}

Write-Log "Found $($records.Count) matching record(s) in zone '$Zone' on '$Server':"
foreach ($r in $records) {
    Write-Log "  $($r.HostName)  $($r.RecordType)  $($r.RecordData.IPv4Address)"
}

$removed = 0
$failed = 0

foreach ($r in $records) {
    $target = "$($r.HostName) ($($r.RecordType), $($r.RecordData.IPv4Address)) in zone $Zone on $Server"

    if (-not ($Force -or $PSCmdlet.ShouldProcess($target, 'Remove DNS record'))) {
        Write-Log "Skipped: $target"
        continue
    }

    try {
        Remove-DnsServerResourceRecord -ZoneName $Zone -ComputerName $Server -InputObject $r -Force -ErrorAction Stop
        Write-Log "Removed: $target"
        $removed++
    } catch {
        Write-Log "FAILED to remove $target : $($_.Exception.Message)"
        $failed++
    }
}

Write-Log "Done. Removed=$removed Failed=$failed. Log: $logFile"

if ($failed -gt 0) {
    exit 1
}
exit 0
