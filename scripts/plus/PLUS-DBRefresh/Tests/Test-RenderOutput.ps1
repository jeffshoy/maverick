# Throwaway smoke test. Renders one of each variant and asserts a few things.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'PLUSDBRefreshKit.psd1') -Force

function Assert-Contains([string]$haystack,[string]$needle,[string]$label) {
    if ($haystack -notmatch [regex]::Escape($needle)) {
        throw "FAIL [$label]: expected to find '$needle'."
    } else {
        Write-Host "OK   [$label]: found '$needle'." -ForegroundColor Green
    }
}
function Assert-NotContains([string]$haystack,[string]$needle,[string]$label) {
    if ($haystack -match [regex]::Escape($needle)) {
        throw "FAIL [$label]: did not expect to find '$needle'."
    } else {
        Write-Host "OK   [$label]: '$needle' absent as expected." -ForegroundColor Green
    }
}

# --- Case 1: FinPro 5.2 training, full features, no audit log ---
Write-Host "`n=== Case 1: orotrnfinpro (FinPro 5.2 training) ===" -ForegroundColor Cyan
$sql1 = New-PLUSDBRefreshScript -DestDB orotrnfinpro -NoFile
Assert-Contains    $sql1 'Destination DB:    orotrnfinpro'                     '1.header.dest'
Assert-Contains    $sql1 'Source DB:         orofinpro'                         '1.header.src'
Assert-Contains    $sql1 'Product Version:   5.2'                               '1.header.prodver'
Assert-Contains    $sql1 'Template:          Template_SQL_DBDataRefresh_52.txt' '1.header.tpl'
Assert-NotContains $sql1 'STEP 1 - Login / DB-user reconciliation'              '1.no.userrepair'   # 5.2 template does it
Assert-Contains    $sql1 'STEP 2 - Templated data refresh'                      '1.has.template'
Assert-Contains    $sql1 'STEP 3 - SPI_INTEGRATION_DET URL fix'                 '1.has.spi'
Assert-Contains    $sql1 'STEP 4 - Reapply DB User Access'                      '1.has.reapply'
Assert-Contains    $sql1 'STEP 5 - POST-REFRESH VERIFICATION'                   '1.has.verify'
Assert-NotContains $sql1 'STEP 6 - Audit log'                                   '1.no.audit'        # opt-in
Assert-NotContains $sql1 'ZZZ'                                                  '1.no.unreplaced.tokens'

# --- Case 2: FinPlus 5.1 training, exercises user-repair prelude ---
Write-Host "`n=== Case 2: hfmtrnfinplus51 (FinPlus 5.1 training) ===" -ForegroundColor Cyan
$sql2 = New-PLUSDBRefreshScript -DestDB hfmtrnfinplus51 -NoFile
Assert-Contains    $sql2 'Product Version:   5.1'                               '2.header.prodver'
Assert-Contains    $sql2 'Template:          Template_SQL_DBDataRefresh.txt'    '2.header.tpl51'
Assert-Contains    $sql2 'STEP 1 - Login / DB-user reconciliation'              '2.has.userrepair'
Assert-Contains    $sql2 "(N'webuser')"                                          '2.has.webuser.literal'
Assert-Contains    $sql2 "(N'crnuser')"                                          '2.has.crnuser.literal'
Assert-Contains    $sql2 "(N'hfm_webuser')"                                      '2.has.cust_webuser'
Assert-NotContains $sql2 'STEP 3 - SPI_INTEGRATION_DET'                          '2.no.spi'         # only 5.2 finpro
Assert-NotContains $sql2 'STEP 4 - Reapply DB User Access'                       '2.no.reapply'     # finplus, not finpro/compro
Assert-Contains    $sql2 'STEP 5 - POST-REFRESH VERIFICATION'                    '2.has.verify'
Assert-NotContains $sql2 'ZZZ'                                                   '2.no.unreplaced.tokens'

# --- Case 3: ComPro 9.1 training, uses 5.2 template, no SPI fix ---
Write-Host "`n=== Case 3: orotrncompro (ComPro 9.1 training) ===" -ForegroundColor Cyan
$sql3 = New-PLUSDBRefreshScript -DestDB orotrncompro -NoFile
Assert-Contains    $sql3 'Product Version:   9.1'                                '3.header.prodver'
Assert-Contains    $sql3 'Template:          Template_SQL_DBDataRefresh_52.txt'  '3.header.tpl52'
Assert-NotContains $sql3 'STEP 1 - Login / DB-user reconciliation'               '3.no.userrepair'  # 5.2 template
Assert-NotContains $sql3 'STEP 3 - SPI_INTEGRATION_DET'                          '3.no.spi'         # not finpro
Assert-Contains    $sql3 'STEP 4 - Reapply DB User Access'                       '3.has.reapply'    # compro
Assert-NotContains $sql3 'ZZZ'                                                   '3.no.unreplaced.tokens'

# --- Case 4: Switches to suppress sections work ---
Write-Host "`n=== Case 4: -NoSpiFix -NoReapplyUserAccess -NoVerification ===" -ForegroundColor Cyan
$sql4 = New-PLUSDBRefreshScript -DestDB orotrnfinpro -NoSpiFix -NoReapplyUserAccess -NoVerification -NoFile
Assert-NotContains $sql4 'STEP 3 - SPI_INTEGRATION_DET'   '4.no.spi'
Assert-NotContains $sql4 'STEP 4 - Reapply DB User Access' '4.no.reapply'
Assert-NotContains $sql4 'STEP 5 - POST-REFRESH'           '4.no.verify'
Assert-NotContains $sql4 'STEP 6 - Audit log'              '4.no.audit'   # audit block removed entirely

# --- Case 5: clouddba is the stamped change_uid (not $env:USERNAME) ---
Write-Host "`n=== Case 5: change_uid stamp ===" -ForegroundColor Cyan
$sql5 = New-PLUSDBRefreshScript -DestDB orotrnfinpro -NoFile
Assert-Contains    $sql5 'Stamped change_uid: clouddba'    '5.header.changeuid'
Assert-NotContains $sql5 'Requested By:'                   '5.no.requestedby'
Assert-NotContains $sql5 'Ticket:'                         '5.no.ticket'

# --- Case 6: actually write a file and confirm size > 0 ---
Write-Host "`n=== Case 6: -OutputPath round trip ===" -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'PLUSDBRefreshKit-smoke.sql'
$f = New-PLUSDBRefreshScript -DestDB orotrnfinpro -OutputPath $tmp -Force
Write-Host ("OK   [6.write]: $($f.FullName) ($($f.Length) bytes)") -ForegroundColor Green
if ($f.Length -lt 5000) { throw "Rendered file is suspiciously small ($($f.Length) bytes)." }
Remove-Item -LiteralPath $tmp -Force

# --- Case 7: short DestDB rejected ---
Write-Host "`n=== Case 7: parameter validation ===" -ForegroundColor Cyan
try {
    $null = New-PLUSDBRefreshScript -DestDB ab -NoFile
    throw "FAIL: short DestDB should have thrown"
} catch {
    if ($_.Exception.Message -match 'too short') {
        Write-Host 'OK   [7.short.dest]: rejected as expected.' -ForegroundColor Green
    } else { throw }
}

Write-Host "`nALL SMOKE TESTS PASSED." -ForegroundColor Cyan
