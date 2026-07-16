# Application operations standard

Status: **canonical product philosophy for this repo** (not thoughtbot skill parity).  
Audience: humans designing Rails apps; authors of audit rules and optional annotate prompts.

**Independence.** The same standard is maintained as a **full copy** in the metz-scan
repository as well. The two gems do **not** depend on each other for this document (no
shared package, no runtime link). Copies may drift; that is accepted for now.

Related in *this* repo: [DESIGN.md](DESIGN.md), [README.md](../README.md).

## Why this exists

"Service object" is an overloaded label. Teams use it for:

- thin use-case orchestration at an application boundary, and
- ad-hoc procedural scripts (`UserService`, `NotifySlack`, `ProcessX.call` pipelines) that starve domain models of language.

Rails concerns are a parallel escape hatch: a file got big, so behavior is mixed in rather than modeled.

This document defines **when a dedicated operation object is legitimate**, what is **not**, the **concern bar**, and a **rule matrix** for mechanical enforcement. The goal is balance: neither "services for everything" nor "concerns for everything."

**Naming.** Prefer *application operation* (or just *operation*) for the legitimate case. "Service object" is treated as historical jargon; detection should not assume `app/services/` alone implies good design.

**Origin note.** rails-audit began from thoughtbot's rails-audit skill as a *genesis* for mechanizing audit detection. That skill is **not** a parity target. Rules here follow this standard, not thoughtbot heuristics.

---

## 1. Legitimate application operation

An application operation is a **thin command at an application boundary**. It is not the home of domain rules.

### Must have (all)

| # | Criterion | Meaning |
|---|-----------|---------|
| L1 | **Application boundary** | Invoked from a system edge: controller/API action, job, webhook handler, rake/CLI, mailer entry, etc. Not an internal helper invented to split one model's private method. |
| L2 | **Multi-boundary work** | Crosses at least one hard boundary: two or more aggregates/models **or** external I/O **or** multi-step side effects beyond a single Active Record save. |
| L3 | **Orchestration, not ownership** | Invariants, calculations, and state rules live on domain objects (AR models, PORO aggregates, value objects, policies). The operation sequences them and handles transaction/result shape. |
| L4 | **Single public entry** | One intentional API (`call`, `perform`, or one project-wide equivalent). No multi-method bag of use cases. |
| L5 | **Named as the use case** | `Checkout`, `RenewSubscription`, `ImportAccounts`, `HandleStripeWebhook` — not `UserService`, `MediaRatingHelper`, `Utils`. |
| L6 | **Thin body** | Mostly load → ask domain → persist/enqueue/notify → return result. If most lines are rules, the operation is a misplaced domain object. |

### One-line test

> If deleting this class would force inventing a real domain concept (or a clear method on an existing one), it was probably **illegitimate**.  
> If deleting it would leave a multi-step **application** use case with nowhere honest to live, it was probably **legitimate** — keep it thin.

### Allowed homes (convention, not magic)

Any of: `app/operations/`, `app/services/` (legacy), or domain namespaces (`Checkout`, `Billing::RenewSubscription`). Path alone never legitimizes the class.

---

## 2. Illegitimate (disallowed shapes)

Any of these disqualifies the class as a legitimate operation — regardless of folder or `.call` fashion.

| # | Smell | Why |
|---|-------|-----|
| I1 | **CRUD wrapper** | Only creates/updates/destroys a record with no real multi-boundary work. |
| I2 | **Single-model script** | Touches one model and belongs as an instance method, query object, or form object. |
| I3 | **God / multi-use service** | Several public methods for different use cases (`UserService#create/#deactivate/#notify`). |
| I4 | **Rules container** | Validations, pricing, state transitions, authorization implemented *inside* the operation instead of on domain/policy objects. |
| I5 | **Procedure-as-architecture** | Pipeline of micro-operations (`Validate` → `Reserve` → `Create` → `Charge` → `Email`) that only reifies a controller narrative with no domain concepts. |
| I6 | **Concern-shaped dump** | Same script moved into an `ActiveSupport::Concern` (or similar mixin) to avoid the "service" label. |
| I7 | **Presence as architecture** | Extracting every multi-line action into `Something.call` by default (command pattern as *paradigm*). |

