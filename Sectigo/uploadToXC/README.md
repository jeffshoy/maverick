# F5 Distributed Cloud (XC) Certificate Management

PowerShell scripts for managing TLS certificates in the F5 XC Console via REST API.
Useful when the GUI upload fails with a network error or when bulk cert updates are needed.

## Prerequisites

- PowerShell 5.1+
- An F5 XC API token (see below)
- Certificate files in PEM format (`.crt` and unencrypted `.key`)

## Generating an API Token

1. Log into `https://centralsquare.console.ves.volterra.io`
2. Click your account icon (top-right) → **Account Settings**
3. Left sidebar → **Credentials** → **Add Credentials**
4. Set **Credential Type** to `API Token`, give it a name and expiry (90 days recommended)
5. Click **Generate** — copy the token immediately, it is only shown once

Set the token in your session before running either script:

```powershell
$env:XC_API_TOKEN = "paste-token-here"
```

---

## Upload-XCCertificate.ps1

Uploads a new TLS certificate object to F5 XC. Use this when creating a cert for the first time.

### Certificate files needed

| File | Description |
|------|-------------|
| `*_cert.crt` | Leaf/end-entity certificate (PEM) |
| `*_chain.crt` | Intermediate/chain certificate (PEM) |
| `*_key_unencrypted.key` | Private key, unencrypted (PEM) |

The PFX bundle is not needed for this workflow.

### Usage

**Dry-run first (always):**

```powershell
.\Upload-XCCertificate.ps1 `
    -Tenant centralsquare.console.ves.volterra.io `
    -Namespace centralsquare-llc `
    -CertName <cert-object-name> `
    -CertFile .\certs\<year>\<name>_cert.crt `
    -ChainFile .\certs\<year>\<name>_chain.crt `
    -KeyFile .\certs\<year>\<name>_key_unencrypted.key `
    -WhatIf
```

**Upload for real (remove -WhatIf):**

```powershell
.\Upload-XCCertificate.ps1 `
    -Tenant centralsquare.console.ves.volterra.io `
    -Namespace centralsquare-llc `
    -CertName <cert-object-name> `
    -CertFile .\certs\<year>\<name>_cert.crt `
    -ChainFile .\certs\<year>\<name>_chain.crt `
    -KeyFile .\certs\<year>\<name>_key_unencrypted.key
```

On success you will see:
```
SUCCESS: Certificate '<cert-object-name>' created in namespace 'centralsquare-llc'.
```

---

## Update-XCLoadBalancerCert.ps1

Finds all HTTP and TCP load balancers in a namespace that reference a given certificate and
updates them to a new certificate. Use this after uploading a renewal cert to swing all LBs
over at once.

The script stops on the first failed update so the fleet is never silently left in a mixed state.

### Usage

**Dry-run first (always) — shows every LB that will be touched:**

```powershell
.\Update-XCLoadBalancerCert.ps1 `
    -Tenant centralsquare.console.ves.volterra.io `
    -Namespace centralsquare-llc `
    -OldCertName <current-cert-name> `
    -NewCertName <new-cert-name> `
    -WhatIf
```

**Apply the changes (remove -WhatIf):**

```powershell
.\Update-XCLoadBalancerCert.ps1 `
    -Tenant centralsquare.console.ves.volterra.io `
    -Namespace centralsquare-llc `
    -OldCertName <current-cert-name> `
    -NewCertName <new-cert-name>
```

### Example output (dry-run)

```
[HTTP] Found 6 load balancer(s). Checking for cert 'aspgov-wildcard-2026'...
  [WhatIf] [HTTP] my-app-lb
           Cert 'aspgov-wildcard-2026' -> 'aspgov-wildcard-2026pt2'
  [WhatIf] [HTTP] another-app-lb
           Cert 'aspgov-wildcard-2026' -> 'aspgov-wildcard-2026pt2'
[TCP]  No load balancers found in namespace 'centralsquare-llc'.

[WhatIf] 2 load balancer(s) would be updated. No changes made.
```

---

---

## Update-C2gApacheCert.ps1

Renews Apache TLS certificates on c2g* EC2 instances in **PALegacyCzp** via AWS SSM Run
Command. Replaces the old vSphere-based workflow. Cert files are embedded directly in the
SSM payload (no S3 required) — the instances have no outbound internet access.

Targets all `*C2GWB*` instances across `us-east-1` and `us-west-2` by default.

> **Legacy reference:** `c2g-cert-update.ps1` in this folder is the original vSphere-era
> script, kept for historical reference only. It is no longer used and should not be run.

### Prerequisites

- AWS CLI v2 in PATH
- Active SSO session for the `PALegacyCzp` profile:
  ```powershell
  aws sso login --profile PALegacyCzp
  ```
- Cert files staged locally (see file list below)

### Cert files required

| Parameter | Example filename | Description |
|-----------|-----------------|-------------|
| `-CertFile` | `star_aspgov_com_2026pt2.crt` | Leaf certificate (PEM) |
| `-KeyFile` | `star_aspgov_com_2026pt2-decrypted.key` | Unencrypted private key (PEM) |
| `-Intermediate` | `Sectigo_intermediate.crt` | Sectigo intermediate CA |
| `-TrustedRoot` | `Sectigo_CA_root.crt` | USERTrust root CA |
| `-CaCerts` | `cacerts` | Java truststore (reuse from prior year if chain unchanged) |

