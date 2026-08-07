# Community Development — Docker Service Restart ("Secret Sauce")

## When to Use

When a client's Community Development (ComDev) services are unresponsive, throwing errors, or need a forced restart. Services must be restarted in a specific order to avoid dependency failures.

---

## Environment

| Environment | Account ID | AWS Profile | Managers | Workers |
|---|---|---|---|---|
| **Production** | `911318933593` | `com-prd` | 3 (`pac-prd-ubuntu-mgr1-3`) | 16 (`pac-prd-ubuntu-wkr1-16`) |
| **Staging** | `553030370815` | `com-stg` | 3 (`pac-stg-ubuntu-mgr1-3`) | 16 (`pac-stg-ubuntu-wkr1-16`) |

### Production Instances

| Name | Instance ID | Private IP |
|---|---|---|
| pac-prd-ubuntu-mgr1 | i-04675fa34be989615 | 172.21.2.53 |
| pac-prd-ubuntu-mgr2 | i-023403bd60271213c | 172.21.5.29 |
| pac-prd-ubuntu-mgr3 | i-0da0030c17e66d98b | 172.21.6.242 |
| pac-prd-ubuntu-wkr1 | i-0e17b6587c44ae31f | 172.21.3.236 |
| pac-prd-ubuntu-wkr2 | i-02e1cfff4eed090c6 | 172.21.4.106 |
| pac-prd-ubuntu-wkr3 | i-0f96ed5d4e72c7d78 | 172.21.7.65 |
| pac-prd-ubuntu-wkr4 | i-0dbfa0a84dab4b752 | 172.21.2.144 |
| pac-prd-ubuntu-wkr5 | i-0e5e79d40d2baec37 | 172.21.5.228 |
| pac-prd-ubuntu-wkr6 | i-0cefa8765ea3f500b | 172.21.6.206 |
| pac-prd-ubuntu-wkr7 | i-0399b8804e3b75537 | 172.21.3.215 |
| pac-prd-ubuntu-wkr8 | i-07775df7a0841b2b7 | 172.21.4.179 |
| pac-prd-ubuntu-wkr9 | i-02f0d159fcfc67f52 | 172.21.6.51 |
| pac-prd-ubuntu-wkr10 | i-08dcf09aa1de6c3a4 | 172.21.3.163 |
| pac-prd-ubuntu-wkr11 | i-0dcaf59478f337ef9 | 172.21.5.24 |
| pac-prd-ubuntu-wkr12 | i-09d728b73045401cd | 172.21.7.174 |
| pac-prd-ubuntu-wkr13 | i-025111212f29cf105 | 172.21.2.60 |
| pac-prd-ubuntu-wkr14 | i-0a8b659af589cd020 | 172.21.4.7 |
| pac-prd-ubuntu-wkr15 | i-07dad9f984e8d06ac | 172.21.6.252 |
| pac-prd-ubuntu-wkr16 | i-0d57a8b5295cc60f2 | 172.21.3.85 |

### Staging Instances

| Name | Instance ID | Private IP |
|---|---|---|
| pac-stg-ubuntu-mgr1 | i-0c88d6e321527b1ec | 172.21.19.228 |
| pac-stg-ubuntu-mgr2 | i-03df05a5e073a6cb1 | 172.21.20.228 |
| pac-stg-ubuntu-mgr3 | i-0a1f1e990e9231b6f | 172.21.22.136 |
| pac-stg-ubuntu-wkr1 | i-00b448215b71de095 | 172.21.19.143 |
| pac-stg-ubuntu-wkr2 | i-08c8564977ab57eea | 172.21.21.209 |
| pac-stg-ubuntu-wkr3 | i-088cc7d7148fedc4d | 172.21.23.82 |
| pac-stg-ubuntu-wkr4 | i-03f02aef7a3c1cad2 | 172.21.18.236 |
| pac-stg-ubuntu-wkr5 | i-05b36a7a94dc3295f | 172.21.21.247 |
| pac-stg-ubuntu-wkr6 | i-03de4bf81f0a9f469 | 172.21.23.6 |
| pac-stg-ubuntu-wkr7 | i-0f5d50c05fdac8c68 | 172.21.19.221 |
| pac-stg-ubuntu-wkr8 | i-0264a9b53ffed859d | 172.21.20.183 |
| pac-stg-ubuntu-wkr9 | i-0b0811534ad13abec | 172.21.22.217 |
| pac-stg-ubuntu-wkr10 | i-020c3cb4be22e9966 | 172.21.18.192 |
| pac-stg-ubuntu-wkr11 | i-0aa2e618f1bd27e3e | 172.21.20.94 |
| pac-stg-ubuntu-wkr12 | i-0b1d2ad1d22ff0a19 | 172.21.22.56 |
| pac-stg-ubuntu-wkr13 | i-08a56a66cdbe57259 | 172.21.18.90 |
| pac-stg-ubuntu-wkr14 | i-0f2aac767442e58ec | 172.21.20.238 |
| pac-stg-ubuntu-wkr15 | i-078a9d40521e8ba7c | 172.21.23.237 |
| pac-stg-ubuntu-wkr16 | i-0caf641ef36b430e5 | 172.21.19.66 |

