name: cis-hardening-windows2022
description: Applies a CIS Benchmark Level 1 starter control set to Windows Server 2022.
schemaVersion: "1.0"

phases:
  - name: build
    steps:
      - name: WindowsUpdate
        action: ExecutePowerShell
        onFailure: Abort
        timeoutSeconds: 3600
        inputs:
          commands:
            - |
              $ErrorActionPreference = "Stop"
              # Patch to current before hardening, not after — hardening should apply to
              # the packages the AMI will actually ship with, not a stale pre-patch state.
              # Loop passes since installing one batch can reveal more updates (e.g. a
              # servicing-stack update must land before the next cumulative update shows
              # up in the search results) — same rationale as the Linux components' retry
              # loops, just via the native Windows Update Agent COM API (no extra module).
              $maxPasses = 5
              for ($pass = 1; $pass -le $maxPasses; $pass++) {
                  Write-Output "=== Windows Update pass $pass/$maxPasses ==="
                  $session = New-Object -ComObject Microsoft.Update.Session
                  $searcher = $session.CreateUpdateSearcher()
                  $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
                  if ($result.Updates.Count -eq 0) {
                      Write-Output "No more updates found — converged after $pass pass(es)."
                      break
                  }
                  Write-Output "Found $($result.Updates.Count) update(s) to install."
                  $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
                  foreach ($u in $result.Updates) {
                      if (-not $u.EulaAccepted) { $u.AcceptEula() }
                      $toInstall.Add($u) | Out-Null
                  }
                  $downloader = $session.CreateUpdateDownloader()
                  $downloader.Updates = $toInstall
                  $downloader.Download() | Out-Null
                  $installer = $session.CreateUpdateInstaller()
                  $installer.Updates = $toInstall
                  $installResult = $installer.Install()
                  Write-Output "Install result code: $($installResult.ResultCode) (2=Succeeded, 3=SucceededWithErrors)"
                  if ($installResult.RebootRequired) {
                      Write-Output "Reboot required before continuing update passes."
                      exit 3010
                  }
              }
              exit 0

      - name: RebootIfWindowsUpdateNeedsIt
        action: Reboot
        onFailure: Abort
        inputs:
          delaySeconds: 30

      - name: WindowsUpdateSecondPass
        action: ExecutePowerShell
        onFailure: Abort
        timeoutSeconds: 3600
        inputs:
          commands:
            - |
              # Post-reboot continuation of the same loop above, in case the first pass
              # exited early for a reboot with more updates still pending behind it.
              $ErrorActionPreference = "Stop"
              $maxPasses = 5
              for ($pass = 1; $pass -le $maxPasses; $pass++) {
                  Write-Output "=== Windows Update post-reboot pass $pass/$maxPasses ==="
                  $session = New-Object -ComObject Microsoft.Update.Session
                  $searcher = $session.CreateUpdateSearcher()
                  $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
                  if ($result.Updates.Count -eq 0) {
                      Write-Output "No more updates found — converged after $pass pass(es)."
                      break
                  }
                  Write-Output "Found $($result.Updates.Count) update(s) to install."
                  $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
                  foreach ($u in $result.Updates) {
                      if (-not $u.EulaAccepted) { $u.AcceptEula() }
                      $toInstall.Add($u) | Out-Null
                  }
                  $downloader = $session.CreateUpdateDownloader()
                  $downloader.Updates = $toInstall
                  $downloader.Download() | Out-Null
                  $installer = $session.CreateUpdateInstaller()
                  $installer.Updates = $toInstall
                  $installResult = $installer.Install()
                  Write-Output "Install result code: $($installResult.ResultCode) (2=Succeeded, 3=SucceededWithErrors)"
                  if ($installResult.RebootRequired) {
                      Write-Output "Reboot still required — subsequent apply/manual pass needed."
                      break
                  }
              }
              exit 0

      - name: RebootAfterSecondPass
        action: Reboot
        onFailure: Abort
        inputs:
          delaySeconds: 30

      - name: ApplyCisControls
        action: ExecutePowerShell
        onFailure: Abort
        timeoutSeconds: 1800
        inputs:
          commands:
            - |
              $ErrorActionPreference = "Stop"

              # Shared control set — also consumed by the validate phase below.
              # Representative CIS Level 1 starter set, not the full ~200-control benchmark.
              # Type: Registry | SecEdit | AuditPol | Service
              $CisControls = @(
                  @{ Id = "1.1.1"; Type = "SecEdit"; Name = "MinimumPasswordLength"; Value = "14" }
                  @{ Id = "1.1.2"; Type = "SecEdit"; Name = "PasswordComplexity"; Value = "1" }
                  @{ Id = "1.1.3"; Type = "SecEdit"; Name = "MaximumPasswordAge"; Value = "90" }
                  @{ Id = "1.1.4"; Type = "SecEdit"; Name = "PasswordHistorySize"; Value = "24" }
                  @{ Id = "1.2.1"; Type = "SecEdit"; Name = "LockoutBadCount"; Value = "5" }
                  @{ Id = "1.2.2"; Type = "SecEdit"; Name = "ResetLockoutCount"; Value = "15" }
                  @{ Id = "1.2.3"; Type = "SecEdit"; Name = "LockoutDuration"; Value = "15" }
                  @{ Id = "2.3.1.1"; Type = "LocalAccount"; Name = "Guest" }
                  @{ Id = "18.3.1"; Type = "Registry"; Path = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"; Name = "SMB1"; Value = 0 }
                  @{ Id = "9.1"; Type = "Registry"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile"; Name = "EnableFirewall"; Value = 1 }
                  @{ Id = "9.2"; Type = "Registry"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\PrivateProfile"; Name = "EnableFirewall"; Value = 1 }
                  @{ Id = "9.3"; Type = "Registry"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile"; Name = "EnableFirewall"; Value = 1 }
                  @{ Id = "18.9.47.1"; Type = "Registry"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection"; Name = "DisableRealtimeMonitoring"; Value = 0 }
                  @{ Id = "18.9.13.1"; Type = "Registry"; Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoDriveTypeAutoRun"; Value = 255 }
                  @{ Id = "2.3.17.1"; Type = "Registry"; Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "EnableLUA"; Value = 1 }
                  @{ Id = "2.3.17.2"; Type = "Registry"; Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "ConsentPromptBehaviorAdmin"; Value = 2 }
                  @{ Id = "2.3.10.1"; Type = "Registry"; Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"; Name = "RestrictAnonymousSAM"; Value = 1 }
                  @{ Id = "18.9.65.3.9.1"; Type = "Registry"; Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"; Name = "UserAuthentication"; Value = 1 }
                  @{ Id = "18.9.65.3.11.1"; Type = "Registry"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"; Name = "MaxIdleTime"; Value = 900000 }
              )

              function Set-CisControl {
                  param($Control)
                  switch ($Control.Type) {
                      "Registry" {
                          if (-not (Test-Path $Control.Path)) {
                              New-Item -Path $Control.Path -Force | Out-Null
                          }
                          New-ItemProperty -Path $Control.Path -Name $Control.Name -Value $Control.Value -PropertyType DWord -Force | Out-Null
                      }
                      "SecEdit" {
                          $cfgPath = "$env:TEMP\secedit-$($Control.Id).cfg"
                          secedit /export /cfg $cfgPath | Out-Null
                          (Get-Content $cfgPath) -replace "^$($Control.Name)\s*=.*", "$($Control.Name) = $($Control.Value)" | Set-Content $cfgPath
                          secedit /configure /db "$env:TEMP\secedit.sdb" /cfg $cfgPath /areas SECURITYPOLICY | Out-Null
                          Remove-Item $cfgPath -ErrorAction SilentlyContinue
                      }
                      "AuditPol" {
                          auditpol /set /subcategory:"$($Control.Name)" /success:enable /failure:enable | Out-Null
                      }
                      "Service" {
                          Set-Service -Name $Control.Name -StartupType $Control.Value
                      }
                      "LocalAccount" {
                          Disable-LocalUser -Name $Control.Name -ErrorAction SilentlyContinue
                      }
                  }
              }

              $failed = @()
              foreach ($control in $CisControls) {
                  try {
                      Set-CisControl -Control $control
                      Write-Output "[APPLIED] $($control.Id)"
                  } catch {
                      Write-Output "[FAILED] $($control.Id): $($_.Exception.Message)"
                      $failed += $control.Id
                  }
              }

              $CisControls | ConvertTo-Json -Depth 5 | Out-File -FilePath "C:\CIS-Controls.json" -Encoding utf8

              if ($failed.Count -gt 0) {
                  Write-Output "One or more CIS controls failed to apply: $($failed -join ', ')"
                  exit 1
              }
              exit 0

      - name: UploadBuildTranscript
        action: ExecutePowerShell
        onFailure: Continue
        inputs:
          commands:
            - |
              $ts = (Get-Date -AsUTC).ToString("yyyyMMddTHHmmssZ")
              aws s3 cp C:\CIS-Controls.json "s3://${logs_bucket}/windows2022/build-controls-$ts.json"

  - name: validate
    steps:
      - name: TestCisControls
        action: ExecutePowerShell
        onFailure: Abort
        timeoutSeconds: 900
        inputs:
          commands:
            - |
              $ErrorActionPreference = "Stop"
              $CisControls = Get-Content "C:\CIS-Controls.json" | ConvertFrom-Json

              function Test-CisControl {
                  param($Control)
                  switch ($Control.Type) {
                      "Registry" {
                          $actual = (Get-ItemProperty -Path $Control.Path -Name $Control.Name -ErrorAction SilentlyContinue).$($Control.Name)
                          return [string]$actual -eq [string]$Control.Value
                      }
                      "SecEdit" {
                          $cfgPath = "$env:TEMP\secedit-validate-$($Control.Id).cfg"
                          secedit /export /cfg $cfgPath | Out-Null
                          $line = Select-String -Path $cfgPath -Pattern "^$($Control.Name)\s*="
                          Remove-Item $cfgPath -ErrorAction SilentlyContinue
                          if (-not $line) { return $false }
                          $actual = ($line.Line -split "=")[1].Trim()
                          return $actual -eq [string]$Control.Value
                      }
                      "AuditPol" {
                          $result = auditpol /get /subcategory:"$($Control.Name)"
                          return ($result -join " ") -match "Success and Failure|Success|Failure"
                      }
                      "Service" {
                          $svc = Get-Service -Name $Control.Name -ErrorAction SilentlyContinue
                          return $svc.StartType -eq $Control.Value
                      }
                      "LocalAccount" {
                          $acct = Get-LocalUser -Name $Control.Name -ErrorAction SilentlyContinue
                          return ($acct -eq $null) -or ($acct.Enabled -eq $false)
                      }
                      default { return $true }
                  }
              }

              $results = @()
              $failed = @()
              foreach ($control in $CisControls) {
                  $pass = Test-CisControl -Control $control
                  $results += [PSCustomObject]@{ Id = $control.Id; Pass = $pass }
                  if (-not $pass) { $failed += $control.Id }
              }

              $results | ConvertTo-Json | Out-File -FilePath "C:\CIS-Validation-Results.json" -Encoding utf8

              if ($failed.Count -gt 0) {
                  Write-Output "CIS controls failed validation: $($failed -join ', ')"
                  exit 1
              }
              Write-Output "All CIS controls validated successfully."
              exit 0

      - name: UploadValidateTranscript
        action: ExecutePowerShell
        onFailure: Continue
        inputs:
          commands:
            - |
              $ts = (Get-Date -AsUTC).ToString("yyyyMMddTHHmmssZ")
              aws s3 cp C:\CIS-Validation-Results.json "s3://${logs_bucket}/windows2022/validate-results-$ts.json"
