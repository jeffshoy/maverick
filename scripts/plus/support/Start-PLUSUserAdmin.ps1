#Requires -Version 5.1

<#
.SYNOPSIS
    Interactive menu launcher for PLUS customer user management.
.DESCRIPTION
    PowerShell TUI that prompts for inputs and dispatches to the correct
    PLUS user-management script. Replaces support\PLUS-UserAdmin.bat.
.NOTES
    Author: CloudOps SRE - CentralSquare Technologies
#>

$scriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

function Show-PLUSMenu {
    Clear-Host
    Write-Host '===========================================' -ForegroundColor DarkGray
    Write-Host '  PLUS User Admin' -ForegroundColor Cyan
    Write-Host '===========================================' -ForegroundColor DarkGray
    Write-Host '  1  Create new customer user' -ForegroundColor White
    Write-Host '  2  Re-enable a customer user' -ForegroundColor White
    Write-Host '  3  Disable (terminate) a customer user' -ForegroundColor White
    Write-Host '  4  Grant / re-grant SQL access' -ForegroundColor White
    Write-Host '  5  Check user access (read-only)' -ForegroundColor White
    Write-Host '  Q  Quit' -ForegroundColor White
    Write-Host '-------------------------------------------' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Input helpers
# ---------------------------------------------------------------------------

function Read-RequiredInput([string]$prompt) {
    do {
        $value = (Read-Host $prompt).Trim()
        if ($value -eq '') {
            Write-Host '  Input is required - please enter a value.' -ForegroundColor Yellow
        }
    } while ($value -eq '')
    return $value
}

function Read-OptionalInput([string]$prompt) {
    return (Read-Host $prompt).Trim()
}

function Read-YesNo([string]$prompt, [bool]$default = $false) {
    $defaultHint = if ($default) { '[Y/n]' } else { '[y/N]' }
    do {
        $raw = (Read-Host "$prompt $defaultHint").Trim().ToUpper()
        if ($raw -eq '')  { return $default }
        if ($raw -eq 'Y') { return $true }
        if ($raw -eq 'N') { return $false }
        Write-Host '  Please enter Y or N.' -ForegroundColor Yellow
    } while ($true)
}

function Read-ValidatedInput([string]$prompt, [scriptblock]$validator, [string]$errorMsg) {
    do {
        $value = (Read-Host $prompt).Trim()
        if (& $validator $value) { return $value }
        Write-Host "  $errorMsg" -ForegroundColor Yellow
    } while ($true)
}

# ---------------------------------------------------------------------------
# Option handlers
# ---------------------------------------------------------------------------

function Invoke-CreateUser {
    Write-Host "`n-- Create new PLUS customer user --" -ForegroundColor Cyan

    $cust      = Read-ValidatedInput `
                     -prompt    'Customer site code (3 letters, e.g. SJC)' `
                     -validator { param($v) $v -match '^[a-zA-Z]{3}$' } `
                     -errorMsg  'Must be exactly 3 letters (e.g. SJC).'

    $firstName = Read-RequiredInput 'First name'
    $mi        = Read-OptionalInput 'Middle initial (optional - press Enter to skip)'
    $lastName  = Read-RequiredInput 'Last name'

    $email     = Read-ValidatedInput `
                     -prompt    'Email address' `
                     -validator { param($v) $v -match '@' } `
                     -errorMsg  'Must be a valid email address.'

    $isDBA  = Read-YesNo 'Is this user a DBA admin? (Y/N, default N)'
    $is52   = Read-YesNo 'Override 5.2 detection? (Y/N, default N - auto-detected from customer list)'

    $params = @('-Cust', $cust, '-FirstName', $firstName, '-LastName', $lastName, '-EmailAddress', $email)
    if ($mi)     { $params += '-MiddleInitial', $mi }
    if ($isDBA)  { $params += '-IsUserDBA' }
    if ($is52)   { $params += '-Is52Customer' }

    Write-Host "`nRunning New-PLUSCustomerUser -- please wait ...`n" -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$scriptRoot\..\New-PLUSCustomerUser\New-PLUSCustomerUser.ps1" @params

    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
    $null = Read-Host
}

function Invoke-EnableUser {
    Write-Host "`n-- Re-enable a PLUS customer user --" -ForegroundColor Cyan

    $samid  = Read-RequiredInput 'aspgov.pri samAccountName (e.g. sjcjsmith)'

    $params = @('-Samid', $samid)

    Write-Host "`nRunning Enable-PLUSCustomerUser -- please wait ...`n" -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$scriptRoot\..\Enable-PLUSCustomerUser\Enable-PLUSCustomerUser.ps1" @params

    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
    $null = Read-Host
}

function Invoke-DisableUser {
    Write-Host "`n-- Disable (terminate) a PLUS customer user --" -ForegroundColor Cyan

    $samid  = Read-RequiredInput 'aspgov.pri samAccountName (e.g. sjcjsmith)'
    $caseNo = Read-RequiredInput 'Case or ticket number (e.g. 02502101)'

    $params = @('-Samid', $samid, '-CaseNo', $caseNo)

    Write-Host "`nRunning Disable-PLUSCustomerUser -- please wait ...`n" -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$scriptRoot\..\Disable-PLUSCustomerUser\Disable-PLUSCustomerUser.ps1" @params

    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
    $null = Read-Host
}

function Invoke-GrantAccess {
    Write-Host "`n-- Grant / re-grant SQL access --" -ForegroundColor Cyan

    $samid    = Read-RequiredInput 'aspgov.pri samAccountName (e.g. sjcjsmith)'
    $custCode = Read-OptionalInput 'Customer code override for internal users (press Enter to skip)'
    $isDBA    = Read-YesNo 'Grant PLUS Admin access? (Y/N, default N)'

    $params = @('-Samid', $samid)
    if ($custCode -ne '') { $params += '-CustCode', $custCode }
    if ($isDBA) { $params += '-IsUserDBA' }

    Write-Host "`nRunning Grant-PLUSUserAccess -- please wait ...`n" -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$scriptRoot\..\Grant-PLUSUserAccess\Grant-PLUSUserAccess.ps1" @params

    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
    $null = Read-Host
}

function Invoke-CheckAccess {
    Write-Host "`n-- Check user access (read-only) --" -ForegroundColor Cyan

    $samid    = Read-RequiredInput 'aspgov.pri samAccountName (e.g. sjcjsmith)'
    $custCode = Read-OptionalInput 'Customer code override for internal users (press Enter to skip)'

    $params = @('-Samid', $samid)
    if ($custCode -ne '') { $params += '-CustCode', $custCode }

    Write-Host "`nRunning Get-PLUSUserAccess -- please wait ...`n" -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$scriptRoot\..\Get-PLUSUserAccess\Get-PLUSUserAccess.ps1" @params

    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
    $null = Read-Host
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

do {
    Show-PLUSMenu
    $choice = (Read-Host 'Choice').Trim().ToUpper()
    switch ($choice) {
        '1'     { Invoke-CreateUser }
        '2'     { Invoke-EnableUser }
        '3'     { Invoke-DisableUser }
        '4'     { Invoke-GrantAccess }
        '5'     { Invoke-CheckAccess }
        'Q'     { break }
        default { Write-Host '  Invalid choice. Press Enter to try again.' -ForegroundColor Yellow; $null = Read-Host }
    }
} while ($choice -ne 'Q')
