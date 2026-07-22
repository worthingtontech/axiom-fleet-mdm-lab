# ADR-0006: GitOps CI/CD architecture — cloud-ephemeral PR CI, self-hosted apply/drift

- **Status:** Accepted (Phase 3)
- **Date:** 2026-07-22
- **Phase:** 3 — GitOps & CI/CD
- **Related:** ADR-0003 (Free-tier tiering), ADR-0004 (TLS/DNS), ADR-0005
  (Windows MDM enablement), ADR-0007 (self-hosted runner security);
  encyclopedia [06-gitops-and-cicd](../encyclopedia/06-gitops-and-cicd.md);
  research brief [2026-07-20-phase0-1-fleet-brief.md](../research/2026-07-20-phase0-1-fleet-brief.md) §8

## Context

Phase 3 turns the imperatively-built lab into **Git-as-source-of-truth**: the
desired Fleet configuration lives in `gitops/` and reaches the server only
through reviewed, automated `fleetctl gitops` runs. Four forces shape the design:

1. **The Fleet server is LAN-only and unreachable from the GitHub cloud.**
   `https://fleet.axiom.lab` sits behind Caddy/mkcert on the operator's Windows
   host (ADR-0004). GitHub-hosted runners cannot see it; only a **self-hosted
   runner on the LAN** can apply to it.
2. **The repo goes public later** (private now, public at Phase 9). A public repo
   accepts **fork PRs from anyone**. If PR CI ran on the self-hosted LAN runner,
   an untrusted PR could execute code on the host that owns the Fleet server —
   an unacceptable exposure (the full analysis is ADR-0007).
3. **Fleet Free has no teams.** GitOps still uses the two-file layout
   (`gitops/default.yml` + `gitops/fleets/unassigned.yml`), but the teams file is
   silently skipped on Free.
4. **`fleetctl gitops` is declarative and destructive.** Anything a managed
   section omits is deleted on apply; there is no dry-run-by-default and no
   `--delete-missing` toggle. Mistakes are one merge away from wiping live config.

We must decide **where each job runs**, **how the baseline is seeded**, and how
to survive several Fleet-specific footguns discovered during research and build.

## Decision

### D1 — Split the pipeline by trust boundary

| Concern | Where it runs | Trigger | Why |
|---|---|---|---|
| **PR CI** (lint, profile validation, osquery SQL gate, `gitops --dry-run`) | **GitHub-hosted `ubuntu-latest`** against an **ephemeral Fleet** (mysql + redis service containers + a backgrounded `fleet serve`) | `pull_request` → `main` | Untrusted/fork code never touches the LAN or the host. The dry-run runs against a throwaway server built from scratch each run. |
| **Apply** (`fleetctl gitops`, real) | **Self-hosted LAN runner** (`[self-hosted, Windows, fleet-apply]`) | `push` → `main` (post-merge) + `workflow_dispatch` | Only the LAN runner can reach the live server. Trusted, main-only, never fork-triggered. Gated by the `production` environment. |
| **Drift detection** | **Self-hosted LAN runner** | nightly `schedule` + `workflow_dispatch` | Reads live state, which only the LAN runner can do. |

The ephemeral CI Fleet is a genuine `fleetdm/fleet:v4.89.1` server — the dry-run
therefore exercises the **real** validator (schema, env-expansion, Windows-MDM
capability checks), not a lint approximation. See ADR-0007 for the security
rationale that forces this split.

### D2 — Seed the baseline with `fleetctl generate-gitops`

The committed `gitops/` tree is **generator output**, not hand-authored from a
blank page: it was produced by `fleetctl generate-gitops` run against the live,
already-configured server, then trimmed. This matters because **drift detection
diffs the committed tree against fresh generator output** — if the baseline were
hand-shaped, every run would diff on cosmetic key ordering. Generator-in,
generator-compared keeps drift signal clean.

### D3 — The Windows-MDM toggle is a top-level `controls` key (the "C1" key)

Windows MDM is enabled in GitOps via **`controls.windows_enabled_and_configured:
true`** — a **top-level `controls`** key in `default.yml`, **not**
`org_settings.mdm.*` (that latter shape is the `/api/latest/fleet/config` REST
body, a different surface). This is the declarative successor to the imperative
API PATCH from ADR-0005; putting it in GitOps means a cold rebuild no longer
silently turns Windows MDM back **off**. It lives in `default.yml` only (it is a
global control, not a per-team one). Note the generator may not emit this key, so
it is **maintained by hand** and re-asserted on every apply.

### D4 — On Free, `fleets/unassigned.yml` is passed but skipped

