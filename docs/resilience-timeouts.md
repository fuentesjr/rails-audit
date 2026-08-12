# Resilience (timeouts) — feature specification

Status: scope approved by owner 2026-08-11; implementation not started.
Audience: implementing agents. Sections marked **normative** are the contract;
deviations require a stated reason in the handoff.

Domain source: [The Ultimate Guide to Ruby Timeouts](https://github.com/ankane/the-ultimate-guide-to-ruby-timeouts)
(fetched 2026-08-11). Claims tagged *(guide)* come from it. Unit and
disable-semantics claims below were verified 2026-08-11 against the
PostgreSQL, MySQL, and MariaDB reference docs and rack-timeout's
`doc/settings.md`; quotes appear where the fact is load-bearing.

## 1. Why

A resilient Rails app bounds every network wait: "an unresponsive service can
be worse than a down one" *(guide)*. Whether timeouts are specified is
statically auditable, and their absence is silent — exactly the
false-negative class this tool exists to surface (DESIGN.md §2). This feature
adds a `resilience` finding category fed by two detection surfaces: a config
analyzer and call-site cops.

## 2. Locked decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | New top-level category `resilience` | Owner decision 2026-08-11; timeout gaps don't fit the existing seven categories |
| 2 | Value judgment, not presence-only | Findings state the observed value against a suggested threshold; the user decides applicability (convention over configuration). Thresholds are owned, versioned data (§7), displayed in messages, never silent gates |
| 3 | Scope: the four checks in §5–§6; all else deferred (§9) | Prove the category end-to-end on the highest-signal checks first |
| 4 | Static only — no target code executes | `database.yml` ERB is Ruby; evaluating it runs untrusted target code. Never evaluate it (§5). Inherits DESIGN.md §4 determinism/config-ownership contracts |

## 3. Category plumbing (normative)

Add `resilience` at these points:

- `Report::CATEGORY_ORDER` (`lib/rails_audit/report.rb:5`): insert after
  `correctness` → `security, correctness, resilience, rails, performance,
  complexity, design, style`. Timeout gaps are production-outage class; they
  rank with correctness, above idiom and performance. Without this entry the
  category still renders (unknown categories sort last) — in the wrong place.
- `Mappings` (`lib/rails_audit/mappings.rb`): `TOOL_VERSIONS` gains
  `resilience: RailsAudit::VERSION`; new `RESILIENCE_RULES` table (§5) wired
  into the `impact`/`confidence`/`category` case branches as tool
  `"resilience"`; `RUBOCOP_RULES` rows for the cops (§6);
  `RESILIENCE_THRESHOLDS` (§7).
- `Mappings.confidence` extension: RuboCop findings currently get flat
  `"medium"` (`mappings.rb:126-134`) and `Normalizer.rubocop` doesn't pass the
  rule (`normalizer.rb:49`). Change: pass `rule:`, and let `RUBOCOP_RULES`
  rows carry an optional `confidence:` honored before the `"medium"` fallback
  (mirrors `ACTIVE_RECORD_DOCTOR_RULES`). Existing rows are unaffected.
- `Normalizer` (`lib/rails_audit/normalizer.rb`): new `resilience` branch;
  `normalize` gains a `resilience:` keyword. Unlike the `schema` branch, each
  payload row carries its own `file` — resilience findings span
  `config/database.yml` and `Gemfile.lock`.
- `CLI#run_pipeline` (`lib/rails_audit/cli.rb:156`): fifth thread running
  `ResilienceAnalyzer.analyze`, raw output at `raw/resilience.json`, tool
  entry in the document, warnings merged per §8.
- No change needed: `Finding` does not validate categories;
  `DigestBuilder` passes category strings through.
- Docs: update the category set in DESIGN.md §5, add a §8 roster entry
  pointing here, and add a CHANGELOG entry.

## 4. ResilienceAnalyzer (normative)

`RailsAudit::ResilienceAnalyzer.analyze(target:, output_path:)` in
`lib/rails_audit/resilience_analyzer.rb`, modeled on `SchemaAnalyzer`. Result
hash: `{name: "resilience", version: RailsAudit::VERSION, raw_count:,
exit_code: 0, payload:, output_path:}` plus a `warnings:` array (§8) — a
contract extension over `SchemaAnalyzer`, merged into the document by the CLI.

Payload row: `{"rule", "message", "file", "line", "discriminator",
"confidence"}`. Sort the payload by `[file, line, rule, discriminator]` before
writing, as `SchemaAnalyzer` does.

### Inputs

- `config/database.yml`: parse with `Psych.parse` (node marks give line
  numbers) and resolve values with alias support for `<<: *default` merges.
  **Never evaluate ERB.** A value containing `<%` is "present, unresolvable"
  (rule below). If the file as a whole fails to parse, emit no findings and a
  warning (§8). Audit the `production` environment only. Rails
  multi-database layouts (`production: {primary: {...}, replica: {...}}`)
  apply the checks per nested entry that is a mapping containing `adapter`;
  the discriminator carries the path (e.g. `production.primary`). An entry
  with no statically visible `adapter` (URL-only or otherwise dynamic —
  common under `DATABASE_URL`) cannot be audited: emit a §7 warning naming
  the entry path. When `production` itself has neither an `adapter` key nor
  any mapping children, warn for `production`. When the file parses but the
  `production` key is absent or its value is null, warn that the production
  environment is not defined in `config/database.yml` (common in
  `DATABASE_URL`-only apps) — not that the file is invalid. Resolve aliases
  per entry: an
  unresolvable alias inside one entry warns for that entry (§7) and leaves
  sibling entries analyzed; only a failure outside every entry disables the
  whole file.
- `Gemfile.lock`: line-anchored regex on the resolved-gem section, same
  family as `Runners.gem_version` (`runners.rb:128`). Tolerate CRLF line
  endings (`\r?$`, or normalize before matching): a Windows-authored
  lockfile that contains `rack-timeout` must not fire
  `Resilience/MissingRequestTimeout`.

Adapter scope: `postgresql`/`postgis` (PG rules), `mysql2`/`trilogy`
(MySQL/MariaDB rules — the adapter can't distinguish the two servers
statically, so either server's variable satisfies the check). `sqlite3` is
skipped without a warning: embedded, no network path, `statement_timeout`
inapplicable. Any other adapter: skip with a warning (§8).

### Rules

| Rule | Trigger | Impact | Confidence |
|---|---|---|---|
| `Resilience/MissingStatementTimeout` | PG entry with no `variables: statement_timeout`; MySQL/MariaDB entry with neither `variables: max_execution_time` nor `variables: max_statement_time` | high | high |
| `Resilience/StatementTimeoutTooHigh` | value present, resolvable, exceeds the §7 ceiling | medium | high |
| `Resilience/MissingConnectTimeout` | DB entry with no `connect_timeout` | medium | high |
| `Resilience/UnresolvableTimeoutValue` | a checked key is present but its value contains ERB, or parses to neither a number nor a known duration unit | info | low |
| `Resilience/MissingRequestTimeout` | `Gemfile.lock` contains neither `rack-timeout` nor `slowpoke` (slowpoke wraps rack-timeout; either satisfies) | high | high |

Value parsing: accept PG duration strings (`5s`, `500ms`, `1min`) and bare
integers. Units by key (verified 2026-08-11): PG `statement_timeout` bare
integer is milliseconds — "If this value is specified without units, it is
taken as milliseconds. A value of zero (the default) disables the timeout";
MySQL `max_execution_time` is milliseconds and bounds read-only `SELECT`
statements only; MariaDB `max_statement_time` is seconds, double-typed, so
fractional values are valid.

A resolvable statement-timeout value of `0` means the timeout is disabled:
fire `Resilience/MissingStatementTimeout` with a message noting it is
explicitly disabled, not merely unset. A resolvable negative value is not a
working timeout either (PG rejects negatives for `statement_timeout`): fire
the same rule with a message noting the value is not a valid finite timeout.
A resolvable `connect_timeout` of zero or below fires
`Resilience/MissingConnectTimeout` with the observed value — "Zero,
negative, or not specified means wait indefinitely" (libpq, verified
2026-08-11). MySQL messages must note the `SELECT`-only limitation — writes
stay unbounded even with `max_execution_time` set.

Anchoring: findings about a present value anchor to that value's line (Psych
node mark). Missing-key findings anchor to the enclosing DB entry's mapping
key line. `Resilience/MissingRequestTimeout` anchors to `Gemfile.lock` line 1
with discriminator `request-timeout`.