---

## Pre-checks

1. Confirm the affected client code (e.g., `dunw`, `arct`, `apfl`).
2. Confirm environment (production or staging).
3. Ensure you have an active SSM session to a **manager** node (services are managed from managers, not workers).
4. Verify AWS SSO session is active:
   ```bash
   aws sts get-caller-identity --profile com-prd
   ```

---

## Procedure

### 1. Connect to a Manager Node

Connect to any one of the manager instances via SSM:

```powershell
aws ssm start-session --target i-04675fa34be989615 --profile com-prd --region us-east-1
```

Or use the Kiro task **AWS: Connect to Instance** with server name `pac-prd-ubuntu-mgr1`.

### 2. Run the Service Restart Sequence ("Secret Sauce")

Replace `{CLIENT}` with the client's tenant code (e.g., `dunw`, `arct`, `apfl`).

**The order matters.** Restart front-end first, then gateway, then config, then backend services:

```bash
# 1. Portal (front-end)
docker service update tenant_{CLIENT}_workspaces_portal_netcore --force

# 2. Navigation (front-end)
docker service update tenant_{CLIENT}_workspaces_navigation_netcore --force

# 3. Workspaces Web API
docker service update tenant_{CLIENT}_workspaces_webapi --force

# 4. Gateway
docker service update tenant_{CLIENT}_gateway --force

# 5. Global Config (all replicas)
docker service update tenant_{CLIENT}_globalconfig_1 --force
docker service update tenant_{CLIENT}_globalconfig_2 --force
docker service update tenant_{CLIENT}_globalconfig_3 --force
docker service update tenant_{CLIENT}_globalconfig_rest --force

# 6. Common Entity
docker service update tenant_{CLIENT}_commonentity_service --force
docker service update tenant_{CLIENT}_commonentity_rest --force

# 7. ComDev
docker service update tenant_{CLIENT}_comdev_service --force
docker service update tenant_{CLIENT}_comdev_rest --force
```

**One-liner version** (copy-paste, replace `{CLIENT}`):

```bash
docker service update tenant_{CLIENT}_workspaces_portal_netcore --force && \
docker service update tenant_{CLIENT}_workspaces_navigation_netcore --force && \
docker service update tenant_{CLIENT}_workspaces_webapi --force && \
docker service update tenant_{CLIENT}_gateway --force && \
docker service update tenant_{CLIENT}_globalconfig_1 --force && \
docker service update tenant_{CLIENT}_globalconfig_2 --force && \
docker service update tenant_{CLIENT}_globalconfig_3 --force && \
docker service update tenant_{CLIENT}_globalconfig_rest --force && \
docker service update tenant_{CLIENT}_commonentity_service --force && \
docker service update tenant_{CLIENT}_commonentity_rest --force && \
docker service update tenant_{CLIENT}_comdev_service --force && \
docker service update tenant_{CLIENT}_comdev_rest --force
```

### 3. Handle Missing Services

Some services may no longer exist for certain clients. If `docker service update` returns:

```
Error: No such service: tenant_{CLIENT}_<service_name>
```

This is expected — skip that service and continue with the next one. The service was likely decommissioned. Note which services are missing for future reference.

---

## Verification

After all restarts complete, verify services are running:

```bash
docker service ls | grep tenant_{CLIENT}
```

Confirm all listed services show `REPLICAS` as `X/X` (desired count matches running count). Services in `0/X` state need investigation.

---

## Rollback

Docker service updates with `--force` simply restart the existing image. There is no rollback needed — if services were healthy before, they will return to the same state. If a service fails to come back:

1. Check logs: `docker service logs tenant_{CLIENT}_<service_name> --tail 50`
2. Check node placement: `docker service ps tenant_{CLIENT}_<service_name>`
3. Escalate if the container is crash-looping.

---

## Related

- [Bash/magic sauce.sh](../../../Bash/magic%20sauce.sh) — legacy reference script
- [akka-restart.ps1](../../../akka-restart.ps1) — related restart automation
