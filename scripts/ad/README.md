# scripts/ad — Active Directory

Multi-domain Active Directory user management across all four CloudOps domains.

**Pre-requisite:** RSAT ActiveDirectory module must be installed. Each script validates domain reachability before bulk operations.

| Script | Kiro Task | Purpose |
|--------|-----------|---------|
| `Disable_users_4Domains.ps1` | `AD: Disable User (4 Domains)` | Search for and disable a user across all four AD domains |
| `Find-UserAllDomains.ps1` | `AD: Find User (All Domains)` | Search for a user across all four domains (read-only) |
| `FE_User_Creation_Client_Centroid.ps1` | `AD: Create FE Centroid User` | Provision a new FE/Centroid client user |
| `Aptean_User_Management/Create-Apteanps-CitizenUser.ps1` | `AD: Create Aptean Citizen User` | Create an Aptean citizen portal user |
| `Aptean_User_Management/Create-Centroid-Aptean-Users.ps1` | `AD: Create Centroid Aptean User` | Bulk-create Centroid/Aptean users |

**Data files** (in `scripts/ad/` root):

| File | Used by |
|------|---------|
| `bulkUserExample.csv` | `FE_User_Creation_Client_Centroid.ps1` — shows the expected CSV column format for bulk mode |
| `clientMappings.csv` | `FE_User_Creation_Client_Centroid.ps1` — maps client codes to Centroid customer OUs |
| `Aptean_User_Management/Org_OUs_with_Company.csv` | Aptean creation scripts — org-to-OU mapping |
