# LAB_STATE — Project AXIOM (FleetDM DevSecOps Lab)

> Single source of truth for **what's running, what phase we're in, and how to
> resume**. Updated at every phase boundary. If the Fleet server dies, the
> "Resume from cold" section + Git restores everything.

---

## Current status

| | |
|---|---|
| **Phase** | **0 — Recon & plan** (awaiting operator approval of topology) |
| **Date** | 2026-07-20 |
| **Next gate** | Operator approves the topology below → begin Phase 1 (Fleet core) |
| **Live docs research** | ✅ Complete (8 agents, 0 errors). Anchored to **Fleet v4.89.1** (2026-07-16). Full brief: [docs/research/2026-07-20-phase0-1-fleet-brief.md](docs/research/2026-07-20-phase0-1-fleet-brief.md) |
| **Git** | Initialized (`main`), identity `Aaron W`. No remote yet (private GitHub repo to be added; needed for Mac Studio onboarding). |

### Phase checklist

- [ ] **Phase 0** — Recon & plan _(in progress — this doc + ADRs exist; needs approval)_
- [ ] **Phase 1** — Fleet core (Compose: Fleet + MySQL + Redis + Caddy + mkcert TLS)
- [ ] **Phase 2** — Enroll the fleet (fleetd packages, Linux VMs, Windows osquery+MDM, Android)
- [ ] **Phase 3** — GitOps & CI/CD (fleet-gitops layout, GH Actions gates, self-hosted runner, drift job)
- [ ] **Phase 4** — Policy-as-code (≥15 policies + compliance matrix + test plans)
- [ ] **Phase 5** — Telemetry (Vector→Loki, Prometheus, Grafana dashboards-as-JSON)
- [ ] **Phase 6** — Zero-touch provisioning (Linux cloud-init, Windows unattend/PPKG, ADE runbook)
- [ ] **Phase 7** — Identity-driven access (Keycloak SAML SSO + device-trust demo app)
- [ ] **Phase 8** — Security automation & drills (SOAR-lite receiver + 3 IR drills)
- [ ] **Phase 9** — Portfolio hardening (README, diagram, demo script, interview-map)

---

## Host inventory (measured 2026-07-20)

| Resource | Value | Note |
|---|---|---|
| OS | Windows 11 **Home**, build 26200 | no Hyper-V Manager |
| CPU | AMD Ryzen 9 6900HX (8C / 16T) | |
| RAM | **63.2 GB** (36.8 GB free at recon) | 36 GB dedicated to lab |
| Disk `C:` | 929.8 GB total, **303.9 GB free** | |
| Virtualization | VT firmware enabled; `HypervisorPresent=True` | WSL2/VBS active → VBox runs in Hyper-V coexistence |
| VirtualBox | **7.1.4** ✅ | present |
| WSL2 | platform enabled (v2), **no distro yet** | Docker Desktop provisions one in Phase 1 |
| Docker Desktop | **not installed** | Phase 1 |
| mkcert / Multipass | not installed | mkcert added Phase 1 |
| git | 2.45.2 ✅ | |

## Operator decisions (Phase 0)

1. **Apple hardware: YES** — maxed 2025 Mac Studio, **onboarded last** via the
   private GitHub repo. macOS = **real-but-deferred**; author + CI-validate
   macOS artifacts now, enroll the Mac as a real MDM node in a later pass.
   iOS = **simulated** (no physical device + ABM yet).
2. **RAM budget: 36 GB** of 63.2 GB.

## Topology (see ADR-0001)

Full fleet peaks at **~33 GB ≤ 36 GB budget** — everything can run at once;
`corp-win-02` + `android-byod` are marked on-demand for host comfort.

| Host | Kind | Segment / Trust | RAM | Always-on |
|---|---|---|---|---|
| `axiom-core` | Docker stack (Fleet+MySQL+Redis+Caddy + later telemetry/identity/automation) | Server infra | ~10 GB | yes |
| `gpu-node-1` | Ubuntu 24.04 server VM | ML Infra / Standard | 2 GB | yes |
| `gpu-node-2` | Ubuntu 24.04 server VM | ML Infra / Standard | 2 GB | yes |
| `ml-workstation` | Ubuntu 24.04 desktop VM | ML Infra / Standard | 3 GB | yes |
| `enclave-01` | Ubuntu 24.04 hardened VM | **High-Trust Enclave / Elevated** | 2 GB | yes |
| `corp-win-01` | Windows 11 Enterprise Eval VM | Corp / Standard | 5 GB | yes |
| `corp-win-02` | Windows 11 Enterprise Eval VM | Corp / Standard | 5 GB | on-demand |
| `android-byod` | Android 14+ AVD | Mobile BYOD | 4 GB | on-demand |
| `mac-studio` | Real macOS (2025 Mac Studio) | Research & Eng / Standard | — | deferred |
| `ios-device` | iOS | Mobile BYOD | — | simulated |

---

## Stack Encyclopedia

Deep component-by-component reference for the entire build lives at
**[docs/encyclopedia/](docs/encyclopedia/README.md)** — 11 layer files + index,
every entry answering *what it is → why it's here → where it sits → how it works
→ who talks to it (direction/protocol/port) → Free-vs-Premium → gotchas*.
Authored 2026-07-20 by a 23-agent draft→fact-check workflow pinned to the
v4.89.1 research brief; start with the README's stack diagram and the two
data-flow walkthroughs.

