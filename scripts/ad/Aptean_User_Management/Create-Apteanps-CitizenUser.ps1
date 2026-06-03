<#
Creates a new AD user (Default or Clone) under apteanps.local/OU - Citizens/<Org-...>,
enforces password policy, sets ProfilePath & HomeFolder, shows domain-wide duplicate matches,
and prints two copy-paste blocks:
  1) Email to end user (formal wording)
  2) Ticket to Cloud team for centroid.cloud.lcl (MFA) with CSV header + one data line

Validation flow:
- Full Name: trimmed, inner spaces collapsed, TitleCase; must be unique (R/X).
- sAMAccountName: trimmed; must be unique (R/X).
- Email: trimmed, lowercased; can proceed even if duplicate (Y/R/X).
#>

Import-Module ActiveDirectory -ErrorAction Stop

# ---------- Fixed domain/OU helpers ----------
function Get-BaseOuDn  { "OU=OU - Citizens,DC=apteanps,DC=local" }
function Get-DomainDn  { "DC=apteanps,DC=local" }
function Get-DomainUpnSuffix { "apteanps.local" }

function Resolve-OrgOu {
    param([Parameter(Mandatory)][string]$OrgOuName)
    $base = Get-BaseOuDn
    $ou = Get-ADOrganizationalUnit -LDAPFilter "(ou=$OrgOuName)" -SearchBase $base -SearchScope OneLevel -ErrorAction SilentlyContinue
    if ($ou) { return $ou.DistinguishedName }
    return $null
}

# Org-Amherstburg -> Amherstburg (case-insensitive)
function Get-CityFromOrg {
    param([Parameter(Mandatory)][string]$OrgOuName)
    ($OrgOuName -replace '(?i)^Org-','')
}

# ---------- Normalization helpers ----------
function Normalize-Trim {
    param([string]$s)
    if ($null -eq $s) { return "" }
    $s.Trim()
}

function Normalize-InnerSpaces {
    param([string]$s)
    if ($null -eq $s) { return "" }
    ($s -replace '\s+',' ').Trim()
}

function Normalize-FullName {
    param([string]$s)
    $clean = Normalize-InnerSpaces $s
    $ti = (Get-Culture).TextInfo
    $ti.ToTitleCase($clean.ToLower())
}

function Normalize-Sam {
    param([string]$s)
    Normalize-Trim $s  # keep caller's casing; just trim
}

function Normalize-Email {
    param([string]$s)
    (Normalize-Trim $s).ToLower()
}

# ---------- Password policy ----------
$Global:PwUpper   = [char[]]"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
$Global:PwLower   = [char[]]"abcdefghijklmnopqrstuvwxyz"
$Global:PwDigits  = [char[]]"0123456789"
$Global:PwSpecial = [char[]]"!@#$%^&*()-_=+[]{}|;:,.<>?/"

$Global:RestrictedPasswords = @(
    "Password123!", "Welcome2025!", "Welcome2024!", "Admin123!", "Qwerty123!",
    "Aptean123!", "ChangeMe123!"
)

function Test-PasswordCompliance {
    param([Parameter(Mandatory)][string]$Password, [string]$Username = "")
    if ($Password.Length -lt 12) { return $false }
    if ($Password -notmatch '[A-Z]') { return $false }
    if ($Password -notmatch '[a-z]') { return $false }
    if ($Password -notmatch '\d')    { return $false }
    if ($Password -notmatch '[^a-zA-Z0-9]') { return $false }
    if ($Username -and $Username.Length -ge 5) {
        $u = $Username.ToLower(); $p = $Password.ToLower()
        for ($i=0; $i -le ($u.Length-5); $i++) { if ($p.Contains($u.Substring($i,5))) { return $false } }
    }
    if ($Global:RestrictedPasswords -contains $Password) { return $false }
    $true
}

