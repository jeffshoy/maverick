#Requires -Version 7.0

<#
.SYNOPSIS
    Create an Azure DevOps pull request with a multi-line description.
.DESCRIPTION
    Thin wrapper around `az repos pr create` that reads the PR description from a
    markdown file and passes each line as a separate --description argument.
    This is the only reliable way to preserve multi-line descriptions via the az CLI
    (passing a single multiline string truncates to the first line).

    Used by Claude Code and humans alike. Claude MUST call this script rather than
    invoking `az repos pr create` directly.
.PARAMETER Title
    The PR title.
.PARAMETER DescriptionFile
    Path to a markdown file containing the PR body. Every line (including blank
    lines) is forwarded as a separate --description argument to az.
.PARAMETER SourceBranch
    Branch to merge from. Defaults to the current git branch.
.PARAMETER TargetBranch
    Branch to merge into. Defaults to 'main'.
.EXAMPLE
    pwsh scripts\azdo\New-PR.ps1 `
        -Title "fix(setup): fail fast when not elevated" `
        -DescriptionFile "$env:TEMP\pr-setup-elevation.md"
.EXAMPLE
    pwsh scripts\azdo\New-PR.ps1 `
        -Title "feat(aws): add dry-run mode" `
        -DescriptionFile "$env:TEMP\pr-dry-run.md" `
        -TargetBranch "main"
.NOTES
    Author: CloudOps SRE team
    Requires: Azure CLI (az) authenticated to AzDo, git on PATH, PS7+.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Title,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DescriptionFile,

    [Parameter()]
    [string] $SourceBranch,

    [Parameter()]
    [string] $TargetBranch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate description file
if (-not (Test-Path -LiteralPath $DescriptionFile -PathType Leaf)) {
    Write-Error "Description file not found: $DescriptionFile"
    exit 1
}
$descContent = [System.IO.File]::ReadAllText($DescriptionFile)
if ($descContent.Trim().Length -eq 0) {
    Write-Error "Description file is empty: $DescriptionFile"
    exit 1
}

# Resolve source branch
if (-not $SourceBranch) {
    $SourceBranch = git rev-parse --abbrev-ref HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Could not determine current git branch. Pass -SourceBranch explicitly."
        exit 1
    }
    $SourceBranch = $SourceBranch.Trim()
}

# Read lines — Get-Content preserves empty lines as empty strings,
# which is exactly what az --description expects for blank separators.
$lines = Get-Content -LiteralPath $DescriptionFile

Write-Verbose "Creating PR: '$Title' ($SourceBranch -> $TargetBranch)"
Write-Verbose "Description: $($lines.Count) lines from $DescriptionFile"

$azArgs = @(
    'repos', 'pr', 'create',
    '--title',         $Title,
    '--source-branch', $SourceBranch,
    '--target-branch', $TargetBranch,
    '--output',        'json',
    '--description'
) + $lines

$tempErr = [System.IO.Path]::GetTempFileName()
try {
    $output = az @azArgs 2>$tempErr | Out-String
    $azExit = $LASTEXITCODE
    $errOutput = Get-Content $tempErr -Raw -ErrorAction SilentlyContinue
} finally {
    Remove-Item $tempErr -ErrorAction SilentlyContinue
}
if ($azExit -ne 0) {
    Write-Error "az repos pr create failed (exit $azExit):`n$errOutput`n$output"
    exit 1
}

$pr     = $output | ConvertFrom-Json
$webUrl = $pr.repository.remoteUrl -replace '^https://[^@]+@', 'https://'
$webUrl = $webUrl.TrimEnd('/') + "/pullrequest/$($pr.pullRequestId)"

Write-Host "PR $($pr.pullRequestId): $webUrl" -ForegroundColor Green

# Emit the structured object for callers that pipe the result
Write-Output $pr
