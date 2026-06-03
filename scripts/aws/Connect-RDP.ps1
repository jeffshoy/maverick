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

    [switch] $NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$check = [char]::ConvertFromUtf32(0x2714)
$cross = [char]::ConvertFromUtf32(0x274C)

# ---------------------------------------------------------------------------
# 1. Resolve account
# ---------------------------------------------------------------------------
Write-Host "Resolving account '$Account'..." -ForegroundColor Yellow
$acct = & "$PSScriptRoot\Resolve-AwsAccount.ps1" -Name $Account
Write-Host "  $check $($acct.Name) ($($acct.Org), $($acct.AccountId))" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. SSO login check — uses the RESOLVED session, not hardcoded foundation
# ---------------------------------------------------------------------------
Write-Host "Checking SSO session ($($acct.SsoSession))... " -ForegroundColor Yellow -NoNewLine
$identity = aws sts get-caller-identity --profile $acct.Profile 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "$cross expired" -ForegroundColor Red
    Write-Host "Opening browser for SSO login..." -ForegroundColor Cyan
    aws sso login --sso-session $acct.SsoSession
    if ($LASTEXITCODE -ne 0) {
        Write-Error "SSO login failed."
        exit 1
    }
    Write-Host "  $check logged in" -ForegroundColor Green
} else {
    Write-Host "$check active" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 3. Find instance
# ---------------------------------------------------------------------------
Write-Host "Finding '$ServerName' in $($acct.Profile)..." -ForegroundColor Yellow
$instances = & "$PSScriptRoot\Find-Instance.ps1" -ServerName $ServerName -Profile $acct.Profile

if (@($instances).Count -gt 1) {
    Write-Host "  Multiple instances found:" -ForegroundColor Cyan
    $instances | ForEach-Object { Write-Host "    $($_.InstanceId)  $($_.Name)  $($_.Az)" }
    Write-Host "  Using first: $($instances[0].InstanceId)" -ForegroundColor Yellow
}

$instance = @($instances)[0]
Write-Host "  $check $($instance.InstanceId) in $($instance.Region) ($($instance.Az))" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Pick a free local port
# ---------------------------------------------------------------------------
$port = $LocalPort
$maxPort = [Math]::Max($LocalPort, 33399)
while ($port -le $maxPort) {
    $inUse = (Test-NetConnection -ComputerName localhost -Port $port -WarningAction SilentlyContinue -ErrorAction SilentlyContinue).TcpTestSucceeded
    if (-not $inUse) { break }
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
# Build a single inline command: set window title, then exec the AWS CLI.
# The tunnel inherits the pwsh window; closing the window kills the session.
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
Start-Sleep -Seconds 3

if ($NoLaunch) {
    Write-Host ""
    Write-Host "Tunnel is up. Connect with:" -ForegroundColor Cyan
    Write-Host "  mstsc /v:localhost:$port" -ForegroundColor White
    Write-Host "(Tunnel runs in its own window — close it to end the session.)" -ForegroundColor DarkGray
} else {
    Write-Host "Launching Remote Desktop (localhost:$port)..." -ForegroundColor Yellow
    Start-Process mstsc -ArgumentList "/v:localhost:$port"
    Write-Host "  $check mstsc launched. Tunnel window stays open until you close it." -ForegroundColor Green
}
