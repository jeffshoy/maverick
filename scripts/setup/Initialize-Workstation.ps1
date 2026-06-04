#Requires -Version 5.1

<#
.SYNOPSIS
    One-time workstation setup for CloudOps SRE team members.
.DESCRIPTION
    Installs required tools via winget, creates the CLAUDE.md symlink,
    syncs the team AWS config, and verifies the environment is ready.

    All steps are idempotent — safe to re-run at any time.
    Run with -WhatIf to preview every action without making changes.
.PARAMETER SkipWinget
    Skip winget tool installs (use if tools are already installed via another method).
.PARAMETER SkipRsat
    Skip RSAT capability installs (for non-domain-joined workstations).
.PARAMETER SkipAwsSync
    Skip the AWS config sync step.
.EXAMPLE
    .\Initialize-Workstation.ps1
.EXAMPLE
    .\Initialize-Workstation.ps1 -WhatIf
.EXAMPLE
    .\Initialize-Workstation.ps1 -SkipRsat -SkipAwsSync
.NOTES
    Author: CloudOps SRE team
    Package manager: winget (built into Windows 10/11 — no bootstrapping needed).
    RSAT install requires an elevated (admin) PowerShell session.
    See docs/onboarding.md for the manual step-by-step equivalent.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch] $SkipWinget,

    [Parameter()]
    [switch] $SkipRsat,

    [Parameter()]
    [switch] $SkipAwsSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Step  { param([string]$Msg) Write-Host "  $Msg"       -ForegroundColor Cyan     }
function Write-Ok    { param([string]$Msg) Write-Host "  [OK] $Msg"  -ForegroundColor Green    }
function Write-Skip  { param([string]$Msg) Write-Host "  [--] $Msg"  -ForegroundColor DarkGray }

#endregion

#region 0 — Clone location check

$expectedRoot = Join-Path $env:USERPROFILE 'repos\cloudops'
$actualRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if ($actualRoot.TrimEnd('\') -ne $expectedRoot.TrimEnd('\')) {
    Write-Warning "Repo is at '$actualRoot', not the standard '$expectedRoot'."
    Write-Warning "Kiro tasks, CLAUDE.md paths, and documentation all assume $expectedRoot."
    $answer = Read-Host "Continue from '$actualRoot'? (y/N)"
    if ($answer -notin @('y', 'Y')) {
        Write-Host "Exiting. Clone to $expectedRoot and re-run." -ForegroundColor Yellow
        exit 0
    }
}

$repoRoot = $actualRoot

#endregion

#region 1 — Winget tool installs

if (-not $SkipWinget) {
    Write-Host "`n[1/5] Installing prerequisites via winget..." -ForegroundColor White

    $tools = @(
        [PSCustomObject]@{ Id = 'Microsoft.PowerShell';        Name = 'PowerShell 7'          },
        [PSCustomObject]@{ Id = 'Amazon.AWSCLI';               Name = 'AWS CLI v2'            },
        [PSCustomObject]@{ Id = 'Amazon.SessionManagerPlugin'; Name = 'SSM Session Manager'   },
        [PSCustomObject]@{ Id = 'Microsoft.AzureCLI';          Name = 'Azure CLI'             },
        [PSCustomObject]@{ Id = 'Python.Python.3.12';          Name = 'Python 3.12'           },
        [PSCustomObject]@{ Id = 'Git.Git';                     Name = 'Git'                   }
    )

    foreach ($tool in $tools) {
        $alreadyInstalled = $false
        try {
            $listOutput = (winget list --id $tool.Id --exact 2>&1) | Out-String
            $alreadyInstalled = $listOutput -match [regex]::Escape($tool.Id)
        } catch { $alreadyInstalled = $false }

        # PS7 may have been installed outside winget (MSI, Scoop, dotnet install).
        # If `pwsh` resolves on PATH, treat it as already present — don't double-install.
        if (-not $alreadyInstalled -and $tool.Id -eq 'Microsoft.PowerShell') {
            if (Get-Command pwsh -ErrorAction SilentlyContinue) {
                $alreadyInstalled = $true
                Write-Skip "$($tool.Name) — detected on PATH (non-winget install)"
            }
        }

        if ($alreadyInstalled) {
            Write-Skip "$($tool.Name) — already installed"
        } elseif ($PSCmdlet.ShouldProcess($tool.Name, 'winget install')) {
            Write-Step "Installing $($tool.Name)..."
            winget install --id $tool.Id --exact --accept-source-agreements --accept-package-agreements --silent
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "winget install $($tool.Id) exited $LASTEXITCODE — verify manually"
            } else {
                Write-Ok "$($tool.Name) installed"
            }
        }
    }
} else {
    Write-Host "`n[1/5] Skipping winget installs (-SkipWinget)" -ForegroundColor DarkGray
}

#endregion

#region 2 — RSAT capabilities

if (-not $SkipRsat) {
    Write-Host "`n[2/5] Installing RSAT capabilities..." -ForegroundColor White

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Warning "RSAT install requires administrator rights. Skipping. Re-run as admin to install RSAT."
    } else {
        $rsatCaps = @(
            'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0',
            'Rsat.Dns.Tools~~~~0.0.1.0'
        )

        foreach ($cap in $rsatCaps) {
            try {
                $state = (Get-WindowsCapability -Online -Name $cap -ErrorAction Stop).State
            } catch {
                $state = 'Unknown'
            }

            if ($state -eq 'Installed') {
                Write-Skip "$cap — already installed"
            } elseif ($PSCmdlet.ShouldProcess($cap, 'Add-WindowsCapability')) {
                Write-Step "Installing $cap..."
                Add-WindowsCapability -Online -Name $cap -ErrorAction Stop | Out-Null
                Write-Ok "$cap installed"
            }
        }
    }
} else {
    Write-Host "`n[2/5] Skipping RSAT install (-SkipRsat)" -ForegroundColor DarkGray
}

