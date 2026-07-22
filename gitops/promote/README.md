# Canary → production promotion (telemetry-gated)

Progressive rollout of MDM controls: ship a change to a **canary** cohort first, promote it to the
whole fleet **only if the telemetry stays green** over a soak window. Design rationale + the
Free-tier constraint (Fleet *teams* and per-label policy scoping are Premium) are in
[ADR-0009](../../docs/adr/0009-canary-progressive-rollout.md).

## How it works (Fleet Free, $0)

The canary cohort is expressed with **self-scoping SQL** (the ADR-0003 lever), not a Premium team:

- A canary host carries `/etc/axiom/canary` (provision with `new-linux-vm.ps1 -Canary`); the dynamic
  `canary` label matches it.
- A control under rollout is authored **canary-scoped** — it auto-passes on non-canary hosts and only
  grades the canary cohort. Worked example: [`../lib/linux/policies/canary-auditd.yml`](../lib/linux/policies/canary-auditd.yml)
  (+ remediation [`../lib/linux/scripts/install-auditd.sh`](../lib/linux/scripts/install-auditd.sh)).
- Because non-canary hosts auto-pass, the exporter's global
  `axiom_policy_failing_hosts{policy=…}` **equals the canary failing-host count** — so the gate reads
  it directly.

## The gate — [`promote.ps1`](promote.ps1)

Promotes **only if** all three hold for the control:

| # | Check | PromQL |
|---|---|---|
| 1 | telemetry alive | `axiom_exporter_up == 1` |
| 2 | canary cohort populated | `axiom_label_hosts{label="canary"} >= 1` |
| 3 | zero canary failures, soaked | `max_over_time(axiom_policy_failing_hosts{policy=…}[soak]) == 0` |

```powershell
gitops/promote/promote.ps1                 # dry run: report the decision
gitops/promote/promote.ps1 -Apply          # on PASS, widen the control's query to fleet-wide
gitops/promote/promote.ps1 -SoakHours 0.1  # shorten the soak (demo)
```

Exit `0` = PROMOTE (rewrites the control's `query:` from canary-scoped to the full check), `1` = HOLD
(prints which check failed), `2` = error. [`../../.github/workflows/promote.yml`](../../.github/workflows/promote.yml)
runs it on the self-hosted runner (every 6h + on demand) and, on PASS, opens a **PR** — promotion is
human-reviewed; the merge is what `apply.yml` rolls out fleet-wide. Rollback = revert the PR.

## Current state (verified)

The gate runs end-to-end against live Prometheus and **correctly HOLDS**:
```
[1] telemetry alive           axiom_exporter_up = 1
[2] canary cohort populated   axiom_label_hosts{label=canary} = 0  (need >= 1)
[3] no canary failures (soak)  max_over_time(failing[2h]) = 0
RESULT: HOLD -- canary cohort has < 1 host  (nothing to gate on)
```
i.e. its most important property is proven: **it will not promote on a green-but-empty cohort.** The
full live loop (provision `-Canary` host → auditd fails → remediate via run-script → passes → gate
PROMOTES → PR) runs once a canary VM is up (deferred here only by the single-VM NEM ceiling).

## The full loop

```
new-linux-vm.ps1 -Name canary-01 -Canary      # host joins the canary cohort
  → policy "auditd running (canary)" FAILS on it (fresh host, no auditd)
  → promote.ps1 HOLDS (1 canary host failing)
fleetctl run-script --host canary-01 --script-path lib/linux/scripts/install-auditd.sh
  → auditd running → policy PASSES → axiom_policy_failing_hosts → 0
  → promote.ps1 (after soak) PROMOTES → widens the query → PR → apply.yml → fleet-wide
```
