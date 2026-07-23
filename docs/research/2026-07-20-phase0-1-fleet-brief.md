# FleetDM $0 Local Lab — Consolidated Implementation Brief (Phase 0/1)

> **Provenance:** Generated 2026-07-20 by an 8-agent live-docs research workflow
> (`fleet-docs-recon`) that swept fleetdm.com/docs, the fleet & fleet-gitops
> repos, and Docker Hub, then adversarially synthesized the findings. This is
> the reconciled ground truth the lab is built against. Fleet ships ~every 3
> weeks — **re-verify the pinned tag and any surprising schema before each phase.**

**Anchored to:** Fleet **v4.89.1** (stable, released 2026-07-16). `docs-v4.90.0` /
`docs-v4.91.0` on Docker Hub are docs-branch preview builds, **not** stable —
do not pin them.

---

## 1. Versions to pin

| Component | Pin | Notes |
|---|---|---|
| **Fleet server/UI** | `fleetdm/fleet:v4.89.1` | Image tag is `vX.Y.Z` — **drops the `fleet-` prefix** the GitHub release tag carries. Official compose leaves it unpinned (`:latest`) — always pin. |
| **fleetctl** | `4.89.x` (match server) | Version skew can reject GitOps YAML using newer keys. |
| **MySQL** | `mysql:8` | Requires **≥ 8.0.44**; tested on 8.0.44 / 8.4.8 / 9.5.0. **MySQL 9.6.0 is explicitly incompatible.** Single-writer only. |
| **Redis** | `redis:6` | What Fleet ships in its own lab compose (`--appendonly yes`). |
| **Caddy** | latest stable | Reverse proxy / TLS terminator. |
| **mkcert** | latest | Local CA + leaf, $0. |

