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
| **Live docs research** | Background workflow `fleet-docs-recon` running (7 finders + synthesis) to reconcile current Fleet schemas/versions before Phase 1 |
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

## Architecture Decision Records

| ADR | Title | Status |
|---|---|---|
| [0001](docs/adr/0001-right-sized-topology.md) | Right-sized topology for a 63 GB Win 11 Home host | Proposed |
| [0002](docs/adr/0002-vm-backend-virtualbox-cloudinit.md) | VirtualBox + cloud-init (NoCloud) as VM backend | Proposed |
| 0003 | Free-tier tiering: labels + enroll secrets vs Premium teams | _pending live-docs research_ |

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
- ADR-0001 (topology) + ADR-0002 (VM backend) written.
- **Gate:** operator approval of the topology table. _Status: pending._

_(Phase 1+ evidence appended here as each phase passes its checks.)_
