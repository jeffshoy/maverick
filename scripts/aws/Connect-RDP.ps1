#Requires -Version 5.1

<#
.SYNOPSIS
    RDP to an EC2 instance via SSM port forwarding.
.DESCRIPTION
    Resolves an informal account name to an AWS profile, finds the target instance
    across priority regions, opens an SSM port-forwarding tunnel (port 3389), and
    launches mstsc automatically. The SSM session runs in a separate window so the
    tunnel stays alive while you work.

    Account name resolution is fuzzy ("PLUS" -> PALegacyPlus). If multiple accounts
    match equally, you will be prompted to pick one before anything connects.

    Automatically retries SSO login using the correct session (foundation or legacy)
    if the cached token is expired.

    Performance features (transparent):
    - Account resolution is done in native PowerShell (no Python subprocess cold-start).
    - SSO token validity is checked against the local cache before calling AWS CLI.
    - Instance lookup results are cached at $env:LOCALAPPDATA\cloudops\rdp-cache.json
      and lazily verified; repeat connections skip the full region scan.
    - Port probe uses a 100ms TCP connect instead of Test-NetConnection.
    - mstsc launches as soon as the tunnel port accepts connections (polls every 200ms).
.PARAMETER ServerName
    EC2 Name tag of the target server (e.g. CLD-PPLSAPM001). Alias: -s
.PARAMETER Account
    Account name or nickname (e.g. PLUS, PALegacyPlus, SharedServices). Alias: -a
.PARAMETER LocalPort
    Local TCP port to forward RDP to. Default 33389. Auto-increments up to 33399
    if the default port is already in use.
.PARAMETER NoLaunch
    Open the tunnel but do not launch mstsc. Prints the connection string instead.
    Useful for non-RDP port-forward use or scripted callers.
.PARAMETER NoCache
    Skip the instance cache and run a full Find-Instance scan. Use when the instance
    was recently replaced or the cache entry appears stale.
.EXAMPLE
    .\Connect-RDP.ps1 -ServerName CLD-PPLSAPM001 -Account PLUS
.EXAMPLE
    .\Connect-RDP.ps1 -s ARCT-PTRKRD001 -a SharedServices -NoLaunch
.NOTES
    Requires: AWS CLI v2, session-manager-plugin, aws-configs/accounts.json.
    The SSM tunnel window must stay open for the RDP session to remain active.
    Close it (or Ctrl+C it) to terminate the connection.
#>

