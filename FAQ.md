# FAQ

Answers to the non-obvious behavior. For the full rationale, see
[`docs/DESIGN.md`](docs/DESIGN.md).

### Why did it lint files or report offenses my `.rubocop.yml` / rubocop config excludes?

By design. `rails-audit` **owns its analysis configuration** and supplies it explicitly,
which bypasses the target repo's own config discovery — including its `AllCops: Exclude`
list and its `plugins`/`require` entries. This is the core principle: a check should not be
silently disabled by the repo you're auditing. If you need to exclude vendored or generated
code, that belongs in the CLI's own baseline `Exclude`, not the target's.

### It reported zero findings. Does that mean my app is clean?

Not necessarily — but the tool tries hard to make the difference visible. "Zero findings"
means the checks ran and found nothing. If a check *couldn't* run (for example, the schema
cops and schema analyzer need `db/schema.rb`, and a `structure.sql`-only app doesn't have
one), that is surfaced as a **warning** in the report, not omitted. Read the `## Warnings`
section: if it's empty and findings are zero, the checks genuinely ran clean. Surfacing
silent skips is the whole point of the project.

### Why override my brakeman ignore file by default?

Same reason as the rubocop config: an inherited ignore file can suppress real warnings
without you realizing it. By default the ignore file is overridden so brakeman reports
everything. If you deliberately want to honor the target's ignore file, pass
`--respect-target-config`.

### Why are the tool versions pinned to exact versions?

Determinism. The exit-code tables, impact mappings, and category mappings are all scoped to
the *exact* pinned versions of brakeman/rubocop/reek. Loosening the pins (or bumping a tool
without re-verifying) can silently change which findings appear and how they're
classified — so the same code would no longer produce the same report. Bumping a tool is a
deliberate, verified change, not a routine update. See
[`CONTRIBUTING.md`](CONTRIBUTING.md).

### What's `execution-audit`, and why the scary `--i-understand-untrusted-code-runs` flag?

The default `audit` is purely static — it never runs your app's code. `execution-audit` is
an **experimental** tier that actually boots the target (bundle install, schema load, app
boot) inside a container sandbox to reach checks a static pass can't. Because that executes
untrusted code, the acknowledgement flag is mandatory. It's also **not warranted
reproducible** and fails structurally on many real apps — treat it as experimental. See
[`SECURITY.md`](SECURITY.md).

### What does `annotate` do, and do I need it?

No, it's optional. `annotate` is a **separate** command that takes an existing
`findings.json`, builds a truncation-safe digest, and asks the `claude` CLI for
prioritization and refactoring judgment (written to `ANNOTATIONS.md`). It never runs during
`audit`, and the deterministic findings never depend on it. You only need it if you want an
LLM's opinion on top of the raw findings, and it requires the `claude` CLI installed and
authenticated.

### The audit failed with a `--max-findings` error. What now?

Your target produced more findings than the in-memory cap (default 500,000 — comfortably
above even very large real apps). Rather than risk an out-of-memory on a constrained runner,
the run fails loudly. Nothing was silently dropped. Re-run with a higher `--max-findings`,
or narrow the target.

### Which Rails / Ruby versions does it support?

The CLI requires **Ruby >= 3.2.0**. It analyzes the target's source and `db/schema.rb`
statically, so it doesn't load the target's Rails version — it works across Rails
versions as long as the files are parseable by the pinned tools.

### The gem name is "rails-audit" — is that final?

No, it's a working name and not yet published to RubyGems. See `docs/DESIGN.md` §1.
