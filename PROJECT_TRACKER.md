# Project tracker

Working state and next steps. The authoritative spec is [`docs/DESIGN.md`](docs/DESIGN.md);
phases below mirror its delivery plan (§10) — if they drift, the design doc wins and this
file gets updated. Evidence archive: `../rails-audit-spike` (read-only).

## Status

Phases 1–6 complete + Phase 7 Exclude slice (2026-07-10/11). `rails-audit audit <target>` runs
the deterministic pipeline (runners → normalizer → impact-first renderer + CLI); a separate,
off-by-default `rails-audit annotate <findings.json>` adds the LLM layer over a truncation-safe
digest. Pinned toolchain, config ownership, collision-free identity, canonical sort, static
schema cops (schema-absence surfaced), and custom thoughtbot cops (fat model/controller, service
object). Suite green (59 runs). CI green.

**Only decision-gated / optional work remains.** Nothing left is a straightforward autonomous
build: the rest of Phase 7 is a product call (findings.json streaming) + an optional optimization
(runner parallelization), and Phase 8 is the execution-tier proposal (SimpleCov + the reclassified
active_record_doctor / database_consistency) needing a sandboxing/security-posture design.
Delegation model: heavy coding → codex, lighter tasks → Sonnet subagents, Fable as advisor on
forks (used it for the Phase 5 redirect).

## Pre-delivery items

- [ ] **Decide the final gem name** — `rails-audit` placeholder kept for now (user, this
      session). Rename stays cheap only until a remote/RubyGems name exists.
- [ ] **Create GitHub remote and push** — deferred (owner decision; not done autonomously).
      gemspec already points at `fuentesjr/rails-audit`. 12 commits waiting on `main`.
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
- [~] **Phase 7 — remaining scale/config follow-ups** (validation spikes themselves are
      done): CLI-owned baseline `Exclude` list — DONE (commit c7a39f8; minimal, `**/`-prefixed,
      false-negative-safe; caught that unprefixed patterns are a silent no-op). REMAINING
      (need owner input): in-memory `findings.json` upper-bound / streaming decision (product
      call, §9); optional runner parallelization (modest perf win, adds concurrency surface).
- [ ] **Phase 8 — execution-tier tools as their own proposal** (shared trust/execution model:
      SimpleCov runs the target's test suite; active_record_doctor + database_consistency boot
      the target app + connect to a live DB). Needs a sandboxing/opt-in design; can't honor the
      static pipeline's determinism/pinning contracts as-is.

## Open design items

Tracked in DESIGN.md §9 (the authoritative list). The ones most likely to bite phase 1-2
work: baseline `Exclude` list, reek exit-code stability across versions, per-rule
confidence defaults, and the full rule-level category table.

## Log

- 2026-07-09 — Discovery spike completed (`../rails-audit-spike`): pipeline + LLM
  annotation slice against Lobsters; DESIGN.md drafted and adversarially reviewed.
- 2026-07-10 — Micro-spikes A (rubocop config landmine, Mastodon) and B (scale,
  Discourse) closed the two biggest open questions; DESIGN.md updated. Workspace
  scaffolded; design doc adopted as canonical here.
