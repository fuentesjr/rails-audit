# Project tracker

Working state and next steps. The authoritative spec is [`docs/DESIGN.md`](docs/DESIGN.md);
phases below mirror its delivery plan (§10) — if they drift, the design doc wins and this
file gets updated. Evidence archive: `../rails-audit-spike` (read-only).

## Resume here (new session, start with this)

**Phase 8a spike is COMPLETE and the sandboxed execution tier is DEFERRED (owner-approved
2026-07-11). NO-GO on 8b/8c.** The full go/no-go analysis is
[`docs/execution-tier-8a-findings.md`](docs/execution-tier-8a-findings.md). Headline: M5
measured **0/6 full-funnel success on real apps** — structural failures (missing base-image
system libs; the tier requiring targets to bundle active_record_doctor, which blocks every real
app unconditionally; unresolvable dynamic Ruby versions; a broken git-URL ingestion path). The
static pipeline + Phase 8-zero is the shipped product. The 8a harness stays committed as an
experimental artifact, not wired into CI (live test gated behind `RAILS_AUDIT_LIVE`).

**The two remaining Phase 7 code items are DONE, committed, AND pushed (2026-07-11 session,
owner-approved push)** — `origin/main` @ `0319165`, 0 unpushed, working tree clean, nothing
mid-flight. Commits: `4cbf561` (findings cap), `4f045cb` (runner parallelization), `0319165`
(tracker). CI triggered on push (run 29172504570).

Phase 7 is now effectively complete (Exclude slice + both code items done). The two items
resolved this session, per owner decisions:
- **`findings.json` in-memory upper-bound** — RESOLVED: configurable `--max-findings`
  (default 500,000, comfortably above Discourse's real ~430k), HARD-FAIL when exceeded but
  overridable via the flag. Findings are never silently dropped/truncated; the cap is
  enforced after normalize but before any output write (no partial outputs on failure).
  Streaming stays deferred. DESIGN §9 open question closed. (`4cbf561`)
- **Runner parallelization** — DONE: the four static runners run concurrently in threads
  (the three subprocess runners release the GIL during Open3 I/O → real wall-clock win);
  findings are canonically re-sorted downstream so completion order can't affect output.
  Fail-loud preserved + hardened: all four threads are joined (any error type) before the
  first error re-raises, so a failing runner never orphans the others. A peak-concurrency
  probe pins the overlap so a silent revert to sequential can't pass. (`4f045cb`)

**Only remaining decision-gated item:**
1. **Pre-delivery — final gem name** — `rails-audit` is still a placeholder; cheap to rename
   only until a RubyGems name exists.
There is no remaining Phase 8 work: the tier is deferred (see below). If the tier is ever
revived, `docs/execution-tier-8a-findings.md` has the prerequisite fix-list.

**Both prior owner gates cleared (2026-07-10/11 session).** (1) Phase 8-zero commits are
PUSHED — `origin/main` @ `c49d8f0`. (2) The sandboxed 8a spike was APPROVED and RAN
("Full 8a per §7" scope). Docker runtime stood up (owner approved): `docker` CLI 29.6.1 +
colima VM (4 CPU / 8 GB), context `colima`.

**Delegation model CHANGED mid-session (owner directive):** STOP using Sonnet subagents.
ALL coding — heavy and light — goes through **codex-dispatch**. **Fable (advisor)** is
consulted when unsure/stuck or for adversarial review of high-stakes/untrusted-code
milestones (it replaces the old mandatory Sonnet reviewer gate). I decompose, verify each
milestone independently (always run the live suite myself — codex's managed session can't
reach the colima socket, so its live-test result is unreliable), and commit per milestone.

**8a progress (milestones M1–M5):**
- **M1 — synthetic fixture app** ✅ committed `dc401a8`. `test/fixtures/execution/synthetic_app/`:
  minimal bootable Rails ~7.2/Ruby 3.4, ENV-secrets-only boot, Postgres via `DATABASE_URL`,
  committed schema, seeds two AR-doctor issues (unindexed FK `users.account_id`; missing
  unique index `users.email`).
- **M2 — sandbox harness + provisioning funnel** ✅ committed `987cd5a`. `lib/rails_audit/execution/`:
  container-only isolation (no host mount), two-phase network (install egress open — documented
  8a deferral; RUN phase on `--internal` net, bridge-disconnect actively verified), throwaway
  Postgres from committed schema, synthetic env secrets, full hardening + unconditional teardown.
  Funnel = clone/copy→bundle_install→schema_load→boot, structured `FunnelResult`, report-don't-
  swallow. Live funnel reaches all-`:ok` against M1 (verified by orchestrator, 0 skips).
  **Adversarially reviewed by Fable** — verdict: fundamentally sound (no escape/mount/socket/
  host-shell injection; run-phase isolation enforced). 5 findings fixed pre-commit (2 were
  M5-blocking: timed-out probe container leak; bad-`.ruby-version` pin crashed instead of
  structured result). Suite 86/576, 0 skips.
- **M3 — active_record_doctor integration** ✅ committed `550f192`. Read-only invocation
  (§3.4); config ownership (§3.5) via `load_config_with_defaults(nil)` — proven by a hostile
  fixture `.active_record_doctor.rb` that fails to suppress `unindexed_foreign_keys`; fail-loud
  line parser (§3.7) with strict markers + exact detector-set assertion (raises
  `UnexpectedActiveRecordDoctorOutputError`, never silent `[]`); findings reuse §5 Finding via
  Mappings. Live test detects both seeded issues (users.account_id, users.email). Suite 95/622,
  0 skips (verified by orchestrator).
- **M4 — `execution-findings.json` + `execution-audit` command** ✅ committed `efb88ef`.
  Separate `execution-audit <target>` command (mirrors annotate); hard
  `--i-understand-untrusted-code-runs` gate (§3.8); separate `execution-findings.json` artifact
  with tier envelope (`pinned_by_us:false`/`warranted_reproducible:false`/versions/image digest/
  adapter/per-stage+per-tool status), atomic write, reserved-filename guard (never clobbers
  static output); status-first "Execution tier (not warranted reproducible)" report section.
  codex's own self-review caught+fixed 6 issues pre-commit (path clobber; failed-run-exit-0;
  timed-out-but-clean-looking classified `clean`; unvalidated tool-run hash → `ToolRun` value
  object w/ single-source outcome; weak report test). Orchestrator verified live e2e: gate
  refuses without ack, artifact carries envelope + both seeded findings, findings.json untouched.
  Suite 107/730, 0 skips. **This completes the BUILDABLE portion of 8a.**
