#Requires -Version 7.0

<#
.SYNOPSIS
    Provisions a per-client CommDev attachment-migration S3 bucket, IAM user, and IAM policy
    via CloudFormation, then tags the resulting IAM policy.
.DESCRIPTION
    Launches the "CommDev Attachment Migration Infrastructure" CloudFormation stack in the
    legacy-Shared-Services account (343823317319). The stack creates:
      - An S3 bucket (cst-dc-customer-transfer-commdev-<code>) for the client's attachments
      - An IAM managed policy scoped to that bucket only
      - An IAM user (xfer-<code>) attached to the policy, for the client's rclone transfer

    The template only accepts a lowercase ClientCode (enforced by its own AllowedPattern), so
    this script lowercases the code for the template parameter and tag value, and uppercases it
    for the stack name (e.g. client code "gre" -> stack "GRE-CommDev-Attachment-Migration").

    CloudFormation cannot tag AWS::IAM::ManagedPolicy resources, so after the stack reaches
    CREATE_COMPLETE this script tags the policy directly via `aws iam tag-policy`.

    Does NOT create IAM access keys or store credentials anywhere — that remains a manual step
    (console -> IAM user -> Security credentials -> Create access key -> store in NPM) since the
    secret is only ever visible once and should not be captured by unattended automation.
.PARAMETER Region
    AWS region to create the stack in. Must be us-east-1 or us-west-2.
.PARAMETER ClientCode
    Client letter code (any case accepted; normalized to lowercase for the template/tags and
    uppercase for the stack name). Minimum 3 letters, per the template's own validation.
.EXAMPLE
    .\New-CommDevAttachmentBucket.ps1 -Region us-west-2 -ClientCode gre -WhatIf
.EXAMPLE
    .\New-CommDevAttachmentBucket.ps1 -Region us-west-2 -ClientCode gre
.NOTES
    Author: CloudOps SRE
    Date: 2026-07-17
    Account: legacy-Shared-Services (343823317319) — this script has exactly one target account,
    matching the single-purpose nature of the underlying CloudFormation template.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('us-east-1', 'us-west-2')]
    [string] $Region,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z]{3,}$')]
    [string] $ClientCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Profile = 'legacy-Shared-Services'
$AccountId = '343823317319'
$SsoSession = 'legacy'
$TemplateUrl = 'https://commdev-attachment-migration-cloudformation-template.s3.us-west-2.amazonaws.com/CommDev%20Attachment%20Migration%20Infrastructure.yaml'

$codeLower = $ClientCode.ToLower()
$codeUpper = $ClientCode.ToUpper()
$stackName = "$codeUpper-CommDev-Attachment-Migration"
$bucketName = "cst-dc-customer-transfer-commdev-$codeLower"
$userName = "xfer-$codeLower"
$policyName = "cst-dc-customer-transfer-commdev-${codeLower}_policy"
$policyArn = "arn:aws:iam::${AccountId}:policy/$policyName"

function Invoke-AwsCli {
    param([string[]] $Arguments)
    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $joined = $output -join ' '
        if ($joined -match 'expired' -or $joined -match 'Token has expired') {
            Write-Warning "SSO token expired for session '$SsoSession' — refreshing..."
            & aws sso login --sso-session $SsoSession
            if ($LASTEXITCODE -ne 0) {
                throw "SSO refresh failed for session '$SsoSession'."
            }
            $output = & aws @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "AWS CLI error after SSO refresh: $($output -join ' ')"
            }
            return $output
        }
        throw "AWS CLI error: $joined"
    }
    return $output
}

Write-Host "CommDev attachment migration bucket provisioning — client '$codeLower', region $Region, stack '$stackName'" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Idempotency check — refuse to create a duplicate stack for this client
# ---------------------------------------------------------------------------
$existingArgs = @(
    'cloudformation', 'describe-stacks',
    '--stack-name', $stackName,
    '--profile', $Profile,
    '--region', $Region,
    '--query', 'Stacks[0].StackStatus',
    '--output', 'text'
)
$existingOutput = & aws @existingArgs 2>&1
if ($LASTEXITCODE -eq 0) {
    $existingStatus = ($existingOutput | Out-String).Trim()
    if ($existingStatus -ne 'DELETE_COMPLETE') {
        Write-Error "Stack '$stackName' already exists with status '$existingStatus'. Refusing to create a duplicate. Investigate the existing stack before re-running."
        exit 1
    }
} elseif (($existingOutput -join ' ') -notmatch 'does not exist') {
    if (($existingOutput -join ' ') -match 'expired') {
        Write-Warning "SSO token expired for session '$SsoSession' — refreshing..."
        & aws sso login --sso-session $SsoSession
        if ($LASTEXITCODE -ne 0) { throw "SSO refresh failed for session '$SsoSession'." }
    } else {
        throw "AWS CLI error checking for existing stack: $($existingOutput -join ' ')"
    }
}