No hard minimum sizing is documented for a single-node lab; budget ~4 GB RAM for
the full stack on WSL2. Sources: [reference-architectures](https://fleetdm.com/docs/deploy/reference-architectures),
[Docker Hub tags](https://hub.docker.com/r/fleetdm/fleet/tags), [releases](https://github.com/fleetdm/fleet/releases).

---

## 2. docker-compose topology (reconciled)

Canonical supported lab compose: **`docs/solutions/docker-compose/`** (`docker-compose.yml`
+ `env.example`), guide at [deploy-fleet-on-docker-compose](https://fleetdm.com/guides/deploy-fleet-on-docker-compose).

> **Trap:** the `docker-compose.yml` in the **repo root** is the Fleet *developer*
> environment (mailhog, saml_idp, localstack, …) — **NOT a deploy target.**

**Topology:** 4 services + 1 init sidecar:
`mysql:8 (healthcheck)` + `redis:6 (healthcheck)` + `fleet-init (one-shot chown)` → `fleet:v4.89.1` → `caddy (TLS term)`.

- **fleet-init** (`alpine:latest`, one-shot): `chown -R 100:101 /logs /data /vulndb`.
  **Do NOT skip** — Fleet runs non-root as uid 100/gid 101; omitting it reproduces
  the "unknown userid" startup failure (bug class fixed in 4.88.1).
- **Migration is baked into the fleet command** — no separate step:
  `sh -c "/usr/bin/fleet prepare db --no-prompt && /usr/bin/fleet serve"`.
  `depends_on` `service_healthy` (mysql, redis) + `service_completed_successfully`
  (fleet-init) prevents the startup race.

### Key env vars

| Var | Value / note |
|---|---|
| `FLEET_MYSQL_ADDRESS` | `mysql:3306` |
| `FLEET_REDIS_ADDRESS` | `redis:6379` |
| `FLEET_SERVER_ADDRESS` | `0.0.0.0:1337` (internal listener) |
| `FLEET_SERVER_URL` | **external HTTPS URL clients use** (the Caddy hostname) — MDM/enroll redirects and cert SANs must line up |
| `FLEET_SERVER_TLS` | `false` (Caddy owns TLS — simplest lab path) |
| `FLEET_SERVER_PRIVATE_KEY` | **required**, `openssl rand -base64 32`, ≥32 bytes. Encrypts MDM assets → **this is what enables MDM.** Save permanently; regenerating after MDM assets exist makes them undecryptable. |
| `FLEET_SERVER_WEBSOCKETS_ALLOW_UNSAFE_ORIGIN` | `true` — live-query in the web UI behind a proxy |
| `FLEET_SERVER_TRUSTED_PROXIES` | `127.0.0.1,::1` |
| `FLEET_LICENSE_KEY` | empty for Free |
| Logging | `FLEET_OSQUERY_STATUS_LOG_PLUGIN=filesystem`, `FLEET_FILESYSTEM_STATUS_LOG_FILE=/logs/osqueryd.status.log`, `FLEET_FILESYSTEM_RESULT_LOG_FILE=/logs/osqueryd.results.log` |
| Vuln | `FLEET_VULNERABILITIES_DATABASES_PATH=/vulndb` |

### TLS

`env.example` ships `FLEET_SERVER_TLS=true` + bind-mounts `./certs/fleet.crt`/`fleet.key`
read-only — **if those files are missing the fleet container fails to start.**
Lab path: **`FLEET_SERVER_TLS=false` + Caddy terminates TLS**, drop the cert mounts.

**Caddyfile** (mkcert leaf, transparent host-preserving proxy — passes osquery,
live-query WS, and Apple/Windows MDM+SCEP unchanged):
```
fleet.axiom.lab {
    tls /etc/caddy/fleet.axiom.lab+3.pem /etc/caddy/fleet.axiom.lab+3-key.pem
    reverse_proxy 127.0.0.1:1337
}
```

**mkcert flow** (include every hostname + LAN IP fleetd will use as SANs):
```
mkcert -install
mkcert -CAROOT            # location of rootCA.pem — the file to feed fleetd/VMs
mkcert fleet.axiom.lab 192.168.1.50 localhost 127.0.0.1
```
mkcert's root signs the leaf directly (no intermediate) → leaf-on-server +
rootCA.pem-on-client is a valid chain. Trust rootCA.pem on each VM
(`update-ca-certificates` on Linux; `Import-Certificate … Cert:\LocalMachine\Root`
on Windows). Sources: [certificates-in-fleetd](https://fleetdm.com/guides/certificates-in-fleetd), [mkcert](https://github.com/FiloSottile/mkcert).

---

## 3. Exact fleetctl commands

### GitOps
On **Fleet Free the token must be a GLOBAL ADMIN** — the dedicated "GitOps"
API-only role is Premium (a lesser role 403s).
```bash
export FLEET_URL="https://fleet.axiom.lab"
export FLEET_API_TOKEN="<global-admin-api-token>"
export FLEET_GLOBAL_ENROLL_SECRET="<random-secret>"
fleetctl gitops -f default.yml -f teams/no-team.yml --dry-run   # validate/preview
fleetctl gitops -f default.yml -f teams/no-team.yml             # apply
```
- **Declarative:** anything absent from the applied YAML is **deleted** on apply.
  **There is no `--delete-missing` flag** — deletion is automatic. (`--delete-other-teams`
  is Premium.)
- **Empty top-level key = "manage this section, delete everything in it."**
  **Omit** the key to leave a section unmanaged. Always `--dry-run` first.
- `lib/` `path:` refs are relative to the referencing file (`./lib/…` from
  `default.yml`, `../lib/…` from a team file).

### Package builds (with cert flags)
`fleetctl package` is still the current, primary build method. Required:
`--type`, `--fleet-url`, `--enroll-secret`.
```bash
# Linux .deb (no Docker needed):
fleetctl package --type deb --fleet-desktop \
  --fleet-url=https://fleet.axiom.lab \
  --enroll-secret=<ENROLL_SECRET> \
  --fleet-certificate="$(mkcert -CAROOT)/rootCA.pem"
# Windows .msi — requires Docker running:
fleetctl package --type msi --fleet-desktop --fleet-url=… --enroll-secret=… --fleet-certificate=C:\path\to\rootCA.pem
# macOS .pkg — notarize must run on macOS; ARM: add --arch=arm64
```
- **`--fleet-certificate` takes the CA (rootCA.pem), NOT the leaf.** The single
  most common local-lab failure: **osqueryd does not use the OS system CA store**,
  so even if the VM trusts your mkcert CA, osquery enrollment fails unless the CA
  is baked into the package. `--insecure` disables validation (dev only).
- **There is no `--fleet-tls` flag** (don't invent it). Diagnose with:
  `fleetctl debug connection --fleet-certificate ./rootCA.pem https://fleet.axiom.lab`
- Supported `--type`: `deb rpm msi pkg pkg.tar.zst`.

### Enroll secrets
- **Multiple enroll secrets ARE supported on Free** (declared globally under
  `org_settings.secrets`). But **secrets do NOT segment hosts on Free** — all
  land in the single global "No team" and no query exposes which secret was used
  ([#2290](https://github.com/fleetdm/fleet/issues/2290)). Routing a secret to a
  team is Premium.
- Sensitive values inside profiles/scripts use the `$FLEET_SECRET_*` prefix
  (encrypted server-side, injected at delivery). Plain `$VARS` = string substitution.

---

## 4. Free vs Premium — every capability the lab touches

Source of truth: [pricing-features-table.yml](https://github.com/fleetdm/fleet/blob/main/handbook/company/pricing-features-table.yml)
(authoritative over the marketing pricing page).

| Capability | Free? | $0 substitution |
|---|---|---|
| **Teams** (segmentation) | ❌ single global "No team" | separate Fleet instances per tier, or a flat scope |
| **Per-label policy scoping** (`labels_include_any/all/exclude_any`) | ❌ **silently ignored** on Free (runs on ALL hosts) | **platform field** (`darwin/windows/linux`); **self-scoping policy SQL**; label-targeted *queries* (free) |
| **Config-profile / software label scoping** | ❌ | profiles apply globally to all enrolled hosts |
| **Built-in CIS benchmark library** | ❌ (ships in `ee/`) | **hand-author CIS-aligned policy queries** (Phase 4 matrix) |
| **ADE / ABM / DEP zero-touch (Apple)** | ❌ | manual enroll (needs Apple hardware regardless) |
| **Windows auto-enroll (Entra/Autopilot)** | ❌ | **manual Windows MDM enroll — fully free & lab-exercisable** |
| **Conditional access / device trust (Entra/Okta)** | ❌ | none on Free — Phase 7 builds a custom FastAPI sketch instead |
| **Windows MDM (manual, profiles, commands)** | ✅ | full end-to-end at $0 |
| **Apple MDM (APNs, manual macOS/iOS enroll, profiles)** | ✅ (APNs cert free w/ Apple ID) | server-side free; enroll needs real Apple hardware |
| **Android MDM (work-profile BYOD + fully-managed, Wipe)** | ✅ **GA** | full BYOD + fully-managed at $0 (see §5) |
| **Script execution** (saved scripts, `run-script`, REST API) | ✅ | full — **Phase 8 auto-remediation works at $0** |
| **Vulnerability / CVE detection** | ✅ | free gets CVE IDs on software inventory |
| **Vuln scores** (CVSS/EPSS/KEV) | ❌ | free = CVEs **without** scores — don't route SOAR severity on these |
| **Disk-encryption ENFORCEMENT + escrow** (FileVault/BitLocker/LUKS) | ❌ | can push profiles globally + **detect** encryption via osquery policy, but not enforce/escrow |
| **OS-update / min-version enforcement** | ❌ | detection-only policy (is-up-to-date query); no enforced remediation |
| **Software deployment** | ❌ | inventory visibility is free; deployment is not |
| **Failing-policy webhooks / automations** | ✅ | full SOAR-lite support |
| **Labels** (dynamic/manual/host-vitals) | ✅ (global) | grouping + query targeting — **NOT** policy scoping |
| **GitOps, fleetctl, REST API, webhooks, SAML SSO** | ✅ | drive the whole lab as-code (global-admin token) |
| **Prometheus `/metrics`, filesystem osquery logs, `/healthz`** | ✅ | full observability plumbing — but `/metrics` is auth-gated by default (see §6) |

---

## 5. Android MDM verdict

**GA ("first-class citizen"), built on Google's Android Management API.** Not beta.
([android-mdm-setup](https://fleetdm.com/guides/android-mdm-setup))
- **Free:** connect Android Enterprise via a **free** subscription (Google Workspace
  super-admin, Microsoft 365, or **any work email**). Work-profile BYOD + fully-managed
  enrollment via QR/link. **Wipe** (company-owned) free as of 4.87.
- **Premium:** `Lock` and `Clear passcode` only.
- **Requirements:** devices must be **Play Protect certified**. Use a Google-Play-enabled
  Android Studio AVD (not AOSP) or a real device. Work-profile BYOD is the easiest $0 path.

**Fallback (Headwind MDM): NOT needed / rejected.** Fleet's native Android MDM is GA,
free for the core path, and end-to-end exercisable at $0. Adopting Headwind would
fragment the single pane of glass for no benefit.

---

## 6. Contradictions + training-data deltas

**Contradictions resolved**
1. Custom OS settings at "No team" = **Free** (handbook YAML authoritative); label-scoping of those profiles is Premium. Verify in-product (rated medium confidence).
2. Disk-encryption + OS-update enforcement = **Premium** (an earlier automated pricing-table read wrongly showed Free). Don't trust the marketing pricing page.
3. **The "team emulation via labels + enroll secrets" premise is refuted** — per-policy label scoping is Premium & silently ignored on Free; enroll secrets don't segment. *Single most important planning correction* → see [ADR-0003](../adr/0003-free-tier-trust-tiering.md).
4. Policy-webhook payload has **two coexisting shapes** in docs (classic `timestamp/policy/hosts` vs per-host `host_id/failing_policies[]`). **Curl-test what v4.89.1 actually emits** before wiring the receiver.

**Training-data deltas (what a 2024/2025 assistant gets wrong)**
- Latest stable is **4.89.1**, not ~4.4x–4.5x. MySQL floor jumped to **≥ 8.0.44** (9.6.0 incompatible).
- Canonical self-host compose moved to `docs/solutions/docker-compose/` (not repo-root dev compose, not `fleetctl preview`).
- `fleet-init` chown-to-100:101 sidecar is new & required. `FLEET_SERVER_PRIVATE_KEY` now first-class required.
- `fleetctl gitops` (declarative whole-file apply w/ automatic deletion) replaced `fleetctl apply -f`. Correct cert flag is **`--fleet-certificate`** — no `--fleet-tls`.
- **osqueryd ignores the OS system CA store** (orbit + Fleet Desktop use it; osqueryd doesn't).
- Android MDM is **GA**; BYOD/personal Apple MDM enroll landed in **4.88.0**.
- TUF update URL moved to `https://updates.fleetdm.com` (was `tuf.fleetctl.com`).
- **"Teams" → "Fleets" rebrand** underway in UI/docs; stable starter repo still uses `teams/` + `team_settings`.
- `lib/` is **platform-partitioned** (`lib/all|macos|ios|ipados|linux|windows`), not flat.
- **Prometheus `/metrics` is DISABLED by default** — needs `FLEET_PROMETHEUS_BASIC_AUTH_DISABLE=true` or basic-auth creds.
- osquery packs removed from the UI (API-only back-compat); scheduled queries (free, label-targetable) replace them.

---

## 7. Verify in-product during implementation

1. Config-profile "No team" = Free (medium confidence) — confirm no Premium banner blocks saving a custom OS setting.
2. Policy-webhook payload format your v4.89.1 build emits (curl-test before Phase 8).
3. Exact `FLEET_*` env-var names against the **v4.89.1 tag**, not `main`.
4. `redis:6` vs `redis:7` — lab ships 6; confirm clean boot.
5. Windows WSTEP `_BYTES` vars take file **content**; drop `_BYTES` for a **path**. Easy to mis-swap → cryptic MDM turn-on failure.
6. Play-Protect-certified Android AVD (Google-Play image, not AOSP) before assuming BYOD enroll works.
7. `platform: linux/x86_64` pin — confirm images pull under WSL2.
8. `--local-wix-dir` (local WiX MSI build) may be Premium-gated — verify before relying on it if you lack Docker for `.msi`.
9. Live-query WebSocket through Caddy — a passing agent doesn't prove the UI path; confirm live query returns results in the UI.
10. **4.90/4.91 drift** — re-check [releases](https://github.com/fleetdm/fleet/releases) + "Upgrading" notes before pinning a newer tag.
