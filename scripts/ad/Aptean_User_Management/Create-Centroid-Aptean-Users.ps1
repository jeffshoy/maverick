#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Bulk-create Centroid/Aptean users in apteanps.local from a ticket-format input line.
.DESCRIPTION
    Parses a comma-separated ticket line (FullName, sAMAccountName, email, org) and
    creates or recreates an AD user in apteanps.local under the appropriate org OU.
    Enforces password policy, sets ProfilePath and HomeFolder, logs duplicate matches,
    and prints copy-paste email/ticket blocks on success.
.PARAMETER line
    Optional ticket input line. If omitted, the script prompts interactively.
.PARAMETER mappingcsv
    Path to Org_OUs_with_Company.csv. Defaults to .\Org_OUs_with_Company.csv.
.PARAMETER creds
    Optional PSCredential. Uses current Kerberos logon if omitted.
.EXAMPLE
    .\Create-Centroid-Aptean-Users.ps1
    .\Create-Centroid-Aptean-Users.ps1 -line "John Doe,jdoe,jdoe@example.com,ACME"
.NOTES
    Requires RSAT ActiveDirectory module. Run from the Aptean_User_Management folder
    so relative CSV paths resolve correctly.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$line,                                       # if omitted, you'll be prompted (trimmed)
  [string]$mappingcsv = ".\Org_OUs_with_Company.csv",  # mapping CSV in same folder
  [pscredential]$creds = $null                         # optional; otherwise current logon/Kerberos
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory -ErrorAction Stop

# ---------- constants: always target centroid.cloud.lcl ----------
$TargetDomainFqdn = 'centroid.cloud.lcl'
$BaseDN           = 'DC=centroid,DC=cloud,DC=lcl'
$CustomersDN      = "OU=Customers,$BaseDN"

# ---------- colors ----------
function Info ($m){ Write-Host $m -ForegroundColor Cyan }
function Ok   ($m){ Write-Host $m -ForegroundColor Green }
function Warn ($m){ Write-Host $m -ForegroundColor Yellow }
function Err  ($m){ Write-Host $m -ForegroundColor Red }
function Fail ($m){ Err $m; throw $m }

# ---------- AD server wrapper ----------
function Invoke-AD { param([scriptblock]$Block)
  if ($creds) { & $Block -creds $creds } else { & $Block }
}

# ---------- parse the one-line ticket ----------
function Parse-TicketLine {
  param([Parameter(Mandatory)][string]$s)
  $s = $s.Trim()
  $parts = $s -split ',', 4
  if ($parts.Count -lt 4) { Fail "Input line not in expected format (need 4 comma-separated segments)." }

  $fullName = $parts[0].Trim()
  $sam      = $parts[1].Trim()
  $email    = $parts[2].Trim()
  $fourth   = $parts[3].Trim()

  $dn = $fourth
  if     ($fourth -match 'OU where the user is created\s*:\s*(.+)$') { $dn = $Matches[1].Trim() }
  elseif ($fourth -match 'OU where the user is created\s*-\s*(.+)$') { $dn = $Matches[1].Trim() }

  $orgName = $null
  if ($dn -match '(?i)OU=(?<org>[^,]+),\s*OU=OU\s*-\s*Citizens,DC=apteanps,DC=local') { $orgName = $Matches['org'] }

  [PSCustomObject]@{
    FullName = $fullName
    Sam      = $sam
    Email    = $email
    ApteanOU = $dn
    OrgName  = $orgName
  }
}

# ---------- normalize Company -> folder name (letters only, ALL CAPS) ----------
function Normalize-CompanyToFolder {
  param([string]$company)
  ($company -replace '[^A-Za-z]','').ToUpper()
}

# ---------- ensure the 3 OUs EXIST (no creation); return $true/$false and say what’s missing ----------
function Test-CustomerTreeExists {
  param([Parameter(Mandatory)][string]$CompanyFolder)

  $dnCompany   = "OU=$CompanyFolder,$CustomersDN"
  $dnUsers     = "OU=Users,OU=$CompanyFolder,$CustomersDN"

  $exists = {
    param($dn, $creds)
    try {
      if ($creds) { Get-ADOrganizationalUnit -Identity $dn -Server $TargetDomainFqdn -Credential $creds -ErrorAction Stop | Out-Null }
      else        { Get-ADOrganizationalUnit -Identity $dn -Server $TargetDomainFqdn                       -ErrorAction Stop | Out-Null }
      $true
    } catch { $false }
  }

  # Check Customers first (it *is* an OU)
  if (-not (& $exists $CustomersDN $creds)) { Err "Customers OU missing: $CustomersDN"; return $false }
  if (-not (& $exists $dnCompany   $creds)) { Err "Company OU missing:   $dnCompany";   return $false }
  if (-not (& $exists $dnUsers     $creds)) { Err "Users OU missing:     $dnUsers";     return $false }
  return $true
}

# ---------- split full name to given/surname ----------
function Split-FullName {
  param([string]$FullName)
  $p = $FullName.Trim() -split '\s+'
  [PSCustomObject]@{
    GivenName = if ($p.Count -gt 0) { $p[0] } else { "" }
    Surname   = if ($p.Count -gt 1) { $p[-1] } else { "" }
  }
}

