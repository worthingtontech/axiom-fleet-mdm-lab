# Project AXIOM — Phase-by-Phase Status

**Scenario:** device-management platform for *Axiom Intelligence*, a fictional frontier-AI company (tiered trust zones, model-weights protection, compliance-as-code) built as a **local, $0, fully-from-Git-rebuildable** FleetDM MDM / GitOps / policy-as-code lab.

| | |
|---|---|
| **Fleet** | v4.89.1 **Free**, self-hosted (Docker: Fleet + MySQL 8 + Redis 6 + Caddy, mkcert TLS) |
| **Repo** | `github.com/worthingtontech/axiom-fleet-mdm-lab` — personal account, Apache-2.0, currently **private** |
| **Reviewed** | 2026-07-22 |
| **Source of truth** | This document is the reviewer-facing rollup. The live engineering journal is [`../LAB_STATE.md`](../LAB_STATE.md); every architecture choice is an ADR under [`adr/`](adr/). |

> **How to read the status column.** *Done* = every acceptance check in [the origin prompt](origin-prompt.md) passed with real output pasted into `LAB_STATE.md`. *Partial* = the core is built and proven but at least one acceptance sub-item is genuinely open. *Pending* = not started (no directory / no artifacts). *Blocked* = built but cannot be exercised until an operator/hardware dependency clears.
>
> The launching brief rounds to "Phases 0–5 done." That is accurate for **0, 1, 4, 5**; Phases **2 and 3** are ~90 % complete and honestly carried as **Partial** here (and unchecked in `LAB_STATE.md`), because each has one open acceptance item — the Windows client enroll last-mile, and the live apply/drift halves that need the self-hosted runner.

---

## Summary table

