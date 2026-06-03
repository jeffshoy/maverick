# Sectigo Mass Certificate Revocation

> **STOP — read this before proceeding.**
>
> Certificate revocation via Sectigo is **permanent and irreversible.** Sectigo cannot un-revoke a certificate — the only recovery path is reissuing a new cert.
>
> The script ships with a pre-populated `ids.json` (~100 sample IDs). **You MUST replace this file before running**, or you will revoke real production certificates with no way to recover them.
>
> There is **no confirmation prompt.** The script begins revoking immediately on launch.

---

## When to use

- Security incident: private key compromise requiring bulk cert revocation
- Certificate authority migration: revoking all certs under a decommissioned profile
- Compliance event requiring revocation of a defined set of cert IDs

Do not use this for single-cert revocations — contact Sectigo directly or use the web UI.

---

## Pre-checks

- [ ] You have a list of cert IDs (integers) that you have independently verified are the correct targets
- [ ] A change ticket is open and approved — revocation is irreversible, treat it like a deletion
- [ ] Environment variables are set (see setup below)
- [ ] `ids.json` has been replaced with **only** the IDs you intend to revoke
- [ ] You have chosen a reason text and Mozilla reason code for the audit trail

### Setting environment variables

```powershell
$env:SECTIGO_LOGIN         = "<your-login>"
$env:SECTIGO_PASSWORD      = "<your-password>"
$env:SECTIGO_CUSTOMER_URI  = "<customer-uri>"
# Optional (defaults to https://cert-manager.com):
$env:SECTIGO_BASE_URL      = "https://cert-manager.com"
```

Do not hard-code these values in any file. Pull credentials from the team password manager or Key Vault.

### Mozilla reason code reference

| Code | Meaning | When to use |
|------|---------|-------------|
| 0 | Unspecified | Default; use if no specific reason applies |
| 1 | Key Compromise | Private key was exposed or suspected stolen |
| 3 | Affiliation Changed | Org/domain ownership changed |
| 4 | Superseded | Cert replaced by a new one |
| 5 | Cessation of Operation | Service decommissioned |

---

## Procedure

### 1. Replace `ids.json`

Navigate to the script directory:
```powershell
cd scripts/sectigo/MassCertRevoke
```

Write your cert IDs as a JSON array. Example:
```json
[12345678, 12345679, 12345680]
```

```powershell
'[12345678, 12345679, 12345680]' | Out-File ids.json -Encoding utf8
```

Double-check the file before continuing:
```powershell
Get-Content ids.json
```

### 2. Run the revocation script

Run in Kiro: **`Sectigo: Mass Cert Revoke`**

Or from CLI:
```powershell
python scripts/sectigo/MassCertRevoke/revoke_certs.py ids.json `
    --reason "Key compromise — incident ENG-XXXXX" `
    --reason-code 1
```

The script begins immediately. For each cert ID:
- `[OK] <id>` — HTTP 204, revocation confirmed
- `[FAIL] <id>: <message>` — revocation failed; check the error message

### 3. Check the exit code

- Exit code `0`: all certs revoked successfully
- Exit code `1`: one or more certs failed — review the `[FAIL]` lines in the output

Paste the full output into your change ticket for the audit trail.

---

## Verification

After the script completes, verify in the Sectigo web UI:
1. Log into `https://cert-manager.com` → SSL Certificates
2. Search for one or more of the revoked cert IDs
3. Confirm status shows `Revoked`

Allow up to 15 minutes for the CRL to propagate to all relying parties.

---

## Rollback

**There is no rollback.** Revocation is permanent.

If a cert was revoked by mistake:
1. Immediately open a high-priority ticket
2. Reissue the certificate — do not attempt to recreate the same cert with the same serial number
3. Update DNS, load balancers, or application config to reference the new cert
4. Notify affected stakeholders

---

## Related

- [`scripts/sectigo/README.md`](../scripts/sectigo/README.md) — environment variable setup and API reference
- [`scripts/sectigo/MassCertRevoke/`](../scripts/sectigo/MassCertRevoke/) — script and example `ids.json`
