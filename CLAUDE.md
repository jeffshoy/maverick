# CloudOps SRE — Team-Wide Claude Standards

## Who We Are

This file is the authoritative Claude Code configuration for the **CloudOps SRE team** — a blend of System Administrator and DevOps engineering. We manage Windows workloads on AWS EC2, operate across multiple Active Directory domains, use Azure DevOps for source control, and write primarily in PowerShell. This file is **loaded automatically by Claude in every repo a teammate works in**, not just `cloudops`.

**Canonical source:** `CLAUDE.md` at the root of your `cloudops` clone (version-controlled, PR-reviewable).
Each teammate mirrors it to `%USERPROFILE%\.claude\CLAUDE.md` using the setup instructions below.
Standard clone location: `%USERPROFILE%\repos\cloudops`.

**Repo layout & invocation:** see [`README.md`](README.md) for the folder map and how to run scripts via the Kiro task launcher. **AWS SSO setup:** see [`aws-configs/README.md`](aws-configs/README.md).

---

## Setup — One-Time Per Teammate

**Fastest path — bootstrap script (recommended):**
```powershell
cd "$env:USERPROFILE\repos\cloudops"
pwsh scripts\setup\Initialize-Workstation.ps1
```
Installs all tools, links `CLAUDE.md`, and syncs the AWS config in one shot.
See [`docs/onboarding.md`](docs/onboarding.md) for the full guide and manual steps.

**Manual — Option A: Symlink (preferred, stays in sync automatically):**
```powershell
New-Item -ItemType SymbolicLink `
    -Path "$env:USERPROFILE\.claude\CLAUDE.md" `
    -Target "$env:USERPROFILE\repos\cloudops\CLAUDE.md"
```
Once set, `git pull` on `cloudops` updates Claude's guidance for everyone automatically.

**Manual — Option B: Copy (re-run after updates):**
```powershell
Copy-Item "$env:USERPROFILE\repos\cloudops\CLAUDE.md" "$env:USERPROFILE\.claude\CLAUDE.md"
```
Re-run this after pulling changes to the canonical file.

---

## Onboarding — New Teammate Quick Start

### Shell standard: PowerShell 7

The team standard is **PowerShell 7 (`pwsh`)** for all CLI work — Claude Code, Kiro terminals, script invocation, and ad-hoc shells. PS5.1 (`powershell.exe`) still ships with Windows but should not be used for team automation: several scripts (notably `scripts/aws/Connect-RDP.ps1` and `Find-Instance.ps1`) require PS7 features (parallel runspaces, `ForEach-Object -Parallel`).

The bootstrap script installs PS7 via winget. After install:

- **Windows Terminal:** Settings → Startup → Default profile → **"PowerShell"** (PS7 icon), not "Windows PowerShell" (PS5.1).
- **Claude Code CLI:** launch `claude` from a `pwsh` session. Verify with `pwsh --version` (expect 7.x).
- **Kiro:** already uses `pwsh` — no action needed.

**Key built-in commands:**
| Command | What it does |
|---------|-------------|
| `/help` | List available commands |
| `/clear` | Reset the conversation context |
| `/fast` | Toggle fast mode (Opus with faster output) |
| `! <cmd>` | Run a shell command inline and put the output into the conversation |

**Plan mode:** Start a session with Plan mode on for any design-first or prod-touching work. Claude will research, draft a plan for your review, and only act after you approve.

**Memory:** Claude builds a persistent memory index at `~/.claude/projects/.../memory/`. It loads automatically each session and grows over time with context about how you work. Review it periodically — sensitive context should not live there.

**Skills:** The team can define reusable prompts as skills in `~/.claude/skills/`. Invoke them with `/<skill-name>`. If you find yourself typing the same prompt repeatedly (e.g., "scaffold a disable-user script for domain X"), promote it to a skill.

**If Claude drifts:** Paste the relevant section of this file into the chat as a reminder, or file a PR to add a rule. The file is the source of truth.

**If you find a mistake in this file:** Open a PR in the `cloudops` repo. One teammate review minimum before merge.

---

## Using Kiro (IDE) Alongside Claude Code

Management has standardized on **Kiro** as the team IDE. Kiro is a VS Code fork, which means the **Claude Code VS Code extension installs inside it** — same engine, same `CLAUDE.md`, no separate rule system to learn.

**Team posture: Kiro is the IDE; Claude Code is the assistant; this file is the law.**

### Setup in Kiro (after the symlink/copy setup above)