if (-not $PSCmdlet.ShouldProcess($stackName, "Create CloudFormation stack (ClientCode=$codeLower) in $Region")) {
    Write-Host "`nWhatIf: would create stack '$stackName' with parameter ClientCode=$codeLower in $Region." -ForegroundColor Yellow
    Write-Host "WhatIf: would then tag policy '$policyArn' with:" -ForegroundColor Yellow
    Write-Host "  cst_environment=prd, cst_product_line=pa_communitydevelopment, cst_tenant=$codeLower," -ForegroundColor Yellow
    Write-Host "  cst_cost_center=centralsquare_cloud_infrastructure, cst_tenancy=single," -ForegroundColor Yellow
    Write-Host "  cst_compliance_domain=pci, cst_purpose='CommDevPremise to Cloud Migration'" -ForegroundColor Yellow
    Write-Host "`nWhatIf: resulting resources would be:" -ForegroundColor Yellow
    Write-Host "  Bucket: $bucketName" -ForegroundColor Yellow
    Write-Host "  IAM User: $userName" -ForegroundColor Yellow
    Write-Host "  IAM Policy: $policyArn" -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Create the stack
# ---------------------------------------------------------------------------
$createArgs = @(
    'cloudformation', 'create-stack',
    '--stack-name', $stackName,
    '--template-url', $TemplateUrl,
    '--parameters', "ParameterKey=ClientCode,ParameterValue=$codeLower",
    '--capabilities', 'CAPABILITY_NAMED_IAM',
    '--profile', $Profile,
    '--region', $Region,
    '--query', 'StackId',
    '--output', 'text'
)
$stackId = (Invoke-AwsCli -Arguments $createArgs | Out-String).Trim()
Write-Host "Stack creation started: $stackId" -ForegroundColor Gray

# ---------------------------------------------------------------------------
# Poll for CREATE_COMPLETE
# ---------------------------------------------------------------------------
$terminalFailureStates = @('CREATE_FAILED', 'ROLLBACK_COMPLETE', 'ROLLBACK_FAILED', 'ROLLBACK_IN_PROGRESS')
$inProgressStates = @('CREATE_IN_PROGRESS')
$timeoutAt = (Get-Date).AddMinutes(15)
$status = 'CREATE_IN_PROGRESS'

while ($status -in $inProgressStates -and (Get-Date) -lt $timeoutAt) {
    Start-Sleep -Seconds 15
    $statusArgs = @(
        'cloudformation', 'describe-stacks',
        '--stack-name', $stackName,
        '--profile', $Profile,
        '--region', $Region,
        '--query', 'Stacks[0].StackStatus',
        '--output', 'text'
    )
    $status = (Invoke-AwsCli -Arguments $statusArgs | Out-String).Trim()
    Write-Host "  Status: $status" -ForegroundColor Gray
}

if ($status -eq 'CREATE_IN_PROGRESS') {
    Write-Error "Timed out after 15 minutes still CREATE_IN_PROGRESS for stack '$stackName'. Check the CloudFormation console."
    exit 1
}

if ($status -in $terminalFailureStates -or $status -ne 'CREATE_COMPLETE') {
    Write-Warning "Stack '$stackName' ended in status '$status'. Fetching failure events..."
    $eventsArgs = @(
        'cloudformation', 'describe-stack-events',
        '--stack-name', $stackName,
        '--profile', $Profile,
        '--region', $Region,
        '--query', "StackEvents[?contains(ResourceStatus, 'FAILED')].[LogicalResourceId,ResourceStatus,ResourceStatusReason]",
        '--output', 'table'
    )
    $events = Invoke-AwsCli -Arguments $eventsArgs
    Write-Host ($events | Out-String)
    exit 1
}

Write-Host "[OK] Stack '$stackName' reached CREATE_COMPLETE." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Tag the IAM policy — CloudFormation cannot tag AWS::IAM::ManagedPolicy
# ---------------------------------------------------------------------------
Write-Host "`nTagging IAM policy $policyArn ..." -ForegroundColor Cyan
$tagArgs = @(
    'iam', 'tag-policy',
    '--policy-arn', $policyArn,
    '--tags',
    'Key=cst_environment,Value=prd',
    'Key=cst_product_line,Value=pa_communitydevelopment',
    "Key=cst_tenant,Value=$codeLower",
    'Key=cst_cost_center,Value=centralsquare_cloud_infrastructure',
    'Key=cst_tenancy,Value=single',
    'Key=cst_compliance_domain,Value=pci',
    'Key=cst_purpose,Value=CommDevPremise to Cloud Migration',
    '--profile', $Profile,
    '--region', $Region
)
Invoke-AwsCli -Arguments $tagArgs | Out-Null
Write-Host "[OK] Policy tagged." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Provisioned ===" -ForegroundColor Cyan
Write-Host "Bucket:      $bucketName"
Write-Host "IAM User:    $userName"
Write-Host "IAM Policy:  $policyArn"
Write-Host "`n[ACTION REQUIRED] This script does NOT create IAM access keys." -ForegroundColor Yellow
Write-Host "Manually create an access key for '$userName' in the IAM console" -ForegroundColor Yellow
Write-Host "(Security credentials -> Create access key -> Other) and store both" -ForegroundColor Yellow
Write-Host "the access key and secret key in NPM under the client's folder as 'xfer-$codeLower'" -ForegroundColor Yellow
Write-Host "with comment 'IAM Account for migrating CommDev Attachments'." -ForegroundColor Yellow
Write-Host "The secret key is only shown once — capture it before leaving that screen." -ForegroundColor Yellow

exit 0
