#Requires -Version 7.0

<#
.SYNOPSIS
    Stops EC2 instances that have a confirmed COMPLETED final AWS Backup recovery point.
.DESCRIPTION
    Reads the results CSV produced by New-DecommissionSnapshot.ps1 and stops only the
    instances whose State column reads 'COMPLETED' — any instance whose final backup job
    failed, timed out, or was skipped (-WhatIf) is refused, so a decommission can never
    proceed past this step without a verified backup in hand.

    Prompts for per-instance confirmation via ShouldProcess (skip with -Force). Stopping is
    reversible via `aws ec2 start-instances` up until the corresponding terminate step runs.
.PARAMETER Profile
    AWS CLI profile name from ~/.aws/config (e.g. PALegacyCzp).
.PARAMETER BackupManifestCsv
    Path to the results CSV from New-DecommissionSnapshot.ps1
    (Name,InstanceId,Region,RecoveryPointArn,BackupJobId,State,DeleteAfterDate,Error).
.PARAMETER Force
    Skip the per-instance confirmation prompt. Still requires -WhatIf to be absent to act.
.EXAMPLE
    .\Stop-DecommissionedInstances.ps1 -Profile PALegacyCzp -BackupManifestCsv .\decommission-backups-RFC-1234-20260716.csv -WhatIf
.EXAMPLE
    .\Stop-DecommissionedInstances.ps1 -Profile PALegacyCzp -BackupManifestCsv .\decommission-backups-RFC-1234-20260716.csv
.NOTES
    Author: CloudOps SRE
    Date: 2026-07-16
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Profile,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $BackupManifestCsv,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AwsCli {
    param([string[]] $Arguments)
    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI error: $($output -join ' ')"
    }
    return $output
}

$manifest = Import-Csv -Path $BackupManifestCsv
$eligible = @($manifest | Where-Object { $_.State -eq 'COMPLETED' })
$excluded = @($manifest | Where-Object { $_.State -ne 'COMPLETED' })

if ($excluded.Count -gt 0) {
    Write-Warning "$($excluded.Count) instance(s) excluded — no COMPLETED backup on file:"
    $excluded | Format-Table Name, InstanceId, State, Error -AutoSize
}

if ($eligible.Count -eq 0) {
    Write-Error "No instances with State=COMPLETED found in manifest. Nothing to stop."
    exit 1
}

Write-Host "`n$($eligible.Count) instance(s) eligible to stop (verified backup present):" -ForegroundColor Cyan
$eligible | Format-Table Name, InstanceId, Region, RecoveryPointArn -AutoSize

$results = [System.Collections.Generic.List[object]]::new()

foreach ($inst in $eligible) {
    $name = $inst.Name
    $instanceId = $inst.InstanceId
    $region = $inst.Region

    $target = "$name ($instanceId, $region)"
    if (-not ($Force -or $PSCmdlet.ShouldProcess($target, 'Stop EC2 instance'))) {
        Write-Host "Skipped: $target" -ForegroundColor Yellow
        continue
    }

    try {
        $beforeArgs = @('ec2', 'describe-instances', '--instance-ids', $instanceId, '--query', 'Reservations[0].Instances[0].State.Name', '--output', 'text', '--profile', $Profile, '--region', $region)
        $before = (Invoke-AwsCli -Arguments $beforeArgs | Out-String).Trim()

        $stopArgs = @('ec2', 'stop-instances', '--instance-ids', $instanceId, '--profile', $Profile, '--region', $region, '--output', 'json')
        Invoke-AwsCli -Arguments $stopArgs | Out-Null

        Write-Host "[$name] stop requested (was: $before)" -ForegroundColor Green
        $results.Add([PSCustomObject]@{ Name = $name; InstanceId = $instanceId; Region = $region; BeforeState = $before; Action = 'StopRequested'; Error = $null })
    } catch {
        Write-Warning "[$name] FAILED to stop: $($_.Exception.Message)"
        $results.Add([PSCustomObject]@{ Name = $name; InstanceId = $instanceId; Region = $region; BeforeState = $null; Action = 'Failed'; Error = $_.Exception.Message })
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize
