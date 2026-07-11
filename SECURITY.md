# Security Policy

## Reporting a vulnerability

Please report security issues privately via GitHub's
[private vulnerability reporting](https://github.com/fuentesjr/rails-audit/security/advisories/new)
for this repository, rather than opening a public issue. Include a description, affected
version/commit, and reproduction steps if you have them. You'll get an acknowledgement and
a coordinated disclosure timeline.

## Trust model: static pipeline vs. execution tier

`rails-audit` has two very different execution profiles, and the security expectations
differ sharply between them.

### The static pipeline (`audit`) — does not run your app's code

The default `audit` command runs pinned static-analysis tools (brakeman, rubocop, reek)
and reads files (source, `db/schema.rb`). It **does not boot the target app, connect to a
database, or execute the target's code.** The trust surface is the same as running those
linters yourself. This is the supported product.

### The execution tier (`execution-audit`) — runs untrusted code

The experimental `execution-audit` command **executes the target application's code** —
`bundle install`, schema load, and app boot — in order to reach checks that require a live
app. Running an untrusted project's code (including its gems' native extensions and any
build scripts) is inherently dangerous. Two safeguards apply:

1. **Explicit acknowledgement is mandatory.** The command refuses to run without
   `--i-understand-untrusted-code-runs`. There is no way to skip this.
2. **Container sandbox.** The target is cloned and run *inside* a container (no host bind
   mount), with a throwaway database built from the committed schema, synthetic
   environment secrets, and network fencing on the run phase.

**Threat model boundary.** The sandbox is designed to contain *container-class* risk —
accidental damage, filesystem access to the host, credential exposure, and network
egress during the run phase. It is **not** a defense against a determined attacker with a
container-escape or hostile-kernel exploit. Do not point `execution-audit` at code you
consider actively adversarial, and do not run it on a host where a container escape would
be catastrophic. Prefer an isolated/disposable environment.

The execution tier is **not warranted reproducible** and its deeper stages are deferred;
see [`docs/execution-tier-proposal.md`](docs/execution-tier-proposal.md) for the full
sandbox design and [`docs/execution-tier-8a-findings.md`](docs/execution-tier-8a-findings.md)
for the go/no-go measurement.

## Supported versions

This project is pre-release (`0.1.0`). Security fixes are applied to `main`. There is no
long-term-support branch yet.

## A note on findings

`rails-audit` reports potential issues in a *target* codebase; a finding is not a proven
exploit, and the tool can produce false positives. Treat its output as input to human
review, not as an authoritative security certification.
