#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Search for and disable user accounts across all four CloudOps AD domains.
.DESCRIPTION
    Searches cloud.lcl, aws.cloud.lcl, aspgov.pri, and centroid.cloud.lcl for a
    user by name, email, or user ID. Displays matches, prompts for selection, then
    disables the account and updates the Description field with the ticket number,
    date, and SRE initials. Exports a CSV backup to the desktop before any changes.

    Users in centroid.cloud.lcl are also moved to OU=_Deprecated after disabling.
.PARAMETER None
    All inputs are collected interactively.
.EXAMPLE
    .\Disable_users_4Domains.ps1
.NOTES
    Requires RSAT ActiveDirectory module. Validates domain reachability via
    Get-ADRootDSE before searching. Exports a timestamped backup CSV to the
    desktop before making any changes.
#>

[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Define domains
$domains = @(
   @{ Name = "cloud.lcl";         DC = "cloud.lcl" },
   @{ Name = "aws.cloud.lcl";     DC = "aws.cloud.lcl" },
   @{ Name = "aspgov.pri";        DC = "aspgov.pri" },
   @{ Name = "centroid.cloud.lcl"; DC = "centroid.cloud.lcl" }
)

function Search-Users {
    param (
        [string]$searchInput,
        [string]$filterLabel,
        [string]$filter,
        [string]$displayValue
    )

    $results = @()
    foreach ($domain in $domains) {
        try {
            $searchBase = (Get-ADRootDSE -Server $domain.DC).defaultNamingContext
            $users = Get-ADUser -Filter $filter -Server $domain.DC -SearchBase $searchBase -Properties *

            foreach ($user in $users) {
                $groupList = @()
                try {
                    $groupDNs = (Get-ADUser $user.DistinguishedName -Server $domain.DC -Properties MemberOf).MemberOf
                    foreach ($groupDN in $groupDNs) {
                        $groupName = ($groupDN -split ',')[0] -replace '^CN='
                        $groupList += $groupName
                    }
                } catch {
                    $groupList = @("N/A")
                }

                $canonical = "Unavailable"
                try {
                    $adObject = Get-ADObject -Identity $user.DistinguishedName -Server $domain.DC -Properties CanonicalName
                    $canonical = $adObject.CanonicalName
                } catch {
                    $canonical = "Error"
                }

                $record = [PSCustomObject]@{
                    "Full Name"        = $user.Name
                    "User ID"          = $user.SamAccountName
                    "Email"            = $user.EmailAddress
                    "Domain"           = $domain.Name
                    "Enabled"          = $user.Enabled
                    "Created On"       = $user.whenCreated
                    "Last Modified On" = $user.whenChanged
                    "Groups"           = ($groupList -join '; ')
                    "Canonical Name"   = $canonical
                    "DN"               = $user.DistinguishedName
                    "Server"           = $domain.DC
                }

                $results += $record
            }
        } catch {
            Write-Warning "Search failed in $($domain.Name): $_"
        }
    }

    if ($results.Count -gt 0) {
        Write-Host "`nFound $($results.Count) user(s) using $filterLabel. ($displayValue)" -ForegroundColor Green
        $i = 1
        foreach ($user in $results) {
            Write-Host "$i. $($user.'Full Name') | $($user.'User ID') | $($user.Email) | Enabled: $($user.Enabled) | Domain: $($user.Domain)"
            $i++
        }
        $choice = Read-Host "`nDo you want to select from these results? (Y/N)"
        if ($choice -match '^[Yy]$') {
            return $results
        }
    } else {
        Write-Host "`nNo users found using $filterLabel. ($displayValue)" -ForegroundColor Yellow
    }

    return @()
}

do {
    $searchInput = Read-Host "Enter name, email, or user ID to search for"
    $matchedUsers = @()

    if ($searchInput -like "*@*") {
        $matchedUsers = Search-Users -searchInput $searchInput -filterLabel "Email" -filter "(EmailAddress -like '*$searchInput*')" -displayValue $searchInput
    } else {
        $parts = $searchInput -split '\s+'
        $firstName = $parts[0]
        $lastName = if ($parts.Count -gt 1) { $parts[-1] } else { $null }

        if ($matchedUsers.Count -eq 0) {
            $matchedUsers = Search-Users -searchInput $searchInput -filterLabel "Full Name" -filter "(Name -like '*$searchInput*')" -displayValue $searchInput
        }
        if ($matchedUsers.Count -eq 0 -and $lastName) {
            $matchedUsers = Search-Users -searchInput $lastName -filterLabel "Last Name" -filter "(Surname -like '*$lastName*')" -displayValue $lastName
        }
        if ($matchedUsers.Count -eq 0) {
            $matchedUsers = Search-Users -searchInput $searchInput -filterLabel "User ID" -filter "(SamAccountName -like '*$searchInput*')" -displayValue $searchInput
        }
        if ($matchedUsers.Count -eq 0 -and $firstName) {
            $matchedUsers = Search-Users -searchInput $firstName -filterLabel "First Name" -filter "(GivenName -like '*$firstName*')" -displayValue $firstName
        }
        if ($matchedUsers.Count -eq 0) {
            $matchedUsers = Search-Users -searchInput $searchInput -filterLabel "Fallback (All Fields)" -filter "((SamAccountName -like '*$searchInput*') -or (EmailAddress -like '*$searchInput*') -or (Name -like '*$searchInput*') -or (GivenName -like '*$searchInput*') -or (Surname -like '*$searchInput*'))" -displayValue $searchInput
        }
    }

    if ($matchedUsers.Count -eq 0) {
        Write-Host "`nNo matching users found. Please try again." -ForegroundColor Red
    }

} while ($matchedUsers.Count -eq 0)

# Prompt for selection
$indexedUsers = @{}
$i = 1
foreach ($user in $matchedUsers) {
    $indexedUsers["$i"] = $user
    $i++
}

$selection = Read-Host "`nEnter the numbers of the users you want to disable/update (comma-separated like 1,2)"
$selectedIndexes = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }

