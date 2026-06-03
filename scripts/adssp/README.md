# scripts/adssp — ADSS+

PowerShell automation for the ADSS+ platform — Microsoft AD user sync, IBMi group management, and RADIUS/NPS setup.

## msad/

| Script | Kiro Task | Purpose |
|--------|-----------|---------|
| `adssp-conntest.ps1` | `ADSSP: Test Connection` | Validate ADSS+ connectivity |
| `adssp-getusers.ps1` | `ADSSP: Get Users` | Query ADSS+ users |
| `adssp-createusers.ps1` | `ADSSP: Create Users` | Create users in ADSS+ |
| `adssp-manageibmigroups.ps1` | `ADSSP: Manage IBMi Groups` | Manage IBMi group membership |
| `adssp-sortusers.ps1` | `ADSSP: Sort Users` | Sort/organize user records |

## radius/

| Script | Kiro Task | Purpose |
|--------|-----------|---------|
| `adssp-setupradius.ps1` | `ADSSP: Setup RADIUS` | Configure RADIUS for ADSS+ |
| `setupNpsExtension.ps1` | `ADSSP: Install NPS Extension` | Install NPS extension on a server |