1. Open Kiro → Extensions panel → search **"Claude Code"** → install.
2. The extension reads `%USERPROFILE%\.claude\CLAUDE.md` automatically — the same symlink you already created. No extra config.
3. Open the repo via **File > Open Workspace from File** → select `cloudops.code-workspace` at the repo root. This ensures all Kiro tasks appear even when other folders are open alongside `cloudops`.
4. Start a Claude Code session from the extension's sidebar.

**Fallback:** **File > Open Folder** on `%USERPROFILE%\repos\cloudops` also works for single-folder sessions — tasks load from `.vscode/tasks.json`.

### When to reach for the CLI vs the Kiro IDE

| Scenario | Preferred tool |
|---|---|
| Incident response, fleet ops, `! <cmd>` inline | CLI |
| Scaffolding a new script with visual diff/approve | Kiro + extension |
| Multi-step tool design (spec → code → review) | Claude Code Plan mode (CLI or IDE — pick one) |
| Quick edits and one-off questions | Either |
| Anything touching prod, AD, AWS, or Azure | Claude Code + **Plan mode required** |

### Kiro-native features (Specs, Agent Steering, Hooks)

Treat these as **opt-in extras** — useful if a teammate finds them genuinely valuable, but not team-mandatory. **Do not commit `.kiro/steering/`, `.kiro/specs/`, or `.kiro/hooks/` to the repo** — those paths are `.gitignore`d. Keep this file as the single source of truth; maintaining parallel Kiro steering that mirrors this file creates drift and extra maintenance.

---

## AI Etiquette — How to Work with Claude

These rules govern how Claude should behave on this team's work.

- **Use Plan mode before writing any script that touches production, AD, AWS, or Azure resources.** Plan mode is invoked by starting a session with `/plan` or pressing the Plan toggle. Claude will design before acting. Quick README edits and local-only refactors do not require it.
- **Ask before acting on anything irreversible:** user disables, object deletions, permission revocations, role changes, mass updates, or anything that would use `-Confirm:$false` or `-Force`. Surface the action explicitly and wait for approval.
- **Interpret ambiguous requests as questions.** If the user asks "can you do X?", answer the question before doing anything. Don't assume "can you" means "please do."
- **Surface assumptions before acting.** If a target account, region, AD domain, or environment is not specified, ASK. Do not guess or default silently.
- **Scaffold new scripts to the standard.** Follow the PowerShell structure defined in the Platform Guidance section above — required header, `[CmdletBinding(SupportsShouldProcess)]`, strict mode, error action, comment-based help, and input validation.
- **Treat unattended execution targets (pipelines, scheduled tasks, crons) with extra scrutiny.** The 3am test applies double. State blast radius and failure modes explicitly before generating.
- **Automation that is functional but unsafe is incorrect.** Do not ship the first working version if it violates security or safety rules. Fix it first.

---

## Core Operating Principles

These are non-negotiable. Claude MUST apply them to every piece of automation it generates.

- **Safety before speed.** Validate inputs. Simulate or dry-run before making changes. NEVER optimize for brevity at the cost of correctness.
- **Idempotency is mandatory.** Re-running automation MUST be safe. If idempotency is not possible, the script MUST document why and how the risk is mitigated — loudly, at the top.
- **Observability is part of the automation.** Logs MUST answer: what it checked, what it changed, what it skipped, what failed. If logs cannot answer *"what happened?"*, the automation is incomplete.
- **Explicit scope and blast radius.** NEVER generate scripts that target "all servers", "everything in an account", or use implicit discovery without filters. Scope MUST be intentional and configurable.
- **Human-in-the-loop by default.** Automation MUST require confirmation before destructive actions unless explicitly designed and documented for unattended use.
- **Automation is production code.** Changes require review. Behavioral changes must be called out. Scripts that require tribal knowledge to run safely are incomplete.

**The 3am test:** Before finalizing any automation, ask — *"Would I be comfortable with another SRE running this at 3am during an incident?"* If no, refine it.

**The trust test:** Ask — *"Would another SRE understand and trust this without talking to the author?"* If no, simplify it.

**The security test:** Ask — *"If this behaved incorrectly, could it cause a security incident?"* If yes, tighten scope, add guardrails, or do not automate.

---

## Security Guardrails

These are **hard rules**. No exceptions without an explicit, documented justification.

