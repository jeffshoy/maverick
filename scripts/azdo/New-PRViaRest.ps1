#Requires -Version 7.0

<#
.SYNOPSIS
    Create an Azure DevOps pull request via the REST API directly (no az CLI extension).
.DESCRIPTION
    Drives the Azure DevOps Git Pull Requests REST API directly via `az rest`, the same
    pattern New-CloudWorkRequest.ps1 uses for work items — `az repos pr create` requires
    the `azure-devops` CLI extension, and `az extension add --name azure-devops` crashes
    with an access violation (0xC0000005) in this environment's bundled az CLI Python/pip,
    confirming a corrupted local install rather than a network/auth issue. `az rest` reuses
    the existing `az login` token against AzDo's fixed resource GUID
    (499b84ac-1321-427f-aa17-267ca6975798), so no extension is required.

    Org, project, and repository name are all derived automatically from the current
    directory's git remote — run this from inside the target repo, same as New-PR.ps1.

    Prefer this script over New-PR.ps1 in this environment until the az CLI's bundled
    Python is repaired; New-PR.ps1 will keep failing on the missing extension until then.
.PARAMETER Title
    The PR title.
.PARAMETER DescriptionFile
    Path to a markdown file containing the PR body. Read as a single string and posted
    as the PR's description field.
.PARAMETER SourceBranch
    Branch to merge from. Defaults to the current git branch.
.PARAMETER TargetBranch
    Branch to merge into. Defaults to 'master' — most legacy/Terraform repos in this org
    (pasp-tenants, ppt-tenants) default to master, not main. Verify with
    `git remote show origin | grep 'HEAD branch'` if unsure.
.EXAMPLE
    pwsh scripts\azdo\New-PRViaRest.ps1 `
        -Title "Increase lee comdev user_volume_size from 200GB to 260GB (disk capacity)" `
        -DescriptionFile "C:\Temp\pr-lee-user_volume_size-20260723.md" `
        -TargetBranch master
.NOTES
    Author: CloudOps SRE
    Date: 2026-07-23
    Auth: Azure AD via `az login` — not an AWS SSO profile.
#>

[CmdletBinding(SupportsShouldProcess)]
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
    [string] $TargetBranch = 'master'
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
    # is treated as a command separator unless wrapped in literal double quotes.
    $azArgs = @(
        'rest', '--method', $Method,
        '--url', "`"$Url`"",
        '--resource', $AzDoResourceId,
        '--output', 'json'
    )
    if ($BodyFile) {
        $azArgs += @('--body', "`"@$BodyFile`"", '--headers', 'Content-Type=application/json')
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

if (-not (Test-Path -LiteralPath $DescriptionFile -PathType Leaf)) {
    Write-Error "Description file not found: $DescriptionFile"
    exit 1
}
$description = [System.IO.File]::ReadAllText($DescriptionFile)
if ($description.Trim().Length -eq 0) {
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

# Derive org/project/repo from the current directory's git remote, e.g.
# https://psgov@dev.azure.com/psgov/Cloud/_git/pasp-tenants
$remoteUrl = git remote get-url origin 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Could not determine git remote 'origin'. Run this from inside the target repo."
    exit 1
}
if ($remoteUrl -notmatch 'dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+?)(?:\.git)?$') {
    Write-Error "Could not parse Azure DevOps org/project/repo from remote URL: $remoteUrl"
    exit 1
}
$org     = $Matches[1]
$project = $Matches[2]
$repo    = $Matches[3]

Test-AzLogin

$patchBody = @{
    sourceRefName = "refs/heads/$SourceBranch"
    targetRefName = "refs/heads/$TargetBranch"
    title         = $Title
    description   = $description
}

Write-Host "Creating PR — '$Title'" -ForegroundColor Cyan
Write-Host "  Org:     $org"
Write-Host "  Project: $project"
Write-Host "  Repo:    $repo"
Write-Host "  Branch:  $SourceBranch -> $TargetBranch"

if (-not $PSCmdlet.ShouldProcess($Title, "Create PR in $project/$repo")) {
    Write-Host "`nWhatIf: would POST the following JSON body to create the PR:" -ForegroundColor Yellow
    ($patchBody | ConvertTo-Json -Depth 5) | Write-Host -ForegroundColor Yellow
    exit 0
}

$bodyFile = [System.IO.Path]::GetTempFileName()
try {
    ($patchBody | ConvertTo-Json -Depth 5) | Set-Content -Path $bodyFile -Encoding utf8NoBOM

    $createUrl = "https://dev.azure.com/$org/$project/_apis/git/repositories/$repo/pullrequests?api-version=7.1"
    $response = Invoke-AzDoRest -Method 'post' -Url $createUrl -BodyFile $bodyFile
} finally {
    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}

$pr = $response | ConvertFrom-Json
$webUrl = "https://dev.azure.com/$org/$project/_git/$repo/pullrequest/$($pr.pullRequestId)"

Write-Host "`nPR $($pr.pullRequestId): $webUrl" -ForegroundColor Green

Write-Output $pr
exit 0
