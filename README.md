# cloudops

SRE automation for the CloudOps team — PowerShell, Python, and Bash scripts for Windows/AWS fleet operations, Active Directory management, and related tooling.

---

## First-time setup

**New teammate?** Start at [`docs/onboarding.md`](docs/onboarding.md) — it covers tool installs, clone location, AWS SSO, and Kiro setup. The bootstrap script does most of it in one shot:
```powershell
cd "$env:USERPROFILE\repos\cloudops"
pwsh scripts\setup\Initialize-Workstation.ps1
```

After that:
1. **Open the workspace** — in Kiro: **File > Open Workspace from File** → `cloudops.code-workspace`.
2. **Sync AWS config** — run task `Setup: Sync AWS Config`.
3. **Log in to AWS SSO** — run both `Setup: AWS SSO Login (foundation)` and `Setup: AWS SSO Login (legacy)`.

---

## Run a script in 10 seconds

1. Open `cloudops.code-workspace` in Kiro (**File > Open Workspace from File**).
2. Press **`Ctrl+Shift+P`** → **Tasks: Run Task**.
3. Pick a task from the list (prefixed by domain: `AD:`, `AWS:`, `ADSSP:`, `Sectigo:`, `DNS:`, `Setup:`).

The task will prompt for any required inputs and open a dedicated terminal.

**CLI fallback:** scripts live at stable paths under `scripts/`. Example:
```powershell
pwsh -NoProfile -File scripts/ad/Disable_users_4Domains.ps1
```

---

## Folder map

| Folder | Contents |
|--------|----------|
| `scripts/ad/` | Active Directory user management (disable, create) |
| `scripts/adssp/` | ADSS+ tooling — user sync, IBMi groups, RADIUS/NPS setup |
| `scripts/aws/` | AWS EC2/SSM fleet operations — disk expand, server reboot, service restart, site monitor, RDS license reset |
| `scripts/aws-dx/` | AWS Direct Connect route-table helpers (Bash) |
| `scripts/sectigo/` | Certificate lifecycle — mass revoke, mass server registration |
| `scripts/dns/` | DNS record management |
| `aws-configs/` | Team AWS CLI config — both SSO sessions, all 300+ accounts. Source of truth for `~/.aws/config`. |
| `runbooks/` | Incident and operational playbooks, each paired with a Kiro task |
| `inventory/` | Environment metadata — AD domains, SSM documents, OU paths |

---

## Adding a new script

Every new script must include:
- [ ] The standard scaffold from [`CLAUDE.md`](CLAUDE.md) Platform Guidance (`Set-StrictMode`, `[CmdletBinding(SupportsShouldProcess)]`, comment-based help, etc.)
- [ ] An entry in `.vscode/tasks.json` under the appropriate domain prefix
- [ ] A row in the relevant `scripts/<area>/README.md`
- [ ] A runbook in `runbooks/` (or an update to an existing one)

---

## Adding a runbook or inventory entry

- **Runbook:** add a `.md` file to `runbooks/` following the template in [`runbooks/README.md`](runbooks/README.md).
- **New AWS accounts:** run `aws-configs/tools/generate_aws_config.py`, commit the updated `aws-configs/cloudops.config` via PR, and teammates run `Setup: Sync AWS Config`.
- **AD domains / SSM docs / OUs:** edit the relevant YAML in `inventory/`.

---

## Skills

Claude Code skills are reusable prompts invoked with `/<skill-name>` from any Claude session in this workspace. Skills committed to `.claude/skills/` are auto-loaded for the whole team — no symlink required.

| Skill | Invocation | What it does |
|-------|-----------|--------------|
| rdp | `/rdp <server> <account>` | Opens an SSM RDP tunnel to any EC2 instance by fuzzy name and account alias |

**Adding a new skill:** create `.claude/skills/<name>/SKILL.md` with `name` and `description` frontmatter, open a PR. See the **Skills** section in [`CLAUDE.md`](CLAUDE.md) for the full authoring guide.

---

## References

- [`CLAUDE.md`](CLAUDE.md) — team AI standards, PowerShell scaffold, security rules
- [`aws-configs/README.md`](aws-configs/README.md) — AWS SSO setup and config refresh procedure
- [`runbooks/README.md`](runbooks/README.md) — runbook index
- [`.claude/skills/`](.claude/skills/) — repo-shared Claude skills