- **NEVER hard-code secrets.** Credentials, tokens, API keys, passwords, and connection strings MUST come from AWS SSM Parameter Store, AWS Secrets Manager, Azure Key Vault, or runtime environment variables. If secure retrieval is unavailable, the script MUST fail explicitly with a clear error message.
- **NEVER suggest overly permissive roles or policies.** No `Administrator`, no `*FullAccess`, no account-wide policies. Least privilege always. Elevated access MUST be scoped, time-bound, and documented.
- **NEVER bypass MFA, approval gates, or break-glass procedures.** Claude MUST NOT help circumvent access controls, even when asked to "just make it work."
- **Read-only / dry-run first.** All automation that modifies resources MUST support a `-WhatIf`, dry-run, or inspect mode. Destructive actions without a preview are prohibited unless explicitly justified in the spec.
- **Explicit trust boundaries.** Cross-account, cross-tenant, and prod↔non-prod actions MUST be explicitly declared, logged, and confirmed. NEVER assume environment from context alone.
- **Logs MUST NOT contain secrets or PII.** Use hashes, counts, or redaction. Structured summaries over raw values when sensitive data is involved.
- **Failures must be loud, fast, and non-zero.** Silent failures, partial execution, and swallowed errors are security risks. NEVER continue blindly after a security-relevant failure.
- **Automation MUST NOT prevent human override.** Break-glass access and manual recovery must always remain possible.

---

## Platform Guidance

### PowerShell (Primary Language)

PowerShell is the **default language** for all SRE automation. Use it unless the target is Linux-only.

Every non-trivial script MUST include:

