# SRE Technology & Tooling Steering (Kiro)

## Purpose

This document defines **approved languages, tooling, and implementation standards** for SRE-owned automation.

Kiro agents must align generated solutions with these standards to ensure:
- Maintainability
- Team-wide readability
- Operational consistency
- Long-term support

This document defines **how automation is written**, not *what* it does.

---

## Supported Languages (In Order of Preference)

### 1. PowerShell (Primary)

PowerShell is the **default language** for SRE automation.

Use PowerShell when:
- Working on Windows systems
- Interacting with IIS, services, scheduled tasks, or Event Logs
- Automating AWS or Azure workflows from Windows
- Writing scripts expected to be run by on-call SREs

Preferred standards:
- Explicit parameter blocks
- Comment-based help for non-trivial scripts
- Structured objects over `Write-Host`
- Consistent error handling (`try/catch`, terminating errors)

---


### 2. Bash (Limited / Situational)

Bash is acceptable when:
- Operating in Linux-only environments
- Script complexity is minimal
- No PowerShell solution is cleaner

---

## Tooling Standards

### Version Control

All maintained automation must:
- Live in version control
- Be readable without IDE-specific extensions
- Prefer clear structure over cleverness

One-off experiments should not be promoted to automation.

---

### Formatting & Style

Automation should prioritize:
- Readability over brevity
- Explicitness over shortcuts
- Predictable structure across scripts

Kiro should favor:
- Consistent naming
- Clear variable intent
- Early validation of inputs

---

## Interfaces & Inputs

Automation should:
- Accept configuration via parameters or config files
- Avoid interactive prompts unless explicitly required
- Support non-interactive execution where safe

Environment-specific values must not be hard-coded.

---

## Error Handling & Exit Behavior

All automation must:
- Fail explicitly on unexpected conditions
- Use non-zero exit codes on error
- Avoid silent failures or ignored errors

Warnings should be used sparingly; errors must stop execution when safety cannot be guaranteed.

---

## Dependencies & External Tools

Automation must:
- Minimize external runtime dependencies
- Clearly document required modules, CLIs, or tools
- Prefer built-in capabilities over obscure third-party tools

If external tools are required:
- Their purpose must be clear
- Their failure modes must be handled

---

## AWS, Cloud & Platform Tooling

When interacting with cloud platforms:
- Prefer official SDKs or CLIs
- Do not mix multiple toolchains unnecessarily
- Ensure credentials are resolved via standard mechanisms (e.g., env vars, profiles, role assumption)

Cloud automation must clearly indicate:
- Target account
- Region
- Environment (prod, non-prod)

---

## Documentation Is Part of the Code

Automation is incomplete without:
- Clear intent
- Usage examples
- Expected outcomes

Scripts that require tribal knowledge to run safely are considered incomplete.

---

## Explicitly Discouraged Patterns

Avoid:
- Overly clever abstractions
- Framework-heavy solutions for simple problems
- Mixing multiple languages in a single workflow
- Hidden side effects
- Implicit environment assumptions

If simplicity and clarity conflict with elegance, choose simplicity.

---

## Guiding Question (Technical Lens)

Before finalizing automation, ask:

> “Would another SRE understand and trust this without talking to the author?”

If the answer is no, simplify.

---