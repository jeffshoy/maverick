#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Provision a new FE/Centroid client user in Active Directory.
.DESCRIPTION
    Supports SINGLE and BULK (CSV) mode. In SINGLE mode, prompts for user details
    and creates one account. In BULK mode, reads a CSV of users and creates each,
    logging successes and failures to separate CSV files on the desktop.

    Generates a random password meeting the domain policy, sets the Description,
    Department, Company, and OU fields from client mappings, and prints a copy-paste
    email template on success.
.PARAMETER None
    All inputs are collected interactively. Bulk mode reads from a user-selected CSV.
.EXAMPLE
    .\FE_User_Creation_Client_Centroid.ps1
.NOTES
    Requires RSAT ActiveDirectory module. clientMappings.csv must be in the same
    directory as this script. bulkUserExample.csv shows the expected column format.
#>

[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

# Mapping of client codes to Centroid customer OUs
$data = import-csv .\clientMappings.csv
$clientMappings = @{}

foreach ($row in $data) {
    $clientMappings[$row.Code] = $row.ClientName
}

function Write-Color {
    param (
        [string]$Message,
        [ValidateSet("Green","Red","Yellow","White")][string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Update-ClientMappingsCsv{
    param (
        [string]$Path = ".\clientMappings.csv"
    )
    #convert hashtable to array, sort, and save as csv
    $clientMappings.GetEnumerator() | 
        Sort-Object Key | 
        ForEach-Object {
            [PSCustomObject]@{
                Code        = $_.Key
                ClientName  = $_.Value
            }
        } | Export-Csv -Path $Path -NoTypeInformation
}

function Generate-RandomPassword {
    param ([int]$length = 12)
    $upper   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
    $lower   = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $digits  = '0123456789'.ToCharArray()
    $special = '!@#$%^&*()-_=+[]{};:,.<>?'.ToCharArray()
    $all     = $upper + $lower + $digits + $special
    do {
        $chars = @()
        $chars += Get-Random -InputObject $upper -Count 1
        $chars += Get-Random -InputObject $lower -Count 1
        $chars += Get-Random -InputObject $digits -Count 1
        $chars += Get-Random -InputObject $special -Count 1
        $chars += 1..($length - 4) | ForEach-Object { Get-Random -InputObject $all }
        $password = -join $chars
    } while (-not (Test-PasswordPolicy -Password $password -Username ""))
    return $password
}

function Test-PasswordPolicy {
    param ([string]$Password, [string]$Username)
    if ($Password.Length -lt 12) { return $false }
    if ($Password -notmatch '[A-Z]') { return $false }
    if ($Password -notmatch '[a-z]') { return $false }
    if ($Password -notmatch '\d')    { return $false }
    if ($Password -notmatch '[!@#\$%\^&\*\(\)\-_\+=\[\]\{\};:,.<>?]') { return $false }
    if ($Username -and ($Password -match [regex]::Escape($Username.Substring(0, [Math]::Min(5, $Username.Length))))) {
        return $false
    }
    return $true
}

function Create-User {
    param (
        [string]$Domain, [string]$OU, [string]$Name, [string]$Username,
        [string]$Email, [securestring]$Password, [string]$UPN, [string]$Telephone
    )
    try {
        $nameParts = $Name -split ' '
        $givenName = $nameParts[0]
        $surname = $nameParts[-1]
        $middleName = if ($nameParts.Length -gt 2) { ($nameParts[1..($nameParts.Length - 2)] -join ' ') } else { "" }
        $attrs = @{}
        if ($Telephone) { $attrs.telephoneNumber = $Telephone }
        if ($middleName -ne "") { $attrs.middleName = $middleName }

        Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$OU)" -Server $Domain -ErrorAction Stop | Out-Null

       $params = @{
         Server = $Domain
         Name = $Name
         DisplayName = $Name
         SamAccountName = $Username
         UserPrincipalName = $UPN
         EmailAddress = $Email
         AccountPassword = $Password
         Enabled = $true
         GivenName = $givenName
         Surname = $surname
         Path = $OU
         }

        if ($attrs.Count -gt 0) {
            $params.OtherAttributes = $attrs
        }

        New-ADUser @params
        Write-Color "User $Username created in $Domain" -Color Green
        return $true
    } catch {
        Write-Color "Failed to create user '${Username}' in ${Domain}: ${_}" -Color Red
        return $false
    }
}

#----------------------Emial generator for single user---------------------
function Generate-EmailTemplate {
    param (
        [string]$FullName,
        [string]$Username,
        [string]$ClientCode,
        [string]$Password
    )

    $clientCodeCld = "$($ClientCode.ToLower())cld"
    $firstName = $FullName.Split(" ")[0]
    $accountId = "$clientCodeCld\$Username"
    $selfServiceURL = "https://accountportal.centralsquarecloud.com"
    $citrixURL = "https://oneportal.$clientCodeCld.aspgov.com"
    $dateStr = Get-Date -Format "yyyyMMdd"
    $fileName = "$env:USERPROFILE\Desktop\$Username" + "_$ClientCode" + "_$dateStr.txt"

    $content = @"
Hello $firstName,

A new $clientCodeCld domain account has been created for you.

Account ID: $accountId
Password: $Password

Please reset your password using the Self-Service Portal:
$selfServiceURL

Once your local Finance Enterprise administrator grants you access, you'll be able to log into and use the application.

To access the Citrix portal:
$citrixURL
"@

    $content | Out-File -FilePath $fileName -Encoding UTF8
    Write-Color "Email template saved to: $fileName" -Color Green

    Write-Host "`n========== Email Preview ==========" -ForegroundColor Cyan
    Write-Host $content
    Write-Host "===================================`n" -ForegroundColor Cyan
}



function Select-CSVFile {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "CSV files (*.csv)|*.csv"
    if ($dialog.ShowDialog() -eq "OK") {
        return $dialog.FileName
    } else {
        return $null
    }
}

function Show-Duplicates {
    param (
        [string]$Label,
        $Grouped,
        [string]$Color
    )
    Write-Color "Duplicate ${Label}(s) detected. Fix the values listed below in your CSV:" -Color Red
    foreach ($dup in $Grouped) {
        Write-Color "  ${Label}: $($dup.Name) appears $($dup.Count) times." -Color $Color
        Write-Host "  → Entries with this ${Label}:"
        $dup.Group | Format-Table Name, Email, UserID -AutoSize
        Write-Host ""
    }
}

# Select single or Bulk users 
$mode = Read-Host "Enter 'S' for single user or 'B' for bulk user creation"

# --------------------- SINGLE MODE START ---------------------
if ($mode -eq 'S') {
    $clientCode = Read-Host "Enter client code (e.g. CAS)"
    $clientDomain = "$clientCode.cloud.lcl"
    $centroidDomain = "centroid.cloud.lcl"

    try {
        Get-ADDomain -Server $clientDomain | Out-Null
        Write-Color "Connection to $clientDomain successful." -Color Green
    } catch {
        Write-Color "Failed to connect to $clientDomain. Please verify domain access or client code." -Color Red
        return
    }

    if (-not $clientMappings.ContainsKey($clientCode)) {
        Write-Color "No OU mapping found for client code '$clientCode'." -Color Red
        $addMapping = Read-Host "Do you want to add a new mapping for this client code now? (Y/N)"
        if ($addMapping -eq 'Y') {
            $newOU = Read-Host "Enter the full OU value to map for client code '$clientCode' (e.g. SANANGELOTX)"
            if ($newOU -ne "") {
                $clientMappings[$clientCode.toUpper()] = $newOU
                Write-Color "Mapping added for $clientCode => $newOU" -Color Green
                Update-ClientMappingsCsv
            } else {
                Write-Color "No OU entered. Cannot continue." -Color Red
                return
            }
        } else {
            Write-Color "Process cancelled due to missing client mapping." -Color Red
            return
        }
    }

    $permOption = Read-Host "Do you want to create user with default permissions (D), or assign manually (P), or clone another user's permissions (C)?"

    $groupsToAdd = @()
    $clonedFrom = ""
    if ($permOption -eq 'C') {
        $cloneSearch = Read-Host "Enter full or partial username or name to search"
        $cloneCandidates = Get-ADUser -Server $clientDomain -LDAPFilter "(|(SamAccountName=*$cloneSearch*)(Name=*$cloneSearch*)(GivenName=*$cloneSearch*)(Surname=*$cloneSearch*)(EmailAddress=*$cloneSearch*))" -Properties SamAccountName, Name, EmailAddress, MemberOf | Select-Object Name, SamAccountName, EmailAddress, MemberOf

        if (-not $cloneCandidates) {
            Write-Color "No matching users found." -Color Red
            $fallback = Read-Host "Do you want to continue with default permissions (D) or assign manually (P)?"
            if ($fallback -eq 'D') { $permOption = 'D' }
            elseif ($fallback -eq 'P') { $permOption = 'P' }
        } else {
            $index = 1
            $userMap = @{}
            foreach ($u in $cloneCandidates) {
                Write-Host "`n[$index] Name: $($u.Name), Username: $($u.SamAccountName), Email: $($u.EmailAddress)"
                if ($u.MemberOf) {
                    Write-Host "   Groups:"
                    foreach ($groupDN in $u.MemberOf) {
                        try {
                            $groupName = (Get-ADGroup -Identity $groupDN -Server $clientDomain).Name
                            Write-Host "    - $groupName"
                        } catch {
                            Write-Host "    - $groupDN (unresolved)"
                        }
                    }
                } else {
                    Write-Host "   Groups: None"
                }
                $userMap[$index] = $u
                $index++
            }

            $sel = Read-Host "`n Enter the number of the user you want to clone permissions from"
            if ($userMap.ContainsKey([int]$sel)) {
                $cloneUser = $userMap[[int]$sel]
                $clonedFrom = $cloneUser.SamAccountName
                $cloneGroups = @()
                foreach ($groupDN in $cloneUser.MemberOf) {
                    try {
                        $groupName = (Get-ADGroup -Identity $groupDN -Server $clientDomain).SamAccountName
                        $cloneGroups += $groupName
                    } catch {}
                }

                $cloneConfirm = Read-Host "Do you want to clone group memberships from this user? (Y/N)"
                if ($cloneConfirm -eq 'Y' -and $cloneGroups.Count -gt 0) {
                    $groupsToAdd = $cloneGroups
                }
            }
        }
    }

   if ($permOption -eq 'P') {
    $groupsToAdd = @()
    $again = 'Y'

    do {
        $searchTerm = Read-Host "Enter search keyword to filter AD groups (e.g. 'prod', 'test', 'SPSOne')"
        $matchedGroups = Get-ADGroup -Filter "Name -like '*$searchTerm*'" -Server $clientDomain |
                         Sort-Object Name |
                         Select-Object Name, SamAccountName

        if (-not $matchedGroups) {
            Write-Color "No groups found matching '$searchTerm'" -Color Red
            do {
                $again = Read-Host "Do you want to search again? (Y/N)"
                if ($again.ToUpper() -notin @('Y', 'N')) {
                    Write-Color "Please enter only 'Y' or 'N'." -Color Yellow
                }
            } while ($again.ToUpper() -notin @('Y', 'N'))
            continue
        }

        Write-Host "`nMatching Groups for '$searchTerm':" -ForegroundColor Cyan
        $groupMap = @{}
        $i = 1
        foreach ($g in $matchedGroups) {
            $groupMap[$i] = $g.SamAccountName
            $color = if ($i % 2 -eq 0) { "Gray" } else { "White" }
            Write-Host ("[{0}] {1}" -f $i, $g.SamAccountName) -ForegroundColor $color
            $i++
        }

        # Prompt for selection
        do {
            $selection = Read-Host "`nEnter group numbers to assign (e.g. 1,3,5) or type 'R' to search again"
            if ($selection.Trim().ToUpper() -eq 'R') {
                $indexes = @()
                break
            }

            $indexes = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
            if ($indexes.Count -eq 0) {
                Write-Color "Invalid input. Enter comma-separated numbers or 'R' to retry." -Color Yellow
            }
        } while ($indexes.Count -eq 0)

        foreach ($ix in $indexes) {
            if ($groupMap.ContainsKey([int]$ix)) {
                $groupsToAdd += $groupMap[[int]$ix]
            }
        }

        do {
            $again = Read-Host "Do you want to search and add more groups? (Y/N)"
            if ($again.ToUpper() -notin @('Y', 'N')) {
                Write-Color "Please enter only 'Y' or 'N'." -Color Yellow
            }
        } while ($again.ToUpper() -notin @('Y', 'N'))

    } while ($again -eq 'Y')

    $groupsToAdd = $groupsToAdd | Select-Object -Unique
}





    $name = (Read-Host "Enter full name").Trim()
    $username = (Read-Host "Enter user ID").Trim().ToLower()
    $email = (Read-Host "Enter email address").Trim().ToLower()


    if (-not $name -or -not $email -or -not $username) {
        Write-Color "All fields are required (Name, Email, UserID)." -Color Red
        return
    }

    $clientOU = "OU=Users,OU=$clientCode,DC=$clientCode,DC=cloud,DC=lcl"
    $centroidOU = "OU=Users,OU=$($clientMappings[$clientCode]),OU=Customers,DC=centroid,DC=cloud,DC=lcl"
    $centroidUsername = "c_$username"
    if ($centroidUsername.Length -gt 20) {
    $centroidUsername = $centroidUsername.Substring(0, 19) + "1"
    Write-Color "Centroid username trimmed and suffixed: $centroidUsername" -Color Yellow
    }

    $passMode = Read-Host "Press Enter to auto-generate password or type 'manual'"
    if ($passMode -eq 'manual') {
        $passwordPlain = Read-Host "Enter password (will be hidden)"
        $securePassword = ConvertTo-SecureString $passwordPlain -AsPlainText -Force
    } else {
        $passwordPlain = Generate-RandomPassword
        $securePassword = ConvertTo-SecureString $passwordPlain -AsPlainText -Force
        Write-Color "Generated Password: $passwordPlain" -Color Yellow
    }

    $clientStatus = $false
    try {
        $existingUser = Get-ADUser -Server $clientDomain -Filter {SamAccountName -eq $username}
        if ($existingUser) {
            Write-Color "User '$username' already exists in $clientDomain." -Color Yellow
            $opt = Read-Host "User already exists. Type 'R' to recreate or 'S' to skip"
            if ($opt -eq 'R') {
                Remove-ADUser -Server $clientDomain -Identity $existingUser -Confirm:$false
                Write-Color "Deleted user '$username' in $clientDomain." -Color Yellow
            } else {
                Write-Color "Skipped creation in client domain." -Color Yellow
                $clientStatus = $true
            }
        }

        if (-not $clientStatus) {
        $clientStatus = Create-User -Domain $clientDomain -OU $clientOU -Name $name -Username $username -Email $email -Password $securePassword -UPN "$username@$clientDomain" -Telephone ""
        }

        # Stop if client creation failed
        if (-not $clientStatus) {
            Write-Color "Skipping centroid creation because client domain user creation failed." -Color Red
            return
        }

        if ($groupsToAdd -and $groupsToAdd.Count -gt 0) {
            foreach ($grp in $groupsToAdd) {
                try {
                    Add-ADGroupMember -Server $clientDomain -Identity $grp -Members $username
                    Write-Color "Added $username to $grp" -Color Green
                } catch {
                    $errMsg = $_.Exception.Message
                    Write-Color "Something went wrong: $errMsg" -Color Yellow
                }
            }
            if ($clonedFrom -ne "") {
                Write-Color "User '$username' successfully cloned permissions from '$clonedFrom'." -Color Green
            }
        }

    } catch {
        Write-Color "Failed during client domain user check or creation: $_" -Color Red
    }

    $centroidStatus = $false
    try {
        $existingCentroid = Get-ADUser -Server $centroidDomain -Filter {SamAccountName -eq $centroidUsername}
        if ($existingCentroid) {
            Write-Color "User '$centroidUsername' already exists in $centroidDomain." -Color Yellow
            $opt2 = Read-Host "User already exists. Type 'R' to recreate or 'S' to skip"
            if ($opt2 -eq 'R') {
                Remove-ADUser -Server $centroidDomain -Identity $existingCentroid -Confirm:$false
                Write-Color "Deleted user '$centroidUsername' in $centroidDomain." -Color Yellow
            } else {
                Write-Color "Skipped creation in centroid domain." -Color Yellow
                $centroidStatus = $true
            }
        }

        if (-not $centroidStatus) {
            Create-User -Domain $centroidDomain -OU $centroidOU -Name $name -Username $centroidUsername -Email $email -Password $securePassword -UPN "$centroidUsername@$centroidDomain" -Telephone $email
        }
    } catch {
        Write-Color "Failed during centroid domain user check or creation: $_" -Color Red
    }

    Generate-EmailTemplate -FullName $name -Username $username -ClientCode $clientCode -Password $passwordPlain
}





# --------------------- BULK MODE START ---------------------
#$mode = Read-Host "Enter 'S' for single user or 'B' for bulk user creation"
if ($mode -eq 'B') {
    $filePath = Select-CSVFile
    if (-not $filePath) {
        Write-Color "No file selected." -Color Red
        return
    }

    $entries = Import-Csv $filePath | Where-Object { $_.Name -or $_.Email -or $_.UserID } | ForEach-Object {
       $cleanName = ($_.Name -split '\s+' | ForEach-Object {
    if ($_.Length -ge 2) {
        $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
    } elseif ($_.Length -eq 1) {
        $_.ToUpper()
    } else {
        ""
    }
} | Where-Object { $_ -ne "" }) -join ' '

        [PSCustomObject]@{
            Name   = $cleanName.Trim()
            Email  = if ($_.Email) { $_.Email.Trim().ToLower() } else { "" }
            UserID = if ($_.UserID) { $_.UserID.Trim().ToLower() } else { "" }
        }
    }

    # Validate for missing required fields
    $blankEntries = $entries | Where-Object { !$_.Name -or !$_.Email -or !$_.UserID }
    if ($blankEntries.Count -gt 0) {
        Write-Color "Found rows with missing Name, Email, or UserID. Please fix the CSV and try again." -Color Red
        $blankEntries | Format-Table
        return
    }

    $duplicateFound = $false
    $criticalDupFound = $false

   $dupEmails = $entries `
| Where-Object { $_.Email -ne $null -and $_.Email -ne "" } `
| Group-Object -Property Email `
| Where-Object Count -gt 1


if ($dupEmails) {
    Show-Duplicates -Label "Email" -Grouped $dupEmails -Color Yellow
    $response = Read-Host "Duplicate emails found. Do you want to proceed? (Y/N)"
    if ($response -ne 'Y') {
        Write-Color "Process cancelled due to email duplication." -Color Red
        return
    }
}


    $dupUserIDs = $entries | Group-Object UserID | Where-Object Count -gt 1
    if ($dupUserIDs) {
        Show-Duplicates -Label "UserID" -Grouped $dupUserIDs -Color Yellow
        $criticalDupFound = $true
    }

    $dupNames = $entries | Group-Object Name | Where-Object Count -gt 1
    if ($dupNames) {
        Show-Duplicates -Label "Name" -Grouped $dupNames -Color Yellow
        $criticalDupFound = $true
    }

    if ($criticalDupFound) {
        Write-Color "`n Duplicate UserID or Name found. Please fix the following entries in your CSV before continuing:`n" -Color Red
        if ($dupUserIDs) { Show-Duplicates -Label "UserID" -Grouped $dupUserIDs -Color Yellow }
        if ($dupNames) { Show-Duplicates -Label "Name" -Grouped $dupNames -Color Yellow }
        return
    }

    # Prompt for client code once
    $clientCode = Read-Host "Enter client code to apply to all users"
    $clientDomain = "$clientCode.cloud.lcl"

    try {
        Get-ADDomain -Server $clientDomain | Out-Null
        Write-Color "Connection to $clientDomain successful." -Color Green
    } catch {
        Write-Color "Failed to connect to $clientDomain. Please verify domain access or client code." -Color Red
        return
    }

    if (-not $clientMappings.ContainsKey($clientCode)) {
        Write-Color "No OU mapping found for client code '$clientCode'." -Color Red
        $addMapping = Read-Host "Do you want to add a new mapping for this client code now? (Y/N)"
        if ($addMapping -eq 'Y') {
            $newOU = Read-Host "Enter the full OU value to map for client code '$clientCode' (e.g. SANANGELOTX)"
            if ($newOU -ne "") {
                $clientMappings[$clientCode] = $newOU
                Write-Color "Mapping added for $clientCode => $newOU" -Color Green
            } else {
                Write-Color "No OU entered. Cannot continue." -Color Red
                return
            }
        } else {
            Write-Color "Process cancelled due to missing client mapping." -Color Red
            return
        }
    }

    $centroidDomain = "centroid.cloud.lcl"
    $clientOU = "OU=Users,OU=$clientCode,DC=$clientCode,DC=cloud,DC=lcl"
    $centroidOU = "OU=Users,OU=$($clientMappings[$clientCode]),OU=Customers,DC=centroid,DC=cloud,DC=lcl"

    $createdUsers = @()
   $successLog = @()
$failLog = @()

foreach ($entry in $entries) {
    $name = $entry.Name
    $email = $entry.Email
    $username = $entry.UserID
    $status = ""
    $password = Generate-RandomPassword
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force

    $recreateClient = $false
    $recreateCentroid = $false
    $userExistedClient = $false
    $userExistedCentroid = $false

    # -------- Check and optionally delete existing user in client domain --------
    try {
        $existingUser = Get-ADUser -Server $clientDomain -Filter {SamAccountName -eq $username} -Properties EmailAddress, Enabled, MemberOf
        if ($existingUser) {
            $userExistedClient = $true
            Write-Color "User '$username' already exists in $clientDomain." -Color Yellow
            Write-Host "Name     : $($existingUser.Name)"
            Write-Host "Email    : $($existingUser.EmailAddress)"
            Write-Host "Status   : $(if ($existingUser.Enabled) { 'Enabled' } else { 'Disabled' })"
            Write-Host "Groups   :"
            if ($existingUser.MemberOf -and $existingUser.MemberOf.Count -gt 0) {
                $existingUser.MemberOf | ForEach-Object {
                    try {
                        $group = Get-ADGroup -Identity $_ -Server $clientDomain -Properties Name
                        Write-Host "    - $($group.Name)"
                    } catch {
                        Write-Host "    - $_ (Could not resolve group)"
                    }
                }
            } else {
                Write-Host "    - None"
            }

            $opt = Read-Host "`nUser already exists in $clientDomain. R to recreate, S to skip"
            if ($opt -eq 'R') {
                Remove-ADUser -Server $clientDomain -Identity $existingUser -Confirm:$false
                Write-Color "Deleted user '$username' in $clientDomain." -Color Yellow
                $recreateClient = $true
            } else {
                $successLog += [PSCustomObject]@{
                    Name        = $name
                    Email       = $email
                    UserID      = $username
                    Status      = "Skipped (User existed in client domain)"
                    ActionTaken = "No changes made"
                }
                continue
            }
        } else {
            $recreateClient = $true
        }
    } catch {
        Write-Color "Client domain lookup failed: $_" -Color Red
        $failLog += [PSCustomObject]@{
            Name        = $name
            Email       = $email
            UserID      = $username
            Status      = "Failed (Client AD lookup)"
            ActionTaken = "Lookup failed in client domain"
        }
        continue
    }

    # -------- Create user in client domain --------
    if ($recreateClient) {
        $created = Create-User -Domain $clientDomain -OU $clientOU -Name $name -Username $username `
            -Email $email -Password $securePassword -UPN "$username@$clientDomain" -Telephone ""
        if (-not $created) {
            $failLog += [PSCustomObject]@{
                Name        = $name
                Email       = $email
                UserID      = $username
                Status      = "Failed (Client creation)"
                ActionTaken = "User creation failed in client domain"
            }
            continue
        }
    }

    # -------- Check and optionally delete existing user in centroid domain --------
    $centroidUsername = "c_$username"
    if ($centroidUsername.Length -gt 20) {
    $centroidUsername = $centroidUsername.Substring(0, 19) + "1"
    Write-Color "Centroid username trimmed and suffixed: $centroidUsername" -Color Yellow
    }

    try {
        $existingCentroid = Get-ADUser -Server $centroidDomain -Filter {SamAccountName -eq $centroidUsername} -Properties EmailAddress, Enabled, MemberOf
        if ($existingCentroid) {
            $userExistedCentroid = $true
            Write-Color "User '$centroidUsername' already exists in $centroidDomain." -Color Yellow
            Write-Host "Name     : $($existingCentroid.Name)"
            Write-Host "Email    : $($existingCentroid.EmailAddress)"
            Write-Host "Status   : $(if ($existingCentroid.Enabled) { 'Enabled' } else { 'Disabled' })"
            Write-Host "Groups   :"
            if ($existingCentroid.MemberOf -and $existingCentroid.MemberOf.Count -gt 0) {
                $existingCentroid.MemberOf | ForEach-Object {
                    try {
                        $group = Get-ADGroup -Identity $_ -Server $centroidDomain -Properties Name
                        Write-Host "    - $($group.Name)"
                    } catch {
                        Write-Host "    - $_ (Could not resolve group)"
                    }
                }
            } else {
                Write-Host "    - None"
            }

            $opt2 = Read-Host "`nUser already exists in $centroidDomain. R to recreate, S to skip"
            if ($opt2 -eq 'R') {
                Remove-ADUser -Server $centroidDomain -Identity $existingCentroid -Confirm:$false
                Write-Color "Deleted user '$centroidUsername' in $centroidDomain." -Color Yellow
                $recreateCentroid = $true
            } else {
                $successLog += [PSCustomObject]@{
                    Name        = $name
                    Email       = $email
                    UserID      = $centroidUsername
                    Status      = "Skipped (User existed in centroid domain)"
                    ActionTaken = "No changes made"
                }
                continue
            }
        } else {
            $recreateCentroid = $true
        }
    } catch {
        Write-Color "Centroid domain lookup failed: $_" -Color Red
        $failLog += [PSCustomObject]@{
            Name        = $name
            Email       = $email
            UserID      = $centroidUsername
            Status      = "Failed (Centroid creation)"
            ActionTaken = "User creation failed in centroid domain"
        }
        continue
    }

    # -------- Create user in centroid domain --------
    if ($recreateCentroid) {
        $created2 = Create-User -Domain $centroidDomain -OU $centroidOU -Name $name -Username $centroidUsername `
            -Email $email -Password $securePassword -UPN "$centroidUsername@$centroidDomain" -Telephone $email

        if ($created2) {
            $successLog += [PSCustomObject]@{
                Name        = $name
                Email       = $email
                UserID      = "$username / $centroidUsername"
                Status      = if ($userExistedClient -and $userExistedCentroid) { "Recreated (Both Domains)" }
                              elseif ($userExistedCentroid) { "Recreated (Centroid)" }
                              elseif ($userExistedClient) { "Recreated (Client)" }
                              else { "Created" }
                ActionTaken = if ($userExistedClient -and $userExistedCentroid) { "User deleted and recreated in both domains" }
                              elseif ($userExistedCentroid) { "User recreated in centroid domain" }
                              elseif ($userExistedClient) { "User recreated in client domain" }
                              else { "User created in both domains" }
            }
        }
    }
}




    $dateSuffix = Get-Date -Format 'yyyyMMdd'
    $successPath = "$env:USERPROFILE\Desktop\${clientCode}_success_${dateSuffix}.csv"
    $failPath = "$env:USERPROFILE\Desktop\${clientCode}_failed_${dateSuffix}.csv"

    if ($successLog.Count -gt 0) {
        $successLog | Export-Csv -Path $successPath -NoTypeInformation
        Write-Color "Success log saved to: $successPath" -Color Green
    }
    if ($failLog.Count -gt 0) {
        $failLog | Export-Csv -Path $failPath -NoTypeInformation
        Write-Color "Failed/Skipped log saved to: $failPath" -Color Yellow
    }
    }