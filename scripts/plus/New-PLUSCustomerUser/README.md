# New-PLUSCustomerUser

Standalone PowerShell script that creates a new PLUS customer user end-to-end.  
Replaces `PLUS_Create_CustomerUser` from the deprecated `PLUSSysAdmins` module.  
No VM workstations, no legacy PowerShell profile, no PSync, no Rubrik, no VMware.

---

## What it does

1. Creates an AD user on **aspgov.pri** in `OU=USERS,OU=<CUST>,OU=Customer,DC=aspgov,DC=pri`
2. Adds the user to the `<CUST>_PLUS` AD group
3. Sets `msDS-cloudExtensionAttribute18 = IsPLUSCustAdmin=FALSE` on the new account
4. Creates `rpt` folders on the PLUS file servers (prod + train only for customer users)
5. Grants SQL access on **PRD04 + STG04** (5.2 customers) or **PRD01 + STG01** (non-5.2) — never both. If the SQL step fails because the just-created aspgov.pri account hasn't replicated to the DC the SQL instance resolves logins against yet, it automatically retries with backoff (up to ~9.5 minutes total) instead of requiring a manual re-run — see [SQL access retry behavior](#sql-access-retry-behavior) below
6. Creates **c\_\<samid\>** on **centroid.cloud.lcl** (skips gracefully if no OU mapping exists)
7. Prints credentials block to console and copies it to clipboard

---

## Prerequisites

### PowerShell modules

```powershell
Get-Module -ListAvailable ActiveDirectory, SqlServer
```

If `SqlServer` is missing:

```powershell
Install-Module SqlServer -Scope CurrentUser
```

If `ActiveDirectory` is missing, install RSAT on your workstation.

### Config file

All customer data lives in a single CSV: `config/PLUSCustomers.csv`.

| Column | Values | Notes |
|--------|--------|-------|
| `SiteCode` | 3-char lowercase | Customer site code |
| `Name` | Display string | Customer display name (used in AD + credentials block) |
| `State` | 2-char abbrev | Used in AD `State`/`City` fields |
| `Version` | `5.2` or empty | Customers on PLUS 5.2 get PRD04/STG04 SQL envs; others get PRD01/STG01 |
| `UIDLNFI` | `Y` or empty | Customers using Last-Name-First-Initial samid format |
| `CentroidOU` | OU name or empty | Target OU for `centroid.cloud.lcl` account creation |

To add a customer: add a row. To mark a customer as 5.2: set `Version=5.2`. To add a Centroid mapping: set `CentroidOU` to the OU name. **This is the only file that needs editing for customer management.**

### Template file (still required)

| File | Action needed |
|------|--------------|
| `scripts\plus\templates\Template_SQL_GrantUserAccess.txt` | **Copy from** `\\CLD-PPLSRDS001.aspgov.pri\PLUS$\PS_EnvironmentAdmin\scriptTemplates\Template_SQL_GrantUserAccess.txt`. |

---

## Usage

The recommended way for Support staff is to use the menu launcher (`support\PLUS-UserAdmin.bat`, option 1). The direct PowerShell invocation below is for SRE / power users.

```powershell
.\New-PLUSCustomerUser.ps1 `
    -Cust         SJC `
    -FirstName    Rand `
    -LastName     "Al'Thor" `
    -EmailAddress ralthor@sjcfl.us
```

### Dry run (no changes made)

```powershell
.\New-PLUSCustomerUser.ps1 -Cust TMK -FirstName Jane -LastName Smith `
    -EmailAddress jsmith@tompkins.gov -WhatIf
```

### Additional parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-MiddleInitial` | (none) | Used as a tiebreaker if the default samid is taken on aspgov.pri |
| `-IsUserDBA` | false | Grants `User_DBA='Y'` in the PLUS databases (customer admin level) |
| `-ExistingUID` | (auto) | Override the derived employeeID — use when the person already has a record in the customer DBs (migrations) |
| `-Is52Customer` | auto-detected | Force 5.2 SQL envs (PRD04/STG04) even if `Version` is not `5.2` in `PLUSCustomers.csv` |
| `-SamidOverride` | (auto) | Skip automatic samid generation entirely |
| `-Verbose` | (off) | Print detailed step-by-step output |

---

## SQL access retry behavior

`CREATE LOGIN [ASPGOV\<samid>] FROM WINDOWS` requires the SQL Server instance to resolve the
Windows account against a domain controller. Since the aspgov.pri account was just created a few
steps earlier in the same run, that DC may not have replicated the new account yet - this fails
with a `Windows NT user or group ... not found` error, which aborts the entire generated SQL
script (including every downstream per-database grant).

When the SQL grant step hits specifically that error, it automatically retries the whole
generate-and-execute cycle with backoff: 30s, 60s, then 120s per attempt, up to 6 retries (~9.5
minutes total worst case). You'll see a `WARNING: ASPGOV\<samid> not yet visible to <instance>
(AD replication lag) - attempt N of 7, retrying in Ns...` message on each retry - this is expected
and the script is not hung. Any other SQL error (bad template, permissions, connectivity) fails
immediately with no retry, exactly as before.

This means a single `New-PLUSCustomerUser.ps1` run may now take several minutes to finish if
replication is slow, but should no longer require a manual `Grant-PLUSUserAccess.ps1` re-run
afterward.

---

## Networking — required firewall ports

Run from the central RDS/terminal server (`CLD-PPLSRDS001.aspgov.pri` or equivalent).  
The RDS server must be able to reach the following destinations:

| Destination | Port(s) | Protocol | Purpose |
|---|---|---|---|
| aspgov.pri DCs (e.g. `inf-svrdc101.aspgov.pri`) | 389, 3268, 88, 445 | TCP; 88 also UDP | LDAP, Global Catalog, Kerberos, SMB |
| centroid.cloud.lcl DCs | 389, 3268, 88 | TCP; 88 also UDP | LDAP for Centroid user creation |
| `CLD-PPLSDB001.aspgov.pri` (PRD01 SQL) | 1433 | TCP | SQL — non-5.2 customers only |
| `CLD-SPLSDB001.aspgov.pri` (STG01 SQL) | 1433 | TCP | SQL — non-5.2 customers only |
| `CLD-PPLSDB004.aspgov.pri` (PRD04 SQL) | 1433 | TCP | SQL — 5.2 customers only |
| `CLD-SPLSDB004.aspgov.pri` (STG04 SQL) | 1433 | TCP | SQL — 5.2 customers only |
| `plus-efp-fs.aspgov.com` | 445 | TCP | SMB — prod rpt folder creation |
| `plus-efp-fs-train.aspgov.com` | 445 | TCP | SMB — train rpt folder creation |

> **Note on SQL named instances:** The PLUS SQL instances use a named instance (`\PLUS`) which by default uses dynamic ports negotiated via SQL Browser (UDP 1434). If SQL Browser is blocked, a static port must be configured on the SQL servers and opened in the security group. Confirm with the DBA team.

The RDS server is already domain-joined to aspgov.pri, so AD/Kerberos ports are likely already open. SQL ports (TCP 1433) to the database servers are the most likely gap — open a ticket with Networking to verify or add those rules to the RDS server's security group.

---

## Minimum permissions for Support (not Domain Admin)

Create a dedicated AD security group **`PLUS-UserAdmin`** in aspgov.pri and add Support users to it. The script runs as the logged-in Windows identity; all permissions below are granted to that group, not to individual users.

### Active Directory — aspgov.pri

| Where | Right | How |
|---|---|---|
| `OU=Customer,DC=aspgov,DC=pri` | Create User objects + Write all user attributes | Delegation Wizard or `dsacls` |
| Each `<CUST>_PLUS` group | Write Members | Grant via group Properties → Security → Add group → Allow Write Members |

**Step-by-step delegation (AD Delegation Wizard):**

1. Open **Active Directory Users and Computers** on a DC or admin workstation.
2. Right-click `OU=Customer,DC=aspgov,DC=pri` → **Delegate Control**.
3. Add `PLUS-UserAdmin` as the delegated group.
4. Choose **Create a custom task to delegate**.
5. Select **Only the following objects in the folder** → check **User objects** → check **Create selected objects in this folder**.
6. On the permissions page, check **General** + **Property-specific** → check **Write all properties**.
7. Complete the wizard.

Repeat the same process on `centroid.cloud.lcl` for the `OU=Customers` OU, coordinating with whoever manages that domain.

### SQL — aspgov.pri databases (PRD01/STG01 for non-5.2; PRD04/STG04 for 5.2)

The script uses Windows Integrated Authentication (Kerberos) — no SQL password is stored anywhere. Support users' Windows identities must be granted SQL access.

**Recommended (least privilege):**

1. Add the `PLUS-UserAdmin` AD group as a SQL Login on the instances your customers use: `PRD01`/`STG01` for non-5.2 customers, `PRD04`/`STG04` for 5.2 customers — or both if Support handles a mix.
2. Have the DBA team review `templates/Template_SQL_GrantUserAccess.txt` and identify the exact stored procedures it calls.
3. Grant `EXECUTE` on those specific procedures only — do **not** grant `db_owner`, `sysadmin`, or any `*FullAccess` role.

**Fallback (if procedure-level grants are too complex to scope immediately):**

- Grant `db_datareader` + `db_datawriter` + `EXECUTE` on `dbo` schema across the relevant PLUS databases. Still not `sysadmin`.

**Never:** `sysadmin` or `sa` login access.

> DBA action required: the DBA team must review the SQL template and confirm the minimum grant before Support accounts go live on SQL.

### File servers (UNC shares)

`PLUS-UserAdmin` needs **Create Folders / Write** permission on the following shares:

| Share path | Needed for |
|---|---|
| `\\plus-efp-fs.aspgov.com\Userfolders\` | All customers — prod rpt folder |
| `\\plus-efp-fs.aspgov.com\Userfolders52\` | 5.2 customers only |
| `\\plus-efp-fs-train.aspgov.com\Userfolders\` | All customers — train rpt folder |
| `\\plus-efp-fs-train.aspgov.com\Userfolders52TRN\` | 5.2 customers only |

The script only creates subfolders under the existing customer folder — the customer-level folder (e.g., `\Userfolders\sjc\`) must already exist from initial onboarding.

---

## Folder layout

```
New-PLUSCustomerUser/
├── New-PLUSCustomerUser.ps1
└── README.md
```

SQL templates are in the shared `scripts\plus\templates\` folder - not here. Config is in the shared `scripts\plus\config\` folder.

---

## Verification checklist (before first live run)

1. **Module preflight** — `Get-Module -ListAvailable ActiveDirectory, SqlServer` returns both.
2. **Config load** — run with `-WhatIf -Verbose` against a known-good customer; confirm counts: `Loaded X customers (Y on 5.2, Z LNFI), W Centroid mappings`.
3. **Config CSV** — `Import-Csv .\config\PLUSCustomers.csv | Format-Table` shows all customers with expected Version/CentroidOU values.
4. **WhatIf dry run** — run against TMK with `-WhatIf`; verify aspgov DN, centroid DN, SQL instances, and share paths in output. No writes.
5. **Live test run** — use a customer code that's safe to dirty (coordinate cleanup). Confirm after run:
   - aspgov user in correct OU, member of `<CUST>_PLUS`, has `msDS-cloudExtensionAttribute18 = IsPLUSCustAdmin=FALSE`
   - Centroid `c_<samid>` created with correct UPN
   - `\\plus-efp-fs.aspgov.com\Userfolders\<cust>\<samid>\rpt` exists
   - `\\plus-efp-fs-train.aspgov.com\Userfolders\<cust>\<samid>\rpt` exists
   - SQL generated scripts saved to `%TEMP%\GrantUserAccess_*.sql` (for audit)
   - Credentials block in clipboard contains no PSync wording
6. **Permissions test** — run the script as a Support user (not SRE Domain Admin) to validate the delegated permission model works end-to-end.
7. **Failure tests**:
   - Invalid customer code → fails before any AD touch
   - Existing samid → fails with clear message before any other resource is touched
   - Customer with no `CentroidOU` in `PLUSCustomers.csv` → completes aspgov + SQL + folders; centroid shows `SKIPPED-no-OU-mapping`

---

## Test account cleanup

To remove a test account after verification:

```powershell
# 1. Remove aspgov.pri user
Remove-ADUser -Identity <samid> -Server (Get-ADDomain aspgov.pri).PDCEmulator -Confirm:$false

