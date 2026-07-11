# Proposal: Phase 8 — the execution tier

Status: **draft proposal, decision-gated.** This is the "separate proposal" that
[`DESIGN.md`](DESIGN.md) §8 and §10 phase 8 defer to. Nothing here is built. It exists to
be approved, descoped, or rejected as a whole before any execution-tier code is written.
Adversarially reviewed once (Fable, 2026-07-10) — this revision folds in that critique;
material corrections it drove are marked **[review]**.

The three tools in scope — **SimpleCov**, **active_record_doctor**, **database_consistency**
— share one property that separates them from everything in the shipped static pipeline:
**they require executing untrusted, cloned target code** to produce their output. That single
fact breaks four contracts the rest of the tool is built on, and the design below is mostly
about which of those contracts we relax, which we defend, and at what cost. Every capability
claim about the three tools is cited to `DESIGN.md` §8/§9, which in turn cite the 2026-07-10
reconnaissance; claims about *this* proposal's design are marked **Proposed — not validated**.

## 1. Why this is a separate tier, not three more runners

The shipped runners (`lib/rails_audit/runners.rb`) all share one shape: shell out to **our
pinned tool** (`BUNDLE_GEMFILE` → *our* `Gemfile`), pointed at the target's **committed
source files** (`chdir: target`), parse the tool's file output against a version-scoped
exit-code table. brakeman, rubocop, reek, the schema cops, and the custom cops are all static
analysis: they read source, they never run it, and the tool version is ours and pinned.

The execution tier inverts every one of those:

| Property | Static pipeline (shipped) | Execution tier (this proposal) |
|---|---|---|
| Runs target code? | No — reads source only | **Yes** — boots the app and/or runs its test suite |
| Whose bundle? | Ours, pinned (`Gemfile.lock`) | The **target's** — version floats with the target's Gemfile (`DESIGN.md` §8) |
| Depends on live DB state? | No — parses `db/schema.rb` as data | **Yes** — reads a live connection's actual schema |
| Output format | JSON (native or file-captured) | **Plain text only** for AR-doctor & database_consistency (`DESIGN.md` §8) |
| Reproducible findings set? | Yes (determinism contract, §4) | **No** — not pinned by us; depends on the target's floating bundle |
| Mutates the target? | Never | database_consistency's `--autofix`/`install`/`todo` modes **do** (`DESIGN.md` §8) |

The recon establishing the "runs target code" claim for each tool (`DESIGN.md` §8):
- **active_record_doctor** — a rake task depending on Rails' `:environment` +
  `Rails.application.eager_load!` (runs every initializer, eager-loads every model).
- **database_consistency** — directly `require`s the target's own
  `config/boot.rb`/`config/environment.rb`, then connects to a live DB.
