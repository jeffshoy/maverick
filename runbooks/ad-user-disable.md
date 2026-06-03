# AD User Disable

## When to use

- Employee offboarding (resignation, termination)
- Account lockout request from HR or security
- Security incident requiring immediate account disablement
- Contractor access expiry

---

## Pre-checks

- [ ] RSAT ActiveDirectory module installed on your machine
- [ ] You can reach all four domains (run `Test-Connection cloud.lcl` etc. if unsure)
- [ ] Ticket or case number in hand — required by the script
- [ ] You know the user's name, email, or user ID to search by
- [ ] **For immediate security incidents:** confirm with your lead before proceeding — disabling triggers an audit trail
- [ ] **Optional read-only pre-check:** run `AD: Find User (All Domains)` first to confirm which domains the user exists in

---

## Procedure

### 1. Run the disable script

Run in Kiro: **`AD: Disable User (4 Domains)`**

Or from CLI:
```powershell
pwsh scripts/ad/Disable_users_4Domains.ps1
```

Use `-WhatIf` to preview what would be changed without making any modifications:
```powershell
pwsh scripts/ad/Disable_users_4Domains.ps1 -WhatIf
```

### 2. Search for the user

The script prompts for a search term. You can enter:
- Full or partial name (e.g. `Jane Doe` or `Doe`)
- Email address (e.g. `jdoe@aspgov.com`)
- User ID / sAMAccountName (e.g. `jdoe`)

The script searches all four user-management domains in parallel. See [`inventory/ad-domains.yml`](../inventory/ad-domains.yml) for the domain list.

### 3. Review and select

The script displays all matches across domains:
```
1. Jane Doe | jdoe | jdoe@aspgov.com | Enabled: True | Domain: aspgov.pri
2. Jane Doe | jdoe | jdoe@centroid.com | Enabled: True | Domain: centroid.cloud.lcl
```

Enter the numbers of users to disable (comma-separated, e.g. `1,2`).

### 4. Provide ticket details

The script prompts for:
- **Ticket/case number** (e.g. `ENG-012345`) — stamped in the user's Description field
- **SRE initials** (e.g. `TJ`) — also stamped in Description

### 5. Review the desktop backup

Before making any changes, the script exports a CSV to your Desktop:
```
C:\Users\<you>\Desktop\User_Backup_<name>_<timestamp>.csv
```

Keep this file until you've verified the disable completed successfully. It contains all pre-change user state needed for rollback.

### 6. Script execution

The script:
1. Updates the `Description` field: `"Disabled MM/DD/YYYY, ENG-012345, -TJ"`
2. Sets `Enabled = $false`
3. For `centroid.cloud.lcl` users: moves the account to `OU=_Deprecated,OU=Users,OU=Cloud,DC=centroid,DC=cloud,DC=lcl`

Any domain that fails to update is reported as a warning — the script continues with the remaining domains.

---

## Verification

Re-run the script with the same search term and confirm:
- `Enabled: False` shown for all matched users
- Description field updated with the ticket number

Or use the read-only check:
```powershell
pwsh scripts/ad/Find-UserAllDomains.ps1 -UserName <samAccountName or email>
```

---

## Rollback

The desktop CSV backup contains the pre-change `DN` and `Server` for each user.

To re-enable a user:
```powershell
# Re-enable account
Set-ADUser -Identity "<DistinguishedName>" -Server "<Domain>" -Enabled $true -ErrorAction Stop

# Clear the description if needed
Set-ADUser -Identity "<DistinguishedName>" -Server "<Domain>" -Description "" -ErrorAction Stop

# For centroid users: move back from _Deprecated (requires the original OU path from the CSV)
Move-ADObject -Identity "<DistinguishedName>" -TargetPath "<OriginalOU>" -Server "centroid.cloud.lcl"
```

---

## Related

- [`inventory/ad-domains.yml`](../inventory/ad-domains.yml) — domain FQDNs, DCs, and OU paths
- [`scripts/ad/README.md`](../scripts/ad/README.md) — all AD scripts
- [`runbooks/ad-user-creation.md`](ad-user-creation.md) — user provisioning (future runbook)
