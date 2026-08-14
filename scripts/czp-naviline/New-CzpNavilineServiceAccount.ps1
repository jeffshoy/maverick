#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    One-time setup: creates ASPGOV\svc-czp-navi-prov and delegates the AD rights
    required for unattended CZP NaviLine client provisioning.
.DESCRIPTION
    This is a prerequisite for /czp-naviline-provision and is NOT called by that skill.
    Run once, interactively, by an AD admin holding their own domain admin credentials,
    from a workstation/DC with the ActiveDirectory RSAT module and network access to
    aspgov.pri.

    Performs, all idempotent (safe to re-run):
      1. Creates the aspgov.pri/Service Accounts OU if it does not already exist
      2. Creates ASPGOV\svc-czp-navi-prov in that OU (or skips if it already exists —
         it will NOT reset an existing account's password)
      3. Delegates the standard "join a computer to the domain" rights on
         aspgov.pri/C2G — Create/Delete Computer objects, Reset Password,
         validated write to DNS host name, validated write to Service Principal Name,
         and read/write Account Restrictions — scoped to that OU and its computer
         object descendants only (not domain-wide)
      4. Delegates write access to the "Member" attribute on WSUS_PROD_2AM_GROUP and
         Apply_Schannel_TLS1_2_Enabled, scoped to those two group objects only

    This script does NOT store the generated password anywhere other than stdout at
    creation time. After running, the admin MUST manually store that password as a
    SecureString SSM Parameter at /czp-naviline/svc-czp-navi-prov in BOTH
    PALegacyCzp and PALegacySharedServices, in BOTH us-east-1 and us-west-2 — see
    runbooks/czp-naviline-automation-context.md.
.PARAMETER Credential
    Domain admin credential used to perform the AD writes. Prompted if not supplied.
.PARAMETER WhatIf
    Dry-run — shows what would be created/delegated without making any changes.
.EXAMPLE
    .\New-CzpNavilineServiceAccount.ps1 -WhatIf
.EXAMPLE
    .\New-CzpNavilineServiceAccount.ps1
.NOTES
    Author: CloudOps SRE
    Run on: a host with RSAT ActiveDirectory module and access to aspgov.pri
    This script grants AD permissions — least-privilege scoped to the OU/groups
    listed above only. It does not grant domain-wide or account-wide rights.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Credential -eq [System.Management.Automation.PSCredential]::Empty) {
    $Credential = Get-Credential -Message 'Enter domain admin credentials for aspgov.pri'
}

$DomainServer   = 'aspgov.pri'
$ServiceAcctOu  = 'OU=Service Accounts,DC=aspgov,DC=pri'
$SamAccountName = 'svc-czp-navi-prov'
$UpnSuffix      = 'aspgov.pri'
$TargetOu       = 'OU=C2G,DC=aspgov,DC=pri'
$Groups         = @('WSUS_PROD_2AM_GROUP', 'Apply_Schannel_TLS1_2_Enabled')

