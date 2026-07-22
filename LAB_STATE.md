# LAB_STATE — Project AXIOM (FleetDM DevSecOps Lab)

> Single source of truth for **what's running, what phase we're in, and how to
> resume**. Updated at every phase boundary. If the Fleet server dies, the
> "Resume from cold" section + Git restores everything.

---

## Current status

| | |
|---|---|
| **Phase** | **5 — Telemetry ✅** (Loki + Prometheus + Grafana dashboards-as-code; kill-agent→fleet-health-drop PROVEN) · Phase 2 client VMs + Phase 3 self-hosted runner await Aaron's inputs |
| **Date** | 2026-07-22 |
| **Running now** | `axiom-core` stack at **https://fleet.axiom.lab** + **enclave-01** (Ubuntu 24.04 elevated VBox VM, Fleet host **id=4**) enrolled ONLINE — **9/10 Linux policies green** (only #1 LUKS fails, documented). Admin creds `~/axiom-fleet-admin.txt`, fleetctl `~/.axiom-tools/…/fleetctl.exe` (rootca-set), VM artifacts in `C:\vms`. |
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
- [x] **Phase 4** — Policy-as-code ✅ _(22 policies + critical flags + CIS/MITRE matrix + per-policy test plans; break→red→fix→green proven live on enclave-01; osquery-table detection choices in ADR-0008)_
- [x] **Phase 5** — Telemetry ✅ _(Vector→Loki + Prometheus + fleet-exporter + Grafana 3 dashboards-as-JSON; kill-agent→fleet-health-drop acceptance proven)_
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
| [0004](docs/adr/0004-tls-termination-and-lab-dns.md) | Caddy TLS termination + mkcert CA + lab DNS | **Accepted** |
| [0005](docs/adr/0005-windows-mdm-wstep.md) | Windows MDM enablement via WSTEP identity CA | **Accepted** |
| [0006](docs/adr/0006-gitops-ci-architecture.md) | GitOps layout + CI/CD gate architecture | **Accepted** |
| [0007](docs/adr/0007-self-hosted-runner-security.md) | Self-hosted runner security model | **Accepted** |
| [0008](docs/adr/0008-osquery-table-detection-choices.md) | Policy detection tables under fleetd's osquery constraints (augeas/iptables/suid_bin) | **Accepted** |

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

**Windows MDM enabled server-side ✅** (ADR-0005): WSTEP identity CA generated
(`infra/scripts/new-wstep-ca.ps1` → `infra/mdm/`, gitignored, mounted `/etc/fleet/mdm:ro`),
`FLEET_MDM_WINDOWS_WSTEP_IDENTITY_CERT/_KEY` set, fleet restarted, and
`PATCH /api/latest/fleet/config` → **`windows_enabled_and_configured: true`** (verified).
(Enable toggle is imperative for now; Phase 3 moves it into GitOps.)

**Remaining Phase 2:** the Windows **client** VM (Win11 Eval ISO → VBox VM → fleetd MSI →
osquery + auto MDM enroll; needs the mkcert CA in `LocalMachine\Root` + an interactive sign-in);
Android AVD (emulator-only attempt, Play-Integrity risk); gpu-node-2 + ml-workstation (on-demand).

### Phase 3 — GitOps & CI/CD 🔄 (2026-07-22)

**GitOps (live server driven from Git):** `gitops/default.yml` (+ `fleets/unassigned.yml`, `lib/`
skeleton), seeded from `fleetctl generate-gitops`. `fleetctl gitops --dry-run` **and** apply both
exit 0; `windows_enabled_and_configured: true` stays on after apply; label preserved; enroll secret
is an env-ref (`$FLEET_GLOBAL_ENROLL_SECRET`), never in Git. (ADR-0006.)

**Cloud PR CI — both acceptance halves PROVEN** (PR #1, all on GitHub-hosted runners against an
**ephemeral Fleet v4.89.1** — never touches the LAN):
```
Valid change     → Lint ✅  Profiles ✅  osquery-SQL ✅  gitops dry-run (ephemeral) ✅   [PR shows all gates]
Broken .mobileconfig → Profiles ❌  (overall CI red)                                     [broken profile fails CI]
```
Four real CI bugs found by running it (WSTEP CA for the ephemeral Fleet, yamllint indentation/EOF,
actionlint custom-label config). gitleaks ✅. Fixes squash-merged to main (`f9b1e77`).

