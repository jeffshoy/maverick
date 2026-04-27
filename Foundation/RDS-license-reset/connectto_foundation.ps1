<#
.SYNOPSIS
    Connect to any server in the Foundation OU via SSM interactive session.
    Triggers SSO browser login if session is expired.

.EXAMPLES
    .\connectto_foundation.ps1 -s ARCT-PTRKRD001
    .\connectto_foundation.ps1 -s ARCT-PTRKRD001 -r us-west-2
    .\connectto_foundation.ps1 -s ARCT-PTRKRD001 -p PALegacyFinEntANCO
#>

param (
    [Alias('s')]
    [Parameter(Mandatory)][string] $server_name,
    [Alias('p')]
    [string] $aws_profile = "PALegacySharedServices",
    [Alias('r')]
    [string] $aws_region = "us-east-1"
)

$ErrorActionPreference = "Stop"
$check = [char]::ConvertFromUtf32(0x2714)
$cross = [char]::ConvertFromUtf32(0x274C)

# --- SSO Login ---
Write-Host "Checking SSO session... " -ForegroundColor Yellow -NoNewLine
$callerIdentity = aws sts get-caller-identity --profile $aws_profile --region $aws_region 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "$cross expired" -ForegroundColor Red
    Write-Host "Opening browser for SSO login..." -ForegroundColor Cyan
    aws sso login --sso-session foundation
    if ($LASTEXITCODE -ne 0) {
        Write-Host "SSO login failed. Exiting." -ForegroundColor Red
        exit 1
    }
    Write-Host "SSO login successful $check" -ForegroundColor Green
} else {
    Write-Host "active $check" -ForegroundColor Green
}

# --- Get Instance ID ---
Write-Host "Looking up '$server_name' in $aws_region... " -ForegroundColor Yellow -NoNewLine
$instance_id = aws ec2 describe-instances `
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=$server_name" `
    --output text --query "Reservations[*].Instances[*].InstanceId" `
    --profile $aws_profile --region $aws_region

if (-not $instance_id) {
    Write-Host "$cross NOT FOUND" -ForegroundColor Red
    exit 1
}
Write-Host "$instance_id $check" -ForegroundColor Green

# --- Start SSM Session ---
Write-Host "Opening SSM session..." -ForegroundColor Yellow
aws ssm start-session --target $instance_id --profile $aws_profile --region $aws_region