Messages state the consequence, the observed value where there is one, and
the suggestion. Example:

> production.primary sets no statement_timeout; a hung query holds its
> connection indefinitely. Suggested: ≤ 30s (guide example: 5s).

## 5. Cops (normative)

Every cop requires all four registrations — a missed one is a silent false
negative (DESIGN.md §8):

1. Class under `lib/rails_audit/cops/`, namespace `RuboCop::Cop::RailsAudit`.
2. `require_relative` in `lib/rails_audit/cops.rb` (loaded into the
   subprocess via `--require`, `runners.rb:46`).
3. `Enabled: true` entry in `config/rails_audit/rubocop.yml`.
4. `RUBOCOP_RULES` row: `{impact:, category: "resilience", confidence:}`.

| Cop | Flags | Impact | Confidence |
|---|---|---|---|
| `RailsAudit/TimeoutModuleUse` | any `Timeout.timeout` send (explicit receiver form only) | medium | high |
| `RailsAudit/NetHttpDefaultTimeouts` | module-level `Net::HTTP.get`/`.get_response`/`.post_form` — these accept no timeout options and always use the 60s defaults *(guide)* | medium | high |
| `RailsAudit/NetHttpMissingTimeout` | `Net::HTTP.new`/`.start` with no timeout kwarg (`.start` only — see correlation rules below) and no `open_timeout`/`read_timeout`/`write_timeout` setter correlated to the constructor in the enclosing scope | medium | low |
| `RailsAudit/FaradayMissingTimeout` | `Faraday.new` with no `request:` hash containing `timeout`/`open_timeout` and no `options` timeout assignment (`.timeout=`, `.open_timeout=`, or `[]=` with those keys) in an attached block (plain, `_1`, or `it` parameters) | medium | medium |
| `RailsAudit/HttpartyMissingTimeout` | class or module body with `include HTTParty` and none of the `default_timeout`/`read_timeout`/`open_timeout` macros; bare `HTTParty.get`-family calls with no `timeout:` kwarg | medium | medium |
| `RailsAudit/RackTimeoutDisabled` | literal `0`, `0.0`, or `false` for `service_timeout` (kwarg or setter) — "Service timeout can be disabled entirely by setting the property to `0` or `false`" (rack-timeout `doc/settings.md`, verified 2026-08-11) | high | high |

