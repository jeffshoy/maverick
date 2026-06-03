#Requires -Version 5.1

<#
.SYNOPSIS
    Open an interactive SSM shell session on an EC2 instance.
.DESCRIPTION
    Resolves an account name (exact profile or fuzzy nickname), finds the target
    instance across priority regions, and opens an interactive SSM shell session.
    Triggers SSO browser login using the correct session if the token is expired.

    For RDP access use Connect-RDP.ps1 instead.
.PARAMETER server_name
    EC2 Name tag of the target server (e.g. ARCT-PTRKRD001). Alias: -s
.PARAMETER aws_profile
    AWS profile name or account nickname (e.g. PALegacySharedServices, PLUS).
    Defaults to PALegacySharedServices. Alias: -p
.PARAMETER aws_region
    AWS region to search first. Defaults to us-east-1. Alias: -r
.EXAMPLE
    .\connect-instance.ps1 -s ARCT-PTRKRD001
.EXAMPLE
    .\connect-instance.ps1 -s CLD-PPLSAPM001 -p PLUS
.EXAMPLE
    .\connect-instance.ps1 -s ARCT-PTRKRD001 -p PALegacySharedServices -r us-west-2
#>

[CmdletBinding()]
param(
    [Alias('s')]
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $server_name,

    [Alias('p')]
    [string] $aws_profile = 'PALegacySharedServices',

    [Alias('r')]
    [string] $aws_region = 'us-east-1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$check = [char]::ConvertFromUtf32(0x2714)
$cross = [char]::ConvertFromUtf32(0x274C)

# ---------------------------------------------------------------------------
# Resolve profile — if $aws_profile is an exact match in ~/.aws/config, use it
# directly; otherwise treat it as a nickname and run through the resolver.
# This keeps existing callers passing explicit profile names fully backwards-
# compatible while adding fuzzy-nickname support transparently.
# ---------------------------------------------------------------------------
$resolvedProfile    = $aws_profile
$resolvedSsoSession = 'foundation'  # fallback; overwritten when resolver runs

$configPath = Join-Path $HOME '.aws\config'
$profileInConfig = $false
if (Test-Path $configPath) {
    $profileInConfig = (Get-Content $configPath | Select-String -Pattern "^\[profile $([regex]::Escape($aws_profile))\]" -Quiet)
}

if (-not $profileInConfig) {
    Write-Host "Resolving account '$aws_profile'..." -ForegroundColor Yellow
    $acct = & "$PSScriptRoot\Resolve-AwsAccount.ps1" -Name $aws_profile
    $resolvedProfile    = $acct.Profile
    $resolvedSsoSession = $acct.SsoSession
    Write-Host "  $check $($acct.Name) ($($acct.Org)) -> profile: $resolvedProfile" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# SSO login check — uses resolved session, not hardcoded foundation
# ---------------------------------------------------------------------------
Write-Host "Checking SSO session... " -ForegroundColor Yellow -NoNewLine
$identity = aws sts get-caller-identity --profile $resolvedProfile 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "$cross expired" -ForegroundColor Red
    Write-Host "Opening browser for SSO login ($resolvedSsoSession)..." -ForegroundColor Cyan
    aws sso login --sso-session $resolvedSsoSession
    if ($LASTEXITCODE -ne 0) {
        Write-Error "SSO login failed."
        exit 1
    }
    Write-Host "  $check logged in" -ForegroundColor Green
} else {
    Write-Host "$check active" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Find instance — search the explicit region first, then remaining priority
# regions (Find-Instance.ps1 stops at the first hit)
# ---------------------------------------------------------------------------
$regions = @($aws_region) + (@('us-east-1','us-west-2','ca-central-1') | Where-Object { $_ -ne $aws_region })

Write-Host "Finding '$server_name'..." -ForegroundColor Yellow
$instances = & "$PSScriptRoot\Find-Instance.ps1" -ServerName $server_name -Profile $resolvedProfile -Regions $regions
$instance  = @($instances)[0]
Write-Host "  $check $($instance.InstanceId) in $($instance.Region) ($($instance.Az))" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Open interactive SSM session
# ---------------------------------------------------------------------------
Write-Host "Opening SSM session..." -ForegroundColor Yellow
aws ssm start-session --target $instance.InstanceId --profile $resolvedProfile --region $instance.Region
