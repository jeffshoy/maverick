#Requires -Version 7.0

<#
.SYNOPSIS
    Triggers a final, explicitly-retained AWS Backup on-demand job for each instance in a
    decommission manifest.
.DESCRIPTION
    This account already runs tag-driven AWS Backup plans (hourly/daily/weekly/monthly/yearly)
    against any resource tagged cst_backup_policy=prod, targeting a KMS-encrypted "BackupVault"
    in each region via IAM role Backup-Role. Rather than creating an untracked, unmanaged AMI
    via raw `ec2 create-image` (which would sit outside that system and need its own bespoke
    retention/cleanup), this script uses `aws backup start-backup-job` to create one additional,
    on-demand recovery point per instance in the SAME vault, with an explicit
    Lifecycle.DeleteAfterDays override (default 180 / ~6 months) and IdempotencyToken so re-runs
    are safe.

    Polls each backup job until it reaches COMPLETED or a terminal failure state.

    Writes a results CSV (Name,InstanceId,Region,RecoveryPointArn,State,DeleteAfterDate,Error)
    that is the required input to Stop-DecommissionedInstances.ps1 and
    Remove-DecommissionedInstances.ps1 — those scripts refuse to act on any instance not present
    here with State=COMPLETED.

    This script only creates backup jobs; it does not stop or terminate anything.
.PARAMETER Profile
    AWS CLI profile name from ~/.aws/config (e.g. PALegacyCzp).
.PARAMETER InstanceListCsv
    Path to a CSV with columns: Name,InstanceId,Region.
.PARAMETER TicketRef
    Ticket/change reference recorded in the recovery point tags and the results filename.
.PARAMETER BackupVaultName
    Name of the existing AWS Backup vault to target. Defaults to 'BackupVault' (confirmed
    present in both us-east-1 and us-west-2 for this account).
.PARAMETER IamRoleArn
    IAM role AWS Backup assumes to take the backup. Defaults to the account's existing
    'Backup-Role', already used by every scheduled plan in this account.
.PARAMETER RetentionDays
    Days to retain the on-demand recovery point before it is eligible for deletion by AWS
    Backup's own lifecycle management. Defaults to 180 (~6 months).
.PARAMETER OutputDirectory
    Directory to write the results CSV to. Defaults to the script's own directory.
.EXAMPLE
    .\New-DecommissionSnapshot.ps1 -Profile PALegacyCzp -InstanceListCsv .\pc2gwb-decommission-2026-07-16.csv -TicketRef RFC-1234 -WhatIf
.EXAMPLE
    .\New-DecommissionSnapshot.ps1 -Profile PALegacyCzp -InstanceListCsv .\pc2gwb-decommission-2026-07-16.csv -TicketRef RFC-1234
.NOTES
    Author: CloudOps SRE
    Date: 2026-07-16
    These instances are tagged cst_backup_policy=prod and already have scheduled recovery
    points (hourly/daily/weekly/monthly/yearly). This script adds one more, ticket-tagged,
    explicitly-retained point rather than relying on the schedule alone — a monthly/yearly
    point may already exceed 6 months of retention, but this guarantees it per instance
    regardless of where each one happened to be in its own backup cadence.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Profile,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $InstanceListCsv,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $TicketRef,

    [string] $BackupVaultName = 'BackupVault',

    [string] $IamRoleArn = 'arn:aws:iam::797320052894:role/Backup-Role',

    [ValidateRange(1, 3650)]
    [int] $RetentionDays = 180,

    [string] $OutputDirectory = $PSScriptRoot
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

$instances = Import-Csv -Path $InstanceListCsv
if (-not $instances -or $instances.Count -eq 0) {
    Write-Error "No rows found in manifest '$InstanceListCsv'."
    exit 1
}

foreach ($required in 'Name', 'InstanceId', 'Region') {
    if (-not ($instances[0].PSObject.Properties.Name -contains $required)) {
        Write-Error "Manifest is missing required column '$required'."
        exit 1
    }
}

$deleteAfterDate = (Get-Date).AddDays($RetentionDays).ToString('yyyy-MM-dd')
$runStamp = Get-Date -Format 'yyyyMMddHHmmss'
$results = [System.Collections.Generic.List[object]]::new()

Write-Host "Decommission backup run — ticket $TicketRef, profile $Profile, vault $BackupVaultName, $($instances.Count) instance(s), retain $RetentionDays days (until ~$deleteAfterDate)" -ForegroundColor Cyan

