#Requires -Version 7.0

<#
.SYNOPSIS
    Native PowerShell account resolver — mirrors aws_sso_helper.py:resolve_account().
.DESCRIPTION
    Reads accounts.json and fuzzy-matches an informal name to one account entry using
    the same 6-tier logic as the Python helper. Used by Connect-RDP.ps1 to avoid
    the ~1-2s Python/boto3/tkinter cold-start cost. The Python helper remains the
    canonical implementation for all other callers.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$_AccountsJson = $null
$_Registry     = $null

function _Get-Registry {
    if ($script:_Registry) { return $script:_Registry }
    $jsonPath = Join-Path $PSScriptRoot '..\..\aws-configs\accounts.json'
    $jsonPath = (Resolve-Path $jsonPath).Path
    $script:_Registry = Get-Content $jsonPath -Raw | ConvertFrom-Json
    return $script:_Registry
}

function _Normalize([string]$s) {
    return ($s -replace '[\s\-_]', '').ToLower()
}

function _TokenScore([string]$query, [string]$candidate) {
    # Split on hyphen, underscore, and camelCase boundaries
    $qt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    ($query -split '(?<=[a-z])(?=[A-Z])|[-_]') | ForEach-Object { if ($_) { $null = $qt.Add($_) } }
    $ct = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    ($candidate -split '(?<=[a-z])(?=[A-Z])|[-_]') | ForEach-Object { if ($_) { $null = $ct.Add($_) } }
    $intersection = $qt | Where-Object { $ct.Contains($_) }
    return @($intersection).Count
}

function Resolve-AwsAccount {
    <#
    .SYNOPSIS
        Fuzzy-resolve an account name to a single account entry from accounts.json.
    .PARAMETER Name
        Account name or nickname (e.g. PLUS, PALegacyPlus, SharedServices).
    .PARAMETER NonInteractive
        When set, throw on genuine ambiguity instead of prompting with Read-Host.
        Use for pipeline/CI callers or any context where stdin is not a terminal.
    .OUTPUTS
        PSCustomObject with Name, AccountId, Org, SsoSession, Profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [switch] $NonInteractive
    )

    $registry = _Get-Registry
    $accounts = $registry.accounts

    # Tier 1: exact
    $candidates = @($accounts | Where-Object { $_.name -ceq $Name })

    # Tier 2: case-insensitive exact
    if (-not $candidates) {
        $candidates = @($accounts | Where-Object { $_.name -ieq $Name })
    }

    # Tier 3: normalized nickname
    if (-not $candidates) {
        $normInput = _Normalize $Name
        $candidates = @($accounts | Where-Object {
            $nicknames = @($_.nicknames)
            ($nicknames | Where-Object { (_Normalize $_) -eq $normInput }) -ne $null
        })
    }

    # Tier 4: normalized application
    if (-not $candidates) {
        $normInput = _Normalize $Name
        $candidates = @($accounts | Where-Object {
            $apps = @($_.applications)
            ($apps | Where-Object { (_Normalize $_) -eq $normInput }) -ne $null
        })
    }

    # Tier 5: CI substring
    if (-not $candidates) {
        $candidates = @($accounts | Where-Object { $_.name -ilike "*$Name*" })
    }

    # Tier 6: token overlap
    if (-not $candidates) {
        $scored = $accounts | ForEach-Object {
            [PSCustomObject]@{ Account = $_; Score = (_TokenScore $Name $_.name) }
        } | Sort-Object -Descending Score
        if ($scored -and $scored[0].Score -gt 0) {
            $top = $scored[0].Score
            $candidates = @($scored | Where-Object { $_.Score -eq $top } | ForEach-Object { $_.Account })
        }
    }

    if (-not $candidates) {
        $suggestions = ($accounts | Sort-Object { -1 * ($Name.ToLower().ToCharArray() | Where-Object { $_.name.ToLower().Contains([string]$_) }).Count } |
            Select-Object -First 5 | ForEach-Object { $_.name }) -join ', '
        throw "No account found matching '$Name'. Did you mean: $suggestions?"
    }

    if ($candidates.Count -eq 1) {
        return _ToOutput $candidates[0]
    }

    # Same display name, Foundation wins silently
    $names = @($candidates | ForEach-Object { $_.name } | Select-Object -Unique)
    if ($names.Count -eq 1) {
        $foundation = @($candidates | Where-Object { $_.org -eq 'foundation' })
        if ($foundation.Count -eq 1) { return _ToOutput $foundation[0] }
    }

    # Genuine ambiguity — fail fast in non-interactive contexts, prompt otherwise
    $listing = ($candidates | ForEach-Object {
        "{0} ({1}, {2})" -f $_.name, $_.org, $_.accountId
    }) -join '; '

    if ($NonInteractive) {
        throw "Multiple accounts match '$Name': $listing. Provide a more specific name (e.g., PALegacyPlus instead of PLUS)."
    }

    Write-Host ""
    Write-Host "Multiple accounts match '$Name'. Choose one:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $c = $candidates[$i]
        Write-Host ("  [{0}] {1,-40} {2,-12} {3}" -f ($i + 1), $c.name, $c.org, $c.accountId)
    }
    while ($true) {
        $raw = Read-Host "Enter number"
        if ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -ge 0 -and $idx -lt $candidates.Count) {
                return _ToOutput $candidates[$idx]
            }
        }
        Write-Host "  Invalid — enter 1–$($candidates.Count)." -ForegroundColor Yellow
    }
}

function _ToOutput($a) {
    return [PSCustomObject]@{
        Name      = $a.name
        AccountId = $a.accountId
        Org       = $a.org
        SsoSession = $a.ssoSession
        Profile   = $a.profile
    }
}

Export-ModuleMember -Function Resolve-AwsAccount