- **SimpleCov** — produces coverage only as a side effect of **running the target's test
  suite** (`DESIGN.md` §8, §2 non-goals: "Running the target's own test suite as a side
  effect of detection").

Because the differences are contract-level, not tool-level, the tier gets its own command,
its own output artifact, and its own relaxed determinism statement — detailed below.

## 2. The blast radius, stated plainly

**Recommendation up front: much of this tier's value is capturable *statically* at a
fraction of the cost, and what remains after that is a genuine "maybe," not a clear yes. I
recommend a static-capture pass (Phase 8-zero, §7) *before* committing to any execution-tier
code, then treating the sandboxed tier as opt-in, staged, and abandonable.** The
constructive-challenger case for descoping or deferring:

1. **Arbitrary code execution is the whole point of failure.** Cloning an arbitrary Rails
   repo and booting it (or running its test suite, or even just `bundle install`-ing it —
   the `Gemfile` is Ruby and native-extension `extconf.rb` runs at install time) executes
   that repo's code with whatever the process can reach. This is categorically different from
   parsing files. Every mitigation in §3 is damage control around this one fact.
2. **Partial coverage is structural, not incidental.** Booting a real app needs its secrets.
   An app using encrypted credentials (`config/credentials.yml.enc`) cannot be booted without
   its real `master.key`, which an auditor will not have. `DESIGN.md` §8 already records that
   Mastodon and Discourse "don't `eager_load!` without secrets/`master.key`/Redis/Postgres."
   And boot is only the last stage of a **provisioning funnel** — clone → bundle install →
   schema load → boot — each stage of which fails independently on real targets (native-ext
   deps, Ruby-version mismatch, unreplayable migrations). So the tier inherently *cannot run*
   on a meaningful fraction of real targets, and per this project's founding ethos, every
   funnel failure must be reported as "tier could not run," never swallowed as "clean."
3. **[review] Most of the live-DB value collapses under our own sandbox design, and a big
   slice is statically capturable.** The throwaway DB (§3.2) is built from the target's *own
   committed schema/migrations* — so "models vs. live schema," AR-doctor's and
   database_consistency's headline capability, reduces to "models vs. *committed* schema,"
   which is exactly what the Phase 5 static cops already compare. A freshly-built-from-source
   DB cannot exhibit the drift-vs-deployed-DB that gives these tools their real-world value.
   What genuinely survives is only *runtime model reflection* (metaprogrammed validations,
   engine-provided models) that static parsing can't see. Worse for the tier's marginal
   value: several AR-doctor checks — `unindexed_foreign_keys`, `extraneous_indexes`,
   `mismatched_foreign_key_type`, `table_without_primary_key` — are **pure `db/schema.rb`
   analysis**, needing no boot and no DB at all. The project already ships a schema-parser
   path (Phase 5) and in-repo custom cops (Phase 6); these could land inside the existing
   determinism/pinning contracts. Add the already-shipped
   `Rails/UniqueValidationWithoutIndex` (AR-doctor's single flagship check), and the honest
   baseline the execution tier must beat is **not "no coverage" — it's "a static-capture
   pass."** See Phase 8-zero (§7).
4. **Non-determinism contradicts the product's headline promise.** "Same findings set, every
   run" (`DESIGN.md` §2) is the reason this tool exists instead of running the raw gems. The
   execution tier cannot honor it. Defensible if the tier is fenced off as a different *kind*
   of output (§3.5), but a real dilution of the core value proposition — a conscious decision,
   not a slide.

Net: after Phase 8-zero, the execution tier's only *irreplaceable* payload is **SimpleCov**
(coverage is impossible statically) plus the thin runtime-reflection residue of the two DB
tools. That is the value that has to justify the blast radius — and it should be measured,
not assumed.

### 2.1 [review] Threat model — what container isolation is claimed to defend

The isolation design (§3) is proportionate defense-in-depth for the **intended use: auditing
your own or a client's repo, defending against supply-chain surprises and accidental
damage** (a gem's railtie phoning home, a migration touching a real DB, a test suite deleting
a directory). It is **NOT** claimed to be adequate for pointing the tool at *arbitrary
hostile repositories* — a shared-kernel container does not contain a determined kernel-escape
exploit. That threat class would require VM-class isolation (gVisor / Firecracker) or an
explicit acceptance of kernel-escape risk, and is **out of scope for this proposal**. Stating
the boundary is load-bearing: it's why container-only (not VM) is the right answer here, and
it's the line beyond which this design must not be used.

## 3. Design decisions

Each decision states the fork, the choice, and the rationale — the DESIGN.md house style.

### 3.1 Isolation: clone inside a disposable container; two-phase network

**Fork:** run on the host (fast, simple) vs. inside an ephemeral container; and — within the
container option — bind-mount the host clone vs. copy/clone the target *inside* the container.

**Decision (Proposed):** **container-only, with the target cloned/copied *inside* the
container and no host filesystem mount at all. [review]** Bind-mounting the host checkout —
even read-only — is both weaker (host path exposed) and *broken*: Rails boot writes
`tmp/`/`log/`, `db:migrate` re-dumps `db/schema.rb` into the repo, and SimpleCov writes
`coverage/.resultset.json` **into the target directory**, so a read-only mount fails the
tier's own tools. Cloning inside the container makes writes free (the copy is disposable) and
exposes zero host filesystem. There is **no host-native execution path, not even behind a
flag** — a "fast path" would become the default and defeat the isolation.

**[review] Two-phase network, because `bundle install` needs egress *and* runs code:**
- **Install phase** — egress restricted to an allowlist (rubygems.org + any git sources
  declared in the target's Gemfile/lockfile). This is the first point arbitrary code runs
  (Gemfile evaluation, native-extension `extconf.rb`), so we honestly accept that exfiltration
  is *possible* during install and minimize the window; egress is allowlisted, not open.
- **Run phase** — network **torn down** to the private bridge only (throwaway DB/Redis, §3.2).
  Booting the app and running checks should reach nothing but the disposable services.

**All target-bundle operations happen in-container** — including `bundle lock`/`bundle list`,
because evaluating the target's `Gemfile` is itself code execution and must never run on the
host.

**[review] Container hardening checklist (8a):** non-root user, `--cap-drop=ALL`,
no-new-privileges, hard **CPU / memory / disk-quota / PID** limits (reek alone peaked at
3.8 GB RSS on Discourse per `DESIGN.md` §8; a hostile target can also fill disk or fork-bomb,
which a CPU/mem-only limit misses), a wall-clock timeout, and unconditional teardown after the
run. **Pick one runtime for the 8a spike (Docker), not Docker-vs-Podman detection** — dual
support is scope creep before the tier has proven value. A container runtime becomes a **hard
dependency** of the tier (documented; the static pipeline keeps zero such dependency).

**Open — not resolved here:** base-image strategy — prebuilt-per-Ruby-version (Proposed
default, more deterministic) vs. build-from-target-Dockerfile (future convenience). Unspiked.

### 3.2 Database: ephemeral, throwaway, schema-loaded from committed source

**Fork:** connect to an operator-provided DB vs. provision a disposable one; and load schema
via `db:schema:load` vs. replaying migrations.

**Decision (Proposed):** stand up a **throwaway DB** (Postgres by default, MySQL when the
target's adapter demands it) inside the sandbox network, load the target's committed schema
into it, point the target at it via `DATABASE_URL`, and destroy it with the container. **A
real/operator DB is never touched.** **[review] Prefer `db:schema:load` from `db/schema.rb`
(or `structure.sql`) as the primary path; replaying full migration history from zero is the
*fallback*** — mature apps routinely have migration histories that no longer replay cleanly,
so migrations-first would fail the funnel unnecessarily.

**Rationale, honestly bounded:** the checks need a live connection but not real data. But note
§2.3 — because schema comes from committed source, this DB cannot exhibit deploy-vs-source
drift, so it delivers only the runtime-reflection slice of these tools' value, not their
headline "catch the DB that diverged from your code" capability. That limitation is a reason
the tier's DB-tool value is thin, and it feeds the Phase 8-zero baseline (§7).

### 3.3 Secrets & boot: env-var provisioning only; every funnel failure is reported

**Fork:** how to satisfy the app's boot-time secret requirements.

**Decision (Proposed):** provide **synthetic env-var secrets only** — `SECRET_KEY_BASE`,
`RAILS_ENV` (a dedicated `audit`/`test` env), a generated `DATABASE_URL` (§3.2), and a stub
`REDIS_URL` pointing at a throwaway Redis when the target needs one. **We do not, and cannot,
supply a real `master.key`.** Targets requiring `credentials.yml.enc` decryption at boot will
fail, and any failure *along the whole funnel* (clone / bundle install / schema load / boot)
is reported as a structured execution-tier outcome
(`status: "boot_failed" | "install_failed" | "schema_failed" | ..., reason: <captured
stderr>`), **never** as an empty/clean result — consistent with the Phase 5c schema-absent
precedent (`DESIGN.md` §9). Roughly: "works on apps that boot from env-var secrets;
reports-and-skips the rest, at whatever funnel stage they fall over."

### 3.4 Read-only invocation is a *contract*, not a security control

**[review]** The tier **only ever invokes read/report modes** — AR-doctor's default report
task, database_consistency's plain check. The mutating modes (`database_consistency
--autofix`/`install`/`todo`; any AR-doctor generator) are **never wired into the argv builder
at all**. This is worth keeping — it's the no-mutation contract (`DESIGN.md` §8 flags these
modes) — but it is **not a security mitigation**: the untrusted target code executes
arbitrarily inside the container regardless of which argv *we* build, so the argv lockout only
constrains our own invocation. Real containment comes from §3.1 (disposable clone, teardown),
not from argv discipline. Filed here as a contract, not among the security posture, so the
posture isn't inflated.

### 3.5 [review] Config ownership — the founding lesson, applied to this tier too

The project exists because a tool silently inherited the target's own suppression config
(brakeman's `config/brakeman.ignore`, `DESIGN.md` §3). The execution tools have the same trap:
database_consistency auto-loads the target's `.database_consistency.yml`, active_record_doctor
loads `.active_record_doctor.rb`, and SimpleCov's filters/output are driven by the target's own
config. **Decision (Proposed): the tier owns each tool's config** (CLI-supplied config path or
explicit flags overriding target discovery), respecting the target's config only via an
explicit opt-in flag — exactly the §4 config-ownership model, extended to the execution tools.
Without this, a target could silently suppress its own execution-tier checks, reintroducing the
class of silent false negative this project was built to eliminate.

### 3.6 Determinism: a separate artifact, not a field on the reproducible one

**Fork:** merge execution-tier findings into `findings.json` with a `tier` discriminator vs.
emit a **separate artifact**.

**Decision (Proposed):** emit a **separate `execution-findings.json`**, never mixed into the
static `findings.json`. The static file keeps its byte-for-byte determinism contract
(`DESIGN.md` §4) completely intact. A `tier: static|execution` field on one merged file
preserves diffability *only if every consumer remembers to filter* — a discipline guarantee,
and this project's own history (brakeman ignore, unprefixed `Exclude`, silent cop loading) is
a catalog of discipline guarantees failing. Separate artifact is the structural version.

**[review] Precise disclosure, not blanket "reproducible: false".** For a given
(target commit, container image digest), 8a/8b output is actually *stable* — the target's own
`Gemfile.lock` pins the tool version and the DB is built from committed source. The honest
metadata is **`pinned_by_us: false` / `warranted_reproducible: false`**, plus the environment
that produced it (resolved tool versions per §3.7, container image digest, DB adapter/version)
— not a claim that the output is random. SimpleCov (8c) is the genuinely less-stable case
(suite flakiness), and its per-tool metadata should say so.

**Rendering (resolve mechanically):** `execution-audit` writes `execution-findings.json` and
its own report section; a subsequent static `audit` run must **not** clobber it, and the merged
human report (if any) is rendered by whichever command runs last, reading both artifacts and
fencing the execution section under a **"Execution tier (not warranted reproducible)"** heading
with a status-first layout (so a `boot_failed` is impossible to miss). Reuses the §5 Finding
object shape so no new downstream vocabulary is needed.

### 3.7 Output normalization: line parsers with a fail-loud unknown-format tripwire

**Fork:** AR-doctor and database_consistency emit **plain text only** (`DESIGN.md` §8). Parse
it (brittle) vs. wait for JSON support (indefinite).

**Decision (Proposed):** per-tool **line parsers** mapping text output into the §5 Finding
schema, each guarded by an **explicit output-shape assertion**: if the tool's output doesn't
match the expected format (e.g. a target-bundle version bump changed the wording), the parser
**raises with the raw output attached** rather than silently returning zero findings —
mirroring the runners' existing `MissingOutputError` and the project's recurring lesson that
*a check silently producing nothing is the exact failure mode this tool exists to prevent*
(`DESIGN.md` §9; the schema-loader/`chdir`, unprefixed-`Exclude`, and custom-cop-loading
silent no-ops). **[review] Exit-code policy:** the runners' version-scoped exit-code table
(`runners.rb` `EXIT_CODES`) can't apply when versions float, so the tier treats the
**output-shape assertion, not the exit code**, as the authoritative "did this run correctly"
signal, with exit code recorded but advisory. SimpleCov is the exception — it emits structured
`.resultset.json`, so it gets a real JSON parse. **[review] SimpleCov injection is an open
problem** (§8): if the target doesn't already use SimpleCov, coverage requires injecting it
(a `RUBYOPT` preload — preferred — or editing the test helper, which is mutation); if it does,
its config is target-owned (§3.5). Non-trivial; a named 8c open question.

### 3.8 Command surface & opt-in gate

**Fork:** a flag on `audit` vs. a separate command.

**Decision (Proposed):** a **separate command** — `rails-audit execution-audit <target>` —
mirroring the `annotate` precedent (`DESIGN.md` §4: annotate is separate because of a totally
different runtime/cost profile). The execution tier boots apps and runs test suites:
minutes-to-tens-of-minutes, container-dependent, arbitrary-code-executing. It does not belong
inline in the ~15 s static `audit` run, and must not run in CI-by-default. The command
requires an **explicit acknowledgment** that it executes untrusted code — a
`--i-understand-untrusted-code-runs` flag (or a config-file acceptance), refusing to run
without it. No silent arbitrary execution, ever.

## 4. Per-tool notes

- **active_record_doctor** — smallest execution blast radius (boots app; does **not** run the
  test suite), but §2.3 shows a large fraction of its checks are static-capturable and its
  flagship check already ships. Its genuinely runtime-only residue plus its boot-dependent
  checks are what the tier would add. Plain-text output → line parser (§3.7). The natural
  harness proving-ground *if the tier proceeds* (§7).
- **database_consistency** — same boot cost as AR-doctor (no test suite), reuses the same
  harness. Config-ownership trap (§3.5) and mutation-mode lockout (§3.4) both apply. Same
  throwaway-DB value-collapse caveat (§2.3).
- **SimpleCov** — **the tier's only irreplaceable payload** (coverage is impossible
  statically), but the largest blast radius: it runs the **entire target test suite**. The
  "reuses the proven harness" framing understates it — suite execution brings framework
  detection, parallel test DBs, `DatabaseCleaner`, system-test browser deps, and a
  flaky/failing-suite policy (partial/no data → report, don't swallow). That machinery is the
  *majority* of 8c's difficulty, not an increment on 8a. Upside: clean JSON normalization.

## 5. Report & schema integration

- `execution-findings.json`: reuses the §5 Finding object; adds a tier envelope
  (`pinned_by_us: false`, `warranted_reproducible: false`, resolved tool versions, container
  image digest, DB adapter, per-tool/per-funnel-stage `status` with captured reason).
- Report: a dedicated **"Execution tier (not warranted reproducible)"** section, status-first,
  fenced from the deterministic findings (§3.6). New impact/confidence rows for these tools'
  rules — **Proposed, needs the same security/eng review the §5 table already flags as
  pending.**
- The static `findings.json`, its determinism contract, and the existing report are
  **untouched** by this tier.

## 6. What this tier explicitly does NOT do

- Does not run by default, in CI or otherwise (§3.8).
- Does not touch a real database, supply a real `master.key`, or expose the host filesystem
  (§3.1–§3.3).
- Does not run any tool's mutating/autofix mode (§3.4).
- Does not enter the reproducible `findings.json` (§3.6).
- Does not claim coverage on apps that fail any funnel stage — it reports the failure (§3.3).
- Does not claim to contain a hostile kernel-escape exploit — container-class isolation only
  (§2.1).

## 7. Staged delivery (static capture first, then an abandonable tier)

**[review] Phase 8-zero — the static-capture pass, *before* any execution code.** Enumerate
every AR-doctor and database_consistency check into three buckets: **(a) already shipped**
(e.g. `Rails/UniqueValidationWithoutIndex`); **(b) statically capturable** from `db/schema.rb`
+ model source with no boot (`unindexed_foreign_keys`, `extraneous_indexes`,
`mismatched_foreign_key_type`, `table_without_primary_key`, …); **(c) genuinely runtime-only**.
Ship bucket (b) as cops/checks inside the existing determinism & pinning contracts (reusing the
Phase 5 schema parser and Phase 6 custom-cop machinery). This is cheap, deterministic, and
carries none of §2's blast radius — and it **re-baselines the whole tier decision**: the
execution tier now has to justify itself against bucket (c) + SimpleCov, not against zero
coverage.

Then, **only if (c) + SimpleCov justify it**, the sandboxed tier — the hard, shared cost is the
container/DB/secret harness (§3.1–§3.3):

- **Phase 8a — harness + active_record_doctor.** Build the sandbox harness and the read-only
  invocation + config-ownership + line-parser + fail-loud contracts, validated end-to-end with
  AR-doctor against a fixture target that boots from env-var secrets. **Decision gate:** measure
  the **full provisioning funnel** success rate (§8) and operational cost. If the harness costs
  more than bucket-(c) findings justify, **stop here** — 8b/8c are not sunk cost. **Caveat: an
  8a "go" tells you little about 8c** — 8c's difficulty is suite execution, which 8a never
  exercises (§4).
- **Phase 8b — database_consistency.** Reuses the 8a boot harness; adds its line parser,
  config-ownership, and the structural mutation-mode lockout. Small increment over 8a.
- **Phase 8c — SimpleCov.** The tier's only irreplaceable payload, and the largest blast
  radius: test-suite execution, its own decision gate independent of 8a's result.

Each sub-phase is independently shippable and independently abandonable.

## 8. Open questions (new to this tier; the §9 static-pipeline list still stands)

1. **Container runtime as a hard dependency** (§3.1) — acceptable, or a blocker for some
   users? Docker base-image + rootless support need a spike.
2. **Base-image strategy** (§3.1) — prebuilt-per-Ruby vs. build-from-target-Dockerfile —
   unspiked.
3. **[review] Full-funnel success rate on real targets** — clone → bundle install → schema
   load → boot, each failing independently (§2.2, §3.3). §2.2 predicts a meaningful fraction
   can't complete it; the actual rate across a sample of real apps is unmeasured and directly
   determines the tier's real-world value. **The single most important thing to measure in an
   8a spike — and measure the whole funnel, not just boot.**
4. **[review] SimpleCov injection** (§3.7) — `RUBYOPT` preload vs. helper edit (mutation) vs.
   rely on target already using it; each has a cost. Named 8c open question.
5. **Plain-text parser durability** (§3.7) across the tools' floating versions — the tripwire
   catches drift loudly but each break is maintenance cost; frequency unknown.
6. **Wall-clock budget** — booting + suite-running large apps could exceed any reasonable
   budget; ceiling and timeout policy need real measurement (the static tier's Discourse
   numbers, `DESIGN.md` §9, are a floor, not a guide, for this tier).
7. **[review] Overlap accounting with Phase 5 / Phase 8-zero** (§2.3) — dedup AR-doctor's
   uniqueness-index finding against the static cop's, or report both with tier provenance?
   Leaning "report both, labeled by tier," but unresolved.

## 9. Recommendation

**[review] Ship Phase 8-zero (the static-capture pass, §7) first; then approve Phase 8a only
as a spike, not Phase 8 as a commitment.** Concretely:

1. **Do Phase 8-zero now** — it's cheap, deterministic, inside the existing contracts, and it
   captures a real chunk of the two DB tools' value with none of the blast radius. It also
   sets the honest baseline every later decision is measured against.
2. **Then decide the tier against that baseline.** If bucket-(c) runtime-only findings +
   SimpleCov look worth it, run an **8a spike** to measure the full-funnel success rate (§8.3)
   and operational cost before committing to 8b/8c. If not, **deferring the sandboxed tier
   entirely is a legitimate outcome** — the static pipeline plus Phase 8-zero stands on its
   own, and `DESIGN.md` §10.8 already frames the tier as optional.

The sandboxing / opt-in / determinism-fencing / config-ownership design above is, I believe,
the right *shape* if we proceed. But the honest read (§2, sharpened by review) is that the
execution tier's irreplaceable payload is thinner than it first appears, and the static-capture
pass should come first and may well be enough.
