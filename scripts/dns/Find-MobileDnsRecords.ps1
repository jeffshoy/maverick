#Requires -Modules DnsServer
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Finds DNS records in a forward lookup zone whose name contains a given pattern.
.DESCRIPTION
    Queries a remote DNS server for all resource records in the specified forward lookup zone
    and returns those whose hostname matches the search pattern. Defaults to searching
    for "-mobile" in the aspgov.com zone. Read-only — makes no changes.
.PARAMETER DnsServer
    FQDN or IP of the DNS server hosting the target zone. Required.
.PARAMETER Zone
    The forward lookup zone to search. Defaults to aspgov.com.
.PARAMETER Pattern
    Substring to match against record hostnames. Defaults to -mobile.
.EXAMPLE
    .\Find-MobileDnsRecords.ps1 -DnsServer dc01.cloud.lcl
.EXAMPLE
    .\Find-MobileDnsRecords.ps1 -DnsServer dc01.cloud.lcl -Zone aspgov.com -Pattern "-mobile"
.NOTES
    Requires RSAT DNS Server Tools (DnsServer module) on the workstation.
    Run as a user with DNS read access on the target server.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DnsServer,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Zone = 'aspgov.com',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Pattern = '-mobile'
)

Write-Verbose "Querying DNS server '$DnsServer' for zone '$Zone'"

try {
    $allRecords = Get-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $Zone -ErrorAction Stop
}
catch {
    Write-Error "Failed to retrieve records from '$DnsServer' zone '$Zone': $_"
    exit 1
}

Write-Verbose "Total records retrieved: $($allRecords.Count)"

$matches = $allRecords | Where-Object { $_.HostName -like "*$Pattern*" }

if (-not $matches) {
    Write-Warning "No records found matching pattern '$Pattern' in zone '$Zone' on server '$DnsServer'."
    exit 0
}

Write-Verbose "Matching records found: $($matches.Count)"

$matches | Select-Object HostName, RecordType, TimeToLive,
    @{ Name = 'RecordData'; Expression = {
        $rd = $_.RecordData
        switch ($_.RecordType) {
            'A'     { $rd.IPv4Address.IPAddressToString }
            'AAAA'  { $rd.IPv6Address.IPAddressToString }
            'CNAME' { $rd.HostNameAlias }
            'MX'    { "$($rd.MailExchange) (pref $($rd.Preference))" }
            'TXT'   { $rd.DescriptiveText }
            default { $rd.ToString() }
        }
    }} |
    Sort-Object HostName |
    Format-Table -AutoSize
