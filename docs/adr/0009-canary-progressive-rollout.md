# ADR-0009 — Progressive rollout (canary → production) gated on telemetry, on Fleet Free

- **Status:** Accepted (2026-07-22)
- **Builds on:** [ADR-0003](0003-free-tier-trust-tiering.md) (self-scoping SQL), [ADR-0006](0006-gitops-ci-architecture.md) (GitOps/CI), Phase 5 telemetry (the exporter)
- **Related:** [gitops/promote/](../../gitops/promote/), [.github/workflows/promote.yml](../../.github/workflows/promote.yml)

## Context

A core Client-Platform responsibility is **rolling out MDM policy/config changes progressively** —
canary first, then promote to the fleet only if telemetry stays healthy — rather than big-bang.
The obvious mechanism (Fleet **teams**: a `canary` team and a `production` team, apply to canary on
merge, promote after a soak) is **Premium**. Per-label **policy scoping** is also Premium (ADR-0003).
So on Free we cannot segment *what a policy targets* by team or label.

## Decision

Model the canary cohort with **self-scoping policy SQL** — the same free-tier lever ADR-0003 used for
trust tiering — and gate promotion on **the telemetry we already emit**.

1. **Canary cohort = a sentinel.** Canary hosts carry `/etc/axiom/canary` (Linux; dropped by
   `new-linux-vm.ps1 -Canary`). A dynamic Fleet label `canary` matches it (observability; Free).

2. **New controls ship canary-scoped.** A control under evaluation is authored so it **auto-passes on
   non-canary hosts** and only truly evaluates where the sentinel exists:
   ```sql
   SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM file WHERE path='/etc/axiom/canary')
                OR ( <the real compliance check> );
   ```
   Effect: the control is *live in GitOps* (drift-tracked, applied by CI) but only **bites the canary
   cohort**. Production hosts are unaffected.

3. **The gate reads the metric directly.** Because non-canary hosts auto-pass, the exporter's global
   `axiom_policy_failing_hosts{policy="<control>"}` **equals the canary failing-host count**. No
   per-cohort metric is needed — the self-scoping makes the existing global gauge canary-specific.

4. **Promotion = widening the scope.** When the gate passes, the canary wrapper is removed so the
   control evaluates on **every** host:
   ```sql
   SELECT 1 WHERE ( <the real compliance check> );
   ```
   This is an ordinary code change → PR → CI `gitops` apply. Rollback = revert the PR.

## The gate

[`gitops/promote/promote.ps1`](../../gitops/promote/promote.ps1) queries Prometheus and **promotes
only if**, for the control under test:
- canary hosts are actually **reporting** (heartbeat present — a green metric on a dead cohort is
  meaningless), and
- `max_over_time(axiom_policy_failing_hosts{policy="<control>"}[<soak>]) == 0` — i.e. **zero canary
  failures sustained over the soak window** (default 2h).

Pass → it rewrites the control's SQL to the promoted (unscoped) form and prints the diff; a human/CI
opens the PR. Fail → it holds and reports which canary hosts are failing. [`promote.yml`](../../.github/workflows/promote.yml)
wraps it on the self-hosted runner (same trust model as apply/drift, ADR-0007).

## Consequences

- **Positive:** genuine telemetry-gated progressive rollout at **$0**, reusing the trust-tiering lever
  and the Phase 5 exporter. The gate runs on metrics *we built*, which is the whole point.
- **Scope / honesty:** self-scoping canaries work for **policies** (osquery SQL). **Configuration
  profiles** cannot be label-scoped on Free, so profile canaries are the documented **Premium delta**
  (a real `canary` *team* + team-assigned profiles). The mechanism and the gate are identical; only
  the targeting primitive changes.
- **Soak realism:** the soak window trades rollout speed for confidence; 2h is a lab default, not a
  production SLO.