#endregion

#region 3 — Python packages

Write-Host "`n[3/5] Installing Python packages..." -ForegroundColor White

$pyPackages = @('boto3', 'colorama')
foreach ($pkg in $pyPackages) {
    try {
        $showOutput = (pip show $pkg 2>&1) | Out-String
        $installed  = $showOutput -match "Name: $pkg"
    } catch {
        $installed = $false
    }

    if ($installed) {
        Write-Skip "$pkg — already installed"
    } elseif ($PSCmdlet.ShouldProcess($pkg, 'pip install')) {
        Write-Step "Installing $pkg..."
        pip install $pkg --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "pip install $pkg exited $LASTEXITCODE — verify manually"
        } else {
            Write-Ok "$pkg installed"
        }
    }
}

#endregion

#region 4 — CLAUDE.md symlink

Write-Host "`n[4/5] Linking CLAUDE.md to Claude Code config..." -ForegroundColor White

$claudeDir   = Join-Path $env:USERPROFILE '.claude'
$symlinkPath = Join-Path $claudeDir 'CLAUDE.md'
$sourcePath  = Join-Path $repoRoot 'CLAUDE.md'

if (-not (Test-Path $claudeDir)) {
    if ($PSCmdlet.ShouldProcess($claudeDir, 'New-Item -ItemType Directory')) {
        New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    }
}

if (Test-Path $symlinkPath -PathType Leaf) {
    $existing = Get-Item $symlinkPath -Force
    if ($existing.LinkType -eq 'SymbolicLink') {
        Write-Skip "Symlink already exists at $symlinkPath"
    } else {
        Write-Warning "File exists at $symlinkPath (not a symlink — type: $($existing.Attributes)). Remove it manually and re-run to replace."
    }
} else {
    if ($PSCmdlet.ShouldProcess("$symlinkPath -> $sourcePath", 'New-Item -ItemType SymbolicLink')) {
        try {
            New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $sourcePath -ErrorAction Stop | Out-Null
            Write-Ok "Symlink created: $symlinkPath"
        } catch {
            Write-Warning "Symlink creation failed ($_)."
            Write-Warning "Falling back to Copy-Item. Re-run this script after 'git pull' to keep CLAUDE.md current."
            Copy-Item $sourcePath $symlinkPath -Force
            Write-Ok "Copied CLAUDE.md to $symlinkPath"
        }
    }
}

#endregion

#region 5 — Sync AWS config

if (-not $SkipAwsSync) {
    Write-Host "`n[5/5] Syncing team AWS config..." -ForegroundColor White

    $syncScript = Join-Path $repoRoot 'aws-configs\tools\Sync-AwsConfig.ps1'
    if (-not (Test-Path $syncScript)) {
        Write-Warning "Sync script not found at $syncScript — skipping"
    } elseif ($WhatIfPreference) {
        & $syncScript -WhatIf
    } else {
        & $syncScript
    }
} else {
    Write-Host "`n[5/5] Skipping AWS config sync (-SkipAwsSync)" -ForegroundColor DarkGray
}

#endregion

#region Verify PATH

Write-Host "`nVerifying tools on PATH..." -ForegroundColor White

$verifyList = @(
    [PSCustomObject]@{ Command = 'pwsh';   Name = 'PowerShell 7' },
    [PSCustomObject]@{ Command = 'aws';    Name = 'AWS CLI v2'   },
    [PSCustomObject]@{ Command = 'az';     Name = 'Azure CLI'    },
    [PSCustomObject]@{ Command = 'python'; Name = 'Python 3'     },
    [PSCustomObject]@{ Command = 'git';    Name = 'Git'          }
)

$results = foreach ($item in $verifyList) {
    $cmd = Get-Command $item.Command -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Tool   = $item.Name
        Status = if ($cmd) { 'OK' }        else { 'MISSING'              }
        Path   = if ($cmd) { $cmd.Source } else { '(not found on PATH)'  }
    }
}

$results | Format-Table -AutoSize

$missing = @($results | Where-Object { $_.Status -eq 'MISSING' })
if ($missing.Count -gt 0) {
    Write-Warning "$($missing.Count) tool(s) not found on PATH: $($missing.Tool -join ', ')"
    Write-Warning "If tools were just installed by winget, open a NEW terminal and re-run to verify."
    exit 1
}

#endregion

#region Shell self-check

Write-Host "`nShell self-check:" -ForegroundColor White
Write-Host "  Bootstrap ran under: PowerShell $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "Team standard is PowerShell 7. Open a new 'pwsh' terminal for future work."
    Write-Warning "Set Windows Terminal default profile to PowerShell 7 (see docs/onboarding.md step 3.5)."
}

#endregion

Write-Host "`nSetup complete. Next steps:" -ForegroundColor Green
Write-Host "  1. Open cloudops.code-workspace in Kiro (File > Open Workspace from File)"
Write-Host "  2. Install the Claude Code extension (Extensions panel, search 'Claude Code')"
Write-Host "  3. aws sso login --sso-session foundation"
Write-Host "  4. aws sso login --sso-session legacy"
Write-Host "  5. git config --global user.name 'First Last'"
Write-Host "  6. git config --global user.email 'first.last@centralsquare.com'"
Write-Host "`n  See docs/onboarding.md for full details and verification steps."