**Remaining Phase 3 (authored + committed; DISABLED until the self-hosted runner is registered —
needs Aaron's OK, ADR-0007):** `apply.yml` (apply-on-merge to the LAN Fleet) and `drift-detection.yml`
(nightly `generate-gitops` live-vs-Git). These cover the last two acceptance criteria (merge applies;
drift flags UI changes). Also pending: `GITLEAKS_LICENSE` repo secret (free, Aaron).

### Phase 4 — Policy-as-code ✅ (2026-07-22)

**22 policies** in [`gitops/default.yml`](gitops/default.yml) (`policies:`) across 3 platforms — 10
Linux (3 enclave-scoped), 6 macOS, 6 Windows — each with a `critical:` flag, description, resolution,
and a CIS + MITRE ATT&CK mapping in [docs/compliance-matrix.md](docs/compliance-matrix.md). Per-policy
break/fix **test plans** in [docs/test-plans.md](docs/test-plans.md), authored + **adversarially
verified** by a 25-agent workflow (3 platform authors → 22 skeptics; the verify pass caught the #7
allowlist defect below). Agent packages are now built reproducibly with `--enable-scripts` via
[`provisioning/build-packages.ps1`](provisioning/build-packages.ps1) (required for the run-script API
+ Phase 8 remediation).

**ACCEPTANCE — break→red→fix→green PROVEN live** on `enclave-01`, every flip driven by Fleet's free
`fleetctl run-script` (no SSH) and confirmed by Refetch:
```
#8 weights-cache FIM canary:  PASS  --append 1 byte (sha256 04c4afd9…)-->  FAIL
                                    --rewrite exact 16 bytes (sha256 7954095f…0b92 = pinned)-->  PASS
```
Also verified red↔green live: **#2** firewall-effective (`ufw disable`/rogue listener), **#3**
root-account-locked (`chpasswd` ↔ `passwd -l root`), **#7** unauthorized-SUID (`/usr/local/bin` setuid drop).

**Live posture (enclave-01, host id=4): 9/10 Linux policies green.** Only **#1 LUKS FAILs** — the
throwaway cloud image is not encrypted; FDE *enforcement*/escrow is Fleet **Premium**, so we **detect**
the gap (a genuine red, documented). macOS/Windows policies are `platform:`-pinned and authored-only
until those hosts enroll.

**Detection engineering — diagnosed on the live agent, not assumed (ADR-0008):** `fleetd`'s osquery
ships **no augeas lenses** (table returns 0 rows; autoload excludes `ufw.conf`+`sshd_config` even after
installing 462 lenses), the **`iptables` table is empty on 24.04** (nftables backend), and `suid_bin`
reports **usrmerge `/bin`==`/usr/bin` aliases**. Three policies were therefore re-authored onto
**populated** tables — #2 → `listening_ports` (inbound attack surface), #3 → `shadow`
(`password_status='locked'`), #7 → **directory-scoped** `suid_bin`. During this, #2 caught a real
regression (aide's `postfix` recommend opened `0.0.0.0:25`) — remediated by purging the MTA and pinning
`--no-install-recommends aide` in the elevated cloud-init.

**Webhook automation** (`failing_policies_webhook`) is authored in GitOps but disabled — its
destination is the Phase 8 SOAR-lite receiver; it activates there.

_Prove it live:_ `fleetctl run-script --host enclave-01 --script-path <break>.sh` then Refetch → policy
flips red; run the fix script → green. Commands per policy in `docs/test-plans.md`.

### Phase 5 — Telemetry ✅ (2026-07-22)

Observability layer in [`infra/telemetry/`](infra/telemetry/README.md) as a **composable add-on**:
it joins the `axiom-core` bridge and reads the `fleet-logs` volume, so the Phase 1–4 stack is never
touched. One command stands it up:
`docker compose -f infra/telemetry/docker-compose.yml --env-file infra/.env up -d --build`.

**Pipeline (all from Git):**
- **Sources:** 3 scheduled queries in GitOps `reports:` (Fleet renamed the key `queries`→`reports`) —
  heartbeat 60s, enclave-canary-hash 300s, listening-ports 300s → `/logs/osqueryd.results.log`.
  Fleet `/metrics` enabled via `FLEET_PROMETHEUS_BASIC_AUTH_*` (off by default — the path otherwise
  serves the SPA; verified it 401s without creds once enabled).
- **Vector** tails the osquery logs → **Loki** (parsed JSON; labels host/query/log_type).
- **Prometheus** scrapes Fleet `/metrics` (server health — Go/RSS/HTTP latency; basic-auth password
  written into a volume by a `prom-init` sidecar and referenced via `password_file`, never in Git) +
  the **fleet-exporter**.
- **fleet-exporter** (stdlib-only Python; authenticates as a dedicated **api-only observer** via
  token — api-only users can't use `/login`) polls the Fleet REST API for the business metrics Fleet's
  own `/metrics` lacks: `axiom_hosts_online/_offline`, `axiom_policy_failing_hosts{policy}`,
  `axiom_enclave_canary_failing_hosts`.
- **Grafana** provisioned from Git (datasources + 3 dashboards as JSON): **Fleet Health, Compliance,
  Enclave FIM**.

**Verified live:** Prometheus targets `fleet` + `fleet-exporter` + `prometheus` all **up**; Loki
ingesting `job=fleet_osquery`; both Grafana datasources health-**OK**; 3 dashboards auto-provisioned
under the AXIOM folder; exporter `axiom_exporter_up 1`, `axiom_hosts_online 1`, canary `0` (intact).

**ACCEPTANCE — kill an agent, fleet-health drops:**
```
BASELINE   Loki heartbeats(2m) = 2          (enclave-01 beaconing)
KILL       systemctl stop orbit on enclave-01  (delivered via Fleet run-script)
AFTER      Loki heartbeats(2m) = 0  +  exporter axiom_hosts_online = 0   [within ~2 min]
RESTORE    VM reboot -> orbit.service auto-starts -> heartbeat resumes -> hosts_online = 1
```

**Free-tier note:** Fleet does not persist the per-policy `critical` flag (Premium), so the exporter's
`axiom_critical_policy_failing_hosts` stays 0 — the Compliance dashboard keys on **total failing
checks** instead. Grafana is on **http://127.0.0.1:3000** (loopback only; Caddy `:443` remains the sole
LAN-facing port). Secrets (Grafana admin, exporter token, /metrics password) live only in `infra/.env`.

_(Phase 6+ evidence appended here as each phase passes its checks.)_
