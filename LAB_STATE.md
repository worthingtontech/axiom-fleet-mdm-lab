# LAB_STATE — Project AXIOM (FleetDM DevSecOps Lab)

> Single source of truth for **what's running, what phase we're in, and how to
> resume**. Updated at every phase boundary. If the Fleet server dies, the
> "Resume from cold" section + Git restores everything.

---

## Current status

| | |
|---|---|
| **Phase** | **2 — Enroll the fleet 🔄 IN PROGRESS** (gpu-node-1 online; Linux pipeline proven) |
| **Date** | 2026-07-22 |
| **Running now** | `axiom-core` stack at **https://fleet.axiom.lab** + **gpu-node-1** (Ubuntu 24.04 VBox VM) enrolled ONLINE. Admin creds `~/axiom-fleet-admin.txt`, fleetctl `~/.axiom-tools/…/fleetctl.exe` (rootca-set), VM artifacts in `C:\vms`. |
| **Next (Phase 2)** | gpu-node-2 + ml-workstation + enclave-01 (tier markers + dynamic label); Windows osquery+MDM (WSTEP CA); Android AVD (or physical fallback) |
| **VM mechanism** | Raw VirtualBox + Ubuntu cloud image → VDI + NoCloud CIDATA seed (ADR-0002; Multipass **rejected** — broken on VBox 7.1.x/Win11 Home, Canonical #3915). NAT + `/etc/hosts fleet.axiom.lab→10.0.2.2`; TLS validates on the SAN hostname. .deb rides on the seed ISO. |
| **Perf caveat** | Hyper-V coexistence (NEM) → first boot ~6 min with a CPU soft-lockup that recovers; `--paravirtprovider kvm` + longer enroll polls (600s) mitigate. |
| **Live docs research** | ✅ Complete (8 agents, 0 errors). Anchored to **Fleet v4.89.1** (2026-07-16). Full brief: [docs/research/2026-07-20-phase0-1-fleet-brief.md](docs/research/2026-07-20-phase0-1-fleet-brief.md) |
| **Git** | `main` → **github.com/worthingtontech/axiom-fleet-mdm-lab** (private, Apache-2.0). Flips public at Phase 9. |

### Phase checklist

- [x] **Phase 0** — Recon & plan _(topology approved; ADRs 0001-0004 + encyclopedia + research brief)_
- [x] **Phase 1** — Fleet core ✅ _(Compose: Fleet v4.89.1 + MySQL 8 + Redis 6 + Caddy + mkcert TLS — both acceptance checks pass, evidence below)_
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
- **Gate:** operator approval of the topology table. _Status: ✅ **APPROVED** 2026-07-21._

### Phase 1 — Fleet core ✅ (2026-07-22)

Stack: `infra/docker-compose.yml` (`axiom-core`) — Fleet **v4.89.1** + MySQL 8 + Redis 6 +
one-shot fleet-init + Caddy (TLS via mkcert). ADR-0004 (TLS termination + lab DNS).
Host prep: Docker Desktop 4.83 / engine 29.6.2, mkcert 1.4.4, fleetctl 4.89.1.

**Check 1 — `fleetctl` authenticates over HTTPS (validated chain, NO `--insecure`):**
```
$ fleetctl config set --address https://fleet.axiom.lab --rootca <infra/tls/rootCA.pem>
[+] Set the address config key to "https://fleet.axiom.lab" in the "default" context
[+] Set the rootca config key to "...\infra\tls\rootCA.pem" in the "default" context
# .fleet/config → tls-skip-verify: false   (secure; real mkcert chain)
$ fleetctl setup --email admin@axiom.lab --name "Aaron Perkins" --org-name "Axiom Intelligence"
[+] Fleet setup successful and context configured!
$ fleetctl get hosts
No hosts found            # exit 0 — authenticated, nothing enrolled yet (correct for Phase 1)
$ curl https://fleet.axiom.lab/healthz  → HTTP 200   (through Caddy, full TLS validation)
```
> Windows gotcha documented: `curl.exe`/Schannel hard-fails a local mkcert cert with
> `CRYPT_E_NO_REVOCATION_CHECK` (no CRL/OCSP for a private CA) — cosmetic; fleetctl (Go TLS)
> and browsers are fine. fleetctl needs the CA via `--rootca` (it won't read the OS store on Windows).

**Check 2 — `down -v && up` restores a loginable server (rebuild from Git + `.env`):**
```
$ docker compose down -v      # destroyed ALL 7 named volumes incl. mysql-data (the whole DB)
$ docker compose up -d        # rebuilt from Git-tracked compose + host .env
  fleet-init Exited(0) · redis Healthy · mysql Healthy · fleet Started · caddy Started
  Fleet /healthz 200 after ~48 s   (migrations re-ran automatically)
$ fleetctl setup ... ; fleetctl get hosts → No hosts found (exit 0)
$ curl https://fleet.axiom.lab/healthz → HTTP 200
=== ACCEPTANCE #2: PASS ===
```
`.env` + `infra/tls/*.pem` are host files (survive `-v`); only volumes are destroyed → the
private key and certs persist, everything else rebuilds. **This is the only phase where `-v`
is safe** (from Phase 2 on it would wipe enrollment/MDM state).

**Check 3 — VM CA-install is scripted:** `infra/tls/install-ca-linux.sh` (update-ca-certificates)
+ `install-ca-windows.ps1` (LocalMachine\Root) + `make-certs.ps1` copies `rootCA.pem` for
provisioning. (Reminder: osqueryd ignores the OS store → Phase 2 also bakes the CA into fleetd
via `fleetctl package --fleet-certificate`.)

_Prove it cold:_ `docker compose -f infra/docker-compose.yml up -d` → browse https://fleet.axiom.lab.

### Phase 2 — Enroll the fleet 🔄 (in progress, 2026-07-22)

**fleetd packages** built via the `fleetdm/fleetctl` Docker image (Windows host can only build
`.msi` natively; the Linux container builds all types). Both bake in the enroll secret + mkcert
CA (`--fleet-certificate`, so **osqueryd** trusts Fleet despite ignoring the OS store):
- `fleet-osquery_1.58.0_amd64.deb` (Linux) · `fleet-osquery.msi` (Windows) — in `provisioning/build/` (gitignored).

**First Linux host enrolled (gpu-node-1) — zero-touch via cloud-init:**
```
$ fleetctl get hosts
+--------------------------------------+------------+----------+-----------------+--------+
| UUID                                 | HOSTNAME   | PLATFORM | OSQUERY VERSION | STATUS |
| 77f8a835-0e20-9b4e-a27c-fd0cc099622c | gpu-node-1 | ubuntu   | 5.23.1          | online |
+--------------------------------------+------------+----------+-----------------+--------+
```
Serial log confirmed: cloud-init mounted the CIDATA seed, `apt-get install` the fleetd `.deb`,
`Started orbit.service`, `AXIOM_ORBIT_ACTIVE`, → **online in Fleet over validated TLS**. (Also
captured the predicted Hyper-V-coexistence soft-lockup: `CPU#0 stuck for 373s` — recovered.)

**enclave-01 (elevated tier) enrolled + free-tier tiering PROVEN:**
```
$ fleetctl get host enclave-01   → labels include: Ubuntu Linux, high-trust-enclave
Label host_count:  Ubuntu Linux = 2 (gpu-node-1 + enclave-01) · high-trust-enclave = 1 (enclave-01 ONLY)
```
Tiering works per ADR-0003: cloud-init (elevated template) writes `/etc/axiom/tier.d/elevated`;
the dynamic `high-trust-enclave` label matches that **sentinel path** (osquery's `file` table has
no content column), so only the elevated node is tiered up — **no Premium teams needed**.

**⚠️ NEM concurrency ceiling (real finding):** under Hyper-V coexistence, only **~1 VM boots at a
time** — a second concurrent boot froze in initramfs (CPU soft-lockup). Booted alone, a VM is fast
(~26 s + ~60 s to enroll). So the fleet runs **serially / a couple at a time**, not all-concurrent.
`new-linux-vm.ps1` hardened through 3 runtime-found bugs (EAP+stderr, ca_certs template corruption,
teardown-before-seed ordering).

**Remaining Phase 2:** gpu-node-2 + ml-workstation (mechanical repeats), Windows osquery+MDM (needs a
Win11 Eval VM + WSTEP CA), Android AVD (biggest risk — may need a physical device).

_(Phase 1+ evidence appended here as each phase passes its checks.)_
