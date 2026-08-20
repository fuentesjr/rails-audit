# Contributing

Thanks for your interest. This document covers development setup and the one contract that
matters more than any style rule here: **tool pinning**.

## Development setup

```sh
git clone https://github.com/fuentesjr/rails-audit
cd rails-audit
bin/setup          # installs dependencies
bundle exec rake   # runs the full test suite
```

Requires Ruby >= 3.2.0. `bin/console` gives an interactive prompt with the library loaded.

Run the CLI against a target app during development:

```sh
bundle exec exe/rails-audit audit PATH/TO/RAILS/APP --output-dir /tmp/audit-out
```

## Testing

- The suite is Minitest, run via `bundle exec rake`.
- Some tests run the real tools (brakeman/rubocop/reek) against fixture apps under
  `test/fixtures/`, so a full run takes a few minutes — that's expected.
- One test is skipped unless `RAILS_AUDIT_LIVE=1` is set and Docker is available: the
  execution-tier harness live test. A single skip in the default run is normal.
- Prefer red-green: for a behavior change or bug fix, add or adjust a test that fails for
  the right reason first, then make it pass.

The most important testing lesson this project has learned repeatedly: **verify that a
check actually fires through the real runner**, not just that it is configured. The worst
failure mode is not a false positive — it is a check that silently no-ops and reads as
"clean." Several bugs here were exactly that (a schema loader keyed off the wrong working
directory, unprefixed `Exclude` globs, custom cops not loaded in the subprocess). Guard
against it with an end-to-end test that asserts the finding shows up in real output.

## The tool-pinning contract

The analysis tools are pinned to **exact** versions in the gemspec (not pessimistic `~>`):

```
brakeman 8.0.5, reek 6.5.0, rubocop 1.88.2,
rubocop-minitest 0.40.0, rubocop-performance 1.26.1, rubocop-rails 2.35.5
```

This is deliberate. The determinism contract (see `docs/DESIGN.md` §4) scopes the
exit-code tables, impact mappings, and category mappings to these exact versions. **Bumping
any tool is not a routine dependency update** — it can silently change what findings appear
and how they're classified. Before bumping a tool version:

1. Re-verify its exit-code table (`lib/rails_audit/runners.rb`) against the new version.
2. Check for output-schema drift in the normalizer (`lib/rails_audit/normalizer.rb`).
3. Re-check the impact/category mappings (`lib/rails_audit/mappings.rb`) for new or
   renamed rules.

Do this in its own PR, separate from feature work.

## Pull requests

- Keep changes small and reviewable. Don't bundle unrelated cleanup, refactors, and
  features into one PR — split them so each can be reviewed independently.
- Update docs when behavior, flags, or output change.
- Make sure `bundle exec rake` passes (one expected skip, as noted above).
- Explain the "why" in the PR description, especially for anything touching config
  ownership, the findings schema, or the tool pins.

## Scope note

The execution tier (`execution-audit`) is experimental and its deeper stages are deferred
(see `docs/execution-tier-8a-findings.md`). If you're proposing work there, read that
writeup first — it documents the structural blockers that led to the deferral.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).

