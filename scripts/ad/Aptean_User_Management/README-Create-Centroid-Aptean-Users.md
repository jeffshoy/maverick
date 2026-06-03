# Create-Centroid-Aptean-Users – README

## Overview
`Create-Centroid-Aptean-Users.ps1` creates a **centroid.cloud.lcl** Active Directory user from a single “ticket line” plus a mapping CSV.

**What it does**
1. Connects to **centroid.cloud.lcl** (works from a workstation or server).
2. Parses a pasted line of the form:  
   `Full Name, samAccountName, email, OU where the user is created: <Aptean OU DN>`
3. Looks up the **Company** from your mapping CSV using the Aptean OU DN (with fallback to the Org name, e.g., `Org-BigLakes`).
4. Normalizes Company to a folder name (letters only, **ALL CAPS**).
5. Builds and **verifies** (no creation) the target OU:  
   `OU=Users,OU=<COMPANY>,OU=Customers,DC=centroid,DC=cloud,DC=lcl`
6. Enforces sAM policy: prefix `c_`; if the result exceeds 20 chars, trim to 19 and try a single digit (`1..9,0`) as the 20th char until unique.
7. Creates the user with a strong random password; sets `OfficePhone = Email` (used as ADSSP login).
8. Prints a color‑coded summary.

---

## Prerequisites
- Windows PowerShell with the **ActiveDirectory** module.
- Network/DNS reachability and permissions against **centroid.cloud.lcl**.
- Mapping CSV present (default path: `.\Org_OUs_with_Company.csv`).

---

## Files
- `Create-Centroid-Aptean-Users.ps1` — the script.
- `Org_OUs_with_Company.csv` — mapping file.

**Required CSV columns**
```
Name, DistinguishedName, Company
```
**Example row:**
```
Org-BigLakes,OU=Org-BigLakes,OU=OU - Citizens,DC=apteanps,DC=local,Big Lakes County, AB
```

> Company is normalized by stripping non‑letters and uppercasing:  
> `Big Lakes County, AB` → `BIGLAKESCOUNTYAB`

---

## Usage

### A) Typical run (prompted input)
```powershell
.\Create-Centroid-Aptean-Users.ps1 -mappingcsv .\Org_OUs_with_Company.csv
```
Paste a line like:
```
Sunil Bl, sunil.bl, sunil.kanakappagari+bl@centralsquare.com, OU where the user is created: OU=Org-BigLakes,OU=OU - Citizens,DC=apteanps,DC=local
```

### B) Inline argument (no prompt)
```powershell
.\Create-Centroid-Aptean-Users.ps1 `
  -mappingcsv .\Org_OUs_with_Company.csv `
  -line 'Sunil Bl, sunil.bl, sunil.kanakappagari+bl@centralsquare.com, OU where the user is created: OU=Org-BigLakes,OU=OU - Citizens,DC=apteanps,DC=local'
```

### C) Alternate credentials
```powershell
$cred = Get-Credential
.\Create-Centroid-Aptean-Users.ps1 -mappingcsv .\Org_OUs_with_Company.csv -creds $cred
```

### D) Dry run (no changes)
```powershell
.\Create-Centroid-Aptean-Users.ps1 -mappingcsv .\Org_OUs_with_Company.csv -WhatIf
```

---

## Behavior & Output

- **Info (Cyan)** – parsing, lookups, checks.  
- **Success (Green)** – user created.  
- **Warning (Yellow)** – non‑fatal duplicates (e.g., email already in use).  
- **Error (Red)** – missing OU, mapping not found, connectivity, duplicate sAM that cannot be resolved.

On success you’ll see:
```
Full Name     :
UserID (sAM)  :  (enforced: c_… ≤ 20 chars)
Email         :
ADSSP Login   :  (same as Email; stored in OfficePhone)
UPN           :  <sam>@centroid.cloud.lcl
OU            :  OU=Users,OU=<COMPANY>,OU=Customers,DC=centroid,DC=cloud,DC=lcl
Temp Password :  <generated>
```

**No OU creation**: If any of the following are missing, the script stops and shows the exact DN it looked for:
- `OU=Customers,DC=centroid,DC=cloud,DC=lcl`
- `OU=<COMPANY>,OU=Customers,DC=centroid,DC=cloud,DC=lcl`
- `OU=Users,OU=<COMPANY>,OU=Customers,DC=centroid,DC=cloud,DC=lcl`

---

## sAM Policy Details
- Always prefix with `c_` (removes any existing `c_` before re‑prefixing).
- Allowed chars kept: letters, digits, `.`, `_`, `-`.
- If `c_<base>` ≤ 20 and unused → use it.  
- Else trim to 19 and try appending a single digit (`1..9,0`) as the 20th char until a free one is found.  
- If all are taken, the script errors and stops.

---

## Troubleshooting

- **Cannot reach centroid.cloud.lcl**: verify DNS/VPN/Firewall and that the **ActiveDirectory** module can query `Get-ADDomain -Server centroid.cloud.lcl`.
- **Mapping row not found**: make sure the pasted DN (or `Org-...` name) matches a `DistinguishedName` or `Name` in the CSV.
- **OU does not exist**: this script never creates OUs; request the OU be created, then rerun.
- **Duplicate sAM**: the script auto‑tries the digit suffixes; if none free, choose a different base user ID.

---

## Examples

Prompted run:
```powershell
PS> .\Create-Centroid-Aptean-Users.ps1 -mappingcsv .\Org_OUs_with_Company.csv
Paste the line from your ticket (it will be trimmed):
Line: Sunil Bl, sunil.bl, sunil.kanakappagari+bl@centralsquare.com, OU where the user is created: OU=Org-BigLakes,OU=OU - Citizens,DC=apteanps,DC=local
Parsing input...
Checking target OU in centroid...
=== USER CREATED IN CENTROID ===
Full Name     : Sunil Bl
UserID (sAM)  : c_sunil.bl
Email         : sunil.kanakappagari+bl@centralsquare.com
ADSSP Login   : sunil.kanakappagari+bl@centralsquare.com
UPN           : c_sunil.bl@centroid.cloud.lcl
OU            : OU=Users,OU=BIGLAKESCOUNTYAB,OU=Customers,DC=centroid,DC=cloud,DC=lcl
Temp Password : <generated>
```

Inline run:
```powershell
PS> .\Create-Centroid-Aptean-Users.ps1 -mappingcsv .\Org_OUs_with_Company.csv -line 'Full Name, sam, email, OU where the user is created: OU=Org-XYZ,OU=OU - Citizens,DC=apteanps,DC=local'
```

---

## Notes
- The script sets `OfficePhone = Email` to track the ADSSP login.
- Password is displayed once—store and handle it securely.
- Works from workstations: all AD lookups and creation explicitly target **centroid.cloud.lcl**.