function New-RandomPassword {
    param([string]$Username = "")
    for ($attempt = 1; $attempt -le 500; $attempt++) {
        $pwdChars = @()
        $pwdChars += Get-Random -Count 1 -InputObject $Global:PwUpper
        $pwdChars += Get-Random -Count 1 -InputObject $Global:PwLower
        $pwdChars += Get-Random -Count 1 -InputObject $Global:PwDigits
        $pwdChars += Get-Random -Count 1 -InputObject $Global:PwSpecial
        $targetLen = Get-Random -Minimum 12 -Maximum 17
        $all = $Global:PwUpper + $Global:PwLower + $Global:PwDigits + $Global:PwSpecial
        $remaining = $targetLen - $pwdChars.Count
        if ($remaining -gt 0) { $pwdChars += Get-Random -Count $remaining -InputObject $all }
        $pwd = ($pwdChars | Sort-Object { Get-Random }) -join ''
        if (Test-PasswordCompliance -Password $pwd -Username $Username) { return $pwd }
    }
    throw "Failed to generate a compliant password after multiple attempts."
}

# ---------- Utility helpers ----------
function Get-FirstActiveUserInOu {
    param([string]$OuDn)
    Get-ADUser -Filter 'Enabled -eq $true' -SearchBase $OuDn -SearchScope Subtree `
        -Properties displayName,mail,samAccountName,ProfilePath,HomeDirectory,HomeDrive,memberOf |
        Sort-Object displayName | Select-Object -First 1
}

function Split-FullName {
    param([Parameter(Mandatory)][string]$FullName)
    $parts = $FullName.Trim() -split '\s+'
    [PSCustomObject]@{ GivenName = $parts[0]; Surname = if ($parts.Count -gt 1) { $parts[-1] } else { "" } }
}

# swap last path segment to the new sAM; or build from default root if template is empty
function Build-RebasedPath {
    param([string]$TemplatePath, [Parameter(Mandatory)][string]$NewSam, [string]$DefaultRoot)
    if ([string]::IsNullOrWhiteSpace($TemplatePath)) { return "$DefaultRoot\$NewSam" }
    $parts = $TemplatePath.TrimEnd('\') -split '\\'
    if ($parts.Length -ge 1) { $parts[$parts.Length-1] = $NewSam; return ($parts -join '\') }
    "$DefaultRoot\$NewSam"
}

# ---------- Duplicate search helpers ----------
function Get-CanonicalOuPath {
    param($User)
    $cn = $User.CanonicalName
    if ($cn) { return ($cn -replace '/[^/]+$','') }  # canonical path w/out CN
    return ($User.DistinguishedName -replace '^CN=.*?,','')  # fallback
}

# SAFE LDAP escaping
function Escape-LdapValue {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '\'       { [void]$sb.Append('\5c') }
            '*'       { [void]$sb.Append('\2a') }
            '('       { [void]$sb.Append('\28') }
            ')'       { [void]$sb.Append('\29') }
            ([char]0) { [void]$sb.Append('\00') }
            default   { [void]$sb.Append($ch) }
        }
    }
    $sb.ToString()
}

function Find-UsersByFullNameExact {
    param([Parameter(Mandatory)][string]$FullName)
    $v = Escape-LdapValue $FullName
    $ldap = "(|(displayName=$v)(name=$v)(cn=$v))"
    Get-ADUser -LDAPFilter $ldap -SearchBase (Get-DomainDn) -SearchScope Subtree `
        -Properties mail,samAccountName,Name,CanonicalName -ErrorAction SilentlyContinue
}

function Find-UsersBySamExact {
    param([Parameter(Mandatory)][string]$Sam)
    $v = Escape-LdapValue $Sam
    Get-ADUser -LDAPFilter "(sAMAccountName=$v)" -SearchBase (Get-DomainDn) -SearchScope Subtree `
        -Properties mail,samAccountName,Name,CanonicalName -ErrorAction SilentlyContinue
}

function Find-UsersByEmailExact {
    param([Parameter(Mandatory)][string]$Email)
    $v = Escape-LdapValue $Email
    Get-ADUser -LDAPFilter "(mail=$v)" -SearchBase (Get-DomainDn) -SearchScope Subtree `
        -Properties mail,samAccountName,Name,CanonicalName -ErrorAction SilentlyContinue
}