# Well-known AD schema GUIDs for the "join a computer to the domain" delegated task
# (the same set the Delegation of Control Wizard applies for that template).
$Guid_ComputerClass          = [Guid]'bf967a86-0de6-11d0-a285-00aa003049e2'
$Guid_ResetPassword          = [Guid]'00299570-246d-11d0-a768-00aa006e0529'
$Guid_ValidatedWriteDns      = [Guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd'
$Guid_ValidatedWriteSpn      = [Guid]'f3a64788-5306-11d1-a9c5-0000f80367c1'
$Guid_AccountRestrictionsSet = [Guid]'4c164200-20c0-11d0-a768-00aa006e0529'
$Guid_MemberAttribute        = [Guid]'bf9679c0-0de6-11d0-a285-00aa003049e2'
$Guid_Empty                  = [Guid]'00000000-0000-0000-0000-000000000000'

# ── Step 1: Ensure Service Accounts OU exists ─────────────────────────────────
Write-Host "=== Step 1: Service Accounts OU ===" -ForegroundColor Cyan

$ouExists = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ServiceAcctOu'" -Server $DomainServer -Credential $Credential -ErrorAction SilentlyContinue
if ($ouExists) {
    Write-Host "  '$ServiceAcctOu' already exists." -ForegroundColor Yellow
} else {
    if ($PSCmdlet.ShouldProcess($ServiceAcctOu, "Create OU")) {
        New-ADOrganizationalUnit -Name 'Service Accounts' -Path 'DC=aspgov,DC=pri' -Server $DomainServer -Credential $Credential -ProtectedFromAccidentalDeletion $true
        Write-Host "  Created '$ServiceAcctOu'" -ForegroundColor Green
    }
}

# ── Step 2: Create the service account ────────────────────────────────────────
Write-Host "`n=== Step 2: Service Account ===" -ForegroundColor Cyan

$existing = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -Server $DomainServer -Credential $Credential -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  'ASPGOV\$SamAccountName' already exists — leaving password untouched." -ForegroundColor Yellow
} else {
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghjkmnpqrstuvwxyz'
    $digits  = '23456789'
    # No $, `, ", ' — any of these inside a double-quoted string passed to a CLI (e.g.
    # aws ssm put-parameter --value "...") can be silently mangled: PowerShell/shells treat
    # "$word" as a variable interpolation attempt and truncate the string when it fails.
    $special = '!@#%^&*'
    $all     = $upper + $lower + $digits + $special
    $rng     = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes   = [byte[]]::new(24)
    $rng.GetBytes($bytes)
    $pwd  = $upper[$bytes[0] % $upper.Length]
    $pwd += $lower[$bytes[1] % $lower.Length]
    $pwd += $digits[$bytes[2] % $digits.Length]
    $pwd += $special[$bytes[3] % $special.Length]
    for ($i = 4; $i -lt 20; $i++) { $pwd += $all[$bytes[$i] % $all.Length] }
    $chars = $pwd.ToCharArray()
    for ($i = $chars.Length - 1; $i -gt 0; $i--) {
        $j = $bytes[$i % $bytes.Length] % ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    $password = -join $chars
    $secPwd   = ConvertTo-SecureString $password -AsPlainText -Force

    if ($PSCmdlet.ShouldProcess($SamAccountName, "Create service account in $ServiceAcctOu")) {
        New-ADUser -SamAccountName $SamAccountName -Name $SamAccountName -DisplayName $SamAccountName `
            -UserPrincipalName "$SamAccountName@$UpnSuffix" -Path $ServiceAcctOu `
            -AccountPassword $secPwd -Enabled $true -PasswordNeverExpires $true `
            -CannotChangePassword $true -Server $DomainServer -Credential $Credential

        Write-Host "  Created 'ASPGOV\$SamAccountName' in $ServiceAcctOu" -ForegroundColor Green
        Write-Host ""
        Write-Host "  GENERATED PASSWORD (store this now — it is not saved anywhere):" -ForegroundColor Red
        Write-Host "  $password" -ForegroundColor White
        Write-Host ""
        Write-Host "  Store it as a SecureString SSM Parameter named /czp-naviline/svc-czp-navi-prov in:" -ForegroundColor Yellow
        Write-Host "    - PALegacyCzp, us-east-1 and us-west-2" -ForegroundColor Yellow
        Write-Host "    - PALegacySharedServices, us-east-1 and us-west-2" -ForegroundColor Yellow
    }
}

# ── Step 3: Delegate domain-join rights on aspgov.pri/C2G ─────────────────────
Write-Host "`n=== Step 3: Delegate Domain-Join Rights on $TargetOu ===" -ForegroundColor Cyan

$svcAcct = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -Server $DomainServer -Credential $Credential -ErrorAction SilentlyContinue
if (-not $svcAcct) {
    Write-Warning "  Service account not found (likely -WhatIf run with no prior creation) — skipping delegation. Re-run after creation."
} else {
    if ($PSCmdlet.ShouldProcess($TargetOu, "Delegate join-computer rights to ASPGOV\$SamAccountName")) {
        $ouPath = "AD:\$TargetOu"
        $acl = Get-Acl -Path $ouPath
        $identity = New-Object System.Security.Principal.NTAccount("ASPGOV", $SamAccountName)
        $sid = $identity.Translate([System.Security.Principal.SecurityIdentifier])

        # Create/Delete Computer objects, scoped to this OU only
        $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $sid, 'CreateChild, DeleteChild', 'Allow', $Guid_ComputerClass, 'All', $Guid_Empty)))

        # Reset Password (extended right), Validated writes, Account Restrictions —
        # scoped to descendant Computer objects only
        foreach ($rightGuid in @($Guid_ResetPassword, $Guid_ValidatedWriteDns, $Guid_ValidatedWriteSpn)) {
            $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $sid, 'ExtendedRight', 'Allow', $rightGuid, 'Descendents', $Guid_ComputerClass)))
        }
        $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $sid, 'ReadProperty, WriteProperty', 'Allow', $Guid_AccountRestrictionsSet, 'Descendents', $Guid_ComputerClass)))

        Set-Acl -Path $ouPath -AclObject $acl
        Write-Host "  Delegated join-computer rights on $TargetOu to ASPGOV\$SamAccountName" -ForegroundColor Green
    }
}

# ── Step 4: Delegate group-membership management ──────────────────────────────
Write-Host "`n=== Step 4: Delegate Group Membership on WSUS/TLS Groups ===" -ForegroundColor Cyan

if (-not $svcAcct) {
    Write-Warning "  Service account not found — skipping delegation. Re-run after creation."
} else {
    foreach ($grpName in $Groups) {
        $grp = Get-ADGroup -Filter "Name -eq '$grpName'" -Server $DomainServer -Credential $Credential -ErrorAction SilentlyContinue
        if (-not $grp) {
            Write-Warning "  Group '$grpName' not found in aspgov.pri — skipping."
            continue
        }
        if ($PSCmdlet.ShouldProcess($grpName, "Delegate Member-attribute write to ASPGOV\$SamAccountName")) {
            $grpPath = "AD:\$($grp.DistinguishedName)"
            $acl = Get-Acl -Path $grpPath
            $identity = New-Object System.Security.Principal.NTAccount("ASPGOV", $SamAccountName)
            $sid = $identity.Translate([System.Security.Principal.SecurityIdentifier])

            $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $sid, 'WriteProperty', 'Allow', $Guid_MemberAttribute, 'None', $Guid_Empty)))

            Set-Acl -Path $grpPath -AclObject $acl
            Write-Host "  Delegated Member-attribute write on '$grpName' to ASPGOV\$SamAccountName" -ForegroundColor Green
        }
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host "`n=== Complete ===" -ForegroundColor Green
Write-Host "  Account:      ASPGOV\$SamAccountName" -ForegroundColor White
Write-Host "  OU:           $ServiceAcctOu" -ForegroundColor White
Write-Host "  Delegated on: $TargetOu (join rights)" -ForegroundColor White
Write-Host "  Delegated on: $($Groups -join ', ') (Member attribute write)" -ForegroundColor White
Write-Host ""
Write-Host "  REMAINING MANUAL STEP:" -ForegroundColor Yellow
Write-Host "  Store the generated password as SecureString SSM Parameter /czp-naviline/svc-czp-navi-prov" -ForegroundColor Yellow
Write-Host "  in PALegacyCzp and PALegacySharedServices, both us-east-1 and us-west-2, before running /czp-naviline-provision." -ForegroundColor Yellow
