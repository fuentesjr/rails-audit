# rails-audit

Deterministic Rails audit CLI (working name — see `docs/DESIGN.md` §1).

Runs a pinned toolchain of static-analysis tools (brakeman, rubocop + extensions, reek)
against a Rails codebase, normalizes their output into one findings schema, and renders a
severity-ranked Markdown report — with the CLI owning all analysis configuration. An
optional, separate LLM annotation pass provides prioritization and refactoring judgment
over the deterministic findings.

## Status

Pre-implementation. The canonical design document is [`docs/DESIGN.md`](docs/DESIGN.md);
implementation follows its delivery plan (§10), starting with phase 1: the three-tool
slice built from scratch to schema v2.

Evidence base: the design was derived from a throwaway discovery spike at
`../rails-audit-spike` (kept read-only as an evidence archive). The spike's raw tool
outputs and measured fingerprint-collision cases will be absorbed here as test fixtures
during phase 1; its code is not carried forward.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then run
`rake test` to run the tests. You can also run `bin/console` for an interactive prompt.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
