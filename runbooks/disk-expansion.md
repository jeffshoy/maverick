# Disk Expansion

## When to use

- LogicMonitor alert: disk usage above threshold (typically 85–90% on a Windows drive)
- Pre-emptive expansion before a scheduled data migration or large batch job
- Post-incident cleanup where logs filled a drive

Disk expansion on Windows EC2 is **online and zero-downtime** — the OS partition resize happens live via SSM with no service interruption.

---

## Pre-checks

- [ ] Confirm the alert is real and current — LM metrics can lag; check the actual usage in the script output before expanding
- [ ] Identify the server name and account
- [ ] Know the target drive letter (from the LM alert's Datasource field, e.g. `WinVolumeUsage-C:` → drive `C`)
- [ ] AWS SSO session is active
- [ ] EBS volumes cannot be shrunk after expansion — **confirm the new size before committing**
- [ ] For production servers: get change approval before proceeding

---

## Procedure

Two paths are available. Use **LM path** when you have the full alert block. Use **Manual path** when you're expanding proactively or the alert details are unclear.

---

### Path A — From a LogicMonitor alert (faster)

#### 1. Copy the LM alert block

From the LM email or Teams notification, copy the full alert details including:
- `Host:` field (server FQDN)
- `Datasource:` field (e.g. `WinVolumeUsage-C:`)
- `Group:` field (contains datacenter hint)
- `Value:` field (current usage %)

#### 2. Run the LM disk expansion script

Run in Kiro: **`AWS: Expand Disk (LM)`** — enter account name or leave blank for picker, then choose:
```
[2] Paste full alert block from LM
```

Paste the copied block and press Enter twice.

The script auto-extracts: server name, drive letter, datacenter.

Or from CLI:
```powershell
python scripts/aws/disk-expand/expand_disk_lm.py --account <AccountName>
```

#### 3. Continue at Step 3 below.

---

### Path B — Manual

Run in Kiro: **`AWS: Expand Disk`** — enter account name or leave blank for picker, then enter the server name or client code when prompted.

Or from CLI:
```powershell
python scripts/aws/disk-expand/expand_disk.py --account <AccountName>
```

---

### Step 3 — Review the disk table

The script queries the instance via SSM and displays current disk state:

```
#    Drive   EBS Volume ID             Device     EBS Size (GB)   OS Size (GB)   Type
1    C:\     vol-0abc123               /dev/sda1  100             100            gp3
2    E:\     vol-0def456               /dev/sdb   200             200            gp3
```

Identify the drive to expand.

### Step 4 — Enter the new size

The script prompts for the new size in GB. Enter a value **larger than the current EBS size**.

> EBS volumes cannot be shrunk. If you mistype, you cannot undo the EBS resize — only the OS partition resize has a window to cancel.

### Step 5 — Confirm the RFC summary

The script prints a change summary before executing. Copy this to your change ticket.

### Step 6 — Script executes

The script:
1. Modifies the EBS volume size via the AWS API (takes ~30 seconds to become available)
2. Waits for the volume modification to complete
3. Runs `Resize-Partition` via SSM to extend the OS partition to fill the new space
4. Reports the new drive size

---

## Verification

The script reports pre- and post-expansion sizes. Additionally:
- In LM, the disk usage % should drop on the next poll cycle (~5 minutes)
- Optional: RDP to the server and check `Get-PSDrive -Name <letter>` in PowerShell

---

## Rollback

EBS volume expansion is **irreversible** — the volume cannot be shrunk.

If the OS partition resize failed (SSM error):
1. The EBS volume is already expanded; only the partition is not yet using the space
2. RDP to the server and manually run Disk Management (`diskmgmt.msc`) → right-click the drive → Extend Volume
3. Or re-run the script — the SSM resize command is idempotent

---

## Related

- [`scripts/aws/disk-expand/README.md`](../scripts/aws/disk-expand/README.md) — technical detail on the SSM commands used
- [`inventory/ssm-documents.yml`](../inventory/ssm-documents.yml) — SSM document reference
- [`runbooks/aws-sso-setup.md`](aws-sso-setup.md) — if SSO session is expired
