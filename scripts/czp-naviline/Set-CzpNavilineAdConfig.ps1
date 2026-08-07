#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Applies Active Directory OU placement and group memberships for a new CZP NaviLine client server.
.DESCRIPTION
    Performs the AD portion of NaviLine CZP client provisioning:
      - Moves the computer object to aspgov.pri/C2G
      - Adds the computer object to WSUS_PROD_2AM_GROUP and Apply_Schannel_TLS1_2_Enabled

    All steps are idempotent - re-running is safe if the computer is already in the
    correct OU or already a member of a group.

    This script is designed to be run on an aspgov.pri domain controller via SSM Run
    Command, invoked by the /czp-naviline-provision Claude skill. SSM Run Command itself
    executes as SYSTEM, which lacks the delegated AD rights needed here - so every AD
    cmdlet is passed -Credential explicitly for ASPGOV\svc-czp-navi-prov, the same way
    the domain-join step already authenticates. No PSSession/WinRM loopback needed.
.PARAMETER ComputerName
    Hostname of the CZP NaviLine server (e.g. AUGU-PC2GWB001). Must already be domain-joined.
.PARAMETER Credential
    Credential for ASPGOV\svc-czp-navi-prov, used on every AD cmdlet call.
.PARAMETER WhatIf
    Dry-run - shows what would be done without making any changes.
.EXAMPLE
    .\Set-CzpNavilineAdConfig.ps1 -ComputerName AUGU-PC2GWB001 -Credential $cred
.NOTES
    Author: CloudOps SRE
    Runs on: aspgov.pri domain controller via SSM Run Command
    Service account: ASPGOV\svc-czp-navi-prov
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ComputerName,

    [Parameter(Mandatory)]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DomainServer = 'aspgov.pri'
$TargetOu     = 'OU=C2G,DC=aspgov,DC=pri'
$RequiredGroups = @(
    'WSUS_PROD_2AM_GROUP'
    'Apply_Schannel_TLS1_2_Enabled'
)

# -- Step 1: Move computer object ---------------------------------------------
Write-Host "=== Step 1: Move Computer Object ===" -ForegroundColor Cyan

$comp = Get-ADComputer -Filter "Name -eq '$ComputerName'" -Server $DomainServer -Credential $Credential -ErrorAction SilentlyContinue
if (-not $comp) {
    throw "Computer '$ComputerName' not found in aspgov.pri. Confirm domain join completed before running AD config."
}

if ($comp.DistinguishedName -like "*$TargetOu") {
    Write-Host "  '$ComputerName' already in $TargetOu." -ForegroundColor Yellow
} else {
    if ($PSCmdlet.ShouldProcess($ComputerName, "Move to $TargetOu")) {
        Move-ADObject -Identity $comp.DistinguishedName -TargetPath $TargetOu -Server $DomainServer -Credential $Credential
        Write-Host "  Moved '$ComputerName' to $TargetOu" -ForegroundColor Green
    }
}

# -- Step 2: Apply group memberships -------------------------------------------
Write-Host "`n=== Step 2: Apply Group Memberships ===" -ForegroundColor Cyan

$comp = Get-ADComputer -Filter "Name -eq '$ComputerName'" -Server $DomainServer -Credential $Credential -ErrorAction Stop
foreach ($grpName in $RequiredGroups) {
    $adGrp = Get-ADGroup -Filter "Name -eq '$grpName'" -Server $DomainServer -Credential $Credential -ErrorAction SilentlyContinue
    if (-not $adGrp) {
        Write-Warning "  Group '$grpName' not found - skipping."
        continue
    }
    $members = Get-ADGroupMember -Identity $adGrp -Server $DomainServer -Credential $Credential -ErrorAction SilentlyContinue
    if ($members | Where-Object { $_.SamAccountName -eq "$ComputerName`$" }) {
        Write-Host "  '$ComputerName' already in '$grpName'." -ForegroundColor Yellow
    } else {
        if ($PSCmdlet.ShouldProcess($ComputerName, "Add to group '$grpName'")) {
            Add-ADGroupMember -Identity $adGrp -Members $comp -Server $DomainServer -Credential $Credential
            Write-Host "  Added '$ComputerName' to '$grpName'" -ForegroundColor Green
        }
    }
}

# -- Summary --------------------------------------------------------------------
Write-Host "`n=== Complete ===" -ForegroundColor Green
Write-Host "  Computer:  $ComputerName" -ForegroundColor White
Write-Host "  OU:        $TargetOu" -ForegroundColor White
Write-Host "  Groups:    $($RequiredGroups -join ', ')" -ForegroundColor White
