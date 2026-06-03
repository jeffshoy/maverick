#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Looks up a user by name across all four AD domains.
.DESCRIPTION
    Searches centroid.cloud.lcl, cloud.lcl, aws.cloud.lcl, and aspgov.pri for an AD
    user matching the provided name. Returns identity details (username, email, enabled
    status, password age, etc.) for verification — no changes are made.

    Search strategy (stops at first strategy that returns results):
      1. Exact GivenName + Surname match
      2. Partial wildcard match on both names
      3. Last-name-only fallback
.PARAMETER Name
    The user's full name as "First Last".
.PARAMETER Credential
    cloud.lcl admin credential used to authenticate against all four domain controllers.
    If omitted, you will be prompted. Format: CLOUD\username
.EXAMPLE
    .\Find-UserAllDomains.ps1 -Name "John Smith"

    Prompts for your cloud.lcl credentials then searches all four domains.
.EXAMPLE
    $cred = Get-Credential "CLOUD\trent.admin"
    .\Find-UserAllDomains.ps1 -Name "John Smith" -Credential $cred

    Reuses a pre-captured credential (useful when running multiple searches).
.EXAMPLE
    .\Find-UserAllDomains.ps1 -Name "John Smith" | Export-Csv -Path .\results.csv -NoTypeInformation

    Exports all results to a CSV for further review.
.NOTES
    Author: CloudOps SRE
    Read-only — no AD changes are made.
    Intended to run from a ps.lcl laptop over cloud admin VPN.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Name,

    [Parameter()]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = (Get-Credential -Message "Enter your cloud.lcl admin credential (e.g. CLOUD\trent.admin)")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts     = $Name.Trim() -split '\s+', 2
$FirstName = $parts[0]
$LastName  = if ($parts.Count -gt 1) { $parts[1] } else { '' }

$domains = @(
    @{ Name = 'centroid.cloud.lcl'; DC = 'centroid.cloud.lcl' },
    @{ Name = 'cloud.lcl';          DC = 'cloud.lcl' },
    @{ Name = 'aws.cloud.lcl';      DC = 'aws.cloud.lcl' },
    @{ Name = 'aspgov.pri';         DC = 'aspgov.pri' }
)

$adProperties = @(
    'GivenName', 'Surname', 'DisplayName', 'SamAccountName',
    'EmailAddress', 'telephoneNumber', 'Enabled', 'Description',
    'whenCreated', 'whenChanged', 'PasswordLastSet'
)

function Find-UsersInDomains {
    param(
        [string] $Filter,
        [string] $FilterLabel
    )

    $found = @()
    foreach ($domain in $domains) {
        try {
            $searchBase = (Get-ADRootDSE -Server $domain.DC -Credential $Credential -ErrorAction Stop).defaultNamingContext
            $users = @(Get-ADUser -Filter $Filter -Server $domain.DC -SearchBase $searchBase `
                       -Properties $adProperties -Credential $Credential -ErrorAction Stop)

            foreach ($user in $users) {
                $found += [PSCustomObject]@{
                    'Domain'            = $domain.Name
                    'Full Name'         = if ($user.DisplayName) { $user.DisplayName } else { $user.Name }
                    'First Name'        = $user.GivenName
                    'Last Name'         = $user.Surname
                    'Username'          = $user.SamAccountName
                    'Email'             = $user.EmailAddress
                    'Phone'             = $user.telephoneNumber
                    'Enabled'           = $user.Enabled
                    'Description'       = $user.Description
                    'Password Last Set' = $user.PasswordLastSet
                    'Created'           = $user.whenCreated
                    'Last Modified'     = $user.whenChanged
                }
            }
        } catch {
            Write-Warning "[$($domain.Name)] Search failed ($FilterLabel): $($_.Exception.Message)"
        }
    }

    return @($found)
}

# Escape single quotes to prevent filter syntax errors (e.g., O'Brien)
$safeFirst = $FirstName -replace "'", "''"
$safeLast  = $LastName  -replace "'", "''"

$strategies = @(
    @{
        Filter = "(GivenName -eq '$safeFirst') -and (Surname -eq '$safeLast')"
        Label  = "exact match"
    },
    @{
        Filter = "(GivenName -like '*$safeFirst*') -and (Surname -like '*$safeLast*')"
        Label  = "partial match"
    },
    @{
        Filter = "(Surname -like '*$safeLast*')"
        Label  = "last-name fallback"
    }
)

$results = @()
foreach ($strategy in $strategies) {
    if ($results.Count -gt 0) { break }
    Write-Verbose "Searching via $($strategy.Label)..."
    $results = @(Find-UsersInDomains -Filter $strategy.Filter -FilterLabel $strategy.Label)
}

if ($results.Count -eq 0) {
    Write-Warning "No users found matching '$Name' in any domain."
    exit 0
}

Write-Host "`nResults for '$Name':" -ForegroundColor Cyan

foreach ($domain in $domains) {
    $domainResults = @($results | Where-Object { $_.Domain -eq $domain.Name })
    if ($domainResults.Count -eq 0) { continue }

    Write-Host "`n## $($domain.Name) ##" -ForegroundColor Yellow

    $domainResults | Format-Table -AutoSize -Property `
        'Full Name',
        @{ Name = 'First';    Expression = { $_.'First Name' } },
        @{ Name = 'Last';     Expression = { $_.'Last Name' } },
        'Username',
        'Email',
        'Phone',
        'Enabled',
        @{ Name = 'Pwd Last Set'; Expression = { if ($_.'Password Last Set') { ($_.'Password Last Set').ToString('yyyy-MM-dd') } else { 'Never' } } },
        @{ Name = 'Created';      Expression = { if ($_.'Created')           { ($_.'Created').ToString('yyyy-MM-dd')           } else { '' } } },
        @{ Name = 'Last Modified';Expression = { if ($_.'Last Modified')     { ($_.'Last Modified').ToString('yyyy-MM-dd')     } else { '' } } },
        'Description'
}
