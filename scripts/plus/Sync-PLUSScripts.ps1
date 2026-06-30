#Requires -Version 5.1

<#
.SYNOPSIS
    Copy scripts/plus/ to C:\PLUS\Scripts\ on all PLUS RDSH servers.

.DESCRIPTION
    Idempotent. Safe to re-run after any script update. Copies the scripts/plus/ tree
    (config, scripts, templates, support launcher) to \\<server>\C$\PLUS\Scripts\
    on all six RDSH servers. Requires admin share access (domain admin or delegated rights).

    Dev-only folders (PLUS-RefreshDBData\Examples, PLUS-RefreshDBData\Tests) are excluded
    from the RDSH copy — they are for developer reference only.

.PARAMETER Servers
    Override the default list of six RDSH servers. Useful for staging to a subset.

.PARAMETER SourceRoot
    Override the source root. Defaults to the scripts/plus/ folder (this script's directory).

.EXAMPLE
    pwsh scripts\plus\Sync-PLUSScripts.ps1

.EXAMPLE
    pwsh scripts\plus\Sync-PLUSScripts.ps1 -WhatIf

.EXAMPLE
    pwsh scripts\plus\Sync-PLUSScripts.ps1 -Servers INF-WSRDS001,INF-WSRDS002

.NOTES
    Author: CloudOps SRE — CentralSquare Technologies
    Blast radius: writes to C:\PLUS\Scripts\ on up to 6 RDSH servers. No AD/SQL changes.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string[]]$Servers = @(
        'INF-WSRDS001', 'INF-WSRDS002', 'INF-WSRDS003',   # us-east-1
        'INF-WSRDS101', 'INF-WSRDS102', 'INF-WSRDS103'    # us-west-2
    ),

    [Parameter()]
    [string]$SourceRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Relative paths (from SourceRoot) that are dev-only and should not land on RDSH servers
$devOnlyFolders = @(
    'PLUS-RefreshDBData\Examples',
    'PLUS-RefreshDBData\Tests'
)

$results = @()

foreach ($server in $Servers) {
    $adminShare = "\\$server\C$"
    $unc        = "$adminShare\PLUS\Scripts"

    Write-Host "[$server] Checking reachability ..." -ForegroundColor Cyan

    if (-not (Test-Path $adminShare -ErrorAction SilentlyContinue)) {
        Write-Warning "[$server] Cannot reach $adminShare — skipping."
        $results += [pscustomobject]@{ Server = $server; Status = 'UNREACHABLE' }
        continue
    }

    if ($PSCmdlet.ShouldProcess($unc, "Copy scripts/plus/ tree")) {
        try {
            if (-not (Test-Path $unc)) {
                $null = New-Item -ItemType Directory -Path $unc -Force -ErrorAction Stop
                Write-Verbose "[$server] Created $unc"
            }

            # Copy all top-level items except dev-only subfolders
            Get-ChildItem -Path $SourceRoot | Where-Object {
                $rel = $_.FullName.Substring($SourceRoot.Length).TrimStart('\')
                $devOnlyFolders -notcontains $rel
            } | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $unc -Recurse -Force -ErrorAction Stop
            }
            Write-Host "[$server] OK — synced to $unc" -ForegroundColor Green
            $results += [pscustomobject]@{ Server = $server; Status = 'OK' }
        } catch {
            Write-Warning "[$server] FAILED — $_"
            $results += [pscustomobject]@{ Server = $server; Status = "FAILED: $_" }
        }
    } else {
        $results += [pscustomobject]@{ Server = $server; Status = 'WHATIF' }
    }
}

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
$results | Format-Table Server, Status -AutoSize

if ($results | Where-Object { $_.Status -notmatch '^(OK|WHATIF)$' }) {
    exit 1
}
