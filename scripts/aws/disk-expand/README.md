# Foundation Disk Expand Tool

Expand EBS volumes and automatically resize OS partitions on Foundation OU servers via SSM.

## Usage

**Kiro task (preferred):** run **`AWS: Expand Disk`** from the task picker. Leave the account prompt blank to get the GUI OU picker.

**CLI:**
```
cd %USERPROFILE%\repos\cloudops
python scripts\aws\disk-expand\expand_disk.py
```

Add `--account <NAME>` to skip the picker (e.g. `--account PLUS`).

## Flow

1. GUI popup — select AWS OU
2. SSO login — opens browser if expired
3. Enter server name or client code (e.g. `PIED` or `PIED-PTRKWB001`)
4. Select the server from results
5. Displays all drives with:
   - Drive letter (C:\, D:\, etc.)
   - EBS Volume ID
   - Device name
   - EBS size (AWS side)
   - OS partition size (server side)
   - Volume type (gp3, gp2, etc.)
6. Select the drive to expand
7. Enter new total size in GB (must be greater than current)
8. Automatically:
   - Expands the EBS volume in AWS
   - Waits for modification to complete
   - Runs SSM command to rescan disk and expand the partition
   - Shows final Used/Free/Total space
9. Option to expand another disk, new server, different OU, or exit

## What it does behind the scenes

1. `ec2:ModifyVolume` — increases the EBS volume size
2. `Update-Disk` — rescans the disk inside Windows
3. `Resize-Partition` — extends the partition to use all available space
4. `Get-PSDrive` — reports final disk usage

## Note

EBS volumes can only be expanded (not shrunk). After expanding, you must wait ~6 hours before expanding the same volume again (AWS limitation).