# Get OU portion from a DN (strip leading CN=...,)
function Get-OuFromDn {
  param([string]$dn)
  if ($dn -match '^CN=.*?,(.+)$') { return $Matches[1] }
  return $dn
}

# ---------- sAM policy: prefix c_; if >20, trim to 19 and try 1..9,0 as 20th char; ensure unique (in centroid) ----------
function Get-PolicySam {
  param([Parameter(Mandatory)][string]$RawSam)

  $base = $RawSam -replace '^(?i)c_',''
  $base = $base -replace '[^A-Za-z0-9._-]', ''
  $candidate = "c_" + $base

  $find = {
    param($sam, $creds)
    if ($creds) { Get-ADUser -Filter "samAccountName -eq '$sam'" -Server $TargetDomainFqdn -Credential $creds -ErrorAction SilentlyContinue }
    else        { Get-ADUser -Filter "samAccountName -eq '$sam'" -Server $TargetDomainFqdn                       -ErrorAction SilentlyContinue }
  }

  if ($candidate.Length -le 20 -and -not (& $find $candidate $creds)) { return $candidate }

  $trim19 = $candidate.Substring(0, [Math]::Min(19, $candidate.Length))
  foreach ($d in '1','2','3','4','5','6','7','8','9','0') {
    $try = $trim19 + $d
    if (-not (& $find $try $creds)) { return $try }
  }
  Fail "Could not allocate a 20th-digit suffix for '$RawSam' under policy."
}

# ---------- simple strong password ----------
function New-StrongPassword {
  for ($i=0; $i -lt 200; $i++) {
    $upper = -join ((65..90)  | Get-Random -Count 2 | ForEach-Object {[char]$_})
    $lower = -join ((97..122) | Get-Random -Count 4 | ForEach-Object {[char]$_})
    $digits= -join ((48..57)  | Get-Random -Count 2 | ForEach-Object {[char]$_})
    $specs = -join ('!@#$%^&*()-_=+[]{}|;:,.<>?/' | Get-Random -Count 2)
    $extra = -join ((33..126) | Get-Random -Count (Get-Random -Minimum 2 -Maximum 6) | ForEach-Object {[char]$_})
    $pwd   = -join ($upper+$lower+$digits+$specs+$extra | Sort-Object {Get-Random})
    if ($pwd.Length -ge 12 -and $pwd -match '[A-Z]' -and $pwd -match '[a-z]' -and $pwd -match '\d' -and $pwd -match '[^A-Za-z0-9]') { return $pwd }
  }
  Fail "Could not generate password."
}

# ---------- print a user summary card in a given color (used for duplicates) ----------
function Show-UserCard {
  param(
    [Parameter(Mandatory)]$User,
    [string]$Color = 'DarkYellow'   # "orange-ish"
  )
  $ou = Get-OuFromDn $User.DistinguishedName
  Write-Host ""
  Write-Host "=== EXISTING USER (EMAIL MATCH) ===" -ForegroundColor $Color
  Write-Host ("Full Name     : {0}" -f $User.Name)               -ForegroundColor $Color
  Write-Host ("UserID (sAM)  : {0}" -f $User.SamAccountName)     -ForegroundColor $Color
  Write-Host ("Email         : {0}" -f $User.Mail)               -ForegroundColor $Color
  Write-Host ("ADSSP Login   : {0}" -f $User.OfficePhone)        -ForegroundColor $Color
  Write-Host ("UPN           : {0}" -f $User.UserPrincipalName)  -ForegroundColor $Color
  Write-Host ("OU            : {0}" -f $ou)                      -ForegroundColor $Color
  Write-Host ("Enabled       : {0}" -f $(if ($User.Enabled) {'True'} else {'False'})) -ForegroundColor $Color
  Write-Host ""
}

