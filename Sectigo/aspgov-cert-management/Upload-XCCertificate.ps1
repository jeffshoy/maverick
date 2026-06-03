#Requires -Version 5.1

<#
.SYNOPSIS
    Uploads a TLS certificate to F5 Distributed Cloud (XC) via REST API.
.DESCRIPTION
    Reads a certificate (.crt), chain (.crt), and unencrypted private key (.key),
    concatenates and base64-encodes them, then POSTs a new certificate object to
    the F5 XC API. Supports WhatIf (dry-run) to preview the payload without uploading.
.PARAMETER Tenant
    F5 XC tenant hostname, e.g. centralsquare.console.ves.volterra.io
.PARAMETER Namespace
    XC namespace to create the certificate in, e.g. centralsquare-llc
.PARAMETER CertName
    Name for the certificate object in XC, e.g. aspgov-wildcard-2026pt2
.PARAMETER CertFile
    Path to the leaf certificate PEM file (.crt)
.PARAMETER ChainFile
    Path to the certificate chain/intermediate PEM file (.crt)
.PARAMETER KeyFile
    Path to the unencrypted private key PEM file (.key)
.PARAMETER ApiToken
    F5 XC API token. Do NOT pass on the command line in shared environments;
    use -ApiTokenSecure or set env var XC_API_TOKEN instead.
.PARAMETER ApiTokenSecure
    API token as a SecureString (preferred over -ApiToken).
.EXAMPLE
    .\Upload-XCCertificate.ps1 `
        -Tenant centralsquare.console.ves.volterra.io `
        -Namespace centralsquare-llc `
        -CertName aspgov-wildcard-2026pt2 `
        -CertFile .\certs\2026_pt2\aspgov_2026pt2_cert.crt `
        -ChainFile .\certs\2026_pt2\aspgov_2026pt2_chain.crt `
        -KeyFile .\certs\2026_pt2\aspgov_2026pt2_key_unencrypted.key `
        -WhatIf
.NOTES
    Author: ksloan
    Date:   2026-05-29
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
    [string] $CertName = 'aspgov-wildcard-2026pt2',

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $CertFile,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $ChainFile,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $KeyFile,

    [Parameter()]
    [string] $ApiToken,

    [Parameter()]
    [System.Security.SecureString] $ApiTokenSecure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Resolve API token (never log it) ---
$resolvedToken = $null

if ($ApiTokenSecure) {
    $resolvedToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiTokenSecure)
    )
} elseif ($ApiToken) {
    Write-Warning 'Passing API tokens via -ApiToken is discouraged. Use -ApiTokenSecure or XC_API_TOKEN env var.'
    $resolvedToken = $ApiToken
} elseif ($env:XC_API_TOKEN) {
    Write-Verbose 'Resolved API token from environment variable XC_API_TOKEN.'
    $resolvedToken = $env:XC_API_TOKEN
} else {
    throw 'No API token provided. Supply -ApiTokenSecure, -ApiToken, or set the XC_API_TOKEN environment variable.'
}

if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
    throw 'API token resolved to an empty value. Aborting.'
}

# --- Read and validate cert files ---
Write-Verbose 'Reading certificate files...'

$certPem  = Get-Content -Raw -Path $CertFile  -ErrorAction Stop
$chainPem = Get-Content -Raw -Path $ChainFile -ErrorAction Stop
$keyPem   = Get-Content -Raw -Path $KeyFile   -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($certPem))  { throw 'CertFile was empty or unreadable.' }
if ([string]::IsNullOrWhiteSpace($chainPem)) { throw 'ChainFile was empty or unreadable.' }
if ([string]::IsNullOrWhiteSpace($keyPem))   { throw 'KeyFile was empty or unreadable.' }

if ($keyPem -match 'ENCRYPTED') {
    throw 'Key file appears to be encrypted. Provide the unencrypted key (aspgov_2026pt2_key_unencrypted.key).'
}

# XC expects cert + chain concatenated, then base64-encoded
$fullCertPem = $certPem.TrimEnd() + "`n" + $chainPem.TrimEnd() + "`n"
$certB64     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($fullCertPem))
$keyB64      = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($keyPem.TrimEnd() + "`n"))

Write-Verbose "Certificate PEM length: $($fullCertPem.Length) chars"
Write-Verbose "Key PEM length        : $($keyPem.Length) chars"

# --- Build request payload ---
$payload = [ordered]@{
    metadata = [ordered]@{
        name      = $CertName
        namespace = $Namespace
    }
    spec = [ordered]@{
        certificate_url = "string:///$certB64"
        private_key     = [ordered]@{
            clear_secret_info = [ordered]@{
                url = "string:///$keyB64"
            }
        }
    }
}

$payloadJson = $payload | ConvertTo-Json -Depth 10 -Compress
$apiUrl      = "https://$Tenant/api/config/namespaces/$Namespace/certificates"

# --- WhatIf / dry-run ---
if ($WhatIfPreference) {
    Write-Host ''
    Write-Host "[WhatIf] Would POST to  : $apiUrl" -ForegroundColor Cyan
    Write-Host "[WhatIf] Cert name      : $CertName"
    Write-Host "[WhatIf] Namespace      : $Namespace"
    Write-Host "[WhatIf] Cert+chain len : $($fullCertPem.Length) chars"
    Write-Host "[WhatIf] Key length     : $($keyPem.Length) chars"
    Write-Host '[WhatIf] No changes made.' -ForegroundColor Yellow
    return
}

# --- Upload ---
if ($PSCmdlet.ShouldProcess($apiUrl, "POST new TLS certificate '$CertName'")) {
    Write-Verbose "Uploading certificate '$CertName' to $apiUrl ..."

    $headers = @{
        'Authorization' = "APIToken $resolvedToken"
        'Content-Type'  = 'application/json'
        'Accept'        = 'application/json'
    }

    try {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $apiUrl `
            -Headers $headers `
            -Body $payloadJson `
            -ErrorAction Stop

        Write-Host "SUCCESS: Certificate '$CertName' created in namespace '$Namespace'." -ForegroundColor Green
        Write-Verbose "Response: $($response | ConvertTo-Json -Depth 5)"
    } catch [System.Net.WebException] {
        $statusCode   = [int]$_.Exception.Response.StatusCode
        $responseBody = ''
        try {
            $stream       = $_.Exception.Response.GetResponseStream()
            $reader       = [System.IO.StreamReader]::new($stream)
            $responseBody = $reader.ReadToEnd()
        } catch {}
        Write-Error "Upload failed. HTTP $statusCode - $responseBody"
        exit 1
    } catch {
        Write-Error "Upload failed: $($_.Exception.Message)"
        exit 1
    }
}