# 2. Remove centroid.cloud.lcl user
Remove-ADUser -Identity c_<samid> -Server centroid.cloud.lcl -Confirm:$false

# 3. Remove rpt folders (adjust server/share/cust as needed)
Remove-Item "\\plus-efp-fs.aspgov.com\Userfolders\<cust>\<samid>" -Recurse -Force
Remove-Item "\\plus-efp-fs-train.aspgov.com\Userfolders\<cust>\<samid>" -Recurse -Force

# 4. SQL: run REVOKE / DROP USER — PRD04/STG04 for 5.2 customers, PRD01/STG01 for non-5.2
#    The generated .sql files in %TEMP% are named GrantUserAccess_<samid>_<cust>_<env>_<ts>.sql
#    for audit reference.
```

---

## Known differences from legacy behavior

| Legacy | This script | Reason |
|--------|-------------|--------|
| 31-day account expiration set on new accounts | **Not set** | The expiration was cleared by the `AD-NewUserWatch.ps1` PSync watcher, which no longer exists. Setting it now would lock out new users with no automated relief. |
| Credentials email (HTM + SMTP) | Console + clipboard only | Email step deferred to a future phase. Send credentials manually. |
| `PLUS_CustomerUsers_QuickSetup` "rename-if-wrong-DN" repair | Not included | Fails fast on samid collision instead. |
| SharePoint/PnP for customer list | Static `config/PLUSCustomers.csv` | No SP dependency on runner's machine. Update the CSV when customers change. |

---

## Next steps (future phases)

- Add remaining PLUS functions as standalone scripts following this same pattern.
- Add `-WhatIf`-safe SQL revoke helper for cleanup.
- Convert to an Azure DevOps pipeline with a service account and secrets from Key Vault.
- Add HTM email delivery step.
