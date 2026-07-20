# ADR-0003: Trust-tiering on Fleet Free — self-scoping policy SQL, not label/enroll-secret scoping

- **Status:** Accepted (Phase 0)
- **Date:** 2026-07-20
- **Phase:** 0 — Recon & plan
- **Related:** ADR-0001 (topology, Enclave node); research brief
  [2026-07-20-phase0-1-fleet-brief.md](../research/2026-07-20-phase0-1-fleet-brief.md) §4/§6
- **Supersedes premise in:** the master prompt's tiering instruction

## Context

The lab must give the **High-Trust Enclave** (`enclave-01`) measurably stricter
policy than the Standard tier — FDE verified, screen-lock ≤ 5 min, no removable
media, FIM on `/opt/axiom/weights-cache`, elevated bars — **and** the master
prompt prescribes the mechanism: *"implement tiering with labels + per-label
policy scoping + separate enroll secrets."*

**Live-docs research (2026-07-20, Fleet v4.89.1) refutes that mechanism on Fleet
Free** — this is a real-world contradiction with the prompt, and per the working
agreement we trust the real world and note the delta:

1. **Per-label policy scoping** (`labels_include_any` / `labels_include_all` /
   `labels_exclude_any` on a policy) is a **Premium** feature and is **silently
   ignored on Free** — no error; the policy simply evaluates on **every** host.
   ([teams guide](https://fleetdm.com/guides/teams), [#24097](https://github.com/fleetdm/fleet/issues/24097))
2. **Enroll secrets do not segment hosts on Free.** All hosts land in the single
   global "No team" regardless of which secret enrolled them, and **no query
   exposes which secret a host used** ([#2290](https://github.com/fleetdm/fleet/issues/2290)).
   Multiple secrets are *allowed* on Free but carry no scoping power.
3. **Labels are free**, but only for **grouping and query targeting** — not for
   scoping *policies*.

So the prompt's design would produce a **false green**: enclave-only policies
would silently run against Standard hosts (failing them for controls that don't
apply) or vice-versa, and nothing would actually be tier-scoped.

## Decision

Enforce trust tiers on Free with **self-scoping policy SQL keyed on a
provisioned, host-intrinsic tier marker**, composed with Fleet's two free
scoping primitives. Concretely:

### 1. Provisioned tier marker (the source of truth on each host)
Every host is provisioned (cloud-init / unattend) with a marker declaring its tier:
- Linux/macOS: file `/etc/axiom/trust-tier` containing `standard` or `elevated`,
  plus tier-specific marker files under `/etc/axiom/tier.d/` (e.g. `elevated`).
- Windows: registry value `HKLM\SOFTWARE\Axiom\TrustTier` = `standard|elevated`.
- The Enclave canary path `/opt/axiom/weights-cache/` is itself an intrinsic
  marker (only `enclave-01` has it).

This marker is created by the same Git-tracked provisioning that installs fleetd,
so tier membership is **declared in code**, not clicked in the UI — and it ties
Phase 2/6 provisioning directly to Phase 4 policy.

### 2. Self-scoping policy SQL (the enforcement)
Because a Free policy runs on all hosts, each **tier-specific** policy is written
to **auto-pass on out-of-scope hosts and only meaningfully evaluate in-scope
hosts**. Canonical shape:

```sql
-- Elevated-only control. Returns a row (COMPLIANT) when EITHER the host is not
-- Elevated tier OR it satisfies the control. Returns no row (FAIL) only for an
-- in-scope host that violates the control.
SELECT 1 WHERE
      NOT EXISTS (SELECT 1 FROM file
                  WHERE path = '/etc/axiom/tier.d/elevated' AND type = 'regular')
   OR EXISTS ( /* the actual compliance check, e.g. screen lock <= 5 min */ );
```

- Fleet policy semantics: **1 row returned = pass/compliant, 0 rows = fail.** The
  `(out-of-scope) OR (compliant)` pattern makes non-enclave hosts always pass,
  so the policy shows red **only** on a non-compliant enclave host.
- The mirror pattern (`(in-scope) AND (compliant)`) is used where a control must
  *fail closed* if the marker is missing.

### 3. Free scoping primitives, composed
- **Platform field** (`platform: linux|darwin|windows`) — the one *built-in*
  free scoping — narrows OS-specific policies (e.g. LUKS only on linux).
- **Label-targeted scheduled/live queries** (free) carry Enclave-specific
  *telemetry* (FIM pack on the `enclave` label) even though *policies* can't be
  label-scoped.
- A dynamic **`enclave` label** (query: marker file present) still exists — for
  humans, dashboards (Phase 5 filters by it), and query targeting — just never
  as a policy scope.

### 4. Keep a distinct Enclave enroll secret — as a Premium-ready artifact
`enclave-01` still enrolls with its own secret. On Free this gives **no**
segmentation (see Context #2); we keep it because (a) it documents the intended
Premium design where a team-routed secret *does* segment, making the Premium
upgrade a config change not a redesign, and (b) it is good secret-rotation
hygiene. **LAB_STATE / runbooks state plainly that on Free this secret is
cosmetic for segmentation.**

## What Fleet Premium would change (constraint #1c)

- Create a real **Team** ("High-Trust Enclave"); route the enclave enroll secret
  to it → hosts auto-segment on enrollment, no marker files needed.
- Attach policies/profiles to the team, or use native `labels_include_any` policy
  scoping → **delete every `(out-of-scope) OR …` guard clause** from the SQL.
- Team-level agent options, per-team RBAC, and the GitOps API-only token.
- Estimated cleanup: the self-scoping guards disappear and `teams/enclave.yml`
  replaces the marker convention — a mechanical simplification, not a rewrite.

## Consequences

**Positive**
- Tiering is real and honest at $0: an enclave-only control genuinely fails only
  enclave hosts; Standard hosts aren't falsely marked non-compliant.
- Fully GitOps-expressible (markers in provisioning code, guards in policy SQL).
- Upgrade path to Premium teams is a documented, mechanical diff.

**Negative / risks**
- Policy SQL is more verbose (every tier policy carries a guard clause). Mitigated
  by a documented snippet + a CI check that tier policies contain a guard.
- The marker is host-local: a host that tampers with its own marker could
  self-downgrade. Acceptable for a lab; noted as a known limitation (Premium
  server-side teams remove it). We additionally cross-check tier via intrinsic
  signals (hostname prefix `enclave-*`, canary path presence) where possible.
- Analysts must remember labels ≠ policy scope on Free (documented in runbooks).

## Alternatives considered

- **Prompt's design (label scoping + enroll-secret segmentation).** *Rejected:*
  silently non-functional on Free — produces false-green compliance.
- **One Fleet instance per tier** (each Free). *Rejected as primary:* closest to
  true isolation but doubles the ops surface and breaks the single-pane-of-glass
  goal; kept documented as the "hard isolation" option if ever needed.
- **Accept a single flat scope** (no tiering). *Rejected:* the Enclave's stricter
  posture is a core portfolio story; a flat scope throws it away.
- **Fleet Premium teams.** The clean answer — out of scope by constraint #1.
