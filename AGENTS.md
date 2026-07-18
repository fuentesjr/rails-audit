# AGENTS.md — rails-audit operating rules

rails-audit is a static Rails audit CLI (runners → normalizer → impact-first
renderer; optional LLM annotate). Authoritative design: `docs/DESIGN.md`.
Evidence archive: `../rails-audit-spike` (read-only).

## Work tracking

Work tracking lives in `.trk/` via the `trk` CLI. Orchestrator: run
`trk status --json` at session start; `trk dispatch` before spawning
long-running subagents and `trk resolve` on return; `trk check --strict`
before session end. Subagents: do not modify anything under `.trk/`; report
results in your final message.

## Standing process notes

- Prefer codex-dispatch for coding; consult Fable for high-stakes/untrusted-code
  milestones and hard forks.
- Do not revive the sandboxed execution tier (Phase 8b/8c) without an explicit
  work order; read `docs/execution-tier-8a-findings.md` first.
- No push or RubyGems publish without explicit approval.