if ($selectedIndexes.Count -gt 0) {
    $ticketNumber = Read-Host "Enter the ticket or case number (e.g., ENG-012345)"
    $sreInitials = Read-Host "Enter your SRE initials (e.g., SKK)"
    $currentDate = Get-Date -Format "MM/dd/yyyy"
    $description = "Disabled $currentDate, $ticketNumber, -$sreInitials"

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $safeSearch = ($searchInput -replace '[\\/:*?"<>|]', '_')
    $outputFile = Join-Path $desktopPath "User_Backup_${safeSearch}_$timestamp.csv"

    $selectedUsers = @()
    foreach ($index in $selectedIndexes) {
        if ($indexedUsers.ContainsKey($index)) {
            $selectedUsers += $indexedUsers[$index]
        }
    }

    $selectedUsers | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
    Write-Host "`nExported $($selectedUsers.Count) selected user(s) to:`n$outputFile" -ForegroundColor Cyan

    foreach ($user in $selectedUsers) {
        try {
            if ($PSCmdlet.ShouldProcess("$($user.'Full Name') ($($user.Domain))", 'Set Description')) {
                Set-ADUser -Identity $user.DN -Server $user.Server -Description $description -ErrorAction Stop
            }

            if ($user.Enabled -eq $true) {
                if ($PSCmdlet.ShouldProcess("$($user.'Full Name') ($($user.Domain))", 'Disable Account')) {
                    Set-ADUser -Identity $user.DN -Server $user.Server -Enabled $false -ErrorAction Stop
                    Write-Host "Disabled user: $($user.'Full Name') in $($user.Domain) and added description." -ForegroundColor Green
                }
            } else {
                Write-Host "User already disabled: $($user.'Full Name') in $($user.Domain). Description updated." -ForegroundColor Yellow
            }

            if ($user.Domain -eq "centroid.cloud.lcl") {
                $targetOU = "OU=_Deprecated,OU=Users,OU=Cloud,DC=centroid,DC=cloud,DC=lcl"
                try {
                    if ($PSCmdlet.ShouldProcess("$($user.'Full Name')", 'Move to _Deprecated OU')) {
                        Move-ADObject -Identity $user.DN -TargetPath $targetOU -Server $user.Server -ErrorAction Stop
                        Write-Host "Moved user to _Deprecated OU in centroid.cloud.lcl." -ForegroundColor Cyan
                    }
                } catch {
                    Write-Warning "Failed to move user to _Deprecated OU: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-Warning "Failed to update user $($user.'Full Name') in $($user.Domain): $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "No valid selections made. No users updated." -ForegroundColor Yellow
}
