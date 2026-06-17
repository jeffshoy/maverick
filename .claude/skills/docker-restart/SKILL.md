---
name: docker-restart
description: Restart Docker Swarm tenant services on a PAC manager node in prod or staging, in the required order. Use when a tenant's services need to be cycled (e.g. "/docker-restart acme prod", "/docker-restart xyz staging", "restart docker services for tenant abc in prod").
---

# /docker-restart — Restart Docker Swarm tenant services for a PAC tenant

Restart all services for a given tenant client code on the correct PAC manager node, in the required order. Each `docker service update --force --detach=false` blocks until that service has fully converged before the next one starts — no separate polling needed.

## Parsing

Extract two values from the user's input:

- **`$client`** — the tenant/customer code (e.g. `acme`, `xyz`). Normalize to lowercase.
- **`$env`** — `prod` or `staging`. Accept aliases: `prd`/`production` → `prod`; `stg`/`stage` → `staging`.

If either is missing or ambiguous, ask before proceeding.

## Account and target resolution

| Environment | AWS profile | SSM target tag |
|---|---|---|
| `prod` | `PROD-PA-Pro` | `pac-prd-ubuntu-mgr1` |
| `staging` | `Pa-pro-staging` | `pac-stg-ubuntu-mgr1` |

Both accounts use SSO session `foundation`. Always target `mgr1` — no instance ID lookup needed.

## SSO token handling

If any `aws` command fails with output containing `expired` or `Token has expired`:
1. Run: `pwsh -NoProfile -Command "aws sso login --sso-session foundation --profile <profile>"`
2. Retry the original command.

## Pre-flight

Print a confirmation block and **wait for the user to confirm** before proceeding:

```
Tenant:      <client>
Environment: <prod|staging>
Account:     <profile>
Manager:     pac-<prd|stg>-ubuntu-mgr1
Services to restart (in order):
  1. tenant_<client>_gateway
  2. tenant_<client>_globalconfig_1
  3. tenant_<client>_globalconfig_2
  4. tenant_<client>_globalconfig_3
  5. tenant_<client>_globalconfig_rest
  6. tenant_<client>_commonentity_rest
  7. tenant_<client>_comdev_service
  8. tenant_<client>_comdev_rest
  + docker system prune -af
  + docker service ls | grep <client>

Proceed? (yes/no)
```

## Execution

Write the script below to `C:\Temp\docker-restart-<client>-<env>.ps1` using the Write tool, then execute it via the Bash tool:

```powershell
pwsh -NoProfile -File "C:\Temp\docker-restart-<client>-<env>.ps1"
```

If the Bash tool returns exit code 5 or a Git bash init error, tell the user to run the command above in their terminal and paste the output back.

### Script template

```powershell
$targetName = "pac-<prd|stg>-ubuntu-mgr1"
$profile    = "<profile>"
$region     = "us-east-1"
$client     = "<client>"

function Invoke-SSMCommand {
    param([string]$Cmd, [int]$TimeoutSeconds = 420)

    $paramsJson = (@{ commands = @($Cmd) } | ConvertTo-Json -Compress)

    $commandId = aws ssm send-command `
        --targets "Key=tag:Name,Values=$targetName" `
        --document-name AWS-RunShellScript `
        --parameters $paramsJson `
        --timeout-seconds $TimeoutSeconds `
        --profile $profile `
        --region $region `
        --query Command.CommandId `
        --output text

    if ($LASTEXITCODE -ne 0) { throw "send-command failed for: $Cmd" }

    Write-Host "  Command ID: $commandId" -ForegroundColor DarkGray

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 30)
    do {
        Start-Sleep -Seconds 5
        $inv = aws ssm list-command-invocations `
            --command-id $commandId `
            --details `
            --profile $profile `
            --region $region | ConvertFrom-Json |
            Select-Object -ExpandProperty CommandInvocations |
            Select-Object -First 1
    } while ($inv.Status -in @('Pending','InProgress','Delayed') -and (Get-Date) -lt $deadline)

    return $inv
}

$services = @(
    'gateway',
    'globalconfig_1',
    'globalconfig_2',
    'globalconfig_3',
    'globalconfig_rest',
    'commonentity_rest',
    'comdev_service',
    'comdev_rest'
)

$step = 1
foreach ($svc in $services) {
    $serviceName = "tenant_${client}_${svc}"
    Write-Host "`n[$step/10] Restarting $serviceName ..." -ForegroundColor Cyan

    $result = Invoke-SSMCommand "sudo docker service update $serviceName --force --detach=false"

    $stderr = $result.CommandPlugins[0].Output
    if ($result.Status -ne 'Success') {
        if ($stderr -match 'not found') {
            Write-Host "  SKIPPED: $serviceName (not found on this swarm)" -ForegroundColor Yellow
        } else {
            Write-Host "FAILED: $serviceName (SSM status: $($result.Status))" -ForegroundColor Red
            Write-Host $stderr
            exit 1
        }
    } else {
        Write-Host "  Converged: $serviceName" -ForegroundColor Green
    }
    $step++
}

Write-Host "`n[$step/10] Running docker system prune -af ..." -ForegroundColor Cyan
$prune = Invoke-SSMCommand "sudo docker system prune -af" -TimeoutSeconds 120
if ($prune.CommandPlugins[0].Output) { Write-Host $prune.CommandPlugins[0].Output }
$step++

Write-Host "`n[$step/10] docker service ls | grep $client" -ForegroundColor Cyan
$ls = Invoke-SSMCommand "sudo docker service ls | grep $client" -TimeoutSeconds 30
Write-Host "`n--- Service status for tenant '$client' ---"
Write-Host $ls.CommandPlugins[0].Output
```

## Reporting

After execution, report:
- Each service and whether it converged, was skipped (not found), or failed
- Full output of `docker service ls | grep <client>`
- Any error output from failed steps

## Examples

- `/docker-restart acme prod`     → client=`acme`, profile=`PROD-PA-Pro`, target=`pac-prd-ubuntu-mgr1`
- `/docker-restart xyz staging`   → client=`xyz`, profile=`Pa-pro-staging`, target=`pac-stg-ubuntu-mgr1`
- "restart docker services for tenant abc in prod" → client=`abc`, profile=`PROD-PA-Pro`
