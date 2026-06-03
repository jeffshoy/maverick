# DNS Record Change (MS DNS)

> **`-WhatIf` does NOT work with this script.**
>
> `change-dns-ms.ps1` declares `[CmdletBinding(SupportsShouldProcess)]` but the actual `Set-DnsServerResourceRecord` call is not guarded by `$PSCmdlet.ShouldProcess`. Passing `-WhatIf` will appear to do nothing wrong but will NOT prevent the DNS write from happening.
>
> Use `-precheck` for dry-run validation. See Step 1 below.

> **`-cleardnsservercache` is fleet-wide.**
>
> The DNS cache clear runs `Invoke-VMScript` against all 10 domain controllers simultaneously. Do not include it unless propagation staleness is confirmed.

---

## When to use

- IP address migration: server moved to a new IP, DNS A record must follow
- Datacenter cutover: updating DNS to point to a new IP block
- Post-migration cleanup: removing stale A records after a decommission

For read-only DNS lookups or mobile DNS inventory, use `Find-MobileDnsRecords.ps1` instead.

---

## Pre-checks

- [ ] **RFC / change ticket approved** — DNS changes affect all clients resolving that name
- [ ] Exact DNS zone name (e.g. `aspgov.com`, `centroid.com`)
- [ ] Exact current IP address (old value) — the script will abort if it cannot find this record
- [ ] Exact new IP address — the script will abort if this IP is already in DNS for the same name
- [ ] Target DNS server / domain controller name (e.g. `inf-svrdns001`)
- [ ] Client identifier for the log file (e.g. `REDB` or `acme-migration`)
- [ ] vCenter access (only required if you will run `-cleardnsservercache`)

---

## Procedure

### Step 1 — Precheck (dry run)

Run the script with `-precheck` to validate inputs without making any changes. This queries the zone and reports whether the old IP exists and the new IP is already in use.

```powershell
pwsh scripts/dns/change-dns-ms.ps1 `
    -client <ClientCode> `
    -oldip <CurrentIP> `
    -newip <NewIP> `
    -zone <ZoneName> `
    -server <DCName> `
    -precheck
```

Example:
```powershell
pwsh scripts/dns/change-dns-ms.ps1 `
    -client REDB `
    -oldip 10.20.30.40 `
    -newip 10.20.30.50 `
    -zone aspgov.com `
    -server inf-svrdns001 `
    -precheck
```

Review the output and the log file created in the current directory (`changedns-ms_<client>_<timestamp>.log`). Fix any errors before continuing.

### Step 2 — Apply the change

Run with `-changedns` to write the new A record:

```powershell
pwsh scripts/dns/change-dns-ms.ps1 `
    -client <ClientCode> `
    -oldip <CurrentIP> `
    -newip <NewIP> `
    -zone <ZoneName> `
    -server <DCName> `
    -changedns
```

The script:
1. Finds the existing A record matching `-oldip`
2. Clones it with the new IP
3. Calls `Set-DnsServerResourceRecord` to replace the record
4. Queries the zone again and logs the post-change state

Attach the log file to your change ticket.

### Step 3 — Clear DNS cache (optional)

Only run this if DNS propagation staleness has been confirmed (e.g., clients are still hitting the old IP after the record updated).

```powershell
pwsh scripts/dns/change-dns-ms.ps1 `
    -client <ClientCode> `
    -oldip <CurrentIP> `
    -newip <NewIP> `
    -zone <ZoneName> `
    -server <DCName> `
    -cleardnsservercache
```

This connects to vCenter (`inf-vmwvc001.cloud.lcl` and `inf-vmwvc401.cloud.lcl`) and runs `Clear-DnsServerCache -Force` via `Invoke-VMScript` against all 10 DCs in the default list. Confirm you intend fleet-wide cache clearance before running.

### Optional: email notification

Add `-mailto <email@aspgov.com>` to any of the above commands to send a completion notification via the team mail relay.

---

## Verification

After the change, verify from a machine that is NOT the DC you ran the script against (to avoid cached results):

```powershell
Resolve-DnsName <hostname> -Server <DCName> -Type A
# Expected: IPv4Address = <NewIP>
```

Or from a workstation with `nslookup`:
```
nslookup <hostname> <DCName>
```

Allow up to 5 minutes for replication to other DCs if the zone uses AD-integrated replication.

---

## Rollback

Re-run with old and new IPs swapped:

```powershell
# First: precheck
pwsh scripts/dns/change-dns-ms.ps1 `
    -client <ClientCode> `
    -oldip <NewIP> `
    -newip <OldIP> `
    -zone <ZoneName> `
    -server <DCName> `
    -precheck

# Then: apply
pwsh scripts/dns/change-dns-ms.ps1 `
    -client <ClientCode> `
    -oldip <NewIP> `
    -newip <OldIP> `
    -zone <ZoneName> `
    -server <DCName> `
    -changedns
```

---

## Related

- [`scripts/dns/Find-MobileDnsRecords.ps1`](../scripts/dns/Find-MobileDnsRecords.ps1) — read-only lookup of DNS records by client or IP range
- [`inventory/ad-domains.yml`](../inventory/ad-domains.yml) — DC and domain reference (for choosing `-server`)
