# Design: `rails-audit` — deterministic Rails audit CLI

`rails-audit` is a working-name placeholder, not a final product name.

Status: draft, post-spike, post-micro-spikes. Grounded in `rails-audit-spike/`
(implementation-notes.md, implementation-notes-llm.md, SCHEMA.md, RAILS_AUDIT_REPORT.md,
ANNOTATIONS.md, `lib/*.rb`, `bin/audit`, `bin/annotate`), plus two follow-up micro-spikes
run 2026-07-10 to close this doc's two biggest open questions:
`implementation-notes-spikeA.md` (RuboCop config-landmine behavior against a target
shipping its own `.rubocop.yml` with missing gems, target: Mastodon) and
`implementation-notes-spikeB.md` (tool behavior at 5k+ file scale, target: Discourse,
10,679 Ruby files, ~21x Lobsters). Every claim below either cites a spike artifact or is
marked **Proposed — not validated by spike**.

## 1. Summary

`rails-audit` is a CLI that runs a pinned toolchain of static-analysis tools (brakeman,
rubocop + extensions, reek, and future additions) against a Rails codebase, normalizes
their output into one findings schema, and renders an impact-ranked Markdown report —
deterministically, with the CLI owning all analysis configuration rather than trusting
whatever the target repo happens to ship.

**Product identity.** rails-audit is an **auditor** (security, correctness, Rails idiom,
schema, complexity, and selected design *size* signals) — not a design coach and not a
parity implementation of any external skill. Optional LLM annotation adds prioritization
judgment on top of deterministic findings; it is never part of the audit contract.

