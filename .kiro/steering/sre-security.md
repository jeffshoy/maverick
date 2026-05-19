# SRE Security Steering (Kiro)

## Purpose

This document defines **security expectations for SRE automation**.

Automation frequently operates with elevated privileges and broad access.
Security failures in automation scale faster than human mistakes.

Kiro agents must treat this document as **hard guardrails**, not suggestions.

---

## Security Is a Design Constraint

Security must be considered **at design time**, not added later.

Automation that is functional but unsafe is considered **incorrect**.

If a task cannot be automated safely, it must remain manual.

---

## Least Privilege by Default

Automation should:
- Use the **minimum permissions required**
- Avoid broad roles such as:
  - `Administrator`
  - `*FullAccess`
  - Account-wide policies

Where elevated privileges are unavoidable:
- Scope must be explicitly documented
- Access must be time-bound or role-bound where possible

---

## No Hard‑Coded Secrets — Ever

Automation **must not**:
- Embed credentials
- Store secrets in code, comments, or logs
- Write secrets to disk unintentionally

Secrets must be retrieved from:
- Secure stores (e.g., AWS SSM, Secrets Manager, Key Vault)
- Environment variables provided at runtime

If secure secret retrieval is unavailable, the automation **must fail explicitly**.

---

## Read‑Only First

All automation should support a **read-only / inspect / dry-run mode**.

Before making changes, automation must:
- Enumerate affected resources
- Report intended actions
- Allow human verification

Destructive actions without a preview are prohibited unless explicitly justified.

---

## Explicit Trust Boundaries

Automation must clearly define **trust boundaries**, including:
- What account, tenant, or environment it operates in
- What identities it assumes
- What external systems it communicates with

Cross-boundary actions (e.g., cross-account, prod↔non‑prod) must:
- Be explicit
- Be logged
- Require confirmation unless non-interactive execution is approved

---

## Guardrails on Destructive Actions

Destructive operations must:
- Be clearly labeled as destructive
- Require explicit intent (flags, confirmation, or spec approval)
- Log before and after state when feasible

Examples of destructive actions:
- Resource deletion
- Permission revocation
- Credential rotation
- Network rule changes

Silently destructive automation is not acceptable.

---

## Logging Without Leakage

Logs must:
- Be detailed enough for incident review
- Avoid secrets, tokens, private keys, or PII
- Redact sensitive fields if output is unavoidable

If logging risks exposing sensitive data, prefer:
- Structured summaries
- Counts
- Hashes or identifiers

---

## Failure Is a Security Event

Automation failures should be:
- Explicit
- Loud
- Actionable

Silent failures, partial execution, or ignored errors are security risks.

Automation must:
- Fail fast where safety cannot be guaranteed
- Exit with non-zero status on error
- Never continue blindly after a security-relevant failure

---

## Human Override Is a Feature

Automation should never prevent:
- Emergency intervention
- Break-glass access
- Manual recovery

Automation exists to assist humans — not trap them.

---

## Guiding Question (Security Lens)

Before approving automation, ask:

> “If this behaved incorrectly, could it cause a security incident?”

If the answer is yes:
- Tighten scope
- Add guardrails
- Or do not automate

---