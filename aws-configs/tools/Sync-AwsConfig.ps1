#Requires -Version 5.1

<#
.SYNOPSIS
    Merges cloudops.config into ~/.aws/config, preserving personal profiles.
.DESCRIPTION
    Replaces all blocks owned by the 'foundation' or 'legacy' SSO sessions in
    ~/.aws/config with the contents of aws-configs/cloudops.config. Personal
    profiles (other sessions or standalone profiles) are preserved.

    A timestamped backup is written before any change is made.

    Run monthly (or after pulling a config update) to stay in sync with the
    team-wide account list. Use -WhatIf to preview without writing.
.EXAMPLE
    pwsh aws-configs/tools/Sync-AwsConfig.ps1
    pwsh aws-configs/tools/Sync-AwsConfig.ps1 -WhatIf
.NOTES
    Run from the repo root. Requires Python + AWS CLI to regenerate the source
    config; this script only handles the merge step.
#>

[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$repoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourceConfig = Join-Path $repoRoot 'aws-configs\cloudops.config'
$targetConfig = Join-Path $HOME '.aws\config'
$awsDir       = Join-Path $HOME '.aws'

if (-not (Test-Path $sourceConfig)) {
    Write-Error "Source config not found: $sourceConfig"
    exit 1
}

# ---------------------------------------------------------------------------
# Ensure ~/.aws exists
# ---------------------------------------------------------------------------
if (-not (Test-Path $awsDir)) {
    if ($PSCmdlet.ShouldProcess($awsDir, 'Create directory')) {
        New-Item -ItemType Directory -Path $awsDir | Out-Null
        Write-Verbose "Created $awsDir"
    }
}

# ---------------------------------------------------------------------------
# If no existing config, just copy
# ---------------------------------------------------------------------------
if (-not (Test-Path $targetConfig)) {
    if ($PSCmdlet.ShouldProcess($targetConfig, 'Copy cloudops.config (no existing config)')) {
        Copy-Item $sourceConfig $targetConfig
        Write-Host "Created $targetConfig from cloudops.config."
    }
    return
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
$timestamp  = (Get-Date -Format 'yyyyMMdd-HHmmss')
$backupPath = "$targetConfig.backup-$timestamp"
if ($PSCmdlet.ShouldProcess($backupPath, 'Write backup')) {
    Copy-Item $targetConfig $backupPath
    Write-Verbose "Backup written to $backupPath"
}

# ---------------------------------------------------------------------------
# Parse helpers — split a config file into blocks keyed by section header
# ---------------------------------------------------------------------------
function Split-AwsConfig {
    param([string]$Path)

    $blocks   = [System.Collections.Generic.List[hashtable]]::new()
    $current  = $null

    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^\[(sso-session|profile)\s+(.+)\]') {
            if ($null -ne $current) { $blocks.Add($current) }
            $current = @{ Header = $line; Type = $Matches[1]; Name = $Matches[2]; Lines = [System.Collections.Generic.List[string]]::new() }
            $current.Lines.Add($line)
        }
        elseif ($null -ne $current) {
            $current.Lines.Add($line)
        }
        # Lines before the first section (comments, blanks) are ignored — the
        # canonical header comes from cloudops.config.
    }
    if ($null -ne $current) { $blocks.Add($current) }
    return $blocks
}

# ---------------------------------------------------------------------------
# Determine which blocks in the existing config are "owned" by foundation/legacy
# ---------------------------------------------------------------------------
$MANAGED_SESSIONS = @('foundation', 'legacy')

function Test-ManagedBlock {
    param([hashtable]$Block)
    if ($Block.Type -eq 'sso-session' -and $Block.Name -in $MANAGED_SESSIONS) { return $true }
    if ($Block.Type -eq 'profile') {
        # Profile is managed if it contains sso_session = foundation|legacy
        foreach ($line in $Block.Lines) {
            if ($line -match '^\s*sso_session\s*=\s*(\S+)' -and $Matches[1] -in $MANAGED_SESSIONS) {
                return $true
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Parse both files
# ---------------------------------------------------------------------------
$existingBlocks = Split-AwsConfig -Path $targetConfig
$sourceBlocks   = Split-AwsConfig -Path $sourceConfig

# Personal = not owned by foundation/legacy session AND not overridden by a same-named block in cloudops.config.
# If cloudops.config has a profile with the same name, cloudops.config wins — prevents duplicates when
# a personal profile was previously set up with its own per-profile SSO session that has since been
# migrated into the canonical foundation/legacy sessions.
$managedNames = $sourceBlocks | ForEach-Object { $_.Name }
$personal = $existingBlocks | Where-Object {
    (-not (Test-ManagedBlock $_)) -and ($_.Name -notin $managedNames)
}
$managed  = $sourceBlocks    # canonical source replaces all managed blocks

# ---------------------------------------------------------------------------
# Compose new config: canonical header + managed blocks + personal blocks
# ---------------------------------------------------------------------------
$newLines = [System.Collections.Generic.List[string]]::new()

# Header comment from cloudops.config (lines before first section)
foreach ($line in (Get-Content $sourceConfig)) {
    if ($line -match '^\[') { break }
    $newLines.Add($line)
}

foreach ($block in $managed) {
    $newLines.Add('')
    foreach ($line in $block.Lines) { $newLines.Add($line) }
}

if ($personal.Count -gt 0) {
    $newLines.Add('')
    $newLines.Add('# ---------------------------------------------------------------------------')
    $newLines.Add('# Personal profiles (not managed by cloudops.config)')
    $newLines.Add('# ---------------------------------------------------------------------------')
    foreach ($block in $personal) {
        $newLines.Add('')
        foreach ($line in $block.Lines) { $newLines.Add($line) }
    }
}

$newContent = $newLines -join "`n"

# ---------------------------------------------------------------------------
# Diff summary
# ---------------------------------------------------------------------------
$oldContent = Get-Content $targetConfig -Raw
$addedHeaders   = ($managed   | Select-Object -ExpandProperty Header) -join "`n"
$keptHeaders    = ($personal   | Select-Object -ExpandProperty Header) -join "`n"

Write-Host "Managed blocks (from cloudops.config): $($managed.Count)"
Write-Host "Personal blocks preserved:             $($personal.Count)"
if ($keptHeaders) { Write-Verbose "Kept:`n$keptHeaders" }

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------
if ($oldContent.TrimEnd() -eq $newContent.TrimEnd()) {
    Write-Host "~/.aws/config is already up to date. No changes written."
    return
}

if ($PSCmdlet.ShouldProcess($targetConfig, 'Write merged config')) {
    Set-Content -Path $targetConfig -Value $newContent -Encoding UTF8 -NoNewline
    Write-Host "Updated $targetConfig (backup: $backupPath)"
}