function Print-UserRows {
    param([array]$Users, [string]$HeaderMessage, [ConsoleColor]$HeaderColor = [ConsoleColor]::Yellow)
    if (-not $Users -or $Users.Count -eq 0) { return }
    if ($HeaderMessage) { Write-Host "`n$HeaderMessage" -ForegroundColor $HeaderColor }
    foreach ($u in $Users) {
        $ouPath = Get-CanonicalOuPath $u
        "$($u.Name) | sAM: $($u.SamAccountName) | mail: $($u.Mail) | OU: $ouPath"
    }
    Write-Host ""
}

# ---------- Show template user + groups ----------
function Show-TemplateUserInfo {
    param($User)
    if ($User -isnot [Microsoft.ActiveDirectory.Management.ADUser]) {
        try {
            $User = Get-ADUser -Identity $User -Properties mail,displayName,memberOf,samAccountName,Name,ProfilePath,HomeDirectory,HomeDrive
        } catch { Write-Warning "Could not resolve template user to an ADUser object."; return }
    } else {
        $User = Get-ADUser -Identity $User.DistinguishedName -Properties mail,displayName,memberOf,samAccountName,Name,ProfilePath,HomeDirectory,HomeDrive
    }

    $groupNames = @()
    if ($User.memberOf) {
        $groupNames = foreach ($dn in $User.memberOf) { try { (Get-ADGroup -Identity $dn -ErrorAction Stop).Name } catch { $null } }
        $groupNames = $groupNames | Where-Object { $_ } | Sort-Object -Unique
    }

    Write-Host ""
    Write-Host "Template user details:" -ForegroundColor Cyan
    Write-Host ("  Name : {0}" -f $User.Name)
    Write-Host ("  UserID (sAMAccountName): {0}" -f $User.SamAccountName)
    Write-Host ("  Email: {0}" -f $User.Mail)
    Write-Host ("  ProfilePath : {0}" -f $User.ProfilePath)
    Write-Host ("  HomeDrive   : {0}" -f $User.HomeDrive)
    Write-Host ("  HomeDir     : {0}" -f $User.HomeDirectory)
    Write-Host "  Permissions (group memberships):"
    if ($groupNames.Count -eq 0) { Write-Host "    (none)" } else { $groupNames | ForEach-Object { Write-Host "    $_" } }
    Write-Host ""
}

function Copy-GroupsFromTemplate {
    param($Template, [string]$NewSam)
    if ($Template -isnot [Microsoft.ActiveDirectory.Management.ADUser]) {
        $Template = Get-ADUser -Identity $Template -Properties memberOf -ErrorAction SilentlyContinue
    } else {
        $Template = Get-ADUser -Identity $Template.DistinguishedName -Properties memberOf
    }
    if (-not $Template -or -not $Template.memberOf) { return }
    $exclude = @('Domain Users')
    foreach ($dn in $Template.memberOf) {
        try {
            $g = Get-ADGroup -Identity $dn -ErrorAction Stop
            if ($exclude -notcontains $g.Name) {
                Add-ADGroupMember -Identity $g.DistinguishedName -Members $NewSam -ErrorAction Stop
                Write-Host "  Added to group: $($g.Name)"
            }
        } catch {
            Write-Warning "  Could not add to group from DN '$dn': $($_.Exception.Message)"
        }
    }
}

