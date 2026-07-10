# Project tracker

Working state and next steps. The authoritative spec is [`docs/DESIGN.md`](docs/DESIGN.md);
phases below mirror its delivery plan (§10) — if they drift, the design doc wins and this
file gets updated. Evidence archive: `../rails-audit-spike` (read-only).

## Status

Phase 1 complete (2026-07-10). Working `rails-audit audit <target>` pipeline: three runners
→ normalizer (schema v2) → renderer, with pinned toolchain, config ownership, compound-key
identity, and a CLI. Suite green (40 runs). Next: Phase 2 (reek discriminator + collision
re-measurement). Heavy coding delegated to codex, lighter tasks to Sonnet subagents.

## Up next (before/alongside phase 1)

- [ ] Decide the final gem name (`rails-audit` is a placeholder, DESIGN.md §1; rename is
      cheap only until a remote/RubyGems name exists)
- [ ] Create GitHub remote and push (gemspec already points at
      `fuentesjr/rails-audit`)
- [ ] Absorb spike data as test fixtures: raw tool outputs (`../rails-audit-spike/tmp/raw/`),
      the measured fingerprint-collision pairs (identity-spec regression cases,
      DESIGN.md §3/§5), the exit-code/version tables (§4)
- [ ] Set up CI to run `rake test` (scaffolded GitHub Actions workflow exists; verify it
      once a remote exists)

## Delivery phases (DESIGN.md §10)

- [ ] **Phase 1 — from-scratch implementation of the spike's scope** (TDD; red-green from
      fixtures): three runners → normalizer → renderer; pinned Gemfile.lock; CLI-owned
      rubocop config via `--config` + `plugins:`; brakeman-ignore override by default
      (opt-in to respect); version-scoped exit-code tables; schema v2
      (`impact`/`confidence`, compound-key identity, no reek discriminator yet);
      canonical sort; no `runtime_s` in comparable output; no LLM layer
- [ ] **Phase 2 — close the silent-false-negative gaps, re-measure**: integrate the
      CLI-owned rubocop config into the CLI proper (cops verified firing in micro-spike A);
      implement the reek discriminator and re-run collision measurement
- [ ] **Phase 3 — report/digest rework**: impact-first leading section (single individual-
      listing surface); `Lint/*` surfaced individually; verify truncation paths against
      real overflow
- [ ] **Phase 4 — LLM annotation layer, productionized**: hard timeout, automatic retry,
      `--output-format json`; separate command, off by default
- [ ] **Phase 5 — tool roster expansion**: active_record_doctor, database_consistency
      (each needs its own impact/category mapping)
- [ ] **Phase 6 — custom thoughtbot cops extension gem** (fat model/controller,
      service-object detection — not de-risked by the spike)
- [ ] **Phase 7 — remaining scale/config follow-ups** (validation spikes themselves are
      done): CLI-owned baseline `Exclude` list; in-memory `findings.json` upper-bound /
      streaming decision; optional runner parallelization
- [ ] **Phase 8 — SimpleCov as its own proposal** (different trust/execution model:
      requires running the target's test suite)

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
