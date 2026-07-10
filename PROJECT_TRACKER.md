# Project tracker

Working state and next steps. The authoritative spec is [`docs/DESIGN.md`](docs/DESIGN.md);
phases below mirror its delivery plan (§10) — if they drift, the design doc wins and this
file gets updated. Evidence archive: `../rails-audit-spike` (read-only).

## Status

Phases 1–4 complete (2026-07-10) — the full productized core. `rails-audit audit <target>`
runs the deterministic pipeline (runners → normalizer → impact-first renderer + CLI); a
separate, off-by-default `rails-audit annotate <findings.json>` adds the LLM layer over a
truncation-safe digest. Pinned toolchain, config ownership, collision-free compound-key
identity, canonical sort. Suite green (49 runs, ~300 assertions).

**Paused for user decisions** before Phase 5+. Remaining phases each need a call that's the
owner's: new tool dependencies (5), a new cop-development gem (6), the CLI-owned Exclude-list
scope + streaming/parallelization (7), and the SimpleCov security posture (8). See "Delivery
phases" below. Delegation model in use: heavy coding → codex, lighter tasks → Sonnet subagents.

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
- [ ] **Phase 5 — tool roster expansion (REDIRECTED 2026-07-10)**: enable + map + verify the
      static schema/migration cops already shipped by pinned rubocop-rails
      (`Rails/UniqueValidationWithoutIndex` et al.; static `db/schema.rb` parse, stays
      deterministic). active_record_doctor + database_consistency were RECLASSIFIED to Phase 8
      (they require booting the target + a live DB = execution tier; see DESIGN §8/§9). Owner
      approved the redirect.
- [ ] **Phase 6 — custom thoughtbot cops extension gem** (fat model/controller,
      service-object detection — not de-risked by the spike)
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