[CmdletBinding()]
param(
    [Alias('s')]
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ServerName,

    [Alias('a')]
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Account,

    [ValidateRange(1024, 65535)]
    [int] $LocalPort = 33389,

    [switch] $NoLaunch,
    [switch] $NoCache,

    # Force non-interactive mode (fail fast on ambiguous account instead of prompting).
    # Auto-detected when stdin is redirected or the session is non-interactive.
    [switch] $NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AwsResolver.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'SsoTokenCheck.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot 'RdpCache.psm1')       -Force

$check = [char]::ConvertFromUtf32(0x2714)
$cross = [char]::ConvertFromUtf32(0x274C)

# ---------------------------------------------------------------------------
# Helper: fast TCP port probe (~100ms vs Test-NetConnection's ~1-2s)
# ---------------------------------------------------------------------------
function Test-PortInUse {
    param([int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        return $client.ConnectAsync('127.0.0.1', $Port).Wait(100)
    } finally { $client.Dispose() }
}

# ---------------------------------------------------------------------------
# 1. Resolve account (native PS — no Python subprocess)
# ---------------------------------------------------------------------------
Write-Host "Resolving account '$Account'..." -ForegroundColor Yellow
$isNonInteractive = $NonInteractive -or
    -not [Environment]::UserInteractive -or
    [Console]::IsInputRedirected
$acct = Resolve-AwsAccount -Name $Account -NonInteractive:$isNonInteractive
Write-Host "  $check $($acct.Name) ($($acct.Org), $($acct.AccountId))" -ForegroundColor Green

# Resolve the startUrl for SSO token precheck
# PSObject.Properties indexing is strict-mode-safe; $().$() syntax is not.
$accountsJson = Join-Path $PSScriptRoot '..\..\aws-configs\accounts.json'
$registry = Get-Content (Resolve-Path $accountsJson) -Raw | ConvertFrom-Json
$sessionEntry = $registry.ssoSessions.PSObject.Properties[$acct.SsoSession]
if (-not $sessionEntry) {
    Write-Error "Unknown SSO session '$($acct.SsoSession)' in accounts.json."
    exit 1
}
$startUrl = $sessionEntry.Value.startUrl

# ---------------------------------------------------------------------------
# 2. SSO session check — precheck local cache before calling AWS CLI
# ---------------------------------------------------------------------------
Write-Host "Checking SSO session ($($acct.SsoSession))... " -ForegroundColor Yellow -NoNewLine
$tokenValid = Test-AwsSsoTokenValid -SsoSession $acct.SsoSession -StartUrl $startUrl
if ($tokenValid) {
    Write-Host "$check active (cached)" -ForegroundColor Green
} else {
    Write-Host "$cross expired or not found" -ForegroundColor Red
    # Verify via CLI before triggering browser (handles clock skew / partial cache)
    $identity = aws sts get-caller-identity --profile $acct.Profile 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Opening browser for SSO login..." -ForegroundColor Cyan
        aws sso login --sso-session $acct.SsoSession
        if ($LASTEXITCODE -ne 0) {
            Write-Error "SSO login failed."
            exit 1
        }
        Write-Host "  $check logged in" -ForegroundColor Green
    } else {
        Write-Host "  $check active (CLI confirmed)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 3. Find instance — check cache first, fall back to Find-Instance on miss
# ---------------------------------------------------------------------------
Write-Host "Finding '$ServerName' in $($acct.Profile)..." -ForegroundColor Yellow
$instance = $null

if (-not $NoCache) {
    $instance = Get-CachedInstance -ServerName $ServerName -Profile $acct.Profile
    if ($instance) {
        Write-Host "  $check $($instance.InstanceId) in $($instance.Region) ($($instance.Az)) [cache]" -ForegroundColor Green
    }
}

if (-not $instance) {
    $instances = & "$PSScriptRoot\Find-Instance.ps1" -ServerName $ServerName -Profile $acct.Profile

    if (@($instances).Count -gt 1) {
        Write-Host "  Multiple instances found:" -ForegroundColor Cyan
        $instances | ForEach-Object { Write-Host "    $($_.InstanceId)  $($_.Name)  $($_.Az)" }
        Write-Host "  Using first: $($instances[0].InstanceId)" -ForegroundColor Yellow
    }

    $instance = @($instances)[0]
    Write-Host "  $check $($instance.InstanceId) in $($instance.Region) ($($instance.Az))" -ForegroundColor Green

    # Write to cache for next time
    Set-CachedInstance -ServerName $ServerName -Profile $acct.Profile `
        -InstanceId $instance.InstanceId -Region $instance.Region
}

# ---------------------------------------------------------------------------
# 4. Pick a free local port (fast TCP probe)
# ---------------------------------------------------------------------------
$port = $LocalPort
$maxPort = [Math]::Max($LocalPort, 33399)
while ($port -le $maxPort) {
    if (-not (Test-PortInUse -Port $port)) { break }
    Write-Verbose "Port $port in use, trying $($port + 1)..."
    $port++
}
if ($port -gt $maxPort) {
    Write-Error "No free local port found in range $LocalPort-$maxPort."
    exit 1
}

# ---------------------------------------------------------------------------
# 5. Start SSM port-forward tunnel in a new, titled pwsh window
# ---------------------------------------------------------------------------
Write-Host "Opening SSM port-forward tunnel (localhost:$port -> $($instance.InstanceId):3389)..." -ForegroundColor Yellow

$tunnelTitle = "SSM RDP tunnel: $($instance.Name) -> localhost:$port"
$tunnelCmd = @"
`$Host.UI.RawUI.WindowTitle = '$tunnelTitle'
Write-Host '$tunnelTitle' -ForegroundColor Cyan
Write-Host 'Close this window to end the RDP session.' -ForegroundColor DarkGray
Write-Host ''
aws ssm start-session ``
    --target '$($instance.InstanceId)' ``
    --document-name 'AWS-StartPortForwardingSession' ``
    --parameters 'portNumber=3389,localPortNumber=$port' ``
    --profile '$($acct.Profile)' ``
    --region '$($instance.Region)'
"@

$tunnelProc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoExit', '-NoProfile', '-Command', $tunnelCmd) -PassThru -WindowStyle Normal
Write-Host "  $check Tunnel window PID $($tunnelProc.Id), title: '$tunnelTitle'" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. Launch mstsc (or print and exit)
# ---------------------------------------------------------------------------
if ($NoLaunch) {
    Write-Host ""
    Write-Host "Tunnel is up. Connect with:" -ForegroundColor Cyan
    Write-Host "  mstsc /v:localhost:$port" -ForegroundColor White
    Write-Host "(Tunnel runs in its own window — close it to end the session.)" -ForegroundColor DarkGray
} else {
    # Poll until the tunnel port accepts a connection (typically 500ms-1s)
    Write-Host "Waiting for tunnel to be ready..." -ForegroundColor Yellow -NoNewLine
    $deadline = ([datetime]::UtcNow).AddSeconds(8)
    $ready = $false
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-PortInUse -Port $port) { $ready = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if ($ready) {
        Write-Host " $check ready" -ForegroundColor Green
    } else {
        Write-Host " (timeout — launching anyway)" -ForegroundColor Yellow
    }

    Write-Host "Launching Remote Desktop (localhost:$port)..." -ForegroundColor Yellow
    Start-Process mstsc -ArgumentList "/v:localhost:$port"
    Write-Host "  $check mstsc launched. Tunnel window stays open until you close it." -ForegroundColor Green
}