# ---------- Output summary ----------
function Show-Result {
    param([Parameter(Mandatory)]$Result)
    Write-Host ""
    Write-Host "=== USER CREATED ===" -ForegroundColor Green
    "{0,-16}: {1}" -f "Full Name",     $Result.FullName
    "{0,-16}: {1}" -f "UserID",        $Result.Sam
    "{0,-16}: {1}" -f "Temp Password", $Result.Password
    "{0,-16}: {1}" -f "Email",         $Result.Email
    "{0,-16}: {1}" -f "ProfilePath",   $Result.ProfilePath
    "{0,-16}: {1}" -f "HomeDrive",     $Result.HomeDrive
    "{0,-16}: {1}" -f "HomeDirectory", $Result.HomeDirectory
    "{0,-16}: {1}" -f "OU",            $Result.OU
    "{0,-16}: {1}" -f "UPN",           $Result.UPN
    Write-Host "====================`n"

    # --- End-user email template (formal) ---
    Write-Host "----- Email to end user (copy below) -----" -ForegroundColor Yellow
@"
Hello $($Result.FullName),

Your network account has been created.

Username (domain\user): apteanps\$($Result.Sam)
Temporary password: $($Result.Password)

Next Steps (Action Required):

1. Go to the password portal: https://accountportal.centralsquarecloud.com
2. Use the attached document to reset your password and register for RDP MFA.

Note: Please use your email address to reset your password and keep the default option in the dropdown, which is Centralsquare - Manage Credentials.

If you need assistance, please reply to this email or contact the Service Desk.

Thank you,
IT Support
"@ | Write-Output
    Write-Host "---------------------------------------------`n"

    # --- Cloud-team ticket (CSV-friendly) ---
    # Prints a short intro, then a CSV header row, then the single CSV data row
    Write-Host "----- Ticket to Cloud team (copy below) -----" -ForegroundColor Yellow
@"
Hello Cloud Team,

Please create the following user in centroid.cloud.lcl for MFA support.

userdetails:
User name, UserID, User email, OU
$($Result.FullName), $($Result.Sam), $($Result.Email), OU where the user is created: $($Result.OU)
"@ | Write-Output
    Write-Host "---------------------------------------------`n"

    <#
    # (Optional) Pure CSV line only for quick copy/paste into other automation:
    Write-Host "----- CSV (single line) -----" -ForegroundColor Yellow
    "$($Result.FullName), $($Result.Sam), $($Result.Email), OU where the user is created: $($Result.OU)"
    Write-Host "--------------------------------" -ForegroundColor Yellow
    #>
}

# ---------- Create user (splatting; robust) ----------
function Create-NewAdUser {
    param(
        [Parameter(Mandatory)][string]$OuDn,
        [Parameter(Mandatory)][string]$FullName,
        [Parameter(Mandatory)][string]$SamAccountName,
        [Parameter(Mandatory)][string]$Email,
        [string]$TemplateProfilePath,
        [string]$TemplateHomeDrive,
        [string]$TemplateHomeDirectory,
        [Parameter(Mandatory)][string]$OrgOuName
    )

    # Strong sAM re-check (race safety)
    $samHits = Find-UsersBySamExact -Sam $SamAccountName
    if ($samHits) {
        Print-UserRows -Users $samHits -HeaderMessage "sAMAccountName '$SamAccountName' is no longer available. Matching account(s):" -HeaderColor Red
        throw "SAM_EXISTS"
    }

    $nameParts = Split-FullName -FullName $FullName
    $upn = "$SamAccountName@$(Get-DomainUpnSuffix)"

    $city = Get-CityFromOrg -OrgOuName $OrgOuName
    $defaultProfileRoot = "\\PAPTPSFS01\UserProfiles$\$city"
    $defaultHomeRoot    = "\\PAPTPSFS01\ZDrives$\$city"

    $profilePath = Build-RebasedPath -TemplatePath $TemplateProfilePath -NewSam $SamAccountName -DefaultRoot $defaultProfileRoot
    $homeDrive   = if ($TemplateHomeDrive) { $TemplateHomeDrive } else { 'Z:' }
    $homeDir     = Build-RebasedPath -TemplatePath $TemplateHomeDirectory -NewSam $SamAccountName -DefaultRoot $defaultHomeRoot

    $pwdPlain = New-RandomPassword -Username $SamAccountName
    $pwd = ConvertTo-SecureString $pwdPlain -AsPlainText -Force

    Write-Host ""
    Write-Host "Creating user '$FullName' in OU '$OuDn' ..." -ForegroundColor Green

    $params = @{
        Name                  = $FullName
        DisplayName           = $FullName
        GivenName             = $nameParts.GivenName
        Surname               = $nameParts.Surname
        SamAccountName        = $SamAccountName
        UserPrincipalName     = $upn
        EmailAddress          = $Email
        Enabled               = $false
        ChangePasswordAtLogon = $true
        Path                  = $OuDn
        AccountPassword       = $pwd
        ProfilePath           = $profilePath
        HomeDrive             = $homeDrive
        HomeDirectory         = $homeDir
    }

    New-ADUser @params | Out-Null
    Enable-ADAccount -Identity $SamAccountName

    [PSCustomObject]@{
        FullName      = $FullName
        Sam           = $SamAccountName
        Email         = $Email
        UPN           = $upn
        Password      = $pwdPlain
        OU            = $OuDn
        ProfilePath   = $profilePath
        HomeDrive     = $homeDrive
        HomeDirectory = $homeDir
    }
}

