# Enable-PLUSCustomerUser

Standalone replacement for `PLUS_CustomerUsers_QuickSetup "samid" -Reenable` from the deprecated PLUSSysAdmins module.

---

## What it does

1. Looks up the user on aspgov.pri (disabled or enabled)
2. Re-enables the account — sets `Description` to `Re-enabled - <date> - <who>`, stamps `Info` with who/when, refreshes `Company`/`State`/`City`/`UPN`/`msDS-cloudExtensionAttribute18`, (re-)adds to `<CUST>_PLUS`
3. Verifies `Enabled=$true` on the aspgov.pri PDC emulator immediately after the enable write, and throws a loud error (aborting the script) if verification fails rather than silently reporting success
4. Resets the password to `Welcome<FI><LI>!<MMDD>`
5. Creates any missing rpt folders on prod and train file servers
6. Re-grants SQL access on the environment(s) chosen from an interactive Production/Train/Stage menu (1/2/3, or a comma-separated combination such as `1,2`) — or on the environment given via `-SqlEnv`, which skips the prompt entirely. `-SqlEnv` accepts `PRD01`/`STG01`/`PRD04`/`STG04` directly; the interactive menu resolves Production/Train/Stage to PRD04/STG04 for 5.2 customers or PRD01/STG01 otherwise. If the grant fails because the account hasn't replicated to the DC the SQL instance resolves logins against yet, it automatically retries with backoff (up to ~9.5 minutes total) — see [SQL access retry behavior](#sql-access-retry-behavior) below
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

This script uses the shared `config\` folder at `scripts\plus\config\`. Scripts reference it via `$scriptDir\..\config\` - no per-script symlink needed.

### Required files

| File | Purpose |
|------|---------|
| `config\PLUSCustomers.csv` | Single source of truth - all customers with Version, UIDLNFI, CentroidOU columns |
| `scripts\plus\templates\Template_SQL_GrantUserAccess.txt` | SQL grant template (grab from `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\`) |

---

## Usage

Support staff use menu option 2 via `support\PLUS-UserAdmin.bat`. Direct PowerShell invocation below is for SRE / power users.

By default the script prompts with an interactive Production/Train/Stage SQL menu (see below). Add
`-SqlEnv` to skip the prompt and target a specific instance non-interactively.

```powershell
.\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado

# Dry run (no changes made)
.\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado -WhatIf

# Force 5.2 SQL envs regardless of PLUSCustomers.csv Version column - still prompts with the
# interactive menu, which will offer PRD04/STG04 instead of PRD01/STG01
.\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado -Is52Customer

# Skip the interactive SQL menu and target a specific environment directly
.\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado -SqlEnv PRD01

# Combine Is52Customer with SqlEnv - SqlEnv still wins and skips the prompt entirely
.\Enable-PLUSCustomerUser.ps1 -Samid opakalvarado -Is52Customer -SqlEnv PRD04
```

---

## SQL environment selection

When `-SqlEnv` is not specified, the script prints a Production/Train/Stage menu and prompts for a
selection - enter `1`, `2`, `3`, or a comma-separated combination (e.g. `1,2` or `1,2,3`):

| Menu option | Environment | Instance (5.2 customer) | Instance (non-5.2) |
|---|---|---|---|
| `1` Production | `PRD04` / `PRD01` | `CLD-PPLSDB004.aspgov.pri\PLUS` | `CLD-PPLSDB001.aspgov.pri\PLUS` |
| `2` Train | `STG04` / `STG01` | `CLD-SPLSDB004.aspgov.pri\PLUS` | `CLD-SPLSDB001.aspgov.pri\PLUS` |
| `3` Stage | `STG04` / `STG01` | `CLD-SPLSDB004.aspgov.pri\PLUS` | `CLD-SPLSDB001.aspgov.pri\PLUS` |

Whether the customer is treated as 5.2 (and therefore offered PRD04/STG04 instead of PRD01/STG01) is
determined by the `Version` column in `config/PLUSCustomers.csv`, or overridden with `-Is52Customer`.

Pass `-SqlEnv` to skip the menu entirely and grant access on exactly one instance, non-interactively:

| Value | Instance |
|---|---|
| `PRD01` | `CLD-PPLSDB001.aspgov.pri\PLUS` |
| `STG01` | `CLD-SPLSDB001.aspgov.pri\PLUS` |
| `PRD04` | `CLD-PPLSDB004.aspgov.pri\PLUS` |
| `STG04` | `CLD-SPLSDB004.aspgov.pri\PLUS` |

---

## SQL access retry behavior

`CREATE LOGIN [ASPGOV\<samid>] FROM WINDOWS` requires the SQL Server instance to resolve the
Windows account against a domain controller. If the account was just created/renamed and hasn't
replicated to that DC yet, this fails with a `Windows NT user or group ... not found` error, which
aborts the entire generated SQL script (including every downstream per-database grant).

When the SQL grant step hits specifically that error, it automatically retries the whole
generate-and-execute cycle with backoff: 30s, 60s, then 120s per attempt, up to 6 retries (~9.5
minutes total worst case). You'll see a `WARNING: ASPGOV\<samid> not yet visible to <instance>
(AD replication lag) - attempt N of 7, retrying in Ns...` message on each retry - this is expected
and the script is not hung. Any other SQL error (bad template, permissions, connectivity) fails
immediately with no retry, exactly as before.

---

## Centroid behavior

| Scenario | Result |
|----------|--------|
| `c_<samid>` exists and is enabled | `ALREADY-ENABLED` — no change |
| `c_<samid>` exists but is disabled | `RE-ENABLED` — password reset + enabled |
| `c_<samid>` does not exist | `CREATED` — full account creation |
| No OU mapping for this customer | `SKIPPED-no-OU-mapping` — non-fatal |