- **M5 — real-app funnel measurement** ✅ DONE → **NO-GO (owner-approved 2026-07-11)**. Ran the
  harness against 6 real OSS repos (rubygems.org, huginn, chatwoot, lobsters, mastodon,
  discourse). **0/6 reached schema_load or boot.** Failures were structural: (A) base image
  lacks system libs for native gems (zlib/yaml/idn), (B) tier requires target to bundle
  active_record_doctor → blocks EVERY real app (chatwoot's install succeeded, still failed here),
  (C) unresolvable dynamic Ruby versions, (D) git-URL ingestion broken (3 bugs: heredoc FIXED
  `9fca99a`; workdir chdir + probe-tmpfs sizing FOUND-not-fixed, deferred with the tier). Full
  writeup + "if ever revisited" list: `docs/execution-tier-8a-findings.md`. Measurement used a
  local-path pivot (host-clone → docker cp) to bypass the git-ingestion bugs and measure the
  funnel core. **Decision: do not build 8b/8c; static pipeline + Phase 8-zero is the product.**

Local-only, not in git (gitignored): `docs/notes/phase8-zero-notes.md`, `docs/notes/phase8a-notes.md`
(8a architecture, install-egress deferral, accepted limitations, verification status).

## Status

Phases 1–6 + Phase 7 Exclude slice + Phase 8-zero complete (2026-07-10/11).
`rails-audit audit <target>` runs the deterministic pipeline (runners → normalizer →
impact-first renderer + CLI); a separate, off-by-default `rails-audit annotate <findings.json>`
adds the LLM layer over a truncation-safe digest. Pinned toolchain, config ownership,
collision-free identity, canonical sort, static schema cops (schema-absence surfaced), custom
thoughtbot cops (fat model/controller, service object), and a static schema analyzer (Phase
8-zero: 5 active_record_doctor schema checks, in-contract). Suite green
(70 runs / 520 assertions). Phase 8-zero committed locally, **not yet pushed** (owner-gated).
Prior work on `origin/main` (fuentesjr/rails-audit) @ dda7bb7.

**Phase 8-zero shipped; the sandboxed 8a spike RAN and the tier is DEFERRED (NO-GO on 8b/8c,
owner-approved 2026-07-11).** Phase 8's sandboxing design (`docs/execution-tier-proposal.md`)
was built as milestones M1–M4 and measured (M5): 0/6 full-funnel success on real apps →
structural failures → tier deferred per the proposal's own off-ramp. Go/no-go writeup:
`docs/execution-tier-8a-findings.md`. Phase 8 is now CLOSED. Still decision-gated: rest of
Phase 7 (findings.json streaming product call; optional runner parallelization). Delegation
model (updated mid-session per owner): heavy AND light coding → **codex-dispatch** (no Sonnet
subagents); **Fable** for adversarial review of high-stakes/untrusted-code milestones + hard
forks (used it to review the M2 harness — verdict sound, 5 findings fixed pre-commit).

## Pre-delivery items

- [ ] **Decide the final gem name** — `rails-audit` placeholder kept for now; DEFERRED again
      (owner, 2026-07-11). Rename stays cheap only until a remote/RubyGems name exists.
- [x] **Create GitHub remote and push** — DONE: owner created `origin`
      (github.com/fuentesjr/rails-audit) and pushed; all session work through Phase 6 is on
      `origin/main` @ dda7bb7, CI green on each push.
- [x] **Absorb spike data as test fixtures** — DONE: `test/fixtures/raw/*.json` (normalizer +
      identity ground truth), collision-pair fixtures, exit-code tables encoded in runners.
- [x] **Verify CI** — GREEN on push (run 29129031294): `bundle exec rake` on Ubuntu + Ruby
      4.0.1, incl. the live brakeman/rubocop/reek tests, 1m2s. Remote pushed by owner.

## Delivery phases (DESIGN.md §10)

- [x] **Phase 1 — from-scratch implementation of the spike's scope** (TDD; red-green from
      fixtures): three runners → normalizer → renderer; pinned Gemfile.lock; CLI-owned
      rubocop config via `--config` + `plugins:`; brakeman-ignore override by default
      (opt-in to respect); version-scoped exit-code tables; schema v2
      (`impact`/`confidence`, compound-key identity, no reek discriminator yet);
      canonical sort; no `runtime_s` in comparable output; no LLM layer
      — DONE: commits 11010a0 (M1 core), fe323ea (M2 runners), b8cac7d (M3 renderer),
      f5d6afb (M4 CLI). 40 tests green.