**Genesis (not authority).** Early exploration was inspired by thoughtbot's
`rails-audit-thoughtbot` skill and the estimate that much of a Rails audit is
mechanizable. That skill is **origin context only** — not a feature checklist, severity
model, or design philosophy to match. Design rules for application operations and
concerns live in [`docs/application-operations.md`](application-operations.md) (full
standard in this repo; an independent copy may exist in metz-scan — no hard dependency).
Opinionated Sandi-Metz-style design pressure is a separate product
([metz-scan](https://github.com/fuentesjr/metz-scan)), optional to pair with this auditor.

The spike (`rails-audit-spike/`) was a throwaway thin slice — brakeman/rubocop/reek against
Lobsters, normalize, render, one `claude -p` annotation pass — built specifically to surface
integration-seam surprises before this design was written. Its findings, not this document's
own reasoning, are the primary evidence base below.

## 2. Goals / Non-goals

**Goals**
- Same findings set, every run, for a given target commit + pinned toolchain version.
- Own all analysis configuration; never silently inherit target-repo suppression/config.
- One normalized findings schema across tools, usable by the report renderer, the LLM
  annotation layer, and (later) diffing/CI-gating.
- A ranking model that separates "how sure the tool is" (confidence) from "how bad it'd
  be if real" (impact).
- A report where 23 findings that matter aren't visually swamped by 11,000+ that don't.

**Non-goals (v1)**
- Replacing human/LLM judgment — the LLM annotation layer is optional, off by default,
  and explicitly a second opinion, not ground truth (spike: `ANNOTATIONS.md` header text).
- IDE integration.
- Autofix / auto-remediation.
- Non-Rails projects.
- Running the target's own test suite as a side effect of detection (see §8, SimpleCov).

## 3. Background: what the spike taught us

Each item cites its `implementation-notes.md` (phases 1-2, 4) or
`implementation-notes-llm.md` (phase 3) entry.

**Config ownership breaks silently, twice, by two different mechanisms.**
- Brakeman auto-loads the target's own `config/brakeman.ignore` with zero flags. Default
  run against Lobsters: 27/27 findings moved to `ignored_warnings`, 0 in `warnings` — a
  caller parsing JSON only (not the human console log) would see an empty report and
  conclude "no issues," when 27 real findings were suppressed by the target's own config.
  Fix required an explicit `-i <empty-ignore.json>` override (`implementation-notes.md`
  phase 1, "Brakeman auto-loads the target repo's own suppression file").
- Installing `rubocop-rails`/`rubocop-performance` as Gemfile dependencies does **not**
  make their cops run. Confirmed via `--show-cops`: 0 `Rails/*`, 0 `Performance/*` cops
  loaded against Lobsters (which ships no `.rubocop.yml`), vs. 7 core `Security/*` cops
  loaded regardless. Net effect: the Rails/Performance sections of the spike's own report
  are legitimately empty, "but for the wrong reason (never loaded) rather than 'codebase
  is clean' — and the report itself can't tell those two situations apart"
  (`implementation-notes.md` phase 2). **This is now resolved, not just diagnosed**:
  micro-spike A force-required both extensions via a CLI-owned config against the same
  Lobsters target and confirmed Rails 0→123, Performance 0→30 offenses, cross-checked
  both by offense-department tally and independently by `--show-cops` (138 `Rails/*` / 52
  `Performance/*` cops confirmed loaded) — the fix works, not just the flag
  (`implementation-notes-spikeA.md`, Experiment 4 / Experiment 5b).

**Three severity vocabularies, one tool with none.** brakeman: `confidence`
(High/Medium/Weak). rubocop: `severity` (fatal/error/warning/convention/refactor). reek:
no severity field at all in JSON output (confirmed by key-union across all 1,700
findings) — its human-report "mass"/complexity score is not exposed via `--format json`.
Any severity used for reek is invented, not derived (`implementation-notes.md` phase 1-2,
SCHEMA.md).

**Location shapes diverge non-trivially.** brakeman: single `line` int + optional
`location.{class,method}`, no column. rubocop: `start_line/start_column/last_line/
last_column` — full range, most precise. reek: `lines` as an **unordered array**, can have
>1 entry for smells spanning multiple statements (e.g. `TooManyStatements`). None collapse
cleanly into "start line + end line" without loss (`implementation-notes.md` phase 2).

**Fingerprint collisions are real, not hypothetical — including brakeman's own native
fingerprint.** Two distinct XSS warnings on `app/views/comments/_comment.html.erb:155` and
`:158` share the identical brakeman fingerprint. Synthesized fingerprints collide far more:
rubocop 11,176 raw findings → 9,162 unique (1,529 collision groups covering 3,543
findings, e.g. two distinct `Style/StringLiterals` offenses on `Gemfile:18` at columns 5
and 24 collapsing to one hash because column isn't part of the input); reek 1,700 raw →
1,468 unique (140 groups covering 372 findings, e.g. two distinct `DuplicateMethodCall`
smells on `application_controller.rb:99-100` differing only by the smell's `name` field,
which isn't hashed) (`implementation-notes.md` phase 2).

**stdout is not a safe channel for any of these tools.** rubocop emits a "new cops not
configured" nag block on stdout on every run, JSON mode or not — it doesn't corrupt
`--out <file>` output but would corrupt a captured-stdout parse. reek has no `--out`/`-o`
flag at all (undocumented `--format json` writes to stdout only); the runner captures it
via `Open3.capture3` and writes it to disk itself, purely to preserve "normalizer never
reads captured stdout directly" (`implementation-notes.md` phase 1-2).

**Exit codes are non-uniform and tool-version-specific.** Confirmed by direct
invocation, not assumed from docs: brakeman `3` = warnings found, rubocop `1` = offenses
found, reek `2` = smells found (not the more commonly assumed `1`). `$? != 0` cannot mean
"crashed" uniformly across tools (`implementation-notes.md` phase 1-2).

**Runtimes are environment-sensitive, not just tool-sensitive.** Phase 1's initial run on
Lobsters (~500 files) recorded brakeman ~4s, rubocop ~5s wall (31s CPU, parallelized),
reek ~5-6s. Phase 2's separate end-to-end verification run recorded a full pipeline of
~14s wall clock (13.80s user / 3.19s system / 119% CPU), with brakeman 5.18s, rubocop
2.55s, reek 5.84s per tool — a different run on the same machine, not directly comparable
figure-for-figure to phase 1's numbers above. The orchestrator's independent re-run from a
different sandboxed shell reproduced identical findings content, but rubocop took **662s
wall at ~6% CPU** with similar total CPU-time to the builder's runs — pure
sandboxing/process-throttling effect. `runtime_s` in report output is not comparable
across machines (or, per the above, reliably comparable even run-to-run on the same
machine) and must not be treated as a stable output (`implementation-notes.md` phases 1,
2, 4).

**The LLM call is fragile in exactly the way "just shell out" would miss.** A typical
`claude -p` call took ~70-90s wall, almost all network/model wait. Against the real
13k-finding digest, the first real attempt hung ~17.5 minutes then exited 1 with **empty
stderr** — no diagnostic at all; a manual retry succeeded in 90s. This was observed once,
not reproduced; root cause (transient network/sandbox) unconfirmed
(`implementation-notes.md` phase 4, `implementation-notes-llm.md`).

**Digest truncation is not an edge case — it fires on every real run.** At 12,903
findings, the aggregate (medium/low/info) section's 40-row cap was exceeded on the first
real invocation: 77 rule groups / 545 findings dropped, explicitly marked. The fixture
(33 hand-written findings) never exercised this path; only synthetic stress tests and,
later, the real run did (`implementation-notes.md` phase 4, `implementation-notes-llm.md`).

**Two independent LLM invocations, against two different datasets, both attacked the same
severity/confidence conflation — stronger corroboration than either alone.** The phase-3
run (a hand-written 33-finding fixture, no access to SCHEMA.md or the notes) already
surfaced brakeman's `confidence`-vs-real-world-severity conflation on its own: "the LLM
found this from the aggregate/individual digest alone... is a genuine signal that the
digest carries enough structure for useful second-order critique"
(`implementation-notes-llm.md`). The phase-4 run, against the real 12,903-finding
dataset under the same blind conditions, independently re-derived the same critique and
added findings the phase-3 fixture was too small to surface: (a) correctly identified
that ~76% of rubocop findings are default-config convention mismatch, not code defects —
"one config decision... plus one autocorrect run away from near-zero; do not hand-fix";
(b) flagged that ranking all XSS above all SQLi is backwards by real-world impact; (c)
flagged that the 51 `correctness` (`Lint/*`) findings are "buried in a count bucket while
lower-impact style noise dominates visually" and "deserve line-by-line triage, not a
count bucket" — a genuine miss, since only `security` findings are currently surfaced
individually regardless of category (`ANNOTATIONS.md`, `implementation-notes.md` phase 4,
`implementation-notes-llm.md`).

## 4. Architecture

Pipeline: **runners → normalizer → renderer**, with annotation as a fully separate
command (`bin/annotate`, taking a `findings.json` path as input) — not a stage of the
main pipeline. This mirrors the spike's structure (`bin/audit` vs `bin/annotate`) and is
kept for a concrete reason: annotation is 70-90s+ of network-bound latency behind a
paid API call, `bin/audit` is a ~15s local static-analysis run; conflating them would make
every audit invocation pay LLM latency/cost whether or not annotation was wanted
(`implementation-notes-llm.md`, "A production digest contract needs a cost/latency budget
line").

- **Runners** (one per tool): shell out via `Open3.capture3(*argv, chdir: <root>)` with
  argv arrays, never shell strings. Each writes raw tool-native JSON to a file via the
  tool's own `--out`/`-f`/`-o` flag where one exists; where it doesn't (reek), the runner
  captures stdout itself and writes it to disk before ever parsing it, so the parse step
  is always "read from a file" — never "parse captured stdout" (decision #6; spike
  `lib/runners.rb`). Per-tool exit codes are checked against a hardcoded, toolchain-
  version-scoped table; anything else raises with the tool's stderr attached. Runners are
  independent subprocess calls today, run serially. Micro-spike B measured ~7 minutes
  serial total at Discourse's scale (brakeman + rubocop + reek); running them concurrently
  (e.g. a `Thread.new` per runner, or a process pool) would cut wall time to roughly the
  slowest tool's duration (~227s) instead of the sum — a real but modest win, not a
  "broken without it" finding, and cheap to add later given the existing architecture
  already supports it trivially (`implementation-notes-spikeB.md`; also delivery plan §10
  phase 7).
- **Normalizer**: parses each tool's raw JSON into the v2 finding schema (§5). Owns the
  impact/confidence/category/location/identity mapping tables. Pure function of raw JSON
  in, findings JSON out — no subprocess calls.
- **Renderer**: `findings.json` → `RAILS_AUDIT_REPORT.md` (§6). Pure function, no
  subprocesses.
- **Annotate** (separate binary): `findings.json` → digest → `claude -p` → an annotations
  file (§7).

**Config ownership model.** The CLI carries its own analysis config (rubocop base
`.rubocop.yml` requiring `rubocop-rails`/`rubocop-performance` explicitly, a canonical
empty brakeman ignore file, reek config if/when reek config becomes relevant) and applies
it regardless of what the target repo ships. Respecting the target's own suppression/lint
config is opt-in via an explicit flag, never the default — directly answering the open
question the spike raised but didn't resolve ("should we always force-override target
ignore files... Silent divergent behavior based on file presence in the target is the
wrong default for a tool whose whole premise is deterministic," `implementation-notes.md`
phase 2).

**RuboCop invocation strategy — observed, not just anticipated
(`implementation-notes-spikeA.md`).** A target shipping its own `.rubocop.yml` that
declares `plugins:`/`require:` entries for gems we don't have is a real landmine, not a
hypothetical one: micro-spike A confirmed a plain `bundle exec rubocop` invocation against
such a target (Mastodon, which requires `rubocop-capybara`/`-i18n`/`-rspec`/`-rspec_rails`
— gems absent from our vendored bundle) **exits 2 with a raw, uncaught `LoadError`
backtrace and writes no JSON output at all** — the same "crashes ugly, not gracefully"
failure shape already documented for brakeman's ignore-file surprise (§3). Both
`--force-default-config` and a CLI-owned `--config <file>` fully prevent this — config
resolution short-circuits before the target's `plugins`/`require` list is ever reached,
and both produced functionally equivalent offense counts/department breakdowns in the
spike (Experiments 2, 3, 5b). **Decision: adopt a CLI-owned `--config <file>` as the
primary mechanism**, not bare `--force-default-config` — the config *file* is also where
the CLI's `NewCops` policy, `Metrics` preferences, and (see §9) a CLI-owned `Exclude` list
all need to live regardless, and `--force-default-config` alone gives no hook for any of
that; it remains a documented, functionally-equivalent fallback if a config-file-free
invocation is ever preferred, not a second-class option.

**CRITICAL CORRECTION versus this doc's prior phrasing**: the CLI's rubocop extension
gems must be declared inside that owned config (or via `--force-default-config` plus
explicit flags), **not** via bare `--require`/`--plugin` CLI flags alone. Micro-spike A
Experiment 5 confirmed `--require rubocop-rails --require rubocop-performance` with no
`--config`/`--force-default-config` hits the exact same crash as the unmitigated case —
flag-driven requires and the target's own config discovery are additive, not substitutive,
unless discovery itself is disabled or replaced. Flags alone only help when the target
ships no rubocop config at all (Lobsters' case) or already delegates to
`--force-default-config`/`--config`; they are not an independent defense.

**Prefer `plugins:` (config key) / `--plugin` (CLI flag) over the deprecated
`require:`/`--require`** for declaring `rubocop-rails`/`rubocop-performance`. The pinned
rubocop 1.88.2 still honors `require:`/`--require` but nags on every single invocation
("... specify `plugins: rubocop-rails` instead of `require: rubocop-rails`..." —
`implementation-notes-spikeA.md` Experiments 3, 5, corroborated independently in
`implementation-notes-spikeB.md`) — the same "nag pollutes every run" stderr-noise class
this doc already flags for RuboCop's "new cops not configured" message (§3). Caveat,
honestly carried from the spike's own residual-risk note: byte-identical-output
equivalence of `plugins:`/`--plugin` versus `require:`/`--require` was assumed from the
deprecation message's wording, not independently re-run with `--plugin` substituted — a
cheap follow-up before shipping, not a blocker.

**Toolchain pinning.** `Gemfile.lock` is part of the determinism contract, not incidental
packaging detail: exit-code tables, impact/confidence tables, and category tables are all
version-scoped to the exact pinned gem versions (spike toolchain: Ruby 4.0.1, brakeman
8.0.5, rubocop 1.88.2, rubocop-rails 2.35.5, rubocop-performance 1.26.1, reek 6.5.0 — the
spike's own Gemfile had no pins, per the spike task instructions ("fine for a spike, not
fine for a design that claims to be deterministic," `implementation-notes.md` phase 1)).
Version bumps to any tool require re-verifying its exit-code table and re-checking for
schema drift before the new version is adopted.

**Subprocess environment.** Ambient shell middleware (aliases, hooks, wrappers) can
rewrite bare-command output in a dev's environment — observed in the spike sandbox with
the `rtk` proxy intercepting `--version` calls (it did not corrupt file-redirected tool
output, only bare stdout). Runners avoid this class of risk entirely by (a) always using
file-redirected output, never captured stdout, and (b) reading tool versions from
`Gemfile.lock` directly rather than shelling out to `<tool> --version`
(`implementation-notes.md` phase 1-2, `lib/runners.rb::gem_version`).

**Determinism contract.** The guarantee is: same findings **set**, for the same target
commit + pinned toolchain versions. Two things are explicitly excluded from that
guarantee and must never be treated as stable, comparable output:
- **Wall-clock timing** — measured to vary by two orders of magnitude for the identical
  rubocop invocation across environments (2.55s vs. 662s, above). Micro-spike B adds a
  second, independent real-world data point reinforcing the same conclusion rather than
  changing it: brakeman 56.75s / rubocop 135.40s / reek 227.47s wall against Discourse
  (10,679 files) bear no resemblance to Lobsters' single-digit-second figures above — as
  expected given ~21x the file count, but concrete corroboration that `runtime_s` must
  stay out of the comparable/committed `findings.json` contract regardless of target size
  (`implementation-notes-spikeB.md`).
- **Raw tool-emitted finding order** — the orchestrator's phase-4 re-run reproduced
  identical findings *content* across two different environments but not identical
  finding *order*; brakeman's own warning order is not guaranteed stable run-to-run
  (`implementation-notes.md` phase 4: "findings content was reproducible across two very
  different environments; wall-clock and finding *order* (brakeman) were not... define
  determinism as 'same findings set for same target+toolchain versions,' explicitly
  excluding timings and ordering (or sort findings canonically)").

Mechanism: the renderer, the digest builder, and any future diffing/CI-gating consumer
apply a canonical sort (e.g. `file, start_line, tool, rule`) to `findings.json` before
rendering or comparing — never rely on tool-emitted order for anything that claims to be
reproducible.

## 5. Findings schema v2

### Top-level file

```json
{
  "target": "path/or/identifier",
  "toolchain": { "ruby": "4.0.1", "bundler": "4.0.12" },
  "tools": [
    { "name": "brakeman", "version": "8.0.5", "raw_count": 27, "exit_code": 3 }
  ],
  "findings": [ /* Finding objects */ ]
}
```

`runtime_s` is dropped from the comparable/committed contract (see §4, Determinism
contract) — kept only in an ephemeral run log, never in a file whose content is meant to
be diffed run-over-run. **Proposed** — the spike's v1 schema included `runtime_s` at both the
top-level tool summary and (implicitly) nowhere per-finding; v2 removes it from
`findings.json` given the 662s-vs-2.5s environment-sensitivity finding (§3, §4).

### Finding object

```json
{
  "id": "sha256(tool|rule|file|start_line|column|discriminator)[0,16]",
  "native_fingerprint": "01fb4692...",
  "tool": "brakeman",
  "rule": "SQL Injection",
  "category": "security",
  "impact": "critical",
  "confidence": "high",
  "message": "Possible SQL injection",
  "location": {
    "file": "app/models/story.rb",
    "start_line": 716,
    "end_line": 716,
    "column": null,
    "lines": null
  },
  "context": { "class": "Story", "method": "update_score_and_recalculate!" }
}
```

Changes from spike v1 (`SCHEMA.md`), each grounded in a specific spike finding:

- **`severity` splits into `impact` + `confidence`.** See below — grounded in convergent
  signals: SCHEMA.md's own admission it's "a product decision, not derivable"; the
  phase-3 fixture-run LLM independently flagging the same confidence/severity conflation;
  and the phase-4 real-data LLM independently re-deriving it again and adding the
  XSS-over-SQLi-ranking critique and the File Access read/write sink-granularity gap.
  Two separate LLM invocations, blind to each other and to SCHEMA.md, landing on the same
  conflation is a stronger signal than either alone (§3). Report rank sorts by `impact`;
  `confidence` is displayed, not ranked on (fixed decision).
- **`id` is a compound key, not a bare fingerprint**, because collisions were measured on
  *both* the native (brakeman) and synthesized (rubocop, reek) fingerprints (§3). Adding
  `column` to the hash input resolves the one measured rubocop collision (two
  `Style/StringLiterals` offenses on `Gemfile:18` at columns 5 vs. 24). Adding `column`
  does **not** resolve the measured reek collision — reek has no column concept at all;
  the two colliding `DuplicateMethodCall` smells differ only in `name`. **Proposed, not
  spiked**: `discriminator` is tool-specific — for reek, the smell's `name` field where
  present, falling back to an ordinal index within the collision group as a last resort.
  This has not been implemented or re-measured against the 140 known reek collision
  groups; that re-measurement is an open de-risking item (§9). The brakeman 155-vs-158
  native-fingerprint collision is already resolved by including `start_line` in the
  compound key (the two findings differ on that field even though brakeman's own
  fingerprint doesn't). Micro-spike B corroborates that collisions scale proportionally
  with volume, not as an edge case unique to Lobsters' size: at Discourse's ~21x scale,
  rubocop's raw 380,883 findings had 33,159 collision groups covering 78,636 findings, and
  reek's raw 48,806 findings had 2,555 groups covering 6,412 findings — consistent with
  Lobsters' 1,529/140-group baseline, reinforcing the compound-key rationale. The
  discriminator fix itself remains unimplemented — this is corroborating data, not new
  de-risking of the fix (`implementation-notes-spikeB.md`).
- `native_fingerprint` is kept as a separate field for cross-referencing against the raw
  tool output / external tooling, explicitly **not** used for identity.
- `location.lines` is an added optional field (**Proposed, not spiked**) carrying reek's
  full line-set when it has more than two entries, so the `start_line: min, end_line: max`
  collapse — flagged in the spike as "lossy — flag if exact per-statement lines matter for
  reporting" — doesn't lose information for a smell like `TooManyStatements` that spans
  many lines. `start_line`/`end_line` remain the primary fields other tools populate
  normally; `lines` is null unless the source tool provides a genuine multi-point set.

### Ranking model: impact × confidence

**Impact** — hand-authored, versioned, per-rule/rule-family table; "how bad if real,"
independent of any tool's self-reported certainty. **Confidence** — from the tool where
one exists (brakeman's `confidence`), a hand-authored default otherwise. Neither axis is
derived automatically from the other.

Rank for the report and the digest is impact only; confidence is shown alongside each
finding but never used to reorder. This directly resolves the collision the spike
observed between brakeman's `confidence` field and the fact that the normalizer was, in
v1, using it as if it were severity (SCHEMA.md's own framing: "brakeman (`confidence` →
severity)").

Illustrative starting table — **Proposed, not validated by spike; needs security/eng
review before adoption**:

| Rule family | Impact | Confidence source |
|---|---|---|
| SQL/Command Injection, RCE, Unsafe Deserialization | critical | brakeman `confidence` (High/Medium/Weak) |
| Cross-Site Scripting | critical | brakeman `confidence` |
| Mass Assignment, Open Redirect | high | brakeman `confidence` |
| File Access | high (**open question**: read vs. write sink not distinguishable from brakeman's own output at rule granularity — see §9) | brakeman `confidence` |
| rubocop `Lint/*` (correctness) | high — **illustrative, needs a per-rule pass**: this family mixes bug-shaped cops (`Lint/UselessAssignment`, `Lint/SuppressedException`) with hygiene cops (`Lint/RedundantCopDisableDirective`) that arguably don't warrant `high` uniformly; not aggregated regardless — see §6 | default: medium (no native per-finding confidence) |
| rubocop `Metrics/*`, reek complexity-family (`TooManyStatements`, `FeatureEnvy`, `ClassLength`, ...) | medium | default: medium |
| reek `DuplicateMethodCall`, `UtilityFunction`, other design-family smells | low-medium (needs per-rule pass) | default: medium |
| Style/Layout/Naming (rubocop), reek naming smells | info/low | default: medium |

This table replaces SCHEMA.md's flat security floor ("security findings never map below
medium") with an explicit impact tier per rule family — the two-axis split removes the
need for that floor as a hack, since a Weak-confidence SQLi finding can now be
`impact: critical, confidence: low` instead of being pulled down to a blended `medium`.

**Tradeoff, flagged not resolved.** Because impact no longer dampens for confidence,
every brakeman finding in a `critical`/`high`-impact rule family gets listed individually
and ranked at the top of the report/digest regardless of confidence — including ones
brakeman itself rated `Weak` (4 of the spike's 27 brakeman findings were `Weak`
confidence, verified against `tmp/raw/brakeman.json`). v1's confidence-based dampening
(`Weak` → `medium`) accidentally suppressed low-confidence noise from the
individual-listing surface; removing it is a deliberate consequence of the
impact/confidence split (confidence is meant to be *displayed*, not used to demote), but
it trades away that noise suppression and risks alert fatigue if a given target's
brakeman run skews heavily `Weak`. Whether individual listing should be confidence-gated
is an open question — see §9.

### Category taxonomy v2

v1 assigned category by **tool + department**, not by what the smell actually is:
brakeman → always `security`; rubocop → by cop department (`Security`→security,
`Lint`→correctness, `Rails`→rails, `Performance`→performance, `Metrics`→complexity, else
→style); reek → always `design`. This produces exactly the inconsistency the LLM flagged
independently: reek's `TooManyStatements`/`FeatureEnvy` (complexity-shaped smells) land in
`design` purely because reek is the tool, while rubocop's `Metrics/*` (also
complexity-shaped) land in `complexity` — "the same smell, same category regardless of
tool" is violated (`ANNOTATIONS.md`: "`design` vs `complexity` split is fuzzy... The
boundary is inconsistent").

**Proposed fix — not spiked, needs a full table before implementation**: category is
assigned by a rule-level table keyed on the smell/rule identity, not the producing tool.
Illustrative resolution for the two tools currently in the roster:

| Category | Example rules (either tool) |
|---|---|
| complexity | `Metrics/MethodLength`, `Metrics/AbcSize`, `Metrics/CyclomaticComplexity`, `Metrics/ClassLength`, reek `TooManyStatements`, `FeatureEnvy`, `TooManyMethods`, `TooManyInstanceVariables`, `LargeClass` |
| design | reek `DuplicateMethodCall`, `UtilityFunction`, `DataClump`, `ControlParameter`, `Attribute`, `NilCheck`, `MissingSafeMethod` |
| correctness | rubocop `Lint/*`, reek `MissingSafeMethod`, `NilCheck` (**open question**: are `NilCheck` and `MissingSafeMethod` correctness smells or design smells? spike didn't resolve this — both are listed under both candidate rows above deliberately to flag the ambiguity) |

Category set stays `security | correctness | rails | performance | complexity | design |
style` (unchanged from v1) — the fix is in the *assignment mechanism*, not the taxonomy
itself.

### Location schema

`{ file, start_line, end_line, column: optional, lines: optional }` as shown above.
`file` is always relative to the target app root (v1's `strip_target_prefix` behavior,
unchanged). `column` is `null` when the tool doesn't provide one (brakeman, reek).

## 6. Report & digest contracts

**Attention-follows-severity is the governing principle**, not category order or raw
count. The spike's v1 report (`RAILS_AUDIT_REPORT.md`) groups by category first, severity
second within category, with a fixed `CATEGORY_ORDER` that happens to put `security`
first. This "worked" on Lobsters only because brakeman was the sole source of
critical/high findings in this run — it is not structurally guaranteed: a future tool
(custom in-repo cops, active_record_doctor) could produce a critical/high finding in
`design` or `rails`, and it would render *after* five other category sections under v1's
layout. **Proposed — not spiked**: lead the report with a single "Critical & High"
section spanning all categories, sorted by impact then category. This is the **only**
surface where critical/high findings are listed individually — per-category sections
below carry aggregate tables and total counts only (including a count of their own
critical/high findings), with a back-reference ("see Critical & High section above")
rather than repeating the same finding text a second time per category.

**Correctness (`Lint/*`) findings get individual-listing treatment in the leading
section, not aggregated away** — a direct fix for the spike-flagged miss. v1 aggregated
all 51 `correctness` findings into a rule→count table and only ever gave `security`
individual listing. The LLM's blind critique called this out explicitly: "those 51
deserve line-by-line triage, not a count bucket" (`ANNOTATIONS.md`). v2 rule: whether a
finding gets listed individually (in the leading section) is driven by its `impact` tier
(critical/high, from any category), not by category membership — `Lint/*` findings
currently map to `impact: high` (§5) and so qualify.

**Rendering rules (carried forward from v1, adapted to the single-surface model):**
- Header: target, per-tool versions, raw counts (no `runtime_s` — see §4, Determinism
  contract).
- Leading Critical & High section: individual listing (file:line, rule, message, impact,
  confidence), capped per category subgroup within the section (v1's per-section cap of
  25 carries forward at this narrower scope) with an explicit "…and N more" line. This
  cap-and-overflow path never fired on real Lobsters data (topped out at 23 in the
  security category) and was only verified via a synthetic 30-item feed
  (`implementation-notes.md` phase 2) — flagged as a real but low-risk unverified path.
- Per-category sections: aggregate table only — rule → count, sorted by `(impact desc,
  count desc)` — **Proposed, not spiked**; attention-follows-severity applies to this
  surface exactly as it does to the digest (below), so a rare-but-severe medium finding
  isn't buried under high-volume style noise the way pure count-sorting would bury it.
  Capped (v1: top 15), with an explicit total. Grouping key should be `(category, impact,
  tool, rule)` — matching the digest's aggregation key below — not `(category, tool,
  rule)` alone; v1 grouped by `rule` alone, which was safe only because each rule mapped
  to exactly one impact tier in the fixed tables (flagged as fragile if impact ever
  becomes finding-specific rather than purely rule-level, `implementation-notes.md`
  phase 2).
- Footer: totals by impact (and, separately, by confidence) across all tools.

**Digest contract (LLM layer input), carried forward from spike phase 3 with its
verified budget shape:**
- Two structured sections plus overall stats: critical/high findings listed individually
  (target ~60% of a 15,000-char hard cap), medium/low/info aggregated as
  `(category, impact, tool, rule) → count` (~40%, top 40 rows by count).
- **No silent truncation, anywhere.** Every truncation point emits a marker stating the
  exact count dropped, the total it was dropped from, and a breakdown of what got cut
  (rule→count for the aggregate path, rule→count for the critical/high overflow path).
  This is not a nice-to-have: aggregate truncation fired on the very first real run (77
  rule groups / 545 findings dropped, 4,808-char digest) and the markers are what made
  that visible at all (`implementation-notes.md` phase 4).
- A final hard-cap backstop (string-slice truncation of the whole digest) exists as a
  last resort if section budgets somehow still overrun. This path has never fired in any
  run, real or synthetic — **unverified code path**, low risk given it's a simple slice,
  but explicitly not exercised (`implementation-notes-llm.md`).
- Aggregation sort is by count desc only ("the loudest rule wins"). This is a known,
  accepted limitation carried forward, not a fix: a rare-but-severe medium finding can be
  bumped out of the top-40 by high-volume style noise before the LLM ever sees it. Given
  the impact/confidence split (§5), consider sorting the aggregate section by
  `(impact desc, count desc)` instead of count alone — **Proposed, not spiked**.
  Micro-spike B adds concrete supporting evidence at scale, not just a theoretical
  concern: a single cop, `Style/StringLiterals`, alone produced 230,477 of Discourse's
  380,883 rubocop findings (60%) — a single-cop dominance far more extreme than what
  Lobsters' report already showed. Count-desc-only sorting would let one quote-style cop
  dominate the aggregate section's top rows even more thoroughly at this volume
  (`implementation-notes-spikeB.md`).

## 7. LLM annotation layer

**Scope: judgment only, never detection.** The annotation layer consumes the
deterministic findings JSON and produces prioritization/critique; it must never be a
source of new findings, and its output is explicitly labeled as unverified
("has not been independently verified... treat it as a second opinion," `ANNOTATIONS.md`
header — carried forward verbatim as a UX/contract requirement, not just spike output
styling).

**Invocation contract:**
- Separate command (`rails-audit annotate <findings.json>`), off by default, never run as
  part of the main audit pipeline (§4).
- Digest built per §6, passed to `claude -p` via `Open3.capture3` with an argv array (not
  a shell string) — avoids quoting a multi-KB prompt through a shell.
- **`--output-format json` is required in production**, not the plain-text output the
  spike used for simplicity. The spike's `bin/annotate` captured plain stdout with zero
  cost/token accounting; a production version needs the JSON wrapper specifically for
  diagnosable errors and cost visibility (`implementation-notes-llm.md`: "No cost/token
  visibility from plain `claude -p` text output... A production version would want
  `--output-format json` specifically to capture cost/usage").
- **Hard timeout + at least one automatic retry are mandatory**, not optional hardening.
  The spike's `bin/annotate` has neither today — it's a single `Open3.capture3` call with
  no timeout, and the "retry" observed in phase 4 was the orchestrator manually
  re-invoking the whole command after the first attempt hung ~17.5 minutes and died with
  exit 1 and empty stderr. That failure mode (long hang, no diagnostic) is exactly what a
  built-in timeout + automatic retry + structured output is meant to catch and surface
  (`implementation-notes.md` phase 4).
- **Prompt asks for four fixed Markdown headers** (Top 5 issues to fix first; Systemic
  patterns; Refactoring suggestions (domain modeling; thin operations only when justified);
  Impact ranking critique) — this
  worked first try against both the fixture and the real 13k-finding dataset; no
  multi-call iteration was needed in either case (`implementation-notes-llm.md`: "One call
  is fine... not evidence it always will"). The fourth header's wording — "Severity
  ranking critique" — predates the impact/confidence split (§5); whether to rename it to
  "Impact ranking critique" for v2 schema-vocabulary consistency is an open naming
  question, not resolved here.

**Failure policy:** on timeout, non-zero exit, or empty/malformed output after the retry
budget is exhausted, fail loud with the tool's stderr (or "no stderr" explicitly, matching
the observed hang) — never write a partial or silently-degraded `ANNOTATIONS.md`.

**Cost/latency expectations, from observed data only:** typical call ~70-90s wall,
almost entirely network/model wait (one measured call: 1.57s user / 0.79s system CPU out
of ~70s wall). One observed pathological hang of ~17.5 minutes before an exit 1 with empty
stderr; cause unconfirmed. This is not a fast-path operation — it does not belong in a
CI gate or pre-commit hook without an explicit opt-in and a generous timeout budget
(`implementation-notes-llm.md`).

## 8. Tool roster

**v1 (spiked):**
- **brakeman** 8.0.5 — security scanning. CLI must override target `brakeman.ignore` by
  default (§4).
- **rubocop** 1.88.2 **+ rubocop-rails** 2.35.5 **+ rubocop-performance** 1.26.1, force-
  required via CLI-owned config (§4) — style/complexity/correctness/rails/performance
  cops.
- **reek** 6.5.0 — design-smell detection; needs an invented impact/confidence table (§5)
  since it has none natively. **Memory flag**: at ~21x Lobsters' file count, reek peaked
  at 3.8GB RSS — 4-5x brakeman's and rubocop's peak RSS in the same run, despite producing
  the smallest raw output file of the three (17MB vs. rubocop's 116MB) — reek is the tool
  most likely to be the binding constraint in a memory-limited CI environment, not rubocop
  (more output, less memory) or brakeman (`implementation-notes-spikeB.md`).

**v2 candidates — none spiked, all Proposed:**
- **Static schema/migration cops (rubocop-rails, already in the pinned toolchain)** — the
  in-model way to get a slice of schema-sanity coverage without changing the execution model.
  `rubocop-rails` ships a static `db/schema.rb` parser (`schema_loader.rb`) behind cops like
  `Rails/UniqueValidationWithoutIndex` (uniqueness validation lacking a unique index — the
  flagship active_record_doctor check), `Rails/ThreeStateBooleanColumn`,
  `Rails/UnusedIgnoredColumns`, plus migration-file cops (`Rails/NotNullColumn`,
  `Rails/ReversibleMigration`, ...). All read committed source (`db/schema.rb`, `db/migrate/**`),
  so they stay inside the determinism contract. **This is Phase 5** (§10). Known gap: these cops
  silently do nothing when `db/schema.rb` is absent (a `structure.sql`-only target, or schema not
  committed) — see §9.
- **active_record_doctor** and **database_consistency** — **RECLASSIFIED to the execution tier
  (Phase 8), NOT Phase 5.** Reconnaissance (2026-07-10, source-cited) established that both
  require **booting the target Rails app in-process** (running all initializers, eager-loading
  every model) **and a live database connection** — active_record_doctor is a rake task depending
  on Rails' `:environment` + `Rails.application.eager_load!`; database_consistency directly
  `require`s the target's own `config/boot.rb`/`config/environment.rb`. Neither emits JSON (plain
  text only); database_consistency's `--autofix`/`install`/`todo` modes **mutate the target repo**;
  and results depend on live DB schema state rather than committed source. They also can't honor the
  toolchain-pinning contract (§4): they run inside the *target's* bundle, so the effective tool
  version floats with the target's Gemfile, not our `Gemfile.lock`. This is the **same
  trust/execution class as SimpleCov** — arbitrary execution of untrusted cloned target code — and
  it would fail outright on the project's own validation targets (Mastodon/Discourse don't
  `eager_load!` without secrets/`master.key`/Redis/Postgres). Scoped and reviewed as its own
  decision (Phase 8), never folded into the static pipeline.
- **In-repo custom cops (`RuboCop::Cop::RailsAudit::*`)** — fat model (>200 lines / >15
  public methods) and fat controller actions (>15 lines) as **size** signals only.
  Packaging: in-repo under `lib/rails_audit/cops/`, loaded via CLI-owned config (not a
  separate gem; YAGNI until a second consumer). Loading into the subprocess rubocop is a
  silent-false-negative risk — verify cops actually fire through the real runner.
  **Application-operations policy** ([`docs/application-operations.md`](application-operations.md)):
  service-object *presence* detection was removed. Legitimate operations are rare thin
  boundary orchestration; **shape abuse** is defined in that standard. Mechanical shape
  cops ship in the separate metz-scan product when used; rails-audit does not depend on
  metz-scan. Do not restore thoughtbot-style "service object detected" as a success
  criterion.
- **RubyCritic** — also explicitly out of the spike's scope (`SPIKE_PLAN.md`). Brief,
  unspiked assessment only: it wraps reek/flog/flay into an HTML dashboard; if added, it
  would introduce yet another un-owned scoring scheme (flog's complexity score) needing
  the same hand-authored impact/confidence mapping treatment as reek — no signal from
  this spike on its JSON output shape, exit codes, or config-loading behavior.
- **SimpleCov** — fundamentally different trust/execution model, not a drop-in addition.
  Every other tool in this roster is static analysis against source only; SimpleCov
  requires actually **running the target's test suite** to produce coverage data. The
  spike deliberately never bundle-installed or ran tests inside the cloned target
  (`SPIKE_PLAN.md`: "static analysis only; never bundle-install or run the target's
  tests... Consequence: no SimpleCov in the slice — a known gap to note"). Adding it means
  accepting arbitrary target code execution (via its test suite and whatever that suite
  pulls in) inside the audit pipeline — a materially different security/sandboxing
  posture than everything else in this roster, and should be scoped and reviewed as its
  own decision, not folded in as "just another tool."

## 9. Open questions & de-risking spikes

Carried forward verbatim in spirit from the notes' close-out sections, plus additions
found while drafting this document:

- **RuboCop vs. a target shipping its own `.rubocop.yml` requiring gems we don't have —
  RESOLVED.** Micro-spike A observed (not just anticipated) this against Mastodon:
  `--force-default-config` and a CLI-owned `--config <file>` both fully prevent the
  crash; the verified decision and its rationale now live in §4
  (`implementation-notes-spikeA.md`).
- **New: the CLI needs its own baseline `Exclude` list.** Owning config discovery (via
  `--force-default-config` or `--config`) also bypasses the target's own `AllCops:
  Exclude` entirely, not just its `plugins`/`require` list — confirmed by Mastodon's own
  excluded `Vagrantfile` showing up in the offense output under both mechanisms
  (`implementation-notes-spikeA.md`). This is arguably consistent with the config-
  ownership philosophy (§2: "never silently inherit target-repo suppression/config"), but
  it means the CLI will lint files the target deliberately opts out of (vendored/generated
  code, non-Ruby-convention files matched by RuboCop's default glob) unless it ships its
  own `Exclude` list (e.g. `vendor/**/*`, `db/schema.rb`). Whether skipping the specific
  files Mastodon excludes was actually harmless was **not** assessed — flagged as a
  follow-up, not resolved.
- **Behavior at 5k+ file scale — answered with data, not just flagged as untested.**
  Micro-spike B ran the full toolchain against Discourse (10,679 Ruby files, ~21x
  Lobsters): brakeman 56.75s wall / 854MB peak RSS / 272 findings; rubocop (+rails
  +performance, CLI-owned config) 135.4s wall / ~1472s user CPU / 682MB peak RSS / 116MB
  raw JSON / 380,883 findings; reek 227.5s wall / 3,774MB peak RSS / 48,806 findings.
  Normalize (4.12s → 196.6MB `findings.json`, 429,961 findings), render (0.40s → 218-line
  report), and digest build (1.2s → 11,942 chars, under the 15k cap with clean truncation
  markers) all completed with no crash, no hang, no pathological output. Nothing here
  exceeded a generous 30-minute budget (`implementation-notes-spikeB.md`). Caveats carried
  forward honestly: exit codes at this scale were inferred from valid output plus the
  known exit-code table, not independently re-captured this run; Discourse is one large
  real app, not a proven upper bound.
- **New: practical upper bound for in-memory `findings.json` handling — RESOLVED.** The
  CLI provides configurable `--max-findings` (default 500,000) and hard-fails when the
  cap is exceeded; users can raise the cap or narrow the target. Findings are never
  dropped or truncated. Streaming is deferred (`implementation-notes-spikeB.md`).
- **Fingerprint-based cross-run identity.** Collisions are measured and real; the
  compound-key + tool-specific-discriminator fix proposed in §5 has not been implemented
  or re-measured against the 1,529 (rubocop) / 140 (reek) known collision groups.
- **Rails/Performance cops force-loaded.** RESOLVED by micro-spike A (2026-07-10): with a
  CLI-owned config the cops verifiably fire — Lobsters 0→123 `Rails/*`, 0→30
  `Performance/*` offenses (`implementation-notes-spikeA.md`, experiment 4; see §4).
  Residual: integrating the config into the CLI proper and refreshing the
  §3/RAILS_AUDIT_REPORT.md category-count baseline remain delivery-plan phase 2 work.
- **reek's exit-code-2 "smells found" behavior across versions.** Observed once, on
  6.5.0; not verified as stable across reek releases (`implementation-notes.md` phase 2).
- **`claude` CLI failure modes** (absent binary, expired/missing auth) — reasoned through
  and syntactically exercised (`ruby -c`) in `bin/annotate`'s error branches, never
  behaviorally observed; auth was transparent in every real run so far
  (`implementation-notes-llm.md`).
- **Root cause of the 17.5-minute `claude -p` hang** — unestablished; transient
  network/sandbox suspected but not confirmed. Needs either reproduction or production
  telemetry (via `--output-format json` cost/error metadata, §7) before it can be
  called understood rather than merely mitigated by a timeout.
- **Impact-table granularity brakeman can't give us**: File Access impact depends on
  read-vs-write sink, which isn't distinguishable from brakeman's own per-rule output —
  flagged in the LLM's blind critique, unresolved in the §5 impact table.
- **Whether individual listing should be confidence-gated.** The impact/confidence split
  as designed lists every critical/high-impact finding individually regardless of
  confidence (§5), which could reintroduce the alert fatigue that v1's confidence-based
  severity dampening (`Weak` → `medium`) accidentally prevented. Not resolved here —
  needs a product decision, ideally informed by how common `Weak`-confidence findings
  are across a broader sample of targets than just Lobsters (4 of 27 in this spike run).
- **Default confidence value (flat "medium") for rubocop/reek findings** — no signal from
  the spike on whether this is adequate or whether specific rules warrant per-rule
  confidence tuning (e.g., cops known for high false-positive rates).
- **Category taxonomy rule-level table (§5)** — the design-vs-complexity fix is proposed
  at illustrative granularity only; a full table covering every rule in the v1 roster
  (let alone v2 candidates) has not been built or reviewed.
- **New: schema cops silently no-op when `db/schema.rb` is absent (Phase 5).** The
  rubocop-rails schema-aware cops (`Rails/UniqueValidationWithoutIndex`, etc.) parse
  `db/schema.rb` and do nothing if it's missing — a `structure.sql`-only target, or a repo that
  doesn't commit its schema, gets zero schema coverage with no signal that a check was skipped.
  This is exactly the silent-false-negative class the project exists to surface. Mitigation:
  the runner/report should detect an absent `db/schema.rb` at audit time and note it in the report
  header ("schema cops inactive — no db/schema.rb found") rather than letting absence read as
  "clean." IMPLEMENTED (Phase 5c): the CLI detects a missing `db/schema.rb` and the report renders
  a `## Warnings` section naming the inactive schema-dependent cops (migration cops on
  `db/migrate` are noted as unaffected).
- **`enforce_hard_cap` digest backstop** — never exercised, real or synthetic; low risk
  but genuinely unverified (`implementation-notes-llm.md`).
- **Report restructure to an impact-first leading section (§6)** — proposed but not
  built; needs a rendering pass and a fresh look at Lobsters' actual output once
  implemented to confirm it reads better, not just differently.

## 10. Delivery plan

Small, independently shippable phases. The spike code itself is throwaway and is NOT
carried forward — it predates schema v2, was built exempt from testing discipline, and
embeds decisions this document supersedes. Phase 1 is a from-scratch implementation of
the spike's functional *scope*, built to this document, in a new repo/gem. What does
carry forward from the spike is data, not code: the raw tool outputs in `tmp/raw/` as
normalizer test fixtures, the measured fingerprint-collision pairs as identity-spec
regression cases, and the verified exit-code/version tables.

1. **Implement the spike's scope from scratch as a gem** (three runners → normalizer →
   renderer), per this document and with tests. Pin the Gemfile.lock. Load
   rubocop-rails/rubocop-performance via the CLI-owned `--config` file (`plugins:`, §4).
   Default to overriding target brakeman-ignore files (opt-in flag to respect them).
   Hardcode and version-scope the exit-code tables. Implement findings schema v2's
   `impact`/`confidence` split and compound-key identity (without the reek discriminator
   fix yet — that's phase 2). Canonical sort order for all output; strip `runtime_s` from
   the comparable contract. No LLM layer in this phase.
2. **Close the two confirmed silent-false-negative gaps and re-measure.** Rails/Performance
   cops actually firing once force-required is now **verified** (micro-spike A, §3/§4) —
   what remains in this phase is integrating the CLI-owned rubocop config into the CLI
   proper (not the throwaway spike config) and re-running the fingerprint collision
   measurement with the reek discriminator fix from §5 in place (still unimplemented).
3. **Report/digest rework.** Impact-first leading section; correctness (`Lint/*`)
   surfaced individually per §6; re-verify the "…and N more" and digest-truncation code
   paths against real (not just synthetic) overflow.
4. **LLM annotation layer, productionized.** Hard timeout, automatic retry,
   `--output-format json` for cost/error diagnostics, per §7. Still off-by-default,
   still a separate command.
5. **Tool roster expansion: static schema/migration cops (rubocop-rails).** Enable and verify
   the schema-aware cops that ship with the already-pinned `rubocop-rails` and read committed
   source statically (`Rails/UniqueValidationWithoutIndex` is enabled by default; the `pending`
   ones — `Rails/ThreeStateBooleanColumn`, `Rails/UnusedIgnoredColumns`, and pending migration
   cops — need explicit `Enabled: true` in the CLI-owned config). Add per-cop impact/category
   rows (§5): schema-integrity cops warrant higher impact than the `Rails/*` department default,
   since a uniqueness validation without a unique index is a real data-integrity bug, not style.
   Verify against a fixture target shipping `db/schema.rb`. **Reclassified out of this phase:**
   active_record_doctor and database_consistency — they require booting the target + a live DB
   (§8), so they move to Phase 8's execution tier, not here. Caution: the Phase-7 `Exclude` list
   drops `db/schema.rb` from *linting*, which is correct — the schema loader reads it as data, not
   as an inspected file — but `db/migrate/**` must stay lintable or the migration cops go dark.
6. **Custom in-repo cops (not a separate gem — see §8).** Fat model/controller size signals
   under `RuboCop::Cop::RailsAudit::*`, loaded into the pinned rubocop via the CLI-owned
   config and mapped in §5. Loading through the subprocess runner must fire for real
   (silent-false-negative risk). Operation/service shape abuse lives in metz-scan per
   [`application-operations.md`](application-operations.md).
7. **Scale and config-landmine validation — DONE via micro-spikes, follow-ups remain.**
   Both were run: micro-spike A (Mastodon, missing-gem `.rubocop.yml`) and micro-spike B
   (Discourse, 10,679 files) — see §3, §4, §9. Remaining work this phase should still
   cover: a CLI-owned `Exclude` list (§9), a decision on in-memory `findings.json` upper
   bounds/streaming (§9), and — optionally, cheaply — parallelizing the runners (§4) since
   serial execution at Discourse's scale takes ~7 minutes end-to-end.
8. **Execution-tier tools — SimpleCov, active_record_doctor, database_consistency — as their
   own decision.** Separate proposal, given the shared trust/execution model (§8): all three
   require executing untrusted target code — SimpleCov runs the target's test suite;
   active_record_doctor and database_consistency boot the target app in-process and connect to a
   live database. This tier needs a sandboxing/opt-in design (ephemeral throwaway DB, container
   isolation, arbitrary-code-execution acceptance) and can't honor the static pipeline's
   determinism/pinning contracts as-is. Not bundled into any of the above phases; scoped and
   reviewed separately. **The sandboxing/opt-in design is drafted, decision-gated, in
   [`docs/execution-tier-proposal.md`](execution-tier-proposal.md)** (adversarially reviewed);
   its headline finding is that a static-capture pass ("Phase 8-zero") captures a large slice of
   the two DB tools' value inside the existing contracts, leaving SimpleCov as the tier's only
   irreplaceable payload — so the proposal recommends the static pass first and the sandboxed
   tier only as a conditional, staged spike.