## Architecture Decision Records

| ADR | Title | Status |
|---|---|---|
| [0001](docs/adr/0001-right-sized-topology.md) | Right-sized topology for a 63 GB Win 11 Home host | Proposed |
| [0002](docs/adr/0002-vm-backend-virtualbox-cloudinit.md) | VirtualBox + cloud-init (NoCloud) as VM backend | Proposed |
| [0003](docs/adr/0003-free-tier-trust-tiering.md) | Trust-tiering on Free via self-scoping policy SQL (NOT label/enroll-secret scoping) | **Accepted** |

---

## Research-verified build facts (Fleet v4.89.1) — feeds Phase 1+

Full detail + citations in the [research brief](docs/research/2026-07-20-phase0-1-fleet-brief.md). The load-bearing ones:

- **Pin `fleetdm/fleet:v4.89.1`** (image tag drops the `fleet-` prefix), `mysql:8` (≥8.0.44; **9.6.0 incompatible**), `redis:6`.
- **Compose source:** `docs/solutions/docker-compose/` (the repo-root compose is a *dev* env — not a deploy target). Needs a **`fleet-init` chown sidecar** (uid 100/gid 101) or first boot fails. Migration is baked in: `fleet prepare db --no-prompt && fleet serve`.
- **TLS:** `FLEET_SERVER_TLS=false` + **Caddy** terminates with an **mkcert** leaf; set `FLEET_SERVER_URL` to the external HTTPS name, `FLEET_SERVER_WEBSOCKETS_ALLOW_UNSAFE_ORIGIN=true`. `FLEET_SERVER_PRIVATE_KEY` (`openssl rand -base64 32`) is **required** and enables MDM — never regenerate it after MDM assets exist.
- **Agent packaging:** `fleetctl package --type deb|rpm|msi|pkg --fleet-certificate <rootCA.pem>` — the flag takes the **CA, not the leaf**; **osqueryd ignores the OS trust store**, so the CA must be baked into the package (the #1 local-lab gotcha). No `--fleet-tls` flag exists.
- **GitOps:** declarative — anything absent from applied YAML is **auto-deleted** (no `--delete-missing` flag); always `--dry-run` first. Free requires a **global-admin** token.

### ⚠️ Plan correction — trust-tiering (ADR-0003)
The master prompt's *"labels + per-label policy scoping + separate enroll secrets"* tiering **does not work on Fleet Free**: per-label policy scoping is Premium and **silently ignored**; enroll secrets **don't segment hosts**. Replaced with **self-scoping policy SQL** keyed on a provisioned tier marker (`/etc/axiom/trust-tier`) + the free `platform` field + label-targeted *queries*. This changes how the Enclave and Phase 4 policies are authored — topology shape is unaffected.

### Free-tier scope notes that shape later phases
- **Disk-encryption & OS-update *enforcement* are Premium** → Phase 4 does **detection** policies (osquery reads FDE/version state); enforcement/escrow is documented as the Premium delta.
- **Vuln CVE detection is Free; CVSS/EPSS/KEV scores are Premium** → Phase 8 SOAR-lite must not route severity on score fields.
- **Script execution + failing-policy webhooks are Free** → Phase 8 auto-remediation works at $0.
- **Android MDM is GA + Free** (work-profile BYOD) → **no Headwind fallback needed** (needs a Play-Protect/Google-Play AVD, not AOSP).
- **Windows MDM manual enroll is Free**; **Apple MDM** server-side is Free (enroll needs the Mac Studio, deferred).
- **Prometheus `/metrics` is disabled by default** (not served at all) → Phase 5 enables it with basic-auth creds (`FLEET_PROMETHEUS_BASIC_AUTH_USERNAME/_PASSWORD`) or `FLEET_PROMETHEUS_BASIC_AUTH_DISABLE=true`.

---

## Resume from cold (fill in as phases land)

> Goal: `docker compose up` + one CI run restores the entire desired state.

1. `git clone <private-repo> && cd fleetDM_fullLab`
2. _(Phase 1)_ `cp secrets.example.env .env` and fill secrets → `docker compose -f infra/docker-compose.yml up -d`
3. _(Phase 1)_ run `infra/tls/install-ca.ps1` (or the VM CA-trust script) to trust the mkcert root CA
4. _(Phase 2)_ `provisioning/new-linux-vm.ps1` per node → cloud-init enrolls fleetd on first boot
5. _(Phase 3)_ push to `main` → self-hosted runner applies `fleetctl gitops`

_Detailed, verified commands are pasted into each phase's acceptance section below as it completes._

---

## Acceptance evidence

### Phase 0 — Recon & plan
- Host inventory captured above from real `Get-CimInstance` / `wsl` / `VBoxManage` output.
- Live-docs research complete (8 agents, anchored to Fleet v4.89.1) → brief in `docs/research/`.
- ADR-0001 (topology) + ADR-0002 (VM backend) + ADR-0003 (free-tier tiering, resolves prompt contradiction) written.
- **Gate:** operator approval of the topology table. _Status: pending._

_(Phase 1+ evidence appended here as each phase passes its checks.)_
