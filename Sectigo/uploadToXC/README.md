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

## Cert Renewal Workflow (annual)

1. Obtain new cert files from Sectigo and place them in `certs\<year>\`
2. Run `Upload-XCCertificate.ps1 -WhatIf` to verify payload looks correct
3. Run `Upload-XCCertificate.ps1` to create the new cert object in XC
4. Verify the cert appears in the XC console under **Certificate Management → TLS Certificates**
5. Run `Update-XCLoadBalancerCert.ps1 -WhatIf` to review affected LBs
6. Run `Update-XCLoadBalancerCert.ps1` to swing all LBs to the new cert
7. Spot-check one or two LBs in the XC console to confirm the cert reference updated

## Notes

- Cert files are excluded from this repo via `.gitignore`. Store them in a secure location
  (e.g., a team-shared encrypted store or retrieve fresh from Sectigo at renewal time).
- The API token is never written to disk or logged. Always pass it via `XC_API_TOKEN`.
- Both scripts require `-WhatIf` to be run and reviewed before live execution — treat this
  as mandatory, not optional.
