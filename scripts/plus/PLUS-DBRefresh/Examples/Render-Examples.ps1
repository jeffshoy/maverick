<#
    Render-Examples.ps1

    Hands-on examples for PLUSDBRefreshKit. Each block is independent -
    copy any one of them and adapt the parameters.

    Run this file as-is and it will render a small set of preview scripts
    to PLUSDBRefreshKit\Output\ that you can inspect without ever
    connecting to SQL.
#>

# Locate and import the module relative to this script.
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PLUSDBRefreshKit.psd1') -Force

Write-Host "Module loaded from $moduleRoot" -ForegroundColor Cyan
Write-Host ''

# -------------------------------------------------------------------------
# 1) Simplest case - training refresh, all defaults.
# -------------------------------------------------------------------------
$f = New-PLUSDBRefreshScript -DestDB orotrnfinpro -Force
Write-Host "1) FinPro 5.2 training refresh:`n   $($f.FullName)`n" -ForegroundColor Green

# -------------------------------------------------------------------------
# 2) FinPlus 5.1 training refresh - exercises the user-repair prelude.
# -------------------------------------------------------------------------
$f = New-PLUSDBRefreshScript -DestDB hfmtrnfinplus51 -Force
Write-Host "2) FinPlus 5.1 training refresh (with sp_adduser prelude):`n   $($f.FullName)`n" -ForegroundColor Green

# -------------------------------------------------------------------------
# 3) ComPro 9.1 training refresh - uses the 5.2 template, no SPI fix.
# -------------------------------------------------------------------------
$f = New-PLUSDBRefreshScript -DestDB orotrncompro -Force
Write-Host "3) ComPro 9.1 training refresh:`n   $($f.FullName)`n" -ForegroundColor Green

# -------------------------------------------------------------------------
# 4) Stage refresh from prod (DestDB and SrcDB are the same).
# -------------------------------------------------------------------------
$f = New-PLUSDBRefreshScript -DestDB orofinpro -SrcDB orofinpro -Force
Write-Host "4) Stage refresh from prod:`n   $($f.FullName)`n" -ForegroundColor Green

# -------------------------------------------------------------------------
# 5) Render to a string (no file) for ad-hoc review or piping.
# -------------------------------------------------------------------------
$sql = New-PLUSDBRefreshScript -DestDB orotrnfinpro -NoFile
Write-Host "5) In-memory render: $($sql.Length) characters" -ForegroundColor Green
Write-Host "   First 6 lines:" -ForegroundColor DarkGray
($sql -split "`r?`n" | Select-Object -First 6) | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
Write-Host ''

# -------------------------------------------------------------------------
# 6) Verbose mode - shows product / template detection details.
# -------------------------------------------------------------------------
$null = New-PLUSDBRefreshScript -DestDB orotrnfinpro -Force -Verbose

Write-Host ''
Write-Host 'Done. All rendered files are in:' -ForegroundColor Cyan
Write-Host ('   ' + (Join-Path $moduleRoot 'Output')) -ForegroundColor Cyan