# ---------- Main ----------
try {
    Write-Host "Create AD User - Default (D) or Clone (C)" -ForegroundColor Yellow

    # Mode loop
    do {
        $mode = (Read-Host "Choose mode [D/C]").Trim().ToUpper()
        if ($mode -in @('D','C')) { break }
        Write-Host "Invalid selection. Please enter 'D' for Default or 'C' for Clone." -ForegroundColor Red
    } while ($true)

    # OU loop
    do {
        $orgOuName = Read-Host "Enter Org OU name (e.g., Org-Amherstburg)"
        if ([string]::IsNullOrWhiteSpace($orgOuName)) {
            Write-Host "OU name cannot be empty." -ForegroundColor Red
            continue
        }
        $targetOuDn = Resolve-OrgOu -OrgOuName $orgOuName
        if ($targetOuDn) { break }
        Write-Host "OU '$orgOuName' is not present under apteanps.local/OU - Citizens. Please check and enter again." -ForegroundColor Red
    } while ($true)

    # Choose reference/template user for defaults (Default mode shows first active in OU)
    $templateUser = $null
    if ($mode -eq 'D') {
        $templateUser = Get-FirstActiveUserInOu -OuDn $targetOuDn
        if ($templateUser) { Show-TemplateUserInfo -User $templateUser } else { Write-Host "`n(No active users in this OU for reference.)`n" -ForegroundColor DarkYellow }
    } else {
        # Clone: refined search loop
        $term = Read-Host "Enter name/email/UserID to find the template user"
        if ([string]::IsNullOrWhiteSpace($term)) { throw "Search term is required." }

        while (-not $templateUser) {
            $raw = Get-ADUser -Filter "samAccountName -like '*$term*' -or Name -like '*$term*' -or mail -like '*$term*'" `
                   -Properties mail,displayName,memberOf,samAccountName,Name,ProfilePath,HomeDirectory,HomeDrive
            $matches = @($raw)

            if (-not $matches -or $matches.Count -eq 0) {
                Write-Host "`nNo matches for '$term'." -ForegroundColor DarkYellow
                $term = Read-Host "Enter a new search term (or Ctrl+C to abort)"
                continue
            }

            if ($matches.Count -eq 1) { $templateUser = $matches[0]; break }

            Write-Host "`nMultiple users found:" -ForegroundColor Cyan
            for ($i=0; $i -lt $matches.Count; $i++) {
                $m = $matches[$i]
                "{0,2}) {1}  |  sAM: {2}  |  mail: {3}" -f $i, $m.Name, $m.SamAccountName, $m.Mail
            }

            $action = (Read-Host "Found $($matches.Count) users. [S]elect from list or [R]efine search?").Trim().ToUpper()
            if ($action -eq 'R') { $term = Read-Host "Enter a new search term"; continue }
            elseif ($action -eq 'S') {
                $idx = Read-Host "Enter the index of the template user to clone"
                if ($idx -match '^\d+$' -and [int]$idx -ge 0 -and [int]$idx -lt $matches.Count) { $templateUser = $matches[[int]$idx] }
                else { Write-Host "Invalid index. Try again." -ForegroundColor Red }
            } else { Write-Host "Please enter 'S' or 'R'." -ForegroundColor Red }
        }
        Show-TemplateUserInfo -User $templateUser
    }

    # ---------- FIELD-BY-FIELD DATA ENTRY (with normalization) ----------

    # 1) Full Name (trim + collapse spaces + TitleCase; must be unique)
    do {
        $fullNameInput = Read-Host "New user's Full Name"
        $fullName = Normalize-FullName $fullNameInput
        $nameHits = Find-UsersByFullNameExact -FullName $fullName
        if ($nameHits) {
            Print-UserRows -Users $nameHits -HeaderMessage "A user with this Full Name already exists:" -HeaderColor Red
            $choice = (Read-Host "Full Name must be unique. [R]e-enter or [X] cancel?").Trim().ToUpper()
            if     ($choice -eq 'R') { continue }
            elseif ($choice -eq 'X') { throw "Cancelled by user." }
            else  { Write-Host "Please enter 'R' or 'X'." -ForegroundColor Red }
        } else { break }
    } while ($true)

    # 2) sAMAccountName (trim only; must be unique)
    do {
        $samInput = Read-Host "New user's User ID (sAMAccountName)"
        $sam = Normalize-Sam $samInput
        $samHits = Find-UsersBySamExact -Sam $sam
        if ($samHits) {
            Print-UserRows -Users $samHits -HeaderMessage "This User ID is already in use:" -HeaderColor Red
            $choice = (Read-Host "User ID must be unique. [R]e-enter or [X] cancel?").Trim().ToUpper()
            if     ($choice -eq 'R') { continue }
            elseif ($choice -eq 'X') { throw "Cancelled by user." }
            else  { Write-Host "Please enter 'R' or 'X'." -ForegroundColor Red }
        } else { break }
    } while ($true)

    # 3) Email (trim + lowercase; may proceed even if duplicate)
    do {
        $emailInput = Read-Host "New user's Email address"
        $email = Normalize-Email $emailInput

        if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Write-Host "Email format looks invalid: '$email'" -ForegroundColor Red
            $ans = (Read-Host "Continue anyway? [Y]es to continue, [R]e-enter, [X] cancel").Trim().ToUpper()
            if     ($ans -eq 'R') { continue }
            elseif ($ans -eq 'X') { throw "Cancelled by user." }
        }
        $mailHits = Find-UsersByEmailExact -Email $email
        if ($mailHits) {
            Print-UserRows -Users $mailHits -HeaderMessage "Another account already uses this email:" -HeaderColor Yellow
            $ans = (Read-Host "Proceed with this email anyway? [Y]es, [R]e-enter, [X] cancel").Trim().ToUpper()
            if     ($ans -eq 'R') { continue }
            elseif ($ans -eq 'X') { throw "Cancelled by user." }
            elseif ($ans -ne 'Y') { Write-Host "Please enter Y, R, or X." -ForegroundColor Red; continue }
        }
        break
    } while ($true)

    # ---------- Confirm and create ----------
    Write-Host ""
    if ($mode -eq 'D') {
        Write-Host "About to create:" -ForegroundColor Yellow
    } else {
        Write-Host "About to create (cloning group memberships from '$($templateUser.SamAccountName)'):" -ForegroundColor Yellow
    }
    Write-Host ("  Full Name: {0}" -f $fullName)
    Write-Host ("  User ID  : {0}" -f $sam)
    Write-Host ("  Email    : {0}" -f $email)
    Write-Host ("  OU       : {0}" -f $targetOuDn)
    if ((Read-Host "Proceed? [Y/N]").Trim().ToUpper() -ne 'Y') { throw "Cancelled by user." }

    $result = Create-NewAdUser -OuDn $targetOuDn -FullName $fullName -SamAccountName $sam -Email $email `
              -TemplateProfilePath $templateUser.ProfilePath -TemplateHomeDrive $templateUser.HomeDrive `
              -TemplateHomeDirectory $templateUser.HomeDirectory -OrgOuName $orgOuName

    if ($mode -eq 'C') {
        Write-Host "Copying group memberships..." -ForegroundColor Cyan
        Copy-GroupsFromTemplate -Template $templateUser -NewSam $sam
    }

    Show-Result -Result $result

} catch {
    if ($_.Exception.Message -eq 'SAM_EXISTS') {
        Write-Host "Please choose a different User ID (sAMAccountName) and run again." -ForegroundColor Red
    } else {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}