- [x] **Phase 2 — close the silent-false-negative gaps, re-measure**: integrate the
      CLI-owned rubocop config into the CLI proper (cops verified firing in micro-spike A);
      implement the reek discriminator and re-run collision measurement
      — DONE: commits e2d8a88 (reek `name` discriminator + ordinal uniqueness pass; reek
      collisions 140→0, combined 12,903 findings all-unique), 46fde78 (Rails/Performance
      cop-loading regression test). Also verified `plugins:`≡`require:` cop loading (138
      Rails / 52 Performance), closing the DESIGN §4 caveat. 43 tests green.
- [x] **Phase 3 — report/digest rework**: impact-first leading section (single individual-
      listing surface); `Lint/*` surfaced individually; verify truncation paths against
      real overflow — DONE: commit 4ac450f (report restructure; overflow verified on real
      fixtures: correctness …and 26 more, style …and 63 more rules/953 findings). Digest
      builder moved to Phase 4 (built alongside its only consumer).
- [x] **Phase 4 — LLM annotation layer, productionized**: hard timeout, automatic retry,
      `--output-format json`; separate command, off by default — DONE: commit fbee641
      (DigestBuilder + annotate; popen3 process-group timeout kill, retry, atomic write,
      fail-loud; claude mocked in tests). Live `claude` binary behavior still unverified.
- [x] **Phase 5 — tool roster expansion (REDIRECTED 2026-07-10)**: enable + map + verify the
      static schema/migration cops already shipped by pinned rubocop-rails
      (`Rails/UniqueValidationWithoutIndex` et al.; static `db/schema.rb` parse, stays
      deterministic). active_record_doctor + database_consistency RECLASSIFIED to Phase 8
      (they require booting the target + a live DB; see DESIGN §8/§9). Owner approved the redirect.
      — DONE: commits 395d854 (design amendment), 7ad0502 (cops + runner fix: root-caused &
      fixed the schema-loader/chdir silent no-op), 99d7670 (schema-absence surfaced in report).
- [x] **Phase 6 — custom thoughtbot cops (in-repo, not a separate gem)** (fat model/controller,
      service-object detection — not de-risked by the spike) — DONE: commits 7998145 (packaging
      decision), b3b7f66 (FatModel, FatControllerAction, ServiceObject under
      RuboCop::Cop::RailsAudit::*, loaded via absolute --require injection in the runner;
      functional-through-runner tests prove they fire; e2e confirms correct impact/category).
