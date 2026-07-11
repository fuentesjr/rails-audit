# rails-audit

A deterministic static-analysis CLI for Rails codebases. Working name — see
[`docs/DESIGN.md`](docs/DESIGN.md) §1.

`rails-audit` runs a **pinned** toolchain (brakeman, rubocop + extensions, reek, plus
in-repo custom cops and a static schema analyzer) against a Rails app, normalizes every
tool's output into **one findings schema**, and renders an impact-ranked report. The CLI
**owns all analysis configuration** — it never silently inherits the target repo's own
suppression rules — so "no findings" means the checks ran and found nothing, not that a
check was quietly skipped.

An optional, separate LLM pass (`annotate`) adds prioritization and refactoring judgment
on top of the deterministic findings. It is off by default and never part of the audit
itself.

## Why

Most static-analysis setups are easy to fool into silence: a stray `.rubocop.yml`, an
inherited brakeman ignore file, or an absent `db/schema.rb` makes a check no-op with no
signal. The worst outcome isn't a false positive — it's a **silent false negative** that
reads as "clean." `rails-audit` is built to surface those instead of swallowing them:

- **Config ownership.** The CLI supplies its own tool configuration via explicit flags,
  so target-repo suppression can't disable a check without you knowing.
- **Determinism.** Tool versions are pinned to exact versions; the exit-code, impact, and
  category tables are scoped to those versions, so the same code produces the same report.
- **Surface, don't swallow.** Skipped checks (e.g. schema cops with no `db/schema.rb`) are
  reported as warnings in the output, not omitted.

## Installation

Not yet published to RubyGems (the gem name is still being finalized). Install from source:

```sh
git clone https://github.com/fuentesjr/rails-audit
cd rails-audit
bin/setup
```

Run it against a target app with `exe/rails-audit` (or `bundle exec exe/rails-audit`).

Requires **Ruby >= 3.2.0**. The analysis tools are bundled as pinned dependencies — you do
**not** need brakeman/rubocop/reek installed in the target app.

## Usage

### Audit (the core command)

```sh
rails-audit audit PATH/TO/RAILS/APP
```

Writes two files to the output directory (default: the current directory):

- `findings.json` — the full normalized findings, one schema across all tools.
- `RAILS_AUDIT_REPORT.md` — an impact-ranked Markdown report.

Options:

| Flag | Default | Purpose |
| --- | --- | --- |
| `--output-dir DIR` | `.` | Where to write `findings.json` and the report. |
| `--respect-target-config` | off | Respect the target app's own brakeman ignore file (by default it is overridden — config ownership). |
| `--max-findings N` | `500000` | Hard cap on in-memory findings. Over the cap the run fails loudly instead of straining memory; raise it for a very large monorepo. Findings are never silently dropped. |

The report leads with an impact-first section — every `critical`/`high` finding listed
individually — then groups the rest by category (`security`, `correctness`, `rails`,
`performance`, `complexity`, `design`, `style`), and closes with totals by impact and
confidence.

### Annotate (optional LLM layer)

```sh
rails-audit annotate findings.json
```

Builds a truncation-safe digest of the findings and asks the `claude` CLI for
prioritization and refactoring judgment, writing `ANNOTATIONS.md`. This is a **separate**
command over the audit's output — it never runs during `audit`, and the deterministic
findings never depend on it. Requires the `claude` CLI to be installed and authenticated.

Options: `--output PATH` (default `ANNOTATIONS.md`).

### Execution audit (experimental)

```sh
rails-audit execution-audit PATH/TO/RAILS/APP --i-understand-untrusted-code-runs
```

> **Experimental and unsupported.** This runs the target app's code (`bundle install`,
> schema load, boot) inside a container sandbox to reach checks that require a live app.
> Unlike the static pipeline it is **not warranted reproducible**, and it fails
> structurally on many real-world apps. See
> [`docs/execution-tier-8a-findings.md`](docs/execution-tier-8a-findings.md) for the
> go/no-go measurement, and [`SECURITY.md`](SECURITY.md) for the threat model. Requires
> Docker. The `--i-understand-untrusted-code-runs` acknowledgement is mandatory.

## What it checks

The static pipeline runs four tools, all pinned:

- **brakeman** — security vulnerabilities.
- **rubocop** + **rubocop-rails** + **rubocop-performance** — style, correctness, Rails
  idiom, performance, and the static schema/migration cops.
- **reek** — code smells / complexity and design issues.
- **In-repo additions** — custom cops (fat model, fat controller action, service-object
  detection) and a static schema analyzer that reads `db/schema.rb` for issues like
  unindexed foreign keys, mismatched FK types, and tables without a primary key — all
  without booting the app or touching a database.

## Documentation

- [`docs/DESIGN.md`](docs/DESIGN.md) — the canonical design document (findings schema,
  determinism contract, impact/category model, delivery plan).
- [`FAQ.md`](FAQ.md) — why it overrides your config, why zero findings ≠ clean, and other
  non-obvious behavior.
- [`SECURITY.md`](SECURITY.md) — security policy, the execution-tier threat model, and how
  to report a vulnerability.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — development setup and the tool-pinning contract
  every contributor needs to know.

## Status

The **static pipeline is the shipped product** and is stable. The execution tier
(`execution-audit`) is an experimental, opt-in artifact whose deeper stages are deferred —
see the design docs. Version is `0.1.0` (pre-release).

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
See [`LICENSE.txt`](LICENSE.txt).