```powershell
#Requires -Modules <ModuleName>

<#
.SYNOPSIS
    One-line summary.
.DESCRIPTION
    Full description of what the script does, when to use it, and when not to.
.PARAMETER ParamName
    Description of each parameter.
.EXAMPLE
    .\Script-Name.ps1 -ParamName Value
.NOTES
    Author, date, ticket reference.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $RequiredParam,

    [Parameter()]
    [switch] $WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

- MUST use `try/catch` with terminating errors (`-ErrorAction Stop` on cmdlets inside `try` blocks).
- MUST emit structured objects, not `Write-Host` strings, for pipeline-able output. Use `Write-Verbose`, `Write-Warning`, `Write-Error` appropriately.
- MUST exit with non-zero codes on failure: `exit 1`.
- MUST support non-interactive execution (no blocking `Read-Host` unless `-Interactive` is an explicit flag).
- MUST validate inputs early — fail fast before touching any remote system.

### Language Choice — PowerShell vs Python

PowerShell is the default for new automation. Reach for Python only when one of the following clearly applies:

- **Linux-only target** (e.g., `AWS-DX/`).
- **Heavy AWS data wrangling** — boto3 paginators, multi-service workflows, JSON shaping where AWS.Tools would be verbose. The existing `aws-configs/tools/generate_aws_config.py` and `scripts/aws/aws_sso_helper.py` are the reference patterns.
- **GUI / picker UX** — Tkinter is the team standard; do not shoehorn WinForms/WPF.
- **Significant data work** — joins, dedup, group-by aggregations, regex-heavy string parsing.

Stay in PowerShell for: AD operations (RSAT module is mandatory), Windows fleet ops (services, registry, WinRM, SSM Run Command with PS documents), Windows file/cert/installer work, and anything that pipes structured objects between cmdlets. Do not rewrite working PS scripts in Python without a concrete reason from the list above.

### AWS (EC2 and Adjacent Services)

- MUST declare target account, region, and environment at the top of every script.
- Credentials MUST be resolved via instance profiles, SSO, or role assumption — NEVER embedded keys or access key literals.
- Prefer AWS.Tools (modular) or AWS CLI v2 over AWSPowerShell (monolithic).
- For fleet operations, prefer SSM Run Command over direct SSH/WinRM where possible.
- Secrets MUST come from SSM Parameter Store (`Get-SSMParameter -WithDecryption $true`) or Secrets Manager.
- **SSO token expiry — Claude must self-recover:** When any `aws` CLI command fails due to an expired SSO token (exit code non-zero and output contains "expired" or "Token has expired"), Claude MUST handle the refresh automatically without asking the user:
  1. Read `aws-configs/accounts.json` to resolve the account's `ssoSession` field (`foundation` or `legacy`).
  2. Run `aws sso login --sso-session <session>` via Bash tool — **never ask the user to run this**.
  3. Retry the original command.
  This applies whether Claude is calling a helper script or issuing raw `aws` CLI commands directly. Never bounce the user to a terminal for SSO re-authentication.

### Azure / Azure DevOps

- Use Az PowerShell modules, not AzureRM. Always scope `Connect-AzAccount` to a specific subscription.
- AzDo pipelines: NEVER store secrets in pipeline variables without marking them secret. Use Azure Key Vault integration.
- Variable groups that reference Key Vault are preferred over inline secrets in YAML.

### Windows Server / Active Directory

- For multi-domain operations, ALWAYS target each domain explicitly. NEVER enumerate the forest implicitly.
- The four-domain pattern in `User_Management/` is the established pattern — follow it.
- Use RSAT/ActiveDirectory module cmdlets. Validate domain reachability before bulk operations.
- AD changes MUST log before and after state (samAccountName, DistinguishedName, property changed, old value, new value).

### Bash

Bash is acceptable **only** for Linux-only targets (e.g., `AWS-DX/`). It is not the default. Do not mix PowerShell and Bash in a single workflow.

---

## Git / Azure DevOps Workflow

- **NEVER push directly to `main` or `master`.** All changes go through a feature or fix branch and a PR.
- **Branch naming:** short and descriptive — `feature/<short-desc>`, `fix/<short-desc>`, or `<name>-<topic>` (e.g., `trent-disable-user-fix`).
- **Commits:** imperative mood, what + why. Reference the AzDo work item or ticket number when applicable (e.g., `Add dry-run flag to Disable_users script (#1234)`).
- **PR descriptions:** Every PR MUST have a markdown description. No exceptions. Use this structure:

  ```markdown
  ## Summary
  - What changed and why (bullet points, one per logical change)
  - Reference the ticket/work item if applicable (#1234)

  ## Test plan
  - [ ] Specific step to verify the change works
  - [ ] Edge case or rollback check if relevant

  ## Blast radius (operational scripts only)
  - Scope: which accounts/domains/servers are affected
  - Dry-run output or WhatIf evidence attached
  ```

  Claude MUST generate this description whenever it creates a PR. A PR with no description or a one-liner will be rejected in review.

  **Creating PRs — always use the wrapper.** Claude MUST create PRs by calling `scripts/azdo/New-PR.ps1` from `pwsh`. Never invoke `az repos pr create` directly and never inline Python subprocess snippets — both produce parse errors when shell, heredoc, or escape boundaries don't align.

  Workflow:
  1. Write the PR description to a temp markdown file using the Write tool: `C:\Temp\pr-<short-slug>.md`
  2. Run the wrapper:
  ```powershell
  pwsh scripts\azdo\New-PR.ps1 `
      -Title "fix(scope): summary" `
      -DescriptionFile "C:\Temp\pr-<short-slug>.md"
  ```
  3. The wrapper prints `PR <id>: <url>` — include that URL in the response.

- **Claude MUST print the web URL** after creating a PR. The wrapper prints it automatically. Never report just the PR ID and expect the user to look it up.
- **Claude MUST NOT** run `git push`, create PRs, close PRs, or merge branches without an explicit instruction from the user **in the current turn**. A prior approval does not carry forward.
- **NEVER use `--no-verify`** to skip hooks. NEVER amend a commit that has already been pushed. NEVER `--force` push without explicit user approval in the same turn.

---

## Quick-Reference: What NOT to Do

A fast checklist for reviews and 3am incidents.

**Claude MUST NEVER:**
- [ ] Hard-code passwords, tokens, API keys, or connection strings in any file
- [ ] Suggest `Administrator`, `*FullAccess`, or account-wide IAM policies
- [ ] Generate scripts that target "all servers" or use unfiltered discovery
- [ ] Skip read-only / dry-run mode before destructive operations
- [ ] Push to `main`/`master` or merge PRs without explicit user instruction
- [ ] Use `--no-verify`, `--force-push`, or amend pushed commits without explicit approval
- [ ] Log secrets, tokens, or PII
- [ ] Continue executing after a security-relevant failure
- [ ] Bypass MFA or break-glass controls
- [ ] Cross account/tenant/environment boundaries without declaring and confirming it
- [ ] Generate automation for production without Plan mode being used first
- [ ] Assume a target environment, domain, or account that wasn't stated explicitly

**Claude MUST ALWAYS:**
- [ ] Validate inputs before touching any remote system
- [ ] Support `-WhatIf` or dry-run in any script that modifies resources
- [ ] Include comment-based help, `[CmdletBinding(SupportsShouldProcess)]`, `Set-StrictMode`, and `$ErrorActionPreference = 'Stop'` in PowerShell scripts
- [ ] Exit non-zero on failure
- [ ] Log what was checked, changed, skipped, and why
- [ ] Ask if scope (account, region, domain, environment) is not specified
- [ ] Surface blast radius before generating any operational automation
- [ ] Apply the 3am test, the trust test, and the security test before finishing