Both `-f` files are always passed (`-f gitops/default.yml -f
gitops/fleets/unassigned.yml`) for forward-compatibility, but on Free
`fleetctl` prints *"teams are a Premium feature"* and applies **only
`default.yml`**. The unassigned file is the Free-tier successor to the deprecated
`teams/no-team.yml` (Fleet 4.82.0) and holds only `policies` / `controls` /
`software`. Keeping it in the command line means the Premium upgrade is a license
flip, not a workflow edit.

### D5 — No `--delete-missing`; deletion is declarative-per-section

`fleetctl gitops` has **no `--delete-missing` flag**. Deletion is **declarative
per section**: removing an item from a section in the YAML deletes it on the next
apply; a section omitted *entirely* is left untouched. Every apply path therefore
**dry-runs first** (`gitops.sh` and PR CI both do), and the operator reads the
diff before trusting it. This is the single most dangerous property of the tool.

### D6 — Never write a bare `$VAR` token in YAML comments (env-expansion gotcha)

`fleetctl gitops` expands `$VAR` references in the **raw file, comments
included**, and **fails on any unexpanded variable**. Two consequences the
pipeline hard-codes:

- **Every** `$FLEET_*` referenced anywhere in the YAML (even illustratively in a
  comment) must be exported in the job, or the run dies with
  *"variable used but not set"*. The ephemeral CI Fleet exports
  `FLEET_GLOBAL_ENROLL_SECRET` **and** `FLEET_SERVER_PRIVATE_KEY` (the latter is
  required for the Windows-MDM validation that the C1 key triggers).
- Comments must never contain a bare `$FLEET_...` example token — it would be
  treated as a live reference. `gitops/default.yml` already carries a warning to
  this effect above `org_settings.secrets`.

### D7 — The osquery SQL gate must grep, not trust exit codes

`osqueryi` **exits 0 even on invalid SQL** (osquery#5853). The `osquery-sql` gate
therefore runs each query with `--disable_extensions --json ... 2>&1` and
**greps the combined output** for error signatures
(`error`, `no such (table|column|function)`, `syntax error`, `near `). A green
exit code alone would let a broken query merge.

## Consequences

**Positive**
- A fork PR can never reach the LAN or the host: the only jobs that touch the
  live server are `push:main`-triggered on the self-hosted runner (ADR-0007).
- PR authors get a **real** `gitops --dry-run` verdict from a real Fleet, plus
  lint / profile / SQL gates — false-greens are designed out.
- Drift is caught nightly and re-asserted on merge; the C1 key surviving cold
  rebuilds means Windows MDM no longer silently regresses.
- The apply path is one committed, testable script (`gitops.sh`) shared by CI and
  humans — no divergence between "what the runner does" and "what I do locally".

**Negative / follow-ups**
- The self-hosted runner is a standing liability that must be hardened **before**
  the public flip — the whole of ADR-0007 exists to discharge this.
- The ephemeral CI Fleet adds ~1–2 min of setup per PR (db migrate + serve +
  healthz wait). Accepted: it is the price of a real validator.
- **Drift on the C1 key:** because the generator may omit
  `controls.windows_enabled_and_configured`, a nightly regeneration can surface
  it as a one-line diff. Mitigations: the baseline is kept generator-aligned
  (D2), and — decisively — **every apply re-asserts the key**, so a UI toggle-off
  is corrected on the next merge and a Phase 4 posture policy detects it in the
  meantime. If a future fleetctl emits the key, the diff disappears on its own.
- fleetctl is pinned to **4.89.1** in lockstep with the server; a server upgrade
  is a coordinated bump of the pin in `gitops.sh` and all three workflows.

## Alternatives considered

- **Run everything on the self-hosted runner** (including PR CI). *Rejected:*
  fork PRs would execute untrusted code on the Fleet host after the public flip —
  the exact anti-pattern ADR-0007 forbids. Cloud-ephemeral PR CI removes the LAN
  from the untrusted path entirely.
- **Lint/schema-only PR CI (no real Fleet).** *Rejected:* it cannot catch
  env-expansion failures, Windows-MDM capability errors, or destructive-section
  mistakes — the failures that actually bite. A throwaway real server is cheap
  and honest.
- **`--dry-run` against the live server from the cloud via a tunnel** (Tailscale/
  cloudflared). *Rejected:* punches a hole from the public CI plane into the LAN,
  re-introducing the exposure the split exists to remove; also couples PR CI to
  server availability.
- **Hand-authored GitOps baseline.** *Rejected:* drift detection would diff on
  cosmetic ordering forever. Generator-seeded baseline (D2) keeps drift honest.
- **Fleet Premium teams** (real per-team GitOps, team-routed enroll secrets).
  Out of scope by constraint #1; the two-file layout (D4) makes the upgrade a
  license flip rather than a redesign.