| Phase | Name | Status | One-line state |
|---|---|---|---|
| **0** | Recon & plan | 🟢 **Done** | Host inventory + topology + 4 ADRs; operator-approved 2026-07-21 |
| **1** | Fleet core | 🟢 **Done** | Compose stack + Caddy/mkcert TLS; all 3 acceptance checks pass; `down -v && up` rebuilds |
| **2** | Enroll the fleet | 🟡 **Partial** | Linux zero-touch proven (3 hosts); Windows MDM enabled server-side but client enroll last-mile blocked |
| **3** | GitOps & CI/CD | 🟡 **Partial** | PR-gate CI proven live (PR #1); apply/drift workflows committed but **inert** (no runner) |
| **4** | Policy-as-code | 🟢 **Done** | 22 inline + 1 lib = 23 CIS/MITRE policies; break→red→fix→green proven live |
| **5** | Telemetry | 🟢 **Done** | Vector→Loki, Prometheus, custom fleet-exporter, 3 Grafana dashboards-as-code; kill-agent proven |
| **6** | Zero-touch provisioning | 🟡 **Partial** | Linux half proven end-to-end; Windows authored-only (enroll blocked); macOS/Android missing |
| **7** | Identity-driven access | ⚪ **Pending** | No `identity/`; SSO block is empty Fleet scaffold; reference material only |
| **8** | Security automation & drills | ⚪ **Pending** | No `automation/` SOAR-lite; webhook authored-but-disabled; 0 of 3 IR drills |
| **9** | Portfolio hardening | ⚪ **Pending** | No root `README.md`; no interview-map; no demo script |

**Committed through:** git log head `182b63d`. Commits exist for Phases 0–5 (plus the beyond-spec progressive-rollout / remediation work). **No commits exist for Phases 6–9.**

---

## Phase 0 — Recon & plan · 🟢 Done

**Acceptance:** *`LAB_STATE.md` exists with the topology table and operator has approved it.*

**Complete (evidence):**
- Host inventory table + operator decisions in [`../LAB_STATE.md`](../LAB_STATE.md) (measured 2026-07-20).
- Four foundational ADRs: [ADR-0001 topology](adr/0001-right-sized-topology.md), [ADR-0002 VM backend](adr/0002-vm-backend-virtualbox-cloudinit.md), [ADR-0003 free-tier trust-tiering](adr/0003-free-tier-trust-tiering.md), [ADR-0004 TLS & lab DNS](adr/0004-tls-termination-and-lab-dns.md).
- Research brief [`research/2026-07-20-phase0-1-fleet-brief.md`](research/2026-07-20-phase0-1-fleet-brief.md); 11-file learning [`encyclopedia/`](encyclopedia/).
- Acceptance gate: topology **APPROVED 2026-07-21** (recorded in `LAB_STATE.md`).

**Hold-ups:** None.

**Pending:** None. (Housekeeping only: ADR-0001 and ADR-0002 status fields still read *Proposed* though the topology is approved and the backend is in active use — should be flipped to *Accepted*.)

---

## Phase 1 — Fleet core · 🟢 Done

**Acceptance:** *`fleetctl` authenticates over HTTPS; `docker compose down -v && up` restores a loginable server; the mkcert root-CA install step for VMs is scripted.*

**Complete (evidence):**
- [`../infra/docker-compose.yml`](../infra/docker-compose.yml) (`axiom-core`): Caddy is the only LAN-facing service (:443 TLS, :80→443 redirect) reverse-proxying `fleet:1337`; Fleet + MySQL 8 + Redis 6 + a one-shot `fleet-init` chown sidecar; bridge subnet pinned `172.28.0.0/16` = `FLEET_SERVER_TRUSTED_PROXIES`.
- TLS/PKI: [`../infra/caddy/Caddyfile`](../infra/caddy/Caddyfile), [`../infra/tls/make-certs.ps1`](../infra/tls/make-certs.ps1), [`install-ca-linux.sh`](../infra/tls/install-ca-linux.sh), [`install-ca-windows.ps1`](../infra/tls/install-ca-windows.ps1). Load-bearing hostname is **`fleet.axiom.lab`**.
- Secret bootstrap: [`../infra/scripts/new-env.ps1`](../infra/scripts/new-env.ps1) + tracked `secrets.example.env`; real `.env` gitignored.
- All 3 acceptance checks pasted with real output in `LAB_STATE.md`: (1) `fleetctl` auth over a validated HTTPS chain with no `--insecure`, (2) `docker compose down -v && up` rebuilds a loginable server, (3) CA install scripted. Committed `b0c220a` / `2e13642`.

**Hold-ups:** None for the running lab.

**Pending:** One from-git bootstrap gap (does **not** affect the running lab): `new-env.ps1` auto-generates only 3 of the 6 `__GENERATE_*__` secret placeholders in `secrets.example.env`, leaving `GRAFANA_ADMIN_PASSWORD`, `FLEET_PROMETHEUS_BASIC_AUTH_PASSWORD`, and `FLEET_EXPORTER_PASSWORD` as literal placeholder strings with no operator warning. Predictable non-random telemetry-layer secrets on a fresh clone — fix before public.

---

## Phase 2 — Enroll the fleet · 🟡 Partial

**Acceptance:** *All planned hosts green in Fleet UI, MDM "On" where applicable, screenshot + `fleetctl get hosts` in `LAB_STATE.md`, Enclave VM carries its distinct label via its own enroll secret.*

**Complete (evidence):**
- `fleetd` `.deb`/`.msi` built via [`../provisioning/build-packages.ps1`](../provisioning/build-packages.ps1) (output gitignored; carries the enroll secret). Trust is carried by the mkcert root CA **baked into the package** (`fleetctl package --fleet-certificate rootCA.pem`) because osqueryd ignores the OS trust store.
- **gpu-node-1** enrolled online, zero-touch (`fleetctl get hosts` output in `LAB_STATE.md`).
- **enclave-01** (host id=4) enrolled **and** free-tier trust-tiering **PROVEN** via a dynamic label matching the `/etc/axiom/tier.d/elevated` sentinel ([ADR-0003](adr/0003-free-tier-trust-tiering.md); [`../provisioning/linux/labels/high-trust-enclave.label.yaml`](../provisioning/linux/labels/high-trust-enclave.label.yaml)).
- **canary-01** (host id=5) enrolled after a hard reset (see hold-up a).
- Windows MDM enabled **server-side**: `windows_enabled_and_configured: true` ([`../gitops/default.yml`](../gitops/default.yml); [ADR-0005](adr/0005-windows-mdm-enablement.md); WSTEP identity CA under `infra/mdm/`, gitignored).

**Hold-ups:**
- **(a)** Windows client **corp-win-01** installs + AutoLogons fine, but the osquery/MDM enroll last-mile never completed. Root cause is the **NEM (Hyper-V-coexistence) soft-lockup** that wedges `orbit` (unkillable, 1h+ CPU) — **not NAT** (proven: `curl` with the baked CA reached Fleet in ~15 ms from the guest). Documented as an operational finding in [ADR-0002](adr/0002-vm-backend-virtualbox-cloudinit.md). Mitigation = hard reset clears the wedge (that is how canary-01 enrolled).
- Android AVD never enrolled — blocked on an operator-provided throwaway Google account.

**Pending:**
- Windows client green in UI (blocked by hold-up a); Android AVD enroll; gpu-node-2 + ml-workstation not yet enrolled.
- No Fleet **UI screenshot** captured in `LAB_STATE.md` (only `fleetctl` text output) — required for the acceptance and for the Phase 9 portfolio.

---

## Phase 3 — GitOps & CI/CD · 🟡 Partial

**Acceptance:** *A PR shows all gates; a broken profile fails CI; **merge applies within one run**; a **nightly drift-detection job** flags UI-made changes.*

**Complete (evidence):**
- GitOps tree ([`../gitops/default.yml`](../gitops/default.yml), `gitops/fleets/`, `gitops/lib/`) drives the live server; `fleetctl gitops --dry-run` and apply both exit 0. Wrapper [`../gitops.sh`](../gitops.sh) pins fleetctl 4.89.1.
- **PR-gate CI PROVEN live on GitHub-hosted ephemeral Fleet** — [`../.github/workflows/pr-ci.yml`](../.github/workflows/pr-ci.yml): 4 jobs (yamllint+actionlint / profile plist+json+xml validation / osquery-SQL compile-check against real `osqueryi` / full `gitops --dry-run` vs a throwaway Fleet v4.89.1 + MySQL/Redis service containers). Both halves proven: a valid change goes all-green and a deliberately broken `.mobileconfig` fails CI (**PR #1, merged `f9b1e77`**).
- Secret scanning: [`../.github/workflows/gitleaks.yml`](../.github/workflows/gitleaks.yml) green. Architecture in [ADR-0006](adr/0006-gitops-cicd-architecture.md), [ADR-0007 self-hosted runner security](adr/0007-self-hosted-runner-security.md); operator runbook [`../runbooks/ci-cd-setup.md`](../runbooks/ci-cd-setup.md).

**Hold-ups:**
- **(b)** [`../.github/workflows/apply.yml`](../.github/workflows/apply.yml) and [`../.github/workflows/drift-detection.yml`](../.github/workflows/drift-detection.yml) are committed but **INERT** — both pinned to `runs-on: [self-hosted, …, fleet-apply]` and **no self-hosted runner is registered**. The apply-on-merge and nightly-drift halves have therefore never run live. This is the single gate on the entire write path.

**Pending:**
- Register the LAN self-hosted runner + provision its secrets (`FLEET_URL`, `FLEET_API_TOKEN`, `FLEET_GLOBAL_ENROLL_SECRET`, the `production` environment).
- **Drift false-positive risk (untested):** `default.yml` carries two deliberate non-generator-shaped hand-edits (`windows_enabled_and_configured: true` and the canary policy pulled by `- path:`) that `drift-detection.yml`'s normalize step does not reconcile — the first real nightly run will likely report spurious DRIFT. Reconcile before trusting the diff.
- `gitops/fleets/unassigned.yml` is an empty placeholder; its comment promising ≥15 policies was never fulfilled (the 22 live in global scope in `default.yml` instead — fine on Free, but the comment is stale).

---

## Phase 4 — Policy-as-code · 🟢 Done

**Acceptance:** *Compliance matrix complete; breaking a control on a live VM flips the policy red within one osquery interval; fixing it flips green.*

**Complete (evidence):**
- **23 graded controls** in [`../gitops/default.yml`](../gitops/default.yml): 22 inline (10 Linux, 6 macOS, 6 Windows) + 1 pulled by reference ([`../gitops/lib/linux/policies/canary-auditd.yml`](../gitops/lib/linux/policies/canary-auditd.yml)). Each carries `description` / `resolution` / `critical:` and CIS+MITRE mappings.
- [`compliance-matrix.md`](compliance-matrix.md) (CIS/MITRE map) + [`test-plans.md`](test-plans.md) (per-policy break/fix). [ADR-0008](adr/0008-osquery-table-detection-choices.md) documents the osquery-table detection re-authoring (augeas ships no lenses on 24.04, `iptables` empty under nftables, `suid_bin` directory-scoped to dodge usrmerge alias double-counting).
- Acceptance **PROVEN live** on enclave-01: break→red→fix→green with concrete sha256/commands for #8 FIM canary, #2 firewall, #3 root-locked, #7 SUID (recorded in `LAB_STATE.md`); 9/10 Linux green with #1 LUKS a documented genuine fail. Committed `9ac5498` / `b044587`.

**Hold-ups:**
- macOS/Windows policies (12 of 22) are **authored-only** — platform-pinned and never executed against a real host (no Apple HW; Windows client enroll blocked).

**Pending:**
- Doc staleness: `compliance-matrix.md` and `test-plans.md` are pinned at "22 policies"; the live tree is 23 (the `canary-auditd` progressive-rollout policy is not in either doc). Add it or note the intentional exclusion.

---

## Phase 5 — Telemetry · 🟢 Done

**Acceptance:** *Dashboards render from a clean `docker compose up`; killing an agent shows on fleet-health within minutes.*

**Complete (evidence):**
- Full add-on stack [`../infra/telemetry/docker-compose.yml`](../infra/telemetry/docker-compose.yml) (`axiom-telemetry`, joins `axiom-core` network + mounts `fleet-logs` read-only so Phases 1–4 are untouched): [Vector](../infra/telemetry/vector/vector.yaml) tails osquery logs → [Loki](../infra/telemetry/loki/loki-config.yml) (7-day retention); Fleet `/metrics` + custom exporter → [Prometheus](../infra/telemetry/prometheus/prometheus.yml).
- **Custom fleet-exporter** [`../infra/telemetry/exporter/exporter.py`](../infra/telemetry/exporter/exporter.py): stdlib-only api-only observer polling the Fleet REST API every 30 s; emits the `axiom_*` metric namespace (`axiom_hosts_online`, `axiom_policy_failing_hosts{policy,critical}`, `axiom_label_hosts{label}`, …) that powers the compliance/enclave dashboards **and** the ADR-0009 promote gate.
- **3 Grafana dashboards-as-code** provisioned from Git: [`fleet-health.json`](../infra/telemetry/grafana/dashboards/fleet-health.json), [`compliance.json`](../infra/telemetry/grafana/dashboards/compliance.json), [`enclave-fim.json`](../infra/telemetry/grafana/dashboards/enclave-fim.json).
- 3 scheduled queries in `default.yml` (`reports:` key — Fleet renamed `queries`→`reports`): `axiom-heartbeat` (60 s), `axiom-enclave-canary-hash` (300 s), `axiom-listening-ports` (300 s).
- Acceptance **PROVEN** (in `LAB_STATE.md`): kill `orbit` on enclave-01 → Loki heartbeats 2→0 and exporter `axiom_hosts_online` 1→0 within ~2 min; dashboards render from a clean compose up. Committed `542ebe9`.

**Hold-ups:** None. (Free-tier note: Fleet Free does not persist the per-policy `critical` flag, so `axiom_critical_policy_failing_hosts` stays 0 and the compliance panel sums all failing checks — documented in the dashboard.)

**Pending:** Minor doc/comment fixes only (exporter docstring omits two emitted metrics; a stale metric-name comment in `prometheus.yml`).

---

## Phase 6 — Zero-touch provisioning · 🟡 Partial

**Acceptance:** *Destroying and re-creating a Linux **and** a Windows VM lands both enrolled and policy-evaluated with zero interactive steps after boot.*

**Complete (evidence):**
- **Linux half — DONE + proven** (lands under Phase 2 too): [`../provisioning/linux/new-linux-vm.ps1`](../provisioning/linux/new-linux-vm.ps1) + cloud-init [`user-data.standard.yaml`](../provisioning/linux/cloud-init/user-data.standard.yaml) / [`user-data.elevated.yaml`](../provisioning/linux/cloud-init/user-data.elevated.yaml) enroll fleetd on first boot (NoCloud seed ISO with the `.deb` baked on, retries, hosts entry to the NAT gateway, label/tier assignment). gpu-node-1, enclave-01, and canary-01 all landed zero-touch. Base image built one-time by [`build-base-vdi.ps1`](../provisioning/linux/build-base-vdi.ps1).
- **Windows half — AUTHORED-ONLY:** [`../provisioning/windows/new-windows-vm.ps1`](../provisioning/windows/new-windows-vm.ps1) + [`first-logon.ps1`](../provisioning/windows/first-logon.ps1) + [`autounattend.xml`](../provisioning/windows/autounattend.xml) + runbook [`../runbooks/enroll-windows.md`](../runbooks/enroll-windows.md) exist and install + AutoLogon work.

**Hold-ups:**
- Windows acceptance ("re-create a Windows VM → enrolled, zero interactive steps") is **UNPROVEN** — same NEM soft-lockup last-mile as Phase 2 hold-up (a). The scripts' guidance text presents MDM enroll as working and currently overstates the observed state.

**Pending:**
- **macOS** ADE/ABM runbook — **missing entirely** (no files; only conceptual mentions in ADRs/encyclopedia).
- **Android** work-profile enrollment doc/script — **missing entirely**.
- Doc bug worth fixing before public: `provisioning/README.md` + `new-linux-vm.ps1` synopsis claim a `__ROOTCA_PEM__` / `ca_certs` OS-wide trust block that the templates do **not** contain (approach was abandoned); the `-RootCaPath` parameter is validated but dead. Linux nodes get osqueryd-only CA trust, not OS-level.

---

## Phase 7 — Identity-driven access · ⚪ Pending

**Acceptance:** *Fleet login via Keycloak works; a device-trust demo app denies a session from a non-compliant device and allows it after remediation.*

**Status:** Not started. **Zero acceptance criteria met.**
- No `identity/` directory exists. No Keycloak compose, no realm-as-JSON, no device-trust FastAPI app.
- The `sso_settings:` block in [`../gitops/default.yml`](../gitops/default.yml) is Fleet's **empty generated scaffold** (`enable_sso: false`, blank entity_id/metadata/sso_server_url) — a placeholder, not configured SSO.
- Only reference material exists: [`encyclopedia/09-identity-and-access.md`](encyclopedia/09-identity-and-access.md).

**Hold-ups:** None external — this is simply unstarted work.

**Pending:** Everything — Keycloak realm export, Fleet SAML SSO, SSO-only admin enforcement, the FastAPI device-trust demo, and the ADR on how Premium/beta Entra/Okta conditional access differs.

---

## Phase 8 — Security automation & drills · ⚪ Pending

**Acceptance:** *Policy-failure webhooks → receiver → auto-remediation/ticketing; three scripted IR drills (lost/stolen → lock/wipe, FIM-canary → NIC-isolate, CVE → inventory+fix) each with a runbook, real command output, and an MTTR number.*

**Status:** Not started as specified. **Zero acceptance criteria met.**
- No `automation/` directory and no SOAR-lite webhook receiver. `webhook_settings.failing_policies_webhook` in `default.yml` is authored but **disabled** (`enable: false`, blank destination).
- The three required IR drills have no runbooks (`runbooks/` holds only `ci-cd-setup.md` + `enroll-windows.md`) and no MTTR numbers.

**Adjacent capability that exists but is *not* Phase 8 credit:** [`../gitops/remediate/claude-remediate.ps1`](../gitops/remediate/claude-remediate.ps1) + [`../.github/workflows/claude-remediate.yml`](../.github/workflows/claude-remediate.yml) deliver Claude-in-the-loop PR-drafting remediation (worked example [`../gitops/remediate/drafts/example-enclave-aide.md`](../gitops/remediate/drafts/example-enclave-aide.md)). Real and useful, but it is neither the SOAR-lite receiver nor the drills. See *Cross-cutting capabilities*.

**Hold-ups:** The `claude-remediate` workflow is inert (needs the self-hosted runner + `ANTHROPIC_API_KEY`, hold-up b) and never installs the `claude` CLI (assumes a pre-provisioned runner).

**Pending:** The SOAR-lite receiver, the three drills with real timelines/MTTR, and wiring the failing-policies webhook to it.

---

## Phase 9 — Portfolio hardening · ⚪ Pending

**Acceptance:** *Operator can demo the whole lab cold, from clone, following only the README.*

**Status:** Not started. **Zero acceptance criteria met.**
- **No root `README.md` exists** — GitHub would render the landing page as a bare file list. This is the #1 blocker to making the repo public and the explicit unmet acceptance.
- No `docs/interview-map.md` (STAR / JD mapping). No top-level architecture diagram (mermaid lives only inside `encyclopedia/*.md`). No 15-minute demo script.

**Hold-ups:** None external.

**Pending (portfolio pre-flight, from the public-readiness audit):**
- Write the root README as the lead artifact (scenario, architecture diagram, honest PROVEN/AUTHORED/DEFERRED scope table, quickstart, skills-to-JD map, screenshots, doc links; frame `LAB_STATE.md` as the internal journal).
- Fix 4 broken internal markdown links to real filenames (`LAB_STATE.md` ×2, `adr/0009` ×1, the research brief ×1).
- ~~Resolve the top-level origin prompt~~ — ✅ done 2026-07-23: moved to [`docs/origin-prompt.md`](origin-prompt.md), personal path scrubbed, reframed as an appendix.
- Scrub/parameterize personal absolute paths in 6 tracked provisioning/runbook files.
- Neutralize the 3 inert scheduled workflows (comment out `schedule:` or add an owner guard) so the public Actions tab stays clean; keep `pr-ci.yml` + `gitleaks.yml` active.
- Reconcile doc-staleness nits (`enclave` vs `high-trust-enclave` label; 22 vs 23 policies; 5 GB vs 6 GB Windows RAM; `LAB_STATE` "Running now").

---

## Cross-cutting capabilities

These span multiple phases. The progressive-rollout and remediation work is **beyond the master-prompt spec** — it is real and proven live, and it strengthens the Phase 4/5 story, but it does **not** advance the pending Phases 6–9.

### Progressive rollout (canary → prod, telemetry-gated) — PROVEN LIVE
[ADR-0009](adr/0009-canary-progressive-rollout.md). A `canary` cohort (dynamic label keyed on `/etc/axiom/canary`) receives a control first; [`../gitops/promote/promote.ps1`](../gitops/promote/promote.ps1) runs a **3-check Prometheus gate** — `axiom_exporter_up == 1`, `axiom_label_hosts{label="canary"} >= 1`, and `max_over_time(axiom_policy_failing_hosts[soak]) == 0` — exiting 0 = promote / 1 = hold / 2 = error, and on promote rewrites the policy `query:` from the canary-scoped form to the fleet-wide form. Wrapped by [`../.github/workflows/promote.yml`](../.github/workflows/promote.yml). **Proven end-to-end on canary-01 (id=5):** fail → gate **HOLD** → `run-script` remediation ([`../gitops/lib/linux/scripts/install-auditd.sh`](../gitops/lib/linux/scripts/install-auditd.sh)) → pass → gate **PROMOTE** → **PR #2 (green)**, including the empty-cohort HOLD guard and two bugs fixed (`0da6d8b`). Clever free-tier design: canary self-scoping makes the global failing-hosts gauge equal the canary failing count, so the gate reads it directly.

### Telemetry — PROVEN LIVE
Covered under Phase 5. The load-bearing detail for the rest of the lab: the **custom `axiom_*` exporter** is the shared substrate for the compliance dashboards *and* the promotion gate. `axiom_label_hosts{label}` is the exact input to promote-gate check #2.

### Claude-in-the-loop remediation — BUILT, workflow inert
[`../gitops/remediate/claude-remediate.ps1`](../gitops/remediate/claude-remediate.ps1) pulls failing policies from the Fleet API, hands each to a headless `claude -p` with a grounded brief, writes a draft under `gitops/remediate/drafts/`, and (with `-OpenPr`) opens a single PR. Committed with a worked example. The GitHub side ([`../.github/workflows/claude-remediate.yml`](../.github/workflows/claude-remediate.yml)) is **inert** until the self-hosted runner + `ANTHROPIC_API_KEY` land, and the workflow assumes the `claude` CLI is pre-installed on the runner (latent prerequisite).

### Security hygiene — CLEAN
- **gitleaks v8.30.1 full-history scan = 0 leaks.** [`../SECURITY.md`](../SECURITY.md) documents the `.gitignore` / gitleaks / per-commit-guard model.
- **Nothing sensitive is tracked.** `git ls-files` shows only safe files (`secrets.example.env`, install-CA scripts, `new-wstep-ca.ps1`); `git check-ignore` confirms `infra/.env`, `infra/tls/rootCA.pem`, the WSTEP `.key`, and `provisioning/build/` are ignored. Real `.env`/keys/certs/build-output live locally, regenerated per host, never committed.
- **Two CAs correctly separated & both gitignored:** the mkcert TLS root (guards the osqueryd telemetry/enroll channel; baked into fleetd packages) vs the Windows MDM WSTEP identity CA (signs the device identity cert gating privileged OMA-DM/CSP writes).
- **Enroll secret + all passwords never in Git.** *Nuance for the public flip:* throwaway lab-default console/AutoLogon passwords (`axiom`, `P@ssw0rd!23`) **are** committed as documented lab-only defaults — worth a one-line SECURITY.md callout so a reviewer knows they aren't real credentials.

---

## Known hold-ups & blockers

| # | Blocker | Blast radius | Mitigation / status |
|---|---|---|---|
| **a** | **NEM soft-lockup on Windows** (Hyper-V coexistence) wedges `orbit` (unkillable, 1h+ CPU) during the canary/MDM enroll last-mile — **not NAT** (proven: curl w/ baked CA hit Fleet in ~15 ms from guest). | Phase 2 Windows-client green; Phase 6 Windows acceptance. | **Hard reset clears the wedge** — that is how canary-01 enrolled after reset. Documented as an operational finding in [ADR-0002](adr/0002-vm-backend-virtualbox-cloudinit.md). |
| **b** | **Blocked on operator** — (1) self-hosted GitHub runner not registered (all 4 LAN workflows `apply` / `drift-detection` / `promote` / `claude-remediate` are `[self-hosted, fleet-apply]` and inert); (2) `ANTHROPIC_API_KEY` secret for claude-remediate; (3) Android throwaway Google account for the AVD. | Phase 3 apply+drift halves; the promote & remediate loops; Phase 2 Android; part of Phase 8. | Register runner + provision secrets. This is the single gate on the entire write path and the automation loops going live. |
| **c** | **macOS/iOS deferred** — no Apple hardware in VirtualBox (Mac Studio planned later). | 12 of 23 policies (6 macOS + 6 Windows) are platform-pinned/authored-only; whole `gitops/lib/macos/` tree is empty scaffold; Phase 6 macOS runbook. | Authored + CI-validated per the prompt's "simulated, never faked" rule; execution awaits Apple HW. |
| **d** | **Fleet Free ceiling** — teams, per-label policy scoping, config-profile *delivery*, and per-policy `critical`-flag persistence are Premium. | Caps what can be *proven*; Windows `patch-deadline.xml` CSP delivery wired commented-out; GitOps team-scoped `scripts:` delivered manually via run-script API. | Worked around with self-scoping policy SQL ([ADR-0003](adr/0003-free-tier-trust-tiering.md) / [ADR-0009](adr/0009-canary-progressive-rollout.md)) and manual run-script. Documented, intentional. |
| **e** | **NEM concurrency ceiling** — under Hyper-V coexistence only ~1 VM boots at a time (a second concurrent boot froze in initramfs). | Limits any "whole fleet green at once" demo; the fleet runs serially. | Operate hosts serially; note in the Phase 9 demo script. |

**Reconciliation note (claimed vs verified):** the launching brief says "DONE + committed: Phases 0–5," while `LAB_STATE.md` honestly leaves Phase 2 and Phase 3 **unchecked**. Both readings are correct — **0, 1, 4, 5 are truly done**; **2 and 3 are ~90 %** with one genuinely open acceptance item each (Windows client enroll; live apply/drift needing the runner). This document carries them as **Partial** to avoid overclaiming.