- [x] **Phase 7 — remaining scale/config follow-ups** — COMPLETE. CLI-owned baseline `Exclude`
      list — DONE (commit c7a39f8; minimal, `**/`-prefixed, false-negative-safe; caught that
      unprefixed patterns are a silent no-op). In-memory `findings.json` upper-bound — DONE
      (commit 4cbf561; configurable `--max-findings`, default 500k, hard-fail-overridable, never
      drops findings, enforced pre-write, streaming deferred; DESIGN §9 closed). Runner
      parallelization — DONE (commit 4f045cb; four runners in threads, all joined before first
      error re-raises so none orphan, peak-concurrency test pins the overlap).
- [x] **Phase 8 — execution-tier tools as their own proposal** — CLOSED: 8a spike ran, tier
      DEFERRED (NO-GO on 8b/8c, owner-approved 2026-07-11). M1–M4 built the sandbox harness +
      `execution-audit` command; M5 measured **0/6 full-funnel success on real apps** (structural
      failures: base-image system libs, tier-requires-target-to-bundle-AR-doctor, dynamic Ruby
      versions, broken git ingestion). Off-ramp taken per the proposal's §7/§9.2. Full writeup:
      **`docs/execution-tier-8a-findings.md`**. 8a harness stays committed as an experimental
      artifact, not in the supported product (live test gated behind `RAILS_AUDIT_LIVE`). Original
      proposal + design shape below, for the record:
      (shared trust/execution model:
      SimpleCov runs the target's test suite; active_record_doctor + database_consistency boot
      the target app + connect to a live DB). Needs a sandboxing/opt-in design; can't honor the
      static pipeline's determinism/pinning contracts as-is. **PROPOSAL DRAFTED + adversarially
      reviewed (Fable) — `docs/execution-tier-proposal.md`.** Design shape:
      container-only sandbox (target cloned *inside* the container, no host mount; two-phase
      network so `bundle install` egress is fenced), throwaway DB from committed schema, synthetic
      env secrets (real `master.key` impossible → funnel failures reported, never swallowed),
      CLI-owned tool config, structural mutation-mode lockout, separate non-reproducible
      `execution-findings.json`, own `execution-audit` command behind an explicit
      untrusted-code-ack flag. **Headline recommendation: ship a static-capture pass ("Phase
      8-zero") FIRST** — a big slice of active_record_doctor/database_consistency checks
      (unindexed FKs, extraneous indexes, mismatched FK types, table-without-PK) are pure
      `db/schema.rb` analysis, capturable inside the existing contracts via the Phase 5 parser /
      Phase 6 cop machinery; the throwaway-DB design collapses the "live DB" value to
      runtime-reflection-only, leaving **SimpleCov as the tier's only irreplaceable payload**. So
      the sandboxed tier is a conditional, staged spike (8a AR-doctor → 8b database_consistency →
      8c SimpleCov), not a commitment. **Owner approved both (2026-07-10).**
- [x] **Phase 8-zero — static schema analyzer** (the in-contract static-capture pass): a fourth
      static tool alongside brakeman/rubocop/reek, reading only committed `db/schema.rb` (no boot,
      no DB, no network — fully inside the determinism/pinning contract). Five active_record_doctor
      schema checks: `Schema/TableWithoutPrimaryKey` (high), `Schema/MismatchedForeignKeyType`
      (high), `Schema/UnindexedForeignKey` (medium), `Schema/ExtraneousIndex` (low),
      `Schema/ShortPrimaryKeyType` (medium). Self-contained schema-AST model (SchemaLoader lacks
      `create_table` options/PK + `add_foreign_key`, so it's insufficient — justified deviation
      from the proposal's "reuse SchemaLoader" line, noted in `docs/notes/phase8-zero-notes.md`).
      database_consistency added no net-new static value (duplicates AR-doctor's set; its
      ThreeStateBoolean check already ships as `Rails/ThreeStateBooleanColumn`); the two
      hybrid model/source-AST checks (`MissingIndexChecker`, `MissingIndexFindByChecker`) deferred.
      Built by codex; reviewer subagent caught **two audit-aborting crash blockers** (lambda/
      function column defaults; inferred-FK to custom/absent-PK table — both uncaught NoMethodError
      that took down the whole audit) plus a unique-index false-positive and a duplicate-index
      false-negative — all fixed with regression tests. Suite 70/520 green; verified firing through
      the real CLI pipeline (integration test).

## Open design items

Tracked in DESIGN.md §9 (the authoritative list). Resolved this session: baseline `Exclude`
list (Phase 7 slice), `plugins:`≡`require:` cop loading (§4), reek discriminator (Phase 2),
schema-absent surfacing (Phase 5c). Still open and most likely to matter next: per-rule
confidence defaults; the full rule-level category/impact table (schema + custom cops added
ad-hoc rows, no comprehensive review); reek exit-code stability across versions; whether
individual listing should be confidence-gated; File Access read-vs-write impact granularity;
live `claude` binary behavior (annotate is mocked in tests). `findings.json` in-memory
upper-bound / streaming is a Phase-7 product call (below).

## Log

- 2026-07-11 — Closed the two remaining Phase 7 code items (owner picked both). (1) Findings
  cap: configurable `--max-findings` (default 500k, hard-fail-overridable, findings never
  dropped, enforced pre-write) — owner-refined from "fixed cap" to "configurable with a sane
  default," which dissolved the drop-vs-block tension (`4cbf561`; DESIGN §9 closed). (2) Runner
  parallelization: four runners in threads, all joined before the first error re-raises (no
  orphaned threads), peak-concurrency probe pins the overlap (`4f045cb`). All coding via
  codex-dispatch per the current delegation model; each milestone verified with a full
  independent `bundle exec rake` (114/756, 0 failures, 1 expected `RAILS_AUDIT_LIVE` skip) before
  commit. The parallelization took several codex round-trips: threading → concurrency-pinning
  test → join-all-before-raise → broaden the join rescue to `StandardError` (each surfaced by
  codex's own review; the last two closed a real orphan-thread gap the naive `Thread#value` loop
  left open). Both commits are LOCAL — push owner-gated. Only remaining item: final gem name.
- 2026-07-09 — Discovery spike completed (`../rails-audit-spike`): pipeline + LLM
  annotation slice against Lobsters; DESIGN.md drafted and adversarially reviewed.
- 2026-07-10 — Micro-spikes A (rubocop config landmine, Mastodon) and B (scale,
  Discourse) closed the two biggest open questions; DESIGN.md updated. Workspace
  scaffolded; design doc adopted as canonical here.
- 2026-07-10/11 — Build session: implemented Phases 1–6 + the Phase 7 Exclude slice
  (22 commits, 59 tests green, CI green, pushed). Orchestrated build — heavy coding via the
  codex plugin, lighter tasks via Sonnet subagents, each milestone independently verified
  before commit. Notable: Phase 5 redirected (Fable-advised, owner-approved) — active_record_doctor
  + database_consistency reclassified to the Phase 8 execution tier (they require booting the
  target + a live DB, breaking the static/deterministic model); Phase 5 instead enabled the
  static rubocop-rails schema cops. Three silent-no-op bugs caught before shipping (schema-loader
  `Dir.pwd` vs runner `chdir`; unprefixed `Exclude` patterns; custom-cop subprocess loading) —
  the recurring lesson: verify cops actually FIRE through the real runner, not just that they're
  configured. Remaining work (rest of Phase 7, Phase 8) is decision-gated.
- 2026-07-10 — Drafted the Phase 8 execution-tier proposal (`docs/execution-tier-proposal.md`)
  and had Fable adversarially review it. Review caught load-bearing corrections, all folded in:
  the "no egress" claim contradicted `bundle install` (which needs network + runs code → two-phase
  network); a read-only host mount would break the tools' own writes (→ clone *inside* the
  container, no host mount); and — the sharpest point — the throwaway-DB-from-committed-schema
  design collapses the two DB tools' "live DB" value to runtime-reflection-only, and several
  active_record_doctor checks are pure `db/schema.rb` analysis, so a static-capture "Phase 8-zero"
  should come first and SimpleCov is the tier's only irreplaceable payload. Also added: explicit
  threat-model boundary (container-class, not hostile-kernel-escape), execution-tool config
  ownership (the founding lesson), full-funnel (not just boot) success metric.
- 2026-07-10 — Owner approved both Phase 8 gates. Built **Phase 8-zero** (static schema analyzer,
  5 active_record_doctor schema checks, in-contract) — recon (Sonnet helper) enumerated + bucketed
  every AR-doctor/database_consistency check; heavy build via codex against a written brief;
  reviewer subagent adversarially reviewed and caught two audit-aborting crash blockers (lambda/
  function column defaults; inferred-FK to custom/absent-PK table) + a unique-index false positive
  + a duplicate-index false negative — all fixed with regression tests before commit. Verified
  firing through the real CLI pipeline. Suite 70/520 green. The recurring lesson held again:
  the worst outcome isn't a miss, it's a crash/silent-no-op that reads as "clean" — the review
  gate is what caught it. Committed locally on main (3 commits: proposal / implementation /
  tracker); **not pushed** (owner-gated).