Known blind spots, accepted for v1 and encoded as confidence, not fixed:
timeouts set through wrapper classes, `Faraday.default_connection_options`,
or objects configured far from the construction site are invisible to a
call-site cop. Messages must say what the cop could not see (e.g. "no timeout
set at this call site") rather than assert none exists anywhere.

`NetHttpMissingTimeout` correlation rules (review round, 2026-08-11):

- Timeout kwargs suppress on `.start` only. `Net::HTTP.new` accepts no
  options hash: keywords are silently bound to its `port` parameter and the
  60s defaults stay in force (verified 2026-08-11 on Ruby 4.0.1 /
  net-http 0.9.1) — `.new` with timeout-looking kwargs must still fire.
- Setter correlation searches the enclosing method body, or the whole file
  when the constructor sits outside any `def` (initializer/script case).
- These constructor bindings correlate: plain assignment, memoizing `||=`,
  and a `.tap` block chained on the constructor. `.then`/`.yield_self` do
  not carry identity through an assignment and stay immediate-block-only.
- Configuration blocks count with plain, numbered (`_1`), and `it`
  parameters.
- An attribute `||=` (`http.read_timeout ||= 2`) counts as a setter.
- Accepted v1 blind spots beyond the list above: multiple assignment
  (`http, port = Net::HTTP.new(h), 80`), string-keyed option hashes (these
  libraries mostly ignore string keys, so firing is usually correct),
  safe-navigation sends on constant receivers, and control flow —
  correlation is lexical, so a setter under `if` still suppresses.

Timeout-module message rationale: `Timeout.timeout` interrupts at arbitrary
points and can leave state corrupted; prefer each library's native timeout
options *(guide)*.

## 6. Thresholds (normative)

`Mappings::RESILIENCE_THRESHOLDS = {statement_timeout_max_seconds: 30}.freeze`

Contract: a threshold appears in the finding message alongside the observed
value; it never suppresses a finding; changing one is a reviewable one-line
diff. The 30s ceiling is deliberately generous — the guide's worked example
is 5s — so that exceeding it signals a real gap, not a style disagreement.

## 7. Warnings (normative)

Produced by the analyzer (it owns the knowledge), returned in its `warnings:`
array, merged by the CLI with `warnings_for` output. Same contract as
`SCHEMA_MISSING_WARNING`: inactivity must never read as "clean".

- `config/database.yml` not found → database timeout checks inactive; may
  mean the config lives elsewhere, not that timeouts are set.
- `config/database.yml` present but not statically parseable → checks
  inactive (name the reason: invalid YAML, or ERB beyond value positions).
- Production adapter outside the §4 known set → checks inactive for that
  entry, naming the adapter.
- Production entry with no statically visible `adapter` (URL-only or
  dynamic) → checks inactive for that entry, naming the path.
- `production` key absent, or present with a null value → production
  environment not defined; checks inactive.
- Unresolvable alias inside one entry → checks inactive for that entry,
  naming the path; sibling entries stay audited.
- `Gemfile.lock` not found → request-timeout middleware detection inactive.

## 8. Verification (normative)

Repo testing discipline applies (red-green; characterization before
restructuring).

- `test/rails_audit/resilience_analyzer_test.rb` with fixtures under
  `test/fixtures/resilience/`: PG with/without `statement_timeout`, value
  above threshold, ERB value, multi-database layout, mysql2, unknown adapter,
  unparseable YAML, `Gemfile.lock` with and without `rack-timeout`. Also
  (review round, 2026-08-11): URL-only production, both top-level and as one
  multi-database sibling (warning, siblings still audited); CRLF
  `Gemfile.lock` containing `rack-timeout` (no finding); negative
  `statement_timeout`; `connect_timeout: 0`; unresolved alias on one sibling
  with the other still audited; bare-integer millisecond boundary (`30000`
  clean, `30001` too high); MySQL entry missing both variables; `production`
  key absent and `production:` null (each warns "not defined", no findings).
- Cops: unit tests for trigger and non-trigger cases (including the §5 blind
  spots as documented non-goals), plus a real-runner firing test in the
  `rubocop_plugin_cops_test.rb` pattern — one offense per cop asserted in
  `bundle exec rubocop` JSON output from a fixture app, so a lost
  registration fails the suite instead of going silently dark. Also (review
  round, 2026-08-11): `Net::HTTP.new` with timeout kwargs fires while
  `.start` with them stays clean; tap-then-assign, memoized `||=`, `_1`/`it`
  configuration blocks, top-level constructor with adjacent setter, and
  attribute `||=` setters all suppress; Faraday block `options.open_timeout=`
  and `options[:timeout]=` suppress (with plain, `_1`, and `it` block
  parameters); `include HTTParty` in a module body and
  `service_timeout = 0.0` fire; correlation tests assert the offense line,
  not just the count.
- Extend normalizer/report/digest/CLI tests for the new tool and category:
  report section order (resilience after correctness), high-impact resilience
  findings listed in Critical & High, end-to-end CLI fixture run asserting
  findings and warnings.

## 9. Deferrals

Recorded so expansion is a decision, not drift. Trigger to revisit any row: a
validation target observed using it, or a real-use report of a miss.

| Deferred | Reason |
|---|---|
| Redis | client defaults to 1s connect/read since v5 *(guide)* — flagging "unspecified" is noise |
| Long-tail HTTP clients (rest-client, Typhoeus, Excon, httpclient, open-uri) | add per observed usage; each is a new cop plus mapping rows |
| Puma `worker_timeout`, Sidekiq | process-level with sane defaults; not request resilience *(guide notes Puma's is not a request timeout)* |
| Third-party SDKs (AWS, Stripe, Twilio, Elasticsearch, …) | large authoring surface, app-specific relevance |
| ActionMailer / net-smtp | usually background work; lower blast radius |
| SQLite `busy_timeout` | embedded engine; different failure model |
| Effective-value checks through ENV/ERB | requires executing target code — execution tier (DESIGN.md §8, decision-gated) |
| Faraday options passed through a local variable (`opts = { request: { timeout: … } }; Faraday.new(nil, opts)`) | needs local dataflow tracking; known FP mode, observed once (Discourse `WebHookEmitter`, validation record below); backlog `faraday-lvar-options-correlation` |

## 10. Adoption condition and feedback loop

The category is done when §8 is green **and** a hand-inspected audit of at
least one real validation target (Lobsters; ideally also Mastodon and
Discourse) shows acceptable noise, with that assessment recorded in the
handoff. Threshold and confidence tuning happens against that evidence — the
§6 table being versioned data is the tuning mechanism.

### Validation record (2026-08-12, M3)

All three targets audited with `audit` (static tier only). Every resilience
finding was hand-inspected on Lobsters and Mastodon; on Discourse, 10 of 40
were inspected individually and the rest verified by class pattern.

| Target (clone) | Total findings | Resilience | Verified TP | FP |
|---|---|---|---|---|
| Lobsters `57268d7` | 12,323 | 3 | 3 | 0 |
| Mastodon `2b53f93` | 22,671 | 7 | 7 | 0 |
| Discourse `eedf0ac2` | 424,147 | 40 | 39 | 1 |

- **Inactivity warnings worked on real targets**: Lobsters ships no
  `config/database.yml` and Discourse's has a structural ERB preamble
  (`<%` block at line 1) — both runs surfaced the "database timeout checks
  were inactive" warning instead of reading as clean.
- **The one FP**: Discourse `app/services/web_hook_emitter.rb:27` passes a
  timeout-bearing options hash through a local variable to `Faraday.new` —
  see the §9 deferral row (`faraday-lvar-options-correlation`). The
  finding's "not visible at this call site" wording is literally accurate
  and its confidence is `medium`.
- **Tuning observation (not a defect)**: test/tooling paths account for
  Mastodon's 3 `TimeoutModuleUse` hits and roughly 12 of Discourse's 40
  (all 7 `TimeoutModuleUse`, 2 `NetHttpDefaultTimeouts` in `spec/support/`,
  2 Faraday hits in `docs/developer-guides/`, `script/bench.rb`). A future
  test-path confidence dampener or exclusion is a §6-style tuning decision.
- **Validation surfaced a real pipeline defect**: brakeman's
  `line: null` on file-level warnings crashed the canonical sort
  (Discourse `Gemfile` + rubocop offenses on the same file); fixed with a
  regression test in the M3 change.

Assessment: noise is acceptable — 50 resilience findings across 459,141
total, one FP, no silent inactivity. Adoption condition met.

## 11. Milestones

Each is independently shippable and lands as its own commit.

1. **M1 — analyzer + category plumbing** (§3, §4, §6, §7): the `resilience`
   category exists end-to-end with database.yml and Gemfile.lock rules.
2. **M2 — cops** (§5, including the `Mappings.confidence` extension).
3. **M3 — validation pass + docs** (§10 evidence run; DESIGN.md and
   CHANGELOG updates from §3).
