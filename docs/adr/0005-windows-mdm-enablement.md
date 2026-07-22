# ADR-0005: Windows MDM enablement (WSTEP identity CA)

- **Status:** Accepted (Phase 2)
- **Date:** 2026-07-22
- **Phase:** 2 — Enroll the fleet
- **Related:** ADR-0004 (TLS); research brief §3 (Windows MDM)

## Context

Fleet Free supports **manual Windows MDM** (enrollment, config profiles/CSPs,
commands) — only Autopilot/Entra *zero-touch* is Premium. The lab wants a real
Windows host managed via MDM, not just osquery.

Turning Windows MDM on requires **two** server-side things, not one:
1. `FLEET_SERVER_PRIVATE_KEY` — already set (encrypts MDM assets at rest).
2. A **WSTEP identity CA** (cert + key) that signs the identity certificate each
   enrolling Windows client receives. Fleet does **not** auto-generate this; the
   UI errors *"Please configure Fleet with a certificate and key pair first"*
   without it (fleetdm/fleet#19821). This CA is **separate from the mkcert TLS
   CA** — it never touches HTTPS; it only signs MDM client identities.

## Decision

- Generate a dedicated WSTEP CA with `infra/scripts/new-wstep-ca.ps1`
  (OpenSSL in a Docker container; `-traditional` PKCS#1 RSA-4096, 10-year).
  Output: `infra/mdm/fleet-mdm-win-wstep.{crt,key}` — **gitignored** (the key is
  secret; `.crt` too, to keep the pair together and per-machine).
- Provide it to Fleet by **path, not `_BYTES` content**: bind-mount
  `./mdm → /etc/fleet/mdm:ro` and set
  `FLEET_MDM_WINDOWS_WSTEP_IDENTITY_CERT` / `_KEY` to the mounted paths in
  `.env`. The path form avoids embedding multi-line PEM in the env file.
- **chmod the files `0644`** in the generator: `openssl genrsa` writes `0600
  root`, but Fleet runs non-root (uid 100) and the read-only bind mount preserves
  the host mode, so Fleet crashes with `permission denied` on the key otherwise.
  Perms are not the secret boundary here (single-user host, gitignored, mounted
  read-only) — *not committing* is.
- Flip the feature on with a config API PATCH (what the UI toggle does):
  `PATCH /api/latest/fleet/config {"mdm":{"windows_enabled_and_configured":true}}`.

## Consequences

**Positive**
- Windows MDM is on at $0 (`windows_enabled_and_configured: true` verified). A
  Windows client that installs fleetd auto-triggers programmatic MDM enrollment
  (orbit → Fleet's MS-MDE2 discovery) — no manual "Access work or school" step.
- WSTEP CA is regenerable from Git (`new-wstep-ca.ps1`); the compose/env wiring
  is committed.

**Negative / follow-ups**
- The **enable toggle is imperative** (API PATCH) and lives in the DB, so a
  `down -v` wipes it. **Phase 3 moves it into GitOps** (`org_settings.mdm.
  windows_enabled_and_configured: true`) so it's declarative and survives cold
  rebuilds.
- The client must **also** trust the mkcert root in `LocalMachine\Root`
  (separate from the CA baked into the fleetd MSI via `--fleet-certificate`);
  Windows' MDM stack validates TLS against the machine store (fleetdm/fleet#19539).
- Windows MDM completes **only in a signed-in interactive session**; a VM at the
  lock screen reports MDM "Off" until login.

## Alternatives considered

- **`_BYTES` (content) env form.** Rejected: multi-line PEM in a docker env file
  is fragile (line-ending/quoting hazards).
- **Reuse the mkcert CA as the WSTEP CA.** Rejected: different purpose (MDM
  identity signing vs HTTPS); Fleet treats them as distinct; mixing them couples
  unrelated trust chains.
- **Windows Autopilot / Entra zero-touch.** Premium — out of scope (constraint #1).
