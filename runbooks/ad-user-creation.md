# AD User Creation

Three separate creation flows exist depending on the product line. Choose the one that matches your request.

| Flow | Use when | Script | Kiro task |
|------|----------|--------|-----------|
| [FE Centroid User](#flow-a--fe-centroid-user) | Creating a user for a client on the FE (Faster ERP) platform | `FE_User_Creation_Client_Centroid.ps1` | `AD: Create FE Centroid User` |
| [Aptean Citizen User](#flow-b--aptean-citizen-user) | Creating a citizen user in `apteanps.local` | `Create-Apteanps-CitizenUser.ps1` | `AD: Create Aptean Citizen User` |
| [Centroid Aptean User](#flow-c--centroid-aptean-user) | Creating the corresponding centroid MFA account after the Aptean citizen user is provisioned | `Create-Centroid-Aptean-Users.ps1` | `AD: Create Centroid Aptean User` |

> **None of these scripts prompt for a ticket number.** Record your ticket number in the output files / email templates the scripts generate.

---

## Flow A — FE Centroid User

Creates a user in two domains simultaneously:
1. `<client-code>.cloud.lcl` — the client's application domain
2. `centroid.cloud.lcl` — the shared centroid domain (SAM prefixed `c_`)

### When to use

New user onboarding for a client on the FE platform. Handles both single-user and bulk-from-CSV.

### Pre-checks

- [ ] RSAT ActiveDirectory module installed
- [ ] You can reach both the client domain (`<code>.cloud.lcl`) and `centroid.cloud.lcl`
- [ ] Client code is known (e.g. `CAS`, `REDB`, `AURO`)
- [ ] For bulk: CSV file prepared using the format in `scripts/ad/bulkUserExample.csv`
- [ ] Ticket number in hand — you will need to add it manually to the output files

### Procedure

Run in Kiro: **`AD: Create FE Centroid User`**

Or from CLI:
```powershell
pwsh scripts/ad/FE_User_Creation_Client_Centroid.ps1
```

**Mode selection:** `S` for single user, `B` for bulk (CSV via file dialog).

**Single-user prompts:**
1. Client code (e.g. `CAS`)
2. Permission option:
   - `D` — Default group membership for that client
   - `P` — Manually pick groups
   - `C` — Clone groups from an existing user
3. Full name
4. User ID (sAMAccountName)
5. Email address
6. Password: press Enter for auto-generated 12-char random password; or type `manual` to set manually
7. If the user already exists in either domain: `S` (skip) or `R` (recreate)

> **Warning — `R` (recreate) is destructive.** Choosing `R` calls `Remove-ADUser -Confirm:$false` on the existing account before recreating it. All group memberships, profile paths, and attributes on the old account are permanently deleted. Only choose `R` if the ticket explicitly requires a clean re-provision.

**Output:**
- Single mode: email template written to `Desktop\<user>_<code>_<date>.txt`
- Bulk mode: `<code>_success_<date>.csv` and `<code>_failed_<date>.csv` in the current directory

### Verification

```powershell
# Check client domain
Get-ADUser -Identity <sAMAccountName> -Server <code>.cloud.lcl -Properties *

# Check centroid domain (SAM is c_<username>, truncated if needed)
Get-ADUser -Identity c_<sAMAccountName> -Server centroid.cloud.lcl -Properties *
```

Confirm: account enabled, correct UPN, email attribute set, group memberships match the permission option chosen.

### Rollback

If the user was created in error or must be removed:
1. Follow the disable procedure first: [`ad-user-disable.md`](ad-user-disable.md)
2. Then delete: `Remove-ADUser -Identity <sam> -Server <domain> -Confirm:$false`
3. If the `R`-path destroyed the wrong account, check the AD Recycle Bin:
   ```powershell
   Get-ADObject -Filter {SamAccountName -eq "<sam>"} -Server <domain> `
       -IncludeDeletedObjects | Restore-ADObject
   ```
   Recycle Bin objects are retained for 180 days by default.

---

## Flow B — Aptean Citizen User

Creates a citizen user in `apteanps.local`. After this completes, the script prints a Cloud-team handoff ticket block — paste it into a new ticket and assign it to the team to run [Flow C](#flow-c--centroid-aptean-user).

### Pre-checks

- [ ] RSAT ActiveDirectory module installed
- [ ] You can reach `apteanps.local`
- [ ] The target Org OU exists (e.g. `Org-Amherstburg`) — if not, request OU creation first
- [ ] Ticket number in hand

### Procedure

Run in Kiro: **`AD: Create Aptean Citizen User`**

Or from CLI:
```powershell
pwsh scripts/ad/Aptean_User_Management/Create-Apteanps-CitizenUser.ps1
```

**Prompts:**
1. Mode: `D` (Default) or `C` (Clone groups from existing user)
2. Org OU name (e.g. `Org-Amherstburg`)
3. Full name — must be unique in the OU
4. sAMAccountName — must be unique in the domain
5. Email address
6. Final `Y`/`N` confirmation before the account is created

The script generates a 12-16 character random password meeting Aptean's policy. This password is displayed once — copy it before the script exits.

**Output:**
- End-user email block: copy/paste to send to the new user
- Cloud-team ticket block: copy/paste into a new ticket for Flow C (centroid.cloud.lcl MFA account)

### Verification

```powershell
Get-ADUser -Identity <sAMAccountName> -Server apteanps.local -Properties *
```

Confirm: account enabled, correct UPN, `ProfilePath` and `HomeDirectory` set to `\\PAPTPSFS01\...`.

### Rollback

Disable then delete:
```powershell
Disable-ADAccount -Identity <sAMAccountName> -Server apteanps.local
Remove-ADUser -Identity <sAMAccountName> -Server apteanps.local -Confirm:$false
```

---

## Flow C — Centroid Aptean User

Creates the corresponding account in `centroid.cloud.lcl` for a user provisioned in Flow B. This is typically triggered by the handoff ticket generated at the end of Flow B.

### Pre-checks

- [ ] RSAT ActiveDirectory module installed
- [ ] You can reach `centroid.cloud.lcl`
- [ ] The company's three-OU tree exists in `centroid.cloud.lcl`:
  - `OU=Customers,DC=centroid,DC=cloud,DC=lcl`
  - `OU=<CompanyFolder>,OU=Customers,...` (company name, uppercase letters only)
  - `OU=Users,OU=<CompanyFolder>,OU=Customers,...`
  
  If any OU is missing, the script will fail with a clear error — request OU creation before proceeding.
- [ ] `Org_OUs_with_Company.csv` in the script directory is up to date with the company mapping

### Procedure

Run in Kiro: **`AD: Create Centroid Aptean User`**

Or from CLI (non-interactive with `--line`):
```powershell
pwsh scripts/ad/Aptean_User_Management/Create-Centroid-Aptean-Users.ps1 `
    -line "FullName,sAMAccountName,email,OUPath"
```

Or interactively (prompts for user details).

The SAM account name in centroid is derived automatically: prefixed `c_`, invalid characters stripped, truncated to 20 characters (with a numeric suffix if needed for uniqueness).

### Verification

```powershell
Get-ADUser -Identity c_<sAMAccountName> -Server centroid.cloud.lcl -Properties *
```

Confirm: account in the correct `OU=Users,OU=<Company>,OU=Customers,...` path.

### Rollback

Disable then delete:
```powershell
Disable-ADAccount -Identity c_<sAMAccountName> -Server centroid.cloud.lcl
Remove-ADUser -Identity c_<sAMAccountName> -Server centroid.cloud.lcl -Confirm:$false
```

---

## Related

- [`inventory/ad-domains.yml`](../inventory/ad-domains.yml) — domain FQDNs and DC reference (covers the four disable-script domains; creation flows extend to `apteanps.local` and per-client `<code>.cloud.lcl` domains)
- [`inventory/ous.yml`](../inventory/ous.yml) — OU DNs for centroid and aptean creation flows
- [`runbooks/ad-user-disable.md`](ad-user-disable.md) — disabling users (offboarding or rollback)
- [`scripts/ad/README.md`](../scripts/ad/README.md) — all AD scripts and data file locations (`clientMappings.csv`, `bulkUserExample.csv`, `Org_OUs_with_Company.csv`)