# ---------- main ----------
try {
  # Make sure we can see centroid from the current box
  try {
    if ($creds) { Get-ADDomain -Server $TargetDomainFqdn -Credential $creds | Out-Null }
    else        { Get-ADDomain -Server $TargetDomainFqdn               | Out-Null }
    Ok "Connected to $TargetDomainFqdn"
  } catch {
    Fail "Cannot reach $TargetDomainFqdn from this machine: $($_.Exception.Message)"
  }

  if (-not (Test-Path $mappingcsv)) { Fail "Mapping CSV not found at '$mappingcsv'." }
  $map = Import-Csv -Path $mappingcsv
  if (-not $map -or $map.Count -eq 0) { Fail "Mapping CSV is empty." }

  if (-not $line) {
    Info "Paste the line from your ticket (it will be trimmed):"
    $line = (Read-Host "Line").Trim()
  }

  Info "Parsing input..."
  $parsed = Parse-TicketLine -s $line

  # Resolve company from mapping: DN first, then Org name (strict, then fuzzy)
  $row = $map | Where-Object { $_.DistinguishedName -ieq $parsed.ApteanOU }
  if (-not $row -and $parsed.OrgName) {
    $row = $map | Where-Object { $_.Name -ieq $parsed.OrgName }
    if (-not $row) { $row = $map | Where-Object { $_.Name -like "*$($parsed.OrgName)*" } }
  }
  if (-not $row) { Fail "No mapping found for DN='$($parsed.ApteanOU)' or Org='$($parsed.OrgName)'." }

  $company = $row.Company
  if (-not $company) { Fail "Mapping row found but 'Company' is blank for Org '$($row.Name)'." }

  $companyFolder = Normalize-CompanyToFolder $company
  if (-not $companyFolder) { Fail "Company '$company' normalized to empty; cannot build OU path." }

  $targetUsersOU = "OU=Users,OU=$companyFolder,$CustomersDN"

  Info "Checking target OU in centroid..."
  if (-not (Test-CustomerTreeExists -CompanyFolder $companyFolder)) {
    Err  "OU does not exist in centroid.cloud.lcl."
    Warn "Looked for: $targetUsersOU"
    return
  }

  # Prep attributes
  $names   = Split-FullName -FullName $parsed.FullName
  $sam     = Get-PolicySam -RawSam $parsed.Sam
  $upn     = "$sam@$TargetDomainFqdn"
  $email   = $parsed.Email
  $adssplogin = $email
  $pwdPlain  = New-StrongPassword
  $pwd       = ConvertTo-SecureString -AsPlainText $pwdPlain -Force

  # ===== Duplicates (in centroid) =====

  # sAM must be unique: fail immediately if taken
  $samHit = if ($creds) { Get-ADUser -Filter "samAccountName -eq '$sam'" -Server $TargetDomainFqdn -Credential $creds -ErrorAction SilentlyContinue }
            else        { Get-ADUser -Filter "samAccountName -eq '$sam'" -Server $TargetDomainFqdn                       -ErrorAction SilentlyContinue }
  if ($samHit) { Fail "samAccountName '$sam' already exists in centroid." }

  # --- New: duplicate EMAIL inspection (show details in orange and confirm) ---
  $emailHits = if ($creds) { Get-ADUser -Filter "mail -eq '$email'" -Server $TargetDomainFqdn -Credential $creds -Properties mail,samAccountName,Name,DistinguishedName,UserPrincipalName,OfficePhone,Enabled -ErrorAction SilentlyContinue }
               else        { Get-ADUser -Filter "mail -eq '$email'" -Server $TargetDomainFqdn                       -Properties mail,samAccountName,Name,DistinguishedName,UserPrincipalName,OfficePhone,Enabled -ErrorAction SilentlyContinue }

  if ($emailHits) {
    Warn "Duplicate email detected in centroid for '$email'. Displaying matches..."
    foreach ($hit in @($emailHits)) { Show-UserCard -User $hit -Color 'DarkYellow' }
    $ans = (Read-Host "Proceed with creating a NEW user with the same email? [Y]es / [N]o").Trim().ToUpper()
    if ($ans -ne 'Y') { Fail "Aborted by operator due to duplicate email conflict." }
  }

  # ADSSP login (OfficePhone) duplicate: warn only
  $adsspHits = if ($adssplogin) {
    if ($creds) { Get-ADUser -Filter "officePhone -eq '$adssplogin'" -Server $TargetDomainFqdn -Credential $creds -ErrorAction SilentlyContinue }
    else        { Get-ADUser -Filter "officePhone -eq '$adssplogin'" -Server $TargetDomainFqdn                       -ErrorAction SilentlyContinue }
  }
  if ($adsspHits) { Warn "Warning: ADSSP login (officePhone) '$adssplogin' already exists in centroid." }

  # ===== Create user =====
  $newUserParams = @{
    Server            = $TargetDomainFqdn
    Path              = $targetUsersOU
    SamAccountName    = $sam
    UserPrincipalName = $upn
    GivenName         = $names.GivenName
    Surname           = $names.Surname
    DisplayName       = $parsed.FullName
    Name              = $parsed.FullName
    Enabled           = $true
    AccountPassword   = $pwd
    EmailAddress      = $email
    OfficePhone       = $adssplogin   # ADSSP login same as email
  }
  if ($creds) { $newUserParams['Credential'] = $creds }

  if ($WhatIf) {
    Warn "WHATIF: New-ADUser would run with:"
    $newUserParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
      Write-Host ("  {0,-18}: {1}" -f $_.Key, $_.Value)
    }
    return
  }

  New-ADUser @newUserParams

  Ok "`n=== USER CREATED IN CENTROID ==="
  Write-Host ("Full Name     : {0}" -f $parsed.FullName)
  Write-Host ("UserID (sAM)  : {0}" -f $sam)
  Write-Host ("Email         : {0}" -f $email)
  Write-Host ("ADSSP Login   : {0}" -f $adssplogin)
  Write-Host ("UPN           : {0}" -f $upn)
  Write-Host ("OU            : {0}" -f $targetUsersOU)
  Write-Host ("Temp Password : {0}" -f $pwdPlain)
  Write-Host ""

} catch {
  Err $_.Exception.Message
  exit 1
}
