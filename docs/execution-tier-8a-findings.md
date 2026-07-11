# Phase 8a findings & decision: the sandboxed execution tier is deferred

Status: **DECIDED — NO-GO on 8b/8c; the sandboxed execution tier is deferred (owner-approved
2026-07-11).** This is the outcome of the Phase 8a spike proposed in
[`execution-tier-proposal.md`](execution-tier-proposal.md) §7–§9. The static pipeline
(brakeman/rubocop/reek + schema cops + custom cops) plus Phase 8-zero (the static schema
analyzer) is the shipped product; the sandboxed tier is not built beyond the 8a spike.

## What 8a built

An end-to-end sandbox harness (`lib/rails_audit/execution/`) that clones/copies an untrusted
target Rails app into a disposable Docker container and runs the full provisioning funnel —
**clone/copy → bundle install → schema load → boot** — then runs active_record_doctor and
normalizes its output into findings. Delivered as milestones M1–M4 (fixture, harness+funnel,
AR-doctor integration, `execution-audit` command + `execution-findings.json` artifact),
adversarially reviewed (Fable), suite green (107 runs) against a synthetic fixture.

The 8a decision gate (§7) was explicit: **measure the full provisioning-funnel success rate on
real apps before committing to 8b/8c.** That measurement (M5) is what this document records.

## M5 measurement

Sample: 6 well-known OSS Rails apps, run via the committed harness with relaxed timeouts
(overall 45 min, install 30 min) to find the true funnel outcome rather than a time-boxed one.
The harness resource limits (2 GB workspace tmpfs, 256 MB probe tmpfs, 4 GB memory) were left
**as designed** and are part of what was measured.

Two ingestion paths were exercised:
- **git-URL** (the tier's primary interface) — the path `execution-audit <git-url>` uses.
- **local-path** (`docker cp` of a host clone) — the path the fixture tests exercise.

### Result: full-funnel success = 0 of 6 (0%)

Via the working local-path ingestion (measuring the funnel *core*):

| Repo | Furthest stage reached | Why it stopped | Category |
|---|---|---|---|
| rubygems.org | bundle_install | native gem `zlib` build fails — base image lacks `zlib1g-dev` | A |
| lobsters | bundle_install | native gem `psych` build fails — lacks `libyaml-dev` | A |
| mastodon | bundle_install | native gem `idn-ruby` build fails — lacks `libidn-dev` | A |
| chatwoot | bundle_install | **install succeeded** (Ruby 3.4.4 / Rails 7.1.5.2); harness then required the target to bundle `active_record_doctor` and crashed (`KeyError`) | B |
| huginn | profiling | dynamic `ruby '>=3.4.0'` cannot resolve to a concrete image | C |
| discourse | profiling | "Cannot resolve target Ruby version" | C |

**No app reached `schema_load` or `boot`.**

## Structural failure categories (not incidental)

- **A. Base image lacks system libraries** for real apps' native gems (`zlib1g-dev`,
  `libyaml-dev`, `libidn-dev`, …). Open-ended: each app needs a different, unpredictable set of
  `-dev` packages. The 8a Dockerfile ships only `build-essential`, `libpq-dev`,
  `postgresql-client`, `git`. (3/6)
- **B. The tier requires the target to bundle `active_record_doctor`.** `Harness#install_bundle`
  reads `Gem.loaded_specs.fetch("active_record_doctor")` from the *target's* bundle. The M1
  fixture bundled it; real apps don't. **This blocks every real app unconditionally, regardless
  of provisioning** — proven by chatwoot, which got furthest (install succeeded) and still
  failed. The tier would have to *inject* AR-doctor, not read it from the target. (1/6 observed;
  would affect all.)
- **C. Ruby-version resolution** doesn't handle the common dynamic/constraint declaration form
  (`ruby '>= x', '< y'`) or apps without a concrete `.ruby-version`. (2/6)
- **D. git-URL ingestion is broken** — the tier's primary interface never had end-to-end
  coverage (fixture tests use local-path). Three distinct bugs found:
  - heredoc escape stripping broke the profiling probe (`<<~SH` ate the `find -exec … \;`
    terminator) — **FIXED** in commit `9fca99a` (with a regression test).
  - `transfer_target`'s in-container `git clone` runs via `app_exec`, which forces
    `--workdir /workspace/app` *before the clone creates that directory* → `chdir … no such file
    or directory`. **Found, not fixed** (deferred with the tier). Fix direction: clone with
    `--workdir /workspace`, like the tar/local-path branch.
  - the probe's 256 MB `/tmp` tmpfs is too small for large repos' working trees (discourse's
    23k-file checkout failed on space). **Found, not fixed.**

The killer is **B**: even with A and C fully solved, every real app would still fail at the
post-install version probe. The current tier cannot analyze any real app as built.

## Why this closes the decision

- It empirically confirms the proposal's own §2.2 prediction — the provisioning funnel fails
  independently at each stage on real targets, so the tier inherently cannot run on a meaningful
  fraction of them.
- §2.3 already established that the throwaway-DB-from-committed-schema design collapses the DB
  tools' headline value to runtime-reflection only. With 0% funnel success on top of that, the
  DB-tool payload (8a/8b) does not justify its blast radius or the open-ended engineering (esp.
  category A, which is per-app whack-a-mole).
- SimpleCov (8c) is the tier's only irreplaceable payload, but it is strictly *harder* than
  reaching boot (it runs the target's entire test suite), and this measurement shows boot itself
  is unreached. Its independent decision gate is not met.
- The proposal's documented off-ramp (§7 decision gate; §9.2: "deferring the sandboxed tier
  entirely is a legitimate outcome") applies. The static pipeline + Phase 8-zero stands on its
  own.

## Decision

**Do not build Phase 8b or 8c.** The sandboxed execution tier is deferred. The 8a harness
(`lib/rails_audit/execution/`, the `execution-audit` command, the fixture) remains committed as
an experimental artifact and a record of the spike, but is not part of the supported product and
is not wired into CI (its live test is gated behind `RAILS_AUDIT_LIVE`).

### If ever revisited, this is the minimum that must be solved first

1. Inject `active_record_doctor` into the target environment instead of requiring the target to
   bundle it (category B) — without this, nothing else matters.
2. A base-image / system-library strategy that scales across real apps' native-gem needs
   (category A) — likely the hardest open-ended problem.
3. Ruby-version resolution for dynamic/constraint declarations and missing `.ruby-version`
   (category C).
4. Repair and *test* the git-URL ingestion path end-to-end (category D: workdir + probe tmpfs;
   heredoc already fixed).
5. Right-size the resource limits (workspace/probe tmpfs, memory) for real apps.

Even with all of the above, the payload that remains (per §2.3) is thin — runtime model
reflection plus SimpleCov — which is why deferral, not a fix-and-retry loop, is the recommended
and adopted outcome.
