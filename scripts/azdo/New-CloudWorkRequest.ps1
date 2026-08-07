#Requires -Version 7.0

<#
.SYNOPSIS
    Creates an Azure DevOps "Cloud Work Request" work item.
.DESCRIPTION
    Drives the Azure DevOps REST API directly via `az rest` rather than the `az devops`/
    `az boards` CLI extension — that extension cannot be installed in this environment
    (`az extension add --name azure-devops` segfaults; the CLI's own bundled Python
    segfaults on a bare `pip --version`, confirming a corrupted local Python, unrelated to
    network or auth). `az rest` reuses the existing `az login` token against AzDo's fixed
    resource GUID (499b84ac-1321-427f-aa17-267ca6975798), so no extension is required.

    The JSON Patch body is written to a temp file and passed via `az rest --body @<file>`,
    the same file-based approach `New-PR.ps1` uses to avoid inline multi-line/escaping
    problems on the command line.

    Intended caller: the /pagerduty-workitem skill, after it has parsed a pasted page,
    asked the user for Priority, and gotten explicit go-ahead. This script does not ask
    anything itself — Priority has no default specifically so callers are forced to have
    already asked.
.PARAMETER Title
    Work item title.
.PARAMETER DescriptionHtml
    Work item description, as HTML.
.PARAMETER Priority
    1-4 (1=must fix, 4=unimportant). Azure DevOps' only always-required field on this work
    item type. No default — must be supplied explicitly.
.PARAMETER Tags
    Tags to apply. Defaults to the three standing tags used for paged CloudOps work.
.PARAMETER AreaPath
    Area path. Defaults to Cloud-PA\CloudOps.
.PARAMETER IterationPath
    Iteration path. Defaults to the current calendar quarter (Cloud-PA\<year> Q<quarter>),
    so it advances automatically without a hardcoded default going stale.
.PARAMETER AssignedTo
    UPN/email to assign the work item to. No default — must be supplied explicitly by the
    caller so work items aren't silently assigned to whoever wrote this script.
.PARAMETER Org
    Azure DevOps organization URL.
.PARAMETER Project
    Azure DevOps project name.
.EXAMPLE
    .\New-CloudWorkRequest.ps1 -Title "LogicMonitor critical Alert - Ping loss" -DescriptionHtml "<div>Host: ILECROSSESDRDS</div>" -Priority 3 -AssignedTo "jane.doe@centralsquare.com" -WhatIf
.EXAMPLE
    .\New-CloudWorkRequest.ps1 -Title "LogicMonitor critical Alert - Ping loss" -DescriptionHtml "<div>Host: ILECROSSESDRDS</div>" -Priority 3 -AssignedTo "jane.doe@centralsquare.com"
.NOTES
    Author: CloudOps SRE
    Date: 2026-07-18
    Auth: Azure AD via `az login` — not an AWS SSO profile, so CLAUDE.md's AWS SSO
    self-recovery rule does not apply. This script fails fast with a clear message if
    `az account show` indicates no active session, rather than attempting a silent
    interactive login.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if ($_.Length -gt 255) {
            throw "Title is $($_.Length) characters — Azure DevOps' System.Title field has a 255-character limit (TF401324). Shorten it and move the full text into -DescriptionHtml instead."
        }
        $true
    })]
    [string] $Title,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DescriptionHtml,

    [Parameter(Mandatory)]
    [ValidateSet(1, 2, 3, 4)]
    [int] $Priority,

    [string[]] $Tags = @('Daily Ops', 'PagerDuty', 'unplanned'),

    [string] $AreaPath = 'Cloud-PA\CloudOps',

    [string] $IterationPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $AssignedTo,

    [string] $Org = 'https://dev.azure.com/psgov',

    [string] $Project = 'Cloud-PA'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AzDoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'

function Test-AzLogin {
    $null = & az account show --output none 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Not logged into Azure ('az account show' failed). Run 'az login' and re-run this script."
        exit 1
    }
}

function Invoke-AzDoRest {
    param(
        [string] $Method,
        [string] $Url,
        [string] $BodyFile
    )
    # az on Windows resolves to az.cmd, invoked via cmd.exe — an unquoted '&' in the URL
    # (e.g. from '$expand=fields&api-version=7.1') is treated as a command separator unless
    # the argument is wrapped in literal double quotes before PowerShell hands it off.
    $azArgs = @(
        'rest', '--method', $Method,
        '--url', "`"$Url`"",
        '--resource', $AzDoResourceId,
        '--output', 'json'
    )
    if ($BodyFile) {
        $azArgs += @('--body', "`"@$BodyFile`"", '--headers', 'Content-Type=application/json-patch+json')
    }
    $tempErr = [System.IO.Path]::GetTempFileName()
    try {
        $output = & az @azArgs 2>$tempErr | Out-String
        $exitCode = $LASTEXITCODE
        $errOutput = Get-Content $tempErr -Raw -ErrorAction SilentlyContinue
    } finally {
        Remove-Item $tempErr -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0) {
        throw "az rest $Method $Url failed (exit $exitCode):`n$errOutput`n$output"
    }
    return $output
}

if (-not $IterationPath) {
    $now = Get-Date
    $quarter = [int][Math]::Ceiling($now.Month / 3.0)
    $IterationPath = "Cloud-PA\$($now.Year) Q$quarter"
}

Test-AzLogin

$tagString = $Tags -join '; '

$patchBody = @(
    @{ op = 'add'; path = '/fields/System.Title'; value = $Title }
    @{ op = 'add'; path = '/fields/System.Description'; value = $DescriptionHtml }
    @{ op = 'add'; path = '/fields/System.AreaPath'; value = $AreaPath }
    @{ op = 'add'; path = '/fields/System.IterationPath'; value = $IterationPath }
    @{ op = 'add'; path = '/fields/System.AssignedTo'; value = $AssignedTo }
    @{ op = 'add'; path = '/fields/System.Tags'; value = $tagString }
    @{ op = 'add'; path = '/fields/Microsoft.VSTS.Common.Priority'; value = $Priority }
)

Write-Host "Creating Cloud Work Request — '$Title'" -ForegroundColor Cyan
Write-Host "  Area:      $AreaPath"
Write-Host "  Iteration: $IterationPath"
Write-Host "  Assigned:  $AssignedTo"
Write-Host "  Tags:      $tagString"
Write-Host "  Priority:  $Priority"

if (-not $PSCmdlet.ShouldProcess($Title, "Create Cloud Work Request in $Project")) {
    Write-Host "`nWhatIf: would POST the following JSON Patch body to create the work item:" -ForegroundColor Yellow
    ($patchBody | ConvertTo-Json -Depth 5) | Write-Host -ForegroundColor Yellow
    exit 0
}

$bodyFile = [System.IO.Path]::GetTempFileName()
try {
    ($patchBody | ConvertTo-Json -Depth 5) | Set-Content -Path $bodyFile -Encoding utf8NoBOM

    $createUrl = "$Org/$Project/_apis/wit/workitems/`$Cloud%20Work%20Request?api-version=7.1"
    $response = Invoke-AzDoRest -Method 'post' -Url $createUrl -BodyFile $bodyFile
} finally {
    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}

$workItem = $response | ConvertFrom-Json
$webUrl = $workItem._links.html.href

Write-Host "`nWork Item $($workItem.id): $webUrl" -ForegroundColor Green

Write-Output $workItem
exit 0
