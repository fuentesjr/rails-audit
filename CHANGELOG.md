# Changelog

All notable changes to this project are documented here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/) once it is published.

## [Unreleased]

### Added
- **Resilience timeout auditing** under a new `resilience` category (spec:
  `docs/resilience-timeouts.md`). A `ResilienceAnalyzer` runs as a fifth concurrent
  pipeline thread checking `config/database.yml` (parsed, never ERB-evaluated) for
  missing statement/connect timeouts, `config/` for rack-timeout wiring, and
  `Gemfile.lock` for a request-timeout gem. Six new cops
  (`RailsAudit/TimeoutModuleUse`, `NetHttpDefaultTimeouts`, `NetHttpMissingTimeout`,
  `FaradayMissingTimeout`, `HttpartyMissingTimeout`, `RackTimeoutDisabled`) flag HTTP
  clients and middleware left on unbounded or default timeouts. Findings are value
  judgments with suggested thresholds — never gating — and every check that cannot run
  (missing `database.yml`, unparseable config) surfaces a warning instead of reading
  as clean.
- Configurable `--max-findings` cap on the `audit` command (default 500,000). Over the
  cap the run fails loudly and overridably rather than straining memory; findings are
  never silently dropped or truncated.
- **rubocop-minitest 0.40.0** added to the pinned toolchain, loaded via the CLI-owned
  rubocop config alongside rubocop-rails/rubocop-performance. Three genuinely
  correctness-shaped pending cops (`Minitest/UnreachableAssertion`,
  `Minitest/SkipEnsure`, `Minitest/UselessAssertion`) are explicitly enabled, mirroring
  the Rails schema/migration cops. New: when a target has no `test/**/*_test.rb` files, the report surfaces a
  warning that rubocop-minitest cops had nothing to scan — an RSpec-shop (or any
  non-Minitest) target reads as "no signal," not "tests are clean."

### Fixed
- Crash (`ArgumentError` in the canonical sort) when brakeman reported a file-level
  warning with no line number (e.g. `Unmaintained Dependency` on a `Gemfile`) and
  another tool also had findings on the same file. File-level warnings now normalize to
  line 0. Found auditing Discourse.
- `FaradayMissingTimeout` no longer flags `Faraday.new` when timeouts live in a
  same-method options local (Discourse `WebHookEmitter`). Broader multi-method
  Faraday dataflow stays deferred.
- Tool versions (`Runners.gem_version`) and `Resilience/MissingRequestTimeout`
  tolerate CRLF `Gemfile.lock` line endings.

### Changed
- The four static runners (brakeman, rubocop, reek, schema analyzer) now run concurrently.
  Output is unaffected — findings are canonically re-sorted — and a failing runner still
  fails the whole audit loudly.
- The packaged gem is an allow-list (`lib/`, `exe/`, CLI-owned rubocop config,
  `Gemfile`/`Gemfile.lock`, user-facing docs). Process files (`AGENTS.md`, `.trk/`,
  design notes) no longer ship.

## [0.1.0] - 2026-07-10

Initial pre-release. Deterministic static-analysis pipeline for Rails codebases.

### Added
- `audit` command: runs a pinned toolchain (brakeman, rubocop + rubocop-rails +
  rubocop-performance, reek) against a target app, normalizes every tool's output into a
  single findings schema, and writes `findings.json` plus an impact-ranked
  `RAILS_AUDIT_REPORT.md`.
- CLI-owned analysis configuration: the CLI supplies its own tool config so target-repo
  suppression can't disable a check silently. `--respect-target-config` opts back into the
  target's brakeman ignore file.
- In-repo custom cops (fat model, fat controller action, service-object detection) and a
  static schema analyzer reading `db/schema.rb` (unindexed FKs, mismatched FK types,
  tables without a primary key, and related checks) — no app boot, no database.
- Absent-`db/schema.rb` detection: schema-dependent checks that would silently no-op are
  surfaced as warnings in the report instead of reading as "clean."
- Collision-free finding identity (compound key + tool-specific discriminator) and a
  canonical sort, so reports are stable across runs.
- `annotate` command (optional, off by default): a separate LLM pass over a
  truncation-safe digest of the findings, via the `claude` CLI, writing `ANNOTATIONS.md`.
  With a hard timeout, one automatic retry, and atomic output.
- `execution-audit` command (experimental, opt-in): a container-sandboxed tier that boots
  the target to reach checks requiring a live app. Gated behind an explicit
  `--i-understand-untrusted-code-runs` acknowledgement; writes a separate,
  non-reproducible `execution-findings.json`. Deeper stages are deferred — see
  `docs/execution-tier-8a-findings.md`.

[Unreleased]: https://github.com/fuentesjr/rails-audit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/fuentesjr/rails-audit/releases/tag/v0.1.0
