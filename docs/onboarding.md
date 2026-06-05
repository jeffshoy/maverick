# CloudOps SRE — New Teammate Onboarding

Steps 1–2 must be done manually. After that, run the bootstrap script for a fast setup — or follow the manual steps if you prefer to see exactly what happens.

---

## 1. Install Kiro

Download and install Kiro from the internal software distribution. Use default settings.

---

## 2. Clone the repo

Open a PowerShell terminal and run:

```powershell
# Create the standard location if it doesn't exist
if (-not (Test-Path "$env:USERPROFILE\repos")) {
    New-Item -ItemType Directory -Path "$env:USERPROFILE\repos"
}
cd "$env:USERPROFILE\repos"
git clone https://psgov@dev.azure.com/psgov/Cloud-PA/_git/cloudops
```

The standard clone location is `%USERPROFILE%\repos\cloudops`. All documentation and tooling assume this path.

---

## Fast path — bootstrap script

After cloning, run the bootstrap script to complete steps 3–7 automatically:

```powershell
# Run from an elevated pwsh session — winget MSI installs and RSAT both require admin.
cd "$env:USERPROFILE\repos\cloudops"
pwsh scripts\setup\Initialize-Workstation.ps1
```

To launch elevated: right-click Windows Terminal → "Run as administrator", then open a `pwsh` tab.

Use `-WhatIf` to preview every action without making changes. Use `-SkipRsat` on non-domain-joined machines. If all tools are already installed, `-SkipWinget -SkipRsat` runs the remaining steps (symlink, settings, AWS config sync) without admin.

After the script succeeds, skip to [step 8](#8-open-the-workspace-in-kiro).

---

## Manual path

### 3. Install prerequisites via winget

winget is built into Windows 10/11 — no bootstrapping needed. Open a **new terminal** after these complete so PATH updates take effect.

```powershell
winget install --id Microsoft.PowerShell        --exact --accept-source-agreements --accept-package-agreements
winget install --id Amazon.AWSCLI               --exact --accept-source-agreements --accept-package-agreements
winget install --id Amazon.SessionManagerPlugin --exact --accept-source-agreements --accept-package-agreements
winget install --id Microsoft.AzureCLI          --exact --accept-source-agreements --accept-package-agreements
winget install --id Python.Python.3.12          --exact --accept-source-agreements --accept-package-agreements
winget install --id Git.Git                     --exact --accept-source-agreements --accept-package-agreements
```

### 3.5. Set PowerShell 7 as your default terminal shell

After step 3 finishes, PS7 is installed but Windows hasn't switched to it yet. Open a **new terminal** to pick up the updated PATH first.

**Windows Terminal:**
1. Open **Windows Terminal**.
2. Click the dropdown **▾** next to the new-tab button → **Settings**.
3. **Startup → Default profile → "PowerShell"** — the entry with the PS7 hex icon. **Not** "Windows PowerShell" (PS5.1).
4. Save and open a new tab to verify.

**Verify:**
```powershell
pwsh --version    # expect: PowerShell 7.x.x
```

**Claude Code CLI:** always launch `claude` from a `pwsh` session. With Windows Terminal defaulting to PS7, opening a new tab is enough. From an existing `powershell.exe` session, run `pwsh` first.

**Kiro:** already launches terminals as `pwsh` — no action needed.

### 4. Install RSAT (Active Directory + DNS tools)

Run from an **elevated** PowerShell session (required for AD and DNS scripts):

```powershell
Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
Add-WindowsCapability -Online -Name 'Rsat.Dns.Tools~~~~0.0.1.0'
```

Skip on non-domain-joined machines — you can add this later.

### 5. Install Python packages

```powershell
pip install boto3 colorama
```

`boto3` — required by all AWS Python scripts. `colorama` — terminal color output for site-monitor.

### 6. Link CLAUDE.md to Claude Code config

This makes Claude automatically load the team AI standards in every session.

**Preferred — symlink (auto-updates on `git pull`):**
```powershell
New-Item -ItemType SymbolicLink `
    -Path "$env:USERPROFILE\.claude\CLAUDE.md" `
    -Target "$env:USERPROFILE\repos\cloudops\CLAUDE.md"
```

**Fallback — copy (re-run after updates):**
```powershell
Copy-Item "$env:USERPROFILE\repos\cloudops\CLAUDE.md" "$env:USERPROFILE\.claude\CLAUDE.md"
```

### 7. Sync the team AWS config

```powershell
pwsh "$env:USERPROFILE\repos\cloudops\aws-configs\tools\Sync-AwsConfig.ps1"
```

This merges all 450+ team AWS profiles into `~/.aws/config`, preserving any personal profiles. A timestamped backup is written first. Run with `-WhatIf` to preview changes.

---

## 8. Open the workspace in Kiro

In Kiro: **File > Open Workspace from File** → select `cloudops.code-workspace` at the repo root.

This loads all Kiro tasks even when other folders are open alongside `cloudops`. The task launcher (`Ctrl+Shift+P` → **Tasks: Run Task**) is the primary way to run scripts.

**Fallback:** **File > Open Folder** on `%USERPROFILE%\repos\cloudops` also works for single-folder sessions.

---

## 9. Install the Claude Code extension

In Kiro: Extensions panel → search **"Claude Code"** → install.

The extension automatically reads `%USERPROFILE%\.claude\CLAUDE.md` — the file you linked in step 6.

---

## 10. Log in to AWS SSO

In Kiro, run both SSO login tasks, or from the CLI:

```powershell
# Foundation org (300+ accounts, role: cst-comm-cloudadmin)
aws sso login --sso-session foundation

# Legacy CentralSquare org (role: Cloud-Administrator)
aws sso login --sso-session legacy
```

Each opens a browser — sign in with your CentralSquare credentials. For full detail on the two sessions, see [`aws-configs/README.md`](../aws-configs/README.md).

---

## 11. Configure git identity

```powershell
git config --global user.name "First Last"
git config --global user.email "first.last@centralsquare.com"
```

---

## Verify your setup

```powershell
# Tools on PATH
pwsh --version      # PowerShell 7.x
aws --version       # aws-cli/2.x.x
az --version        # azure-cli x.x.x
python --version    # Python 3.12.x
git --version       # git version x.x.x

# AWS auth
aws sts get-caller-identity --profile PALegacySharedServices
# Expected: "Account": "361362055558"
```

Test a live task: in Kiro, run **`AWS: RDP to Instance`** with a known server name. Expect the SSM tunnel to open and `mstsc` to launch.

---

## What to read next

| Resource | Why |
|---|---|
| [`CLAUDE.md`](../CLAUDE.md) | Team AI standards — read before writing any automation |
| [`README.md`](../README.md) | Folder map and task launcher reference |
| [`aws-configs/README.md`](../aws-configs/README.md) | AWS SSO sessions and config refresh procedure |
| [`runbooks/`](../runbooks/) | Incident and operational playbooks |