Renaming (`Processor`, `Interactor`, `UseCase`, PORO) does **not** fix I1–I7. Shape and ownership do.

---

## 3. What is not an operation

These are legitimate when they fit. They are **not** application operations and should not be forced into the operation mold.

| Pattern | Role |
|---------|------|
| Domain model / PORO aggregate | Owns invariants and state transitions |
| Query object | Read-side composition |
| Form / input object | Params validation + one cohesive commit |
| Policy | Authorization decision |
| Job | Async *boundary* (may invoke an operation) |
| Gateway / adapter | External system API shape |
| Concern / mixin | Only a **stable, cohesive role** shared by similar types (see §4) |

---

## 4. Concerns: parallel high bar

Concerns organize **roles**, not workflows.

### Legitimate concern (all)

| # | Criterion |
|---|-----------|
| C1 | Names a **stable role** shared by multiple types (`SoftDeletable`, `Ratable`, `Publishable`) — not "stuff from `User`." |
| C2 | Methods form one cohesive vocabulary for that role. |
| C3 | Does not own multi-step application workflows (those stay at the boundary or in a thin operation). |
| C4 | Does not become the default extract when a file grows. |

### Illegitimate concern (any)

| # | Smell |
|---|-------|
| IC1 | Junk drawer: unrelated methods dumped from a fat model/controller |
| IC2 | Workflow disguised as mixin (callbacks + multi-model side effects + mailers/jobs in one concern) |
| IC3 | One-off include used by a single class with no shared role |
| IC4 | Concern soup: many includes per class, or huge concern files, used to avoid modeling |

**Balance rule:** service soup and concern soup are the same failure mode — **procedure without concepts** — under different file layouts.

---

## 5. Prefer before extracting an operation

In order:

1. **Method on the object that owns the data/invariant** (instance API when natural).
2. **PORO domain concept** with a clear noun and interface (not a free `run` script).
3. **Form / query / policy** when that is the real shape.
4. **Thin application operation** only when L1–L6 hold.
5. **Concern** only when C1–C4 hold.

Do **not** extract "because the controller is fat" without asking what concept is missing.

---

## 6. Enforcement philosophy

| Kind | Enforceable? | Approach |
|------|----------------|----------|
| Positive legitimacy (L1–L6 fully true) | Mostly **judgment** | Written checklist; optional LLM annotation; code review |
| Negative illegitimacy (I1–I7, IC1–IC4) | Mostly **mechanical** | Cops + project analyzers |
| Portfolio pressure (density, soup) | **Medium** | Cross-file analyzers; advisory or CI by team policy |

**Do not** enforce "must be a good service" as a single RuboCop rule.  
**Do** enforce "this shape is almost certainly abuse" and "this portfolio is process-heavy."

CI default recommendation: hard-fail local **abuse** rules; treat density/soup as design pressure (exit policy is product/team choice).

---

## 7. Rule matrix

Statuses: **shipped** | **planned** | **doc-only** (human/LLM).  
Homes in this copy: **rails-audit** (this product), **metz-scan** (sibling design coach; independent gem), **standard** (this doc).

### 7.1 Written standard

| ID | Rule | Home | Status |
|----|------|------|--------|
| S0 | This document is the definition of legitimate operations and concern bar | standard | **shipped** (this file) |
| S1 | Review checklist for L1–L6 / C1–C4 on new extractions | standard + optional annotate prompts | planned |

### 7.2 Local shape (RuboCop-class)

Shape-abuse enforcement with explainable design pressure is implemented in the **metz-scan**
gem (independent). rails-audit must **not** reintroduce thoughtbot-style "presence = smell."
Optional later: surface similar signals in the audit report without taking a gem dependency
(e.g. document pairing, or optional external ingest).

