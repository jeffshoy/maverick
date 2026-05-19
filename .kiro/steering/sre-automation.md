# SRE Automation Steering (Kiro)

## Purpose

This document defines **how automation is created, evaluated, and maintained by the SRE team**.

Automation is expected to:
- Reduce toil
- Improve reliability and consistency
- Be safe to run repeatedly
- Be understandable by someone other than the original author

Kiro agents should treat this document as **non-negotiable guidance** unless explicitly overridden in a repo-specific steering file.

---

## Core Principles

### 1. Safety Before Speed

Automation must prioritize **safety and correctness** over speed.

- Assume automation may be run by:
  - Another SRE
  - On-call staff
  - CI/CD or scheduled jobs
- Never assume perfect context or flawless inputs

**Preferred pattern:**
- Validate inputs
- Simulate or dry-run first
- Make changes only after guardrails are satisfied

---

### 2. Idempotency Is Mandatory

All SRE automation **must be safe to run multiple times**.

- Re-running an automation should:
  - Make no changes if the system is already in the desired state
  - Never cause duplication, corruption, or escalation

If idempotency is not possible, the spec **must explicitly document why** and how the risk is mitigated.

---

### 3. Observability Is Part of the Automation

Automation is incomplete without visibility.

Every automation should:
- Emit meaningful logs
- Clearly state:
  - What it checked
  - What it changed
  - What it skipped
- Make failures actionable

If logs cannot answer *“what happened?”*, the automation is insufficient.

---

### 4. Explicit Scope and Blast Radius

Automation must clearly define:
- What systems it *will* touch
- What systems it *will not* touch

Avoid patterns such as:
- “All servers”
- “Everything in an account”
- Implicit discovery without filters

Scope must be:
- Intentional
- Documented in the spec
- Adjustable via configuration where possible

---

### 5. Human-in-the-Loop by Default

Unless explicitly designed for unattended use:

- Automation should:
  - Require confirmation for destructive actions
  - Surface a clear summary before execution
- Fully autonomous execution must be justified in the spec

Destructive actions should always be:
- Clearly labeled
- Logged at a higher severity
- Reversible when feasible

---

## Documentation Expectations

Every automation spec should answer:

- What problem does this solve?
- When should this be used?
- When should it *not* be used?
- What are the risks?
- How do I verify success?
- How do I roll back if needed?

If the automation cannot be safely explained in prose, it cannot be safely run.

---

## Change Management

Automation **is production code**.

Changes to automation must:
- Be reviewed
- Be understandable by someone other than the author
- Preserve backward safety unless explicitly documented

Behavioral changes should be called out clearly in the spec.

---

## What Does *Not* Belong in Automation

Avoid automating:
- One-time experiments
- Situations with unclear ownership
- Tasks still being actively figured out by humans

Exploration is encouraged — **promotion to automation is intentional**.

---

## Guiding Question (Use This Test)

Before finalizing automation, ask:

> “Would I be comfortable with another SRE running this at 3am during an incident?”

If the answer is no, refine the design.

---