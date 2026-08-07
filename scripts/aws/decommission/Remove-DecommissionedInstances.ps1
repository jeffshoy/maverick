#Requires -Version 7.0

<#
.SYNOPSIS
    Terminates EC2 instances that are stopped and have a confirmed COMPLETED final AWS Backup
    recovery point. IRREVERSIBLE — run only after RFC approval.
.DESCRIPTION
    Reads the results CSV produced by New-DecommissionSnapshot.ps1 and terminates only the
    instances whose State column reads 'COMPLETED' AND whose current EC2 state is 'stopped'.
    Any instance missing a verified backup, or still running, is refused — this is the last
    gate before an irreversible action, so it deliberately does not trust the manifest alone
    and re-checks live instance state immediately before terminating.

    This script is intentionally separate from Stop-DecommissionedInstances.ps1 — termination
    must never be reachable via a flag on the stop script. Requires explicit per-instance
    confirmation via ShouldProcess (skip with -Force) and is gated at ConfirmImpact='High'.
.PARAMETER Profile
    AWS CLI profile name from ~/.aws/config (e.g. PALegacyCzp).
.PARAMETER BackupManifestCsv
    Path to the results CSV from New-DecommissionSnapshot.ps1
    (Name,InstanceId,Region,RecoveryPointArn,BackupJobId,State,DeleteAfterDate,Error).
.PARAMETER RfcApproved
    Explicit acknowledgement switch. Must be passed for the script to do anything —
    guards against accidental invocation before the RFC referenced in the manifest's
    DecommissionTicket tag has actually been approved.
.PARAMETER Force
    Skip the per-instance confirmation prompt. Still requires -WhatIf to be absent to act.
.EXAMPLE
    .\Remove-DecommissionedInstances.ps1 -Profile PALegacyCzp -BackupManifestCsv .\decommission-backups-RFC-1234-20260716.csv -RfcApproved -WhatIf
.EXAMPLE
    .\Remove-DecommissionedInstances.ps1 -Profile PALegacyCzp -BackupManifestCsv .\decommission-backups-RFC-1234-20260716.csv -RfcApproved
.NOTES
    Author: CloudOps SRE
    Date: 2026-07-16
    Rollback after termination is only possible by restoring the tagged recovery point
    (RecoveryPointArn column) via AWS Backup restore, within its DeleteAfterDate retention.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Profile,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $BackupManifestCsv,

    [Parameter(Mandatory)]
    [switch] $RfcApproved,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RfcApproved) {
    Write-Error "Refusing to proceed: -RfcApproved was not specified. This is an irreversible action and requires explicit confirmation that the change ticket has been approved."
    exit 1
}

function Invoke-AwsCli {
    param([string[]] $Arguments)
    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI error: $($output -join ' ')"
    }
    return $output
}

$manifest = Import-Csv -Path $BackupManifestCsv
$backedUp = @($manifest | Where-Object { $_.State -eq 'COMPLETED' })
$excluded = @($manifest | Where-Object { $_.State -ne 'COMPLETED' })

if ($excluded.Count -gt 0) {
    Write-Warning "$($excluded.Count) instance(s) excluded — no COMPLETED backup on file:"
    $excluded | Format-Table Name, InstanceId, State, Error -AutoSize
}

if ($backedUp.Count -eq 0) {
    Write-Error "No instances with State=COMPLETED found in manifest. Nothing to terminate."
    exit 1
}

Write-Host "`nRe-checking live state for $($backedUp.Count) backed-up instance(s) before terminating..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[object]]::new()
$eligible = [System.Collections.Generic.List[object]]::new()

foreach ($inst in $backedUp) {
    $liveArgs = @('ec2', 'describe-instances', '--instance-ids', $inst.InstanceId, '--query', 'Reservations[0].Instances[0].State.Name', '--output', 'text', '--profile', $Profile, '--region', $inst.Region)
    try {
        $liveState = (Invoke-AwsCli -Arguments $liveArgs | Out-String).Trim()
    } catch {
        Write-Warning "[$($inst.Name)] could not check live state: $($_.Exception.Message)"
        $results.Add([PSCustomObject]@{ Name = $inst.Name; InstanceId = $inst.InstanceId; Region = $inst.Region; LiveState = 'unknown'; Action = 'SkippedNotStopped'; Error = $_.Exception.Message })
        continue
    }

    if ($liveState -ne 'stopped') {
        Write-Warning "[$($inst.Name)] live state is '$liveState', not 'stopped' — skipping. Run Stop-DecommissionedInstances.ps1 first."
        $results.Add([PSCustomObject]@{ Name = $inst.Name; InstanceId = $inst.InstanceId; Region = $inst.Region; LiveState = $liveState; Action = 'SkippedNotStopped'; Error = $null })
        continue
    }

    $eligible.Add($inst)
}

if ($eligible.Count -eq 0) {
    Write-Error "No instances are both backed up AND currently stopped. Nothing to terminate."
    exit 1
}

Write-Host "`n$($eligible.Count) instance(s) eligible to TERMINATE (backed up + stopped):" -ForegroundColor Red
$eligible | Format-Table Name, InstanceId, Region, RecoveryPointArn, DeleteAfterDate -AutoSize

foreach ($inst in $eligible) {
    $name = $inst.Name
    $instanceId = $inst.InstanceId
    $region = $inst.Region
    $target = "$name ($instanceId, $region) — recovery point: $($inst.RecoveryPointArn)"

    if (-not ($Force -or $PSCmdlet.ShouldProcess($target, 'TERMINATE EC2 instance (irreversible)'))) {
        Write-Host "Skipped: $target" -ForegroundColor Yellow
        continue
    }

    try {
        $termArgs = @('ec2', 'terminate-instances', '--instance-ids', $instanceId, '--profile', $Profile, '--region', $region, '--output', 'json')
        Invoke-AwsCli -Arguments $termArgs | Out-Null
        Write-Host "[$name] termination requested" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ Name = $name; InstanceId = $instanceId; Region = $region; LiveState = 'stopped'; Action = 'TerminateRequested'; Error = $null })
    } catch {
        Write-Warning "[$name] FAILED to terminate: $($_.Exception.Message)"
        $results.Add([PSCustomObject]@{ Name = $name; InstanceId = $instanceId; Region = $region; LiveState = 'stopped'; Action = 'Failed'; Error = $_.Exception.Message })
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize
