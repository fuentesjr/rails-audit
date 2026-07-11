# Changelog

All notable changes to this project are documented here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/) once it is published.

## [Unreleased]

### Added
- Configurable `--max-findings` cap on the `audit` command (default 500,000). Over the
  cap the run fails loudly and overridably rather than straining memory; findings are
  never silently dropped or truncated.

### Changed
- The four static runners (brakeman, rubocop, reek, schema analyzer) now run concurrently.
  Output is unaffected — findings are canonically re-sorted — and a failing runner still
  fails the whole audit loudly.

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