> **Note on cert naming:** Certs are now issued on a 180-day cycle with suffixes like
> `2026pt2`. There are no hardcoded defaults — filenames must be supplied at run time.

Stage the files into a local directory, e.g. `C:\temp\ASPGOV_Cert_Renewal\2026pt2\CertFiles\`.

### Step 1 — Dry-run (always run this first)

```powershell
.\Update-C2gApacheCert.ps1 `
    -CertSourceDir 'C:\temp\ASPGOV_Cert_Renewal\2026pt2\CertFiles' `
    -CertFile      'star_aspgov_com_2026pt2.crt' `
    -KeyFile       'star_aspgov_com_2026pt2-decrypted.key' `
    -Intermediate  'Sectigo_intermediate.crt' `
    -TrustedRoot   'Sectigo_CA_root.crt' `
    -WhatIf
```

Review the instance list and SSM reachability output before proceeding.

### Step 2 — Single-server smoke test

Pick one non-production server and run without `-WhatIf`, scoped to that host:

```powershell
.\Update-C2gApacheCert.ps1 `
    -CertSourceDir 'C:\temp\ASPGOV_Cert_Renewal\2026pt2\CertFiles' `
    -CertFile      'star_aspgov_com_2026pt2.crt' `
    -KeyFile       'star_aspgov_com_2026pt2-decrypted.key' `
    -Intermediate  'Sectigo_intermediate.crt' `
    -TrustedRoot   'Sectigo_CA_root.crt' `
    -NameTagFilter 'STPE-TC2GWB001' `
    -Regions       'us-east-1'
```

Verify the summary shows `Result=success`, `Writes=5`, and `ConfigChanges=2`. Run a second
time to confirm idempotency (`ConfigChanges=0`, `Backup=exists`).

### Step 3 — Fleet cert delivery (no restart)

```powershell
.\Update-C2gApacheCert.ps1 `
    -CertSourceDir 'C:\temp\ASPGOV_Cert_Renewal\2026pt2\CertFiles' `
    -CertFile      'star_aspgov_com_2026pt2.crt' `
    -KeyFile       'star_aspgov_com_2026pt2-decrypted.key' `
    -Intermediate  'Sectigo_intermediate.crt' `
    -TrustedRoot   'Sectigo_CA_root.crt'
```

This pushes certs to all 173 instances across both regions (~15–20 min). Apache is **not**
restarted — the new files land on disk but the running service still serves the old cert
until restarted. Results are saved to `%TEMP%\c2g-cert-update\<year>\<run>\results.csv`.

### Step 4 — Fleet Apache restart (after hours)

Once cert delivery is confirmed, restart Apache fleet-wide at a scheduled maintenance window:

```powershell
.\Update-C2gApacheCert.ps1 -RestartApacheOnly
```

Dry-run first to confirm the target list:

```powershell
.\Update-C2gApacheCert.ps1 -RestartApacheOnly -WhatIf
```

Servers without Apache on `D:\Apache24\conf` or `C:\Apache24\conf` are gracefully skipped
and noted in the summary as `skipped` — they are not application servers and can be ignored.

### Summary output

| Column | Meaning |
|--------|---------|
| `Result` | `success` / `skipped` / `failed` |
| `Backup` | `created` (first run) or `exists` (subsequent runs) |
| `Downloads` | Number of cert files written (expect 5) |
| `ConfigChanges` | Number of `httpd.conf`/`httpd-custom.conf` regex replacements (expect 2 on first run, 0 on re-runs) |
| `ApacheRestart` | `skipped`, `restarted`, or `n/a` |

---

## Cert Renewal Workflow

### F5 XC load balancers

1. Obtain new cert files from Sectigo and place them in `certs\<year_suffix>\`
2. Run `Upload-XCCertificate.ps1 -WhatIf` to verify payload looks correct
3. Run `Upload-XCCertificate.ps1` to create the new cert object in XC
4. Verify the cert appears in the XC console under **Certificate Management → TLS Certificates**
5. Run `Update-XCLoadBalancerCert.ps1 -WhatIf` to review affected LBs
6. Run `Update-XCLoadBalancerCert.ps1` to swing all LBs to the new cert
7. Spot-check one or two LBs in the XC console to confirm the cert reference updated

### c2g Apache servers (AWS EC2 / PALegacyCzp)

1. Obtain new cert files from Sectigo; stage in `C:\temp\ASPGOV_Cert_Renewal\<suffix>\CertFiles\`
2. Dry-run `Update-C2gApacheCert.ps1 -WhatIf` to review instance list
3. Smoke test against one non-prod server (`-NameTagFilter`)
4. Fleet cert delivery (Step 3 above) — no service disruption, Apache not restarted
5. Verify certs on a sample of servers via `openssl s_client`
6. Fleet Apache restart after hours (`-RestartApacheOnly`)

## Notes

- Cert files are excluded from this repo via `.gitignore`. Store them in a secure location
  (e.g., a team-shared encrypted store or retrieve fresh from Sectigo at renewal time).
- The F5 XC API token is never written to disk or logged. Always pass it via `XC_API_TOKEN`.
- All scripts support `-WhatIf` — always run a dry-run and review the output before executing
  against production. Treat this as mandatory, not optional.
- Logs for each `Update-C2gApacheCert.ps1` run are written to
  `%TEMP%\c2g-cert-update\<year>\<timestamp>\` including a transcript and per-host SSM output.