foreach ($inst in $instances) {
    $name = $inst.Name
    $instanceId = $inst.InstanceId
    $region = $inst.Region
    $resourceArn = "arn:aws:ec2:${region}:$(($IamRoleArn -split ':')[4]):instance/$instanceId"
    $idempotencyToken = "decom-$TicketRef-$instanceId-$runStamp"

    Write-Host "`n[$name] ($instanceId, $region)" -ForegroundColor White

    $record = [PSCustomObject]@{
        Name             = $name
        InstanceId       = $instanceId
        Region           = $region
        RecoveryPointArn = $null
        BackupJobId      = $null
        State            = $null
        DeleteAfterDate  = $deleteAfterDate
        Error            = $null
    }

    if (-not $PSCmdlet.ShouldProcess("$name ($instanceId)", "Start on-demand AWS Backup job, retain $RetentionDays days")) {
        $record.State = 'SkippedWhatIf'
        $results.Add($record)
        continue
    }

    try {
        $startArgs = @(
            'backup', 'start-backup-job',
            '--backup-vault-name', $BackupVaultName,
            '--resource-arn', $resourceArn,
            '--iam-role-arn', $IamRoleArn,
            '--idempotency-token', $idempotencyToken,
            '--lifecycle', "DeleteAfterDays=$RetentionDays",
            '--recovery-point-tags', "DecommissionTicket=$TicketRef,DeleteAfter=$deleteAfterDate,SourceInstanceName=$name",
            '--query', 'BackupJobId',
            '--output', 'text',
            '--profile', $Profile,
            '--region', $region
        )
        $jobId = (Invoke-AwsCli -Arguments $startArgs | Out-String).Trim()
        $record.BackupJobId = $jobId
        Write-Host "  Started backup job $jobId — polling for completion..." -ForegroundColor Gray

        # CREATED is a real, non-terminal state AWS Backup jobs can sit in before transitioning
        # to RUNNING (e.g. while queued behind another job against the same resource) — it must
        # stay in this set or the loop exits after one poll and misreports an in-progress job as
        # failed.
        $inProgressStates = @('CREATED', 'PENDING', 'RUNNING', 'ABORTING')
        $timeoutAt = (Get-Date).AddMinutes(30)
        $state = 'CREATED'
        $job = $null
        while ($state -in $inProgressStates -and (Get-Date) -lt $timeoutAt) {
            Start-Sleep -Seconds 20
            $describeArgs = @(
                'backup', 'describe-backup-job',
                '--backup-job-id', $jobId,
                '--profile', $Profile,
                '--region', $region,
                '--output', 'json'
            )
            $job = (Invoke-AwsCli -Arguments $describeArgs | Out-String) | ConvertFrom-Json
            $state = $job.State
            Write-Host "  State: $state" -ForegroundColor Gray
        }

        $record.State = $state
        if ($state -eq 'COMPLETED') {
            $record.RecoveryPointArn = $job.RecoveryPointArn
            Write-Host "  [OK] $($job.RecoveryPointArn)" -ForegroundColor Green
        } elseif ($state -in $inProgressStates) {
            $record.Error = 'Timed out after 30 minutes still in progress'
            Write-Warning "  [$name] timed out waiting for backup job $jobId to complete (last state: $state)"
        } else {
            $record.Error = "Job ended in state '$state': $($job.StatusMessage)"
            Write-Warning "  [$name] backup job $jobId ended in state '$state': $($job.StatusMessage)"
        }
    } catch {
        $record.State = 'Failed'
        $record.Error = $_.Exception.Message
        Write-Warning "  [$name] FAILED: $($_.Exception.Message)"
    }

    $results.Add($record)
}

$runDate = Get-Date -Format 'yyyyMMdd'
$outputPath = Join-Path $OutputDirectory "decommission-backups-$TicketRef-$runDate.csv"
$results | Export-Csv -Path $outputPath -NoTypeInformation

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$results | Format-Table Name, InstanceId, State, RecoveryPointArn, Error -AutoSize
Write-Host "Results written to: $outputPath" -ForegroundColor Cyan

$failed = @($results | Where-Object { $_.State -ne 'COMPLETED' -and $_.State -ne 'SkippedWhatIf' })
if ($failed.Count -gt 0) {
    Write-Warning "$($failed.Count) instance(s) did NOT reach 'COMPLETED' — they must be excluded from any stop/terminate step until resolved."
    exit 1
}

exit 0
