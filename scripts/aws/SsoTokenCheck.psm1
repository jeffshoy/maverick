#Requires -Version 5.1

<#
.SYNOPSIS
    Check SSO token validity without invoking the AWS CLI.
.DESCRIPTION
    Reads ~/.aws/sso/cache/*.json (the same files that aws sso login populates) and
    reports whether a token for the given ssoSession/startUrl is present and not
    within 60s of expiry. Mirrors get_sso_access_token() from aws_sso_helper.py.

    Used by Connect-RDP.ps1 to skip the ~700-900ms sts:GetCallerIdentity round-trip
    on runs where the SSO token is already valid.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-AwsSsoTokenValid {
    <#
    .SYNOPSIS
        Return $true if a non-expired cached SSO token exists for the given session.
    .PARAMETER SsoSession
        SSO session name (e.g. 'foundation', 'legacy').
    .PARAMETER StartUrl
        The startUrl for the session (e.g. https://d-9067f93f22.awsapps.com/start).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $SsoSession,

        [Parameter(Mandatory)]
        [string] $StartUrl
    )

    $cacheDir = Join-Path $env:USERPROFILE '.aws\sso\cache'
    if (-not (Test-Path $cacheDir)) { return $false }

    # Sort newest-first so we check the most recent token first
    $files = Get-ChildItem -Path $cacheDir -Filter '*.json' |
             Sort-Object LastWriteTime -Descending

    foreach ($file in $files) {
        try {
            $data = Get-Content $file.FullName -Raw | ConvertFrom-Json

            # Property access must be inside try — under Set-StrictMode -Version Latest
            # accessing a missing property throws rather than returning $null.
            $fileStartUrl = $data.PSObject.Properties['startUrl']
            if (-not $fileStartUrl -or $fileStartUrl.Value -ne $StartUrl) { continue }

            $tokenProp = $data.PSObject.Properties['accessToken']
            if (-not $tokenProp -or -not $tokenProp.Value) { continue }

            $expiryProp = $data.PSObject.Properties['expiresAt']
            if ($expiryProp -and $expiryProp.Value) {
                $expiry = [datetime]::ParseExact(
                    $expiryProp.Value,
                    'yyyy-MM-ddTHH:mm:ssZ',
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeUniversal
                ).ToUniversalTime()
                if ($expiry -le ([datetime]::UtcNow).AddSeconds(60)) { continue }
            }
        } catch { continue }

        return $true
    }

    return $false
}

Export-ModuleMember -Function Test-AwsSsoTokenValid
