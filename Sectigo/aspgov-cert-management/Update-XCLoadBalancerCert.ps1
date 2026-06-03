#Requires -Version 5.1

<#
.SYNOPSIS
    Finds all F5 XC load balancers referencing a given certificate and updates them to a new certificate.
.DESCRIPTION
    Queries HTTP and TCP load balancers in the specified namespace. Any LB whose config
    references OldCertName (exact match, not substring) is updated in-place to reference
    NewCertName. Stops on the first failed PUT so the fleet is never partially updated
    without operator awareness.

    Always run with -WhatIf first to see the full list of affected LBs before committing.
.PARAMETER Tenant
    F5 XC tenant hostname, e.g. centralsquare.console.ves.volterra.io
.PARAMETER Namespace
    XC namespace to search, e.g. centralsquare-llc
.PARAMETER OldCertName
    Exact name of the certificate to find and replace.
.PARAMETER NewCertName
    Exact name of the replacement certificate.
.EXAMPLE
    .\Update-XCLoadBalancerCert.ps1 `
        -Tenant centralsquare.console.ves.volterra.io `
        -Namespace centralsquare-llc `
        -OldCertName aspgov-wildcard-2026 `
        -NewCertName aspgov-wildcard-2026pt2 `
        -WhatIf
.NOTES
    Author: ksloan
    Date:   2026-05-29
    Token:  Set env var XC_API_TOKEN before running.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Tenant = 'centralsquare.console.ves.volterra.io',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Namespace = 'centralsquare-llc',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OldCertName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $NewCertName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Resolve API token ---
$resolvedToken = $env:XC_API_TOKEN
if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
    throw 'No API token found. Set the XC_API_TOKEN environment variable before running.'
}

if ($OldCertName -eq $NewCertName) {
    throw 'OldCertName and NewCertName are the same. Nothing to do.'
}

$headers = @{
    'Authorization' = "APIToken $resolvedToken"
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json'
}

# LB types to check: label for display, list endpoint suffix, item endpoint suffix
$lbTypes = @(
    [pscustomobject]@{ Label = 'HTTP'; ListPath = 'http_loadbalancers'; ItemPath = 'http_loadbalancers' }
    [pscustomobject]@{ Label = 'TCP';  ListPath = 'tcp_loadbalancers';  ItemPath = 'tcp_loadbalancers'  }
)

function Invoke-XCApi {
    param(
        [string] $Method,
        [string] $Uri,
        [string] $Body
    )
    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $headers
        ErrorAction = 'Stop'
    }
    if ($Body) { $params['Body'] = $Body }
    try {
        return Invoke-RestMethod @params
    } catch [System.Net.WebException] {
        $statusCode   = [int]$_.Exception.Response.StatusCode
        $responseBody = ''
        try {
            $stream       = $_.Exception.Response.GetResponseStream()
            $reader       = [System.IO.StreamReader]::new($stream)
            $responseBody = $reader.ReadToEnd()
        } catch {}
        throw "HTTP $statusCode from $Uri - $responseBody"
    }
}

# Regex: match OldCertName only when enclosed in JSON string delimiters,
# and only when NOT already followed by the suffix that makes it NewCertName.
# This prevents a partial double-replace if the script is run twice.
$escapedOld = [regex]::Escape($OldCertName)
$escapedNew = [regex]::Escape($NewCertName)
# Negative lookahead: match OldCertName not followed by what would make it NewCertName already
$suffix     = $NewCertName.Substring($OldCertName.Length)   # e.g. "pt2"
$escapedSuffix = [regex]::Escape($suffix)
$certPattern   = "(?<=[`"])" + $escapedOld + "(?!" + $escapedSuffix + ")(?=[`"])"

$totalFound   = 0
$totalUpdated = 0
$totalErrors  = 0

foreach ($lbType in $lbTypes) {
    $listUrl = "https://$Tenant/api/config/namespaces/$Namespace/$($lbType.ListPath)"
    Write-Verbose "Listing $($lbType.Label) LBs from $listUrl"

    $listResponse = Invoke-XCApi -Method Get -Uri $listUrl
    $items = $listResponse.items

    if (-not $items -or $items.Count -eq 0) {
        Write-Host "[$($lbType.Label)] No load balancers found in namespace '$Namespace'." -ForegroundColor DarkGray
        continue
    }

    Write-Host "[$($lbType.Label)] Found $($items.Count) load balancer(s). Checking for cert '$OldCertName'..." -ForegroundColor Cyan

    foreach ($item in $items) {
        $lbName  = $item.name
        $itemUrl = "https://$Tenant/api/config/namespaces/$Namespace/$($lbType.ItemPath)/$lbName"

        Write-Verbose "  Fetching full spec for '$lbName'..."
        $fullSpec    = Invoke-XCApi -Method Get -Uri $itemUrl
        $specJson    = $fullSpec | ConvertTo-Json -Depth 50 -Compress

        # Check if OldCertName appears anywhere in this LB's config
        if ($specJson -notmatch $certPattern) {
            Write-Verbose "  [$lbName] No reference to '$OldCertName'. Skipping."
            continue
        }

        $totalFound++
        $updatedJson = $specJson -replace $certPattern, $NewCertName

        if ($WhatIfPreference) {
            Write-Host "  [WhatIf] [$($lbType.Label)] $lbName" -ForegroundColor Yellow
            Write-Host "           Cert '$OldCertName' -> '$NewCertName'" -ForegroundColor Yellow
        } else {
            if ($PSCmdlet.ShouldProcess("$($lbType.Label) LB '$lbName'", "Update cert '$OldCertName' -> '$NewCertName'")) {
                Write-Host "  Updating [$($lbType.Label)] $lbName ..." -ForegroundColor Cyan
                try {
                    Invoke-XCApi -Method Put -Uri $itemUrl -Body $updatedJson | Out-Null
                    Write-Host "  OK: $lbName updated." -ForegroundColor Green
                    $totalUpdated++
                } catch {
                    Write-Error "  FAILED: $lbName - $_"
                    $totalErrors++
                    # Stop immediately to avoid partial fleet update
                    Write-Host "Halting after first failure. $totalUpdated LB(s) updated before this error." -ForegroundColor Red
                    exit 1
                }
            }
        }
    }
}

Write-Host ''
if ($WhatIfPreference) {
    Write-Host "[WhatIf] $totalFound load balancer(s) would be updated. No changes made." -ForegroundColor Yellow
} else {
    Write-Host "Done. $totalFound found, $totalUpdated updated, $totalErrors errors." -ForegroundColor Cyan
}
