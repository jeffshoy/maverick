# Enable-PLUSCustomerUser

Standalone replacement for `PLUS_CustomerUsers_QuickSetup "samid" -Reenable -Manager "Name"` from the deprecated PLUSSysAdmins module.

---

## What it does

1. Looks up the user on aspgov.pri (disabled or enabled)
2. Re-enables the account — clears `Description`, stamps `Info` with who/when, refreshes `Company`/`State`/`City`/`UPN`/`msDS-cloudExtensionAttribute18`, (re-)adds to `<CUST>_PLUS`
3. Sets `Manager` on the account if supplied (must be in the same OU)
4. Resets the password to `Welcome<FI><LI>!<MMDD>`
5. Creates any missing rpt folders on prod and train file servers
6. Re-grants SQL access (PRD01+STG01 always; PRD04+STG04 for 5.2 customers)
7. Ensures the `c_<samid>` account on `centroid.cloud.lcl` exists and is enabled
8. Outputs credentials to console and clipboard

## What it does NOT do

- Set an account expiration date — the PSync watcher that cleared the old 31-day window is decommissioned. Setting it without clearing it would lock out the user again.

---

## Prerequisites

- PowerShell 7 (`pwsh`)
- RSAT ActiveDirectory module
- SqlServer module 21.x (`Install-Module SqlServer -RequiredVersion 21.1.18226`)
- Network access to `aspgov.pri`, `centroid.cloud.lcl`, the PLUS file servers, and PLUS SQL instances

---

## Config files

This script shares the same `config/` files as `New-PLUSCustomerUser`. The simplest setup is a symlink:

```powershell
New-Item -ItemType SymbolicLink `
    -Path   ".\config" `
    -Target "..\New-PLUSCustomerUser\config"
```

Or copy the folder if you prefer a standalone copy (remember to keep them in sync).

### Required files

| File | Purpose |
|------|---------|
| `config/PLUSCustomers.txt` | Valid 3-char customer site codes |
| `config/PLUS52Customers.txt` | Customers on the 5.2 platform (PRD04/STG04) |
| `config/PLUSCustomersUIDLNFI.txt` | Customers using Last-Name-First-Initial samid format |
| `config/CentroidCustomerOUMap.csv` | Maps site code → Centroid OU name |
| `config/PLUSCustomerNames.csv` | Maps site code → display name + state |
| `templates/Template_SQL_GrantUserAccess.txt` | SQL grant template (grab from `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\`) |

---

## Usage

```powershell
.\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado

# Dry run (no changes made)
.\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado -Manager "Christopher Walkins" -WhatIf

# Force 5.2 SQL envs regardless of PLUS52Customers.txt
.\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado -Is52Customer
```

---

## Centroid behavior

| Scenario | Result |
|----------|--------|
| `c_<samid>` exists and is enabled | `ALREADY-ENABLED` — no change |
| `c_<samid>` exists but is disabled | `RE-ENABLED` — password reset + enabled |
| `c_<samid>` does not exist | `CREATED` — full account creation |
| No OU mapping for this customer | `SKIPPED-no-OU-mapping` — non-fatal |