| ID | Rule | Detects | Home | Status |
|----|------|---------|------|--------|
| R1 | **Single public entry** on classes in operation paths (`app/services/**`, `app/operations/**`, configurable) | I3 multi-method bags | metz-scan `Metz/OperationsTooManyPublicMethods` | **shipped** (sibling gem) |
| R2 | **God `*Service` class** — `*Service` name + multiple public methods | I3 | metz-scan `Metz/GodServiceClass` | **shipped** (sibling gem) |
| R3 | **Trivial CRUD operation** — body is essentially one create/update/destroy (heuristic) | I1 | metz-scan | planned |
| R4 | **Fat operation body** — `call`/`perform` over line or branch thresholds | I4 / thinness failure | metz-scan | planned |
| R5 | **Concern bloat** — concern file method/line thresholds | IC1 | metz-scan | planned |
| R6 | **Too many app concerns** on one class | IC4 | metz-scan | planned |
| R7 | ~~Service object *presence* under `app/services` + `call`~~ | n/a (thoughtbot-era) | rails-audit | **removed** |

### 7.3 Cross-file / portfolio (project analyzers)

| ID | Rule | Detects | Home | Status |
|----|------|---------|------|--------|
| P1 | **Service soup** — one method coordinates ≥N distinct service-style calls | I5 | metz-scan `MetzProject/ServiceSoup` | **shipped** (sibling gem) |
| P2 | **Operation directory density** — high operations/models ratio or absolute count bands | I7 portfolio | metz-scan | planned |
| P3 | **Concern soup** — portfolio of bloated/over-included concerns | IC2, IC4 | metz-scan | planned |
| P4 | **Workflow-in-mixin** — concern defines callbacks + multi-model writes / job enqueues (heuristic) | IC2 | metz-scan | planned (phase 2) |

### 7.4 Product roles (independent gems)

Neither product depends on the other. Roles below are coordination *intent*, not package edges.

| ID | Product | Responsibility | Status |
|----|---------|----------------|--------|
| A1 | **rails-audit** | Auditor: security, correctness, Rails idiom, schema, complexity aggregation | shipped |
| A2 | **rails-audit** | Fat model / fat controller as **size** signals (not thoughtbot parity) | shipped |
| A3 | **rails-audit** | No service-object *presence* cop | **done** |
| A4 | **rails-audit** | Optional annotate: apply L1–L6 / I1–I7 checklist | planned |
| M1 | **metz-scan** | Design coach: shape abuse (R1–R6), portfolio soup (P*), explainable findings | R1/R2/P1 shipped there |
| A5 | both | Do **not** aim for thoughtbot skill parity | **policy** |

### 7.5 Explicitly out of mechanical scope (doc-only)

| ID | Question | Why static fails |
|----|----------|------------------|
| J1 | Does this operation own invariants that belong on a domain object? | Needs domain understanding |
| J2 | Is the name a real use case vs a script title? | Semantic |
| J3 | Multi-aggregate vs accidental multi-model touch? | Context-heavy |
| J4 | Should this be a job, gateway, or form instead? | Architecture judgment |

---

## 8. rails-audit product stance

1. **Done:** `RailsAudit/ServiceObject` presence detection is **removed**. This auditor no longer flags “class under `app/services` with `call`.”
2. **This document** is the full standard for readers of rails-audit alone; no need to open metz-scan to understand legitimacy / concerns.
3. **rails-audit** remains the multi-tool auditor (security, correctness, schema, size signals). Pair with metz-scan for design-pressure findings if desired — optional, not required, no gem dependency.
4. Fat model / fat controller stay as generic **size** pressure until replaced by clearer rules — not thoughtbot framing.

---

## 9. Suggested review checklist (humans / annotate)

For a proposed operation class:

- [ ] Boundary caller is clear (L1)
- [ ] Multi-boundary justification written in a one-line comment or PR note (L2)
- [ ] Domain rules live elsewhere (L3)
- [ ] Single public entry (L4)
- [ ] Use-case name (L5)
- [ ] Body is orchestration-thin (L6)
- [ ] Not I1–I7
- [ ] Concern alternative rejected for a reason other than "services are bad" (C1–C4 if using a concern)

---

## 10. References (ideas, not authority)

- Jason Swett — command pattern ≠ paradigm; prefer declarative domain structure  
- Jared White — service objects as anti-pattern when they replace OO design  
- metz-scan's `MetzProject/ServiceSoup` (sibling gem) — portfolio pressure on procedural pipelines  

None of these are parity targets; they informed the problem statement.
