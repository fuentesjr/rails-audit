# STATE

## Goal
Static pipeline + Phase 8-zero is the shipped product. Phases 1–7 code items are done and on origin/main (findings cap + runner parallelization included). Phase 8 sandboxed execution tier measured NO-GO (0/6 real apps at M5) and is DEFERRED — see docs/execution-tier-8a-findings.md; do not build 8b/8c. Only remaining decision-gated item: final gem name (rails-audit is still a placeholder). Delegation: coding via codex-dispatch; Fable for adversarial review of high-stakes forks. Authoritative design: docs/DESIGN.md.

## Dispatched

## Next
1. Decide final gem name (rails-audit is still a placeholder; rename stays cheap only until a RubyGems name exists).
2. Implement resilience (timeout) auditing per docs/resilience-timeouts.md — M1 analyzer + category plumbing, M2 cops, M3 validation pass + docs

## Backlog
- open-design-confidence-defaults — DESIGN.md §9: per-rule confidence defaults still open (2026-07-18T08:38Z)
- open-design-category-impact-table — DESIGN.md §9: full rule-level category/impact table not comprehensively reviewed (2026-07-18T08:38Z)
- open-design-reek-exit-codes — DESIGN.md §9: reek exit-code stability across versions (2026-07-18T08:38Z)
- open-design-confidence-gated-listing — DESIGN.md §9: whether individual listing should be confidence-gated (2026-07-18T08:38Z)
- open-design-file-access-impact — DESIGN.md §9: File Access read-vs-write impact granularity (2026-07-18T08:38Z)
- open-design-live-claude-annotate — DESIGN.md §9: live claude binary behavior (annotate is mocked in tests) (2026-07-18T08:38Z)
- revive-execution-tier — If ever revived: prerequisite fix-list in docs/execution-tier-8a-findings.md; no implicit spend on 8b/8c (2026-07-18T08:38Z)
- runners-gem-version-crlf — Runners.gem_version (runners.rb:128) uses the same CRLF-hostile line-anchored regex fixed in ResilienceAnalyzer.request_timeout_gem? during M1 review; a Windows-authored target Gemfile.lock breaks tool-version detection and the minitest-missing warning. Fix with \r?$ (2026-08-11) (2026-08-11T23:22Z)
- faraday-lvar-options-correlation — FaradayMissingTimeout FP mode: timeout options hash passed through a local variable (Discourse app/services/web_hook_emitter.rb:27, connection_opts with request:{*_timeout: 20}). Extending correlation needs same-method lvar dataflow; spec §9 deferral row added 2026-08-12 (2026-08-12T01:07Z)
