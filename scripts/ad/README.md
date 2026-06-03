# scripts/ad — Active Directory

Multi-domain Active Directory user management across all four CloudOps domains.

**Pre-requisite:** RSAT ActiveDirectory module must be installed. Each script validates domain reachability before bulk operations.

| Script | Kiro Task | Purpose |
|--------|-----------|---------|
| `Disable_users_4Domains.ps1` | `AD: Disable User (4 Domains)` | Disable a user account across all four AD domains |
| `FE_User_Creation_Client_Centroid.ps1` | `AD: Create FE Centroid User` | Provision a new FE/Centroid client user |
| `Aptean_User_Management/Create-Apteanps-CitizenUser.ps1` | `AD: Create Aptean Citizen User` | Create an Aptean citizen portal user |
| `Aptean_User_Management/Create-Centroid-Aptean-Users.ps1` | `AD: Create Centroid Aptean User` | Bulk-create Centroid/Aptean users |

**Data files** (`data/` subfolder):

| File | Used by |
|------|---------|
| `bulkUserExample.csv` | `FE_User_Creation_Client_Centroid.ps1` |
| `clientMappings.csv` | `FE_User_Creation_Client_Centroid.ps1` |
| `Aptean_User_Management/Org_OUs_with_Company.csv` | Aptean creation scripts |

See [`runbooks/ad-user-disable.md`](../../runbooks/ad-user-disable.md) and [`runbooks/ad-user-creation.md`](../../runbooks/ad-user-creation.md).
