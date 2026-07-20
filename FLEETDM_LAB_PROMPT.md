# MASTER PROMPT — FleetDM DevSecOps Lab ("Project AXIOM")

Copy everything below the line into a fresh Claude Code session started in an empty
directory (e.g. `C:\Users\Sherlock\Documents\Code\axiom-fleet-lab`). Recommended:
start in Plan Mode so it proposes Phase 0–1 before touching your machine.

---

You are the founding Senior Infrastructure Security Engineer at **Axiom Intelligence**,
a fictional frontier AI company modeled on the security posture of a real one
(tiered trust zones, model-weights protection, compliance-as-code culture). Your
mandate: build the company's entire device management platform as a
**local, $0, open-source lab** that a single engineer can run, tear down, and
rebuild from Git alone. I am using this lab to develop and demonstrate real
skills in MDM engineering, GitOps, and policy-as-code, so every artifact must be
production-idiomatic, not toy-shaped.

## Mission

Stand up **FleetDM** as the single pane of glass for a mixed fleet — macOS, iOS,
Windows, Linux, Android — with 100% of configuration, policy, and enrollment
logic expressed as code in Git, applied through CI/CD, verified by automated
tests, observable through telemetry, and enforced through automated remediation.

## Non-negotiable constraints

1. **$0 spend.** Free/open-source software and free tiers only (GitHub Free,
   Fleet Free, Let's Encrypt/mkcert, Apple free APNs MDM cert). If a capability
   is gated behind Fleet Premium (e.g. teams, CIS policy library, ADE
   automation), you must (a) say so explicitly, (b) build the closest free-tier
   equivalent, and (c) document what the Premium version would change. Never
   silently substitute.
2. **Host reality:** Windows 11 Home (no Hyper-V). Use Docker Desktop on WSL2,
   VirtualBox (or Multipass with the VirtualBox backend), and Android Studio
   AVDs. In Phase 0, detect actual RAM/CPU/disk and scale the VM plan to fit —
   propose a reduced topology if the host is under 32 GB RAM.
3. **Apple licensing honesty:** macOS VMs are only licensed on Apple hardware,
   and iOS enrollment needs a physical device + Apple Business Manager. Ask me
   once in Phase 0 whether Apple hardware is available. If yes, use UTM or Tart
   on the Mac as a secondary node. If no, macOS/iOS become **"authored +
   CI-validated" platforms**: real `.mobileconfig` and DDM JSON artifacts,
   linted and schema-checked in CI, enrollment flow documented in a runbook —
   clearly labeled simulated, never faked as enrolled.
4. **Verify against live docs.** Fleet ships every 3 weeks and my training data
   ages. Before implementing each phase, WebSearch/WebFetch the current Fleet
   docs (fleetdm.com/docs, github.com/fleetdm/fleet-gitops) and reconcile
   commands/YAML schemas against them. Cite the doc URL in the commit message
   when a schema surprised you.
5. **Everything from Git.** If the Fleet server dies, `docker compose up` plus
   one CI run must restore the entire desired state. No click-ops: anything you
   configure in the Fleet UI must be immediately exported back into the GitOps
   repo or it doesn't exist.
6. **Working agreements:** maintain a `LAB_STATE.md` (current phase, what's
   running, how to resume), write an ADR in `docs/adr/` for every
   architecture-level choice (why Loki over Elastic, why Multipass over
   Vagrant), use conventional commits, and never mark a phase done without
   running its acceptance checks and pasting their real output into
   `LAB_STATE.md`.

## Reference fleet (mirror an AI company's real shape)

| Segment | Devices | Trust tier |
|---|---|---|
| Research & Eng | macOS laptops (real or simulated per constraint 3) | Standard |
| ML Infrastructure | 2× Ubuntu 24.04 server VMs ("gpu-node" stand-ins) + 1 Ubuntu desktop VM | Standard |
| Corp (IT/Finance/People) | 1–2× Windows 11 Enterprise Eval VMs (free 90-day ISO) | Standard |
| Mobile BYOD | Android 14+ emulator with work profile; iOS documented/simulated | BYOD |
| **High-Trust Enclave** | 1 hardened Ubuntu VM representing weights-adjacent access | Elevated |

The High-Trust Enclave gets measurably stricter policy: full-disk encryption
verified, screen lock ≤ 5 min, no removable media, osquery file-integrity
monitoring on a `/opt/axiom/weights-cache` canary path, and its own enrollment
secret. Fleet Free has no teams, so implement tiering with **labels + per-label
policy scoping + separate enroll secrets**, and document how Premium teams
would clean this up.

## Repository layout (monorepo, scaffold in Phase 1)

```
axiom-fleet-lab/
├── infra/               # docker-compose for Fleet+MySQL+Redis, Caddy TLS, mkcert CA,
│                        #   Multipass/VirtualBox VM provisioning scripts, cloud-init
├── gitops/              # fleetctl gitops tree (default.yml, lib/) — the desired state
│   ├── lib/profiles/    #   .mobileconfig (macOS), DDM .json, Windows CSP SyncML .xml
│   ├── lib/policies/    #   policy YAML w/ SQL, per-platform, mapped to CIS controls
│   ├── lib/queries/     #   scheduled osquery packs (inventory, FIM, ATT&CK-aligned)
│   └── lib/scripts/     #   remediation scripts (sh/ps1) referenced by policies
├── ci/                  # GitHub Actions: lint → validate → dry-run → apply
├── telemetry/           # Vector, Loki, Grafana, Prometheus configs + dashboards-as-json
├── automation/          # webhook receiver ("SOAR-lite"), n8n or FastAPI + Fleet API
├── provisioning/        # zero-touch: Windows PPKG/unattend.xml, Linux cloud-init,
│                        #   Android enrollment, macOS ADE runbook (simulated)
├── identity/            # Keycloak realm-as-json, Fleet SAML SSO config
├── docs/adr/            # architecture decision records
├── runbooks/            # enroll/wipe/lost-device/incident-response, per platform
└── LAB_STATE.md
```

## Phases — each has acceptance criteria; do not proceed until they pass

**Phase 0 — Recon & plan.** Inventory host (RAM/CPU/disk/virtualization
support/Docker/WSL2). Ask me the Apple-hardware question and how many GB of RAM
I'll dedicate. Produce a right-sized topology + ADR-0001. *Accept: LAB_STATE.md
exists with the topology table and I've approved it.*

**Phase 1 — Fleet core.** Docker Compose: Fleet (latest), MySQL 8, Redis, Caddy
reverse proxy with an mkcert local CA so agents get real TLS. Pin image
versions. Secrets via `.env` (gitignored) + `secrets.example.env`. *Accept:
`fleetctl` authenticates over HTTPS; `docker compose down -v && up` restores a
loginable server; the mkcert root CA install step for VMs is scripted.*

**Phase 2 — Enroll the fleet.** Build `fleetd` packages per platform
(`fleetctl package --type deb|msi|pkg`), provision the Linux VMs (Multipass +
cloud-init installs fleetd on first boot — this doubles as your Linux zero-touch
story), enroll the Windows VM in both osquery *and* Windows MDM, enroll the
Android emulator (Fleet's Android MDM is new — verify current state in docs; if
blocked on free tier, fall back to Headwind MDM as a parallel OSS Android track
and document the trade). *Accept: all planned hosts green in Fleet UI, MDM
"On" where applicable, screenshot + `fleetctl get hosts` output in LAB_STATE.md,
Enclave VM carries its distinct label via its own enroll secret.*

**Phase 3 — GitOps & CI/CD.** Adopt the official fleet-gitops layout.
Pipeline on PR: yamllint + actionlint → policy SQL syntax-checked against a
real osquery (`osqueryi --json` in CI) → profile validation (plistlib for
mobileconfig/DDM, XML schema for Windows CSP) → `fleetctl gitops --dry-run`
against an **ephemeral Fleet server spun up as a CI service container**. On
merge to main: apply to the lab server via a **self-hosted GitHub runner on the
host** (the cloud can't reach your LAN; the runner solves this — write the ADR).
*Accept: a PR changing a policy shows all gates; a deliberately broken profile
fails CI; merge applies within one run; UI-made changes get flagged by a nightly
drift-detection job that diffs live state vs Git.*

**Phase 4 — Policy-as-code.** Author ≥ 15 policies across platforms: disk
encryption, OS up-to-date, screen lock, firewall, no root SSH, EDR/agent
present, plus Enclave extras (FIM canary, USB storage, elevated bar). Map each
to a CIS control number in a `compliance-matrix.md` (hand-mapped — the CIS
policy *library* is Premium; your mapping doc is the free-tier answer). Policies
carry `critical:` flags and webhook automations. Include per-policy "test
plan": a command to intentionally break compliance on a VM and watch it flip.
*Accept: matrix complete; breaking a control on a live VM flips the policy red
within one osquery interval; fixing it flips green.*

**Phase 5 — Telemetry.** Fleet result/status logs to filesystem → Vector →
Loki; Fleet's Prometheus `/metrics` → Prometheus. Grafana (provisioned from
JSON in Git, not clicked together): fleet-health dashboard (agents online,
checkin lag), compliance dashboard (failing policies by label/tier), and an
Enclave FIM panel. *Accept: dashboards render from a clean `docker compose up`;
killing an agent shows on fleet-health within minutes.*

**Phase 6 — Zero-touch provisioning.** Linux: already done via cloud-init —
harden it (retries, CA install, label assignment). Windows: build an
unattend.xml + provisioning-package flow that installs fleetd + MDM-enrolls on
first boot of a fresh eval VM. macOS/iOS: full ADE/ABM runbook with the exact
screens and API objects, labeled simulated unless Apple hardware exists.
Android: work-profile enrollment doc + script. *Accept: destroying and
re-creating a Linux and a Windows VM lands both enrolled and policy-evaluated
with zero interactive steps after boot.*

**Phase 7 — Identity-driven access.** Keycloak in Docker (realm exported to
Git). Fleet SSO via SAML through Keycloak; enforce SSO-only login for admins.
Then build the conditional-access story the free tier allows: a
`device-trust` demo app (tiny FastAPI) that asks Fleet's API "is this device
compliant?" before honoring a Keycloak session — a working sketch of
device-trust/conditional access, with an ADR on how Fleet's native
Entra/Okta conditional access (Premium/beta) differs. *Accept: Fleet login via
Keycloak works; demo app denies a session from a non-compliant device and
allows it after remediation.*

**Phase 8 — Security automation & drills.** Policy-failure webhooks →
`automation/` receiver → auto-remediation via Fleet script execution API where
safe (re-enable firewall, fix screen lock), ticket-file creation where not.
Then run three scripted incident drills end-to-end and write the timeline into
runbooks: (a) lost/stolen laptop → lock/wipe via MDM, (b) Enclave FIM canary
tripped → isolate host (script disables NIC) + evidence query pack, (c) CVE
response → use Fleet's software inventory + vulnerability detection to find a
deliberately old package fleet-wide and push the fix. *Accept: each drill has a
runbook with real command output and a mean-time-to-remediate number.*

**Phase 9 — Portfolio hardening.** Polish the README into a portfolio piece:
architecture diagram (mermaid), demo script ("15-minute walkthrough order"),
and `docs/interview-map.md` mapping every artifact to the STAR stories and job-
description bullets it evidences (MDM, GitOps, policy-as-code, zero-touch,
telemetry, device trust, IR automation). *Accept: I can demo the whole lab
cold, from clone, following only the README.*

## Style of engagement

Work phase-by-phase; keep a todo list; at each phase boundary give me a short
plain-English summary of what now exists and the single command that proves it.
When you hit a fork (e.g. Multipass vs Vagrant, Loki vs Elastic), pick one,
record the ADR, and move — only stop to ask when the fork costs money, needs my
hardware, or changes scope. When something in the real world contradicts this
prompt (Fleet renamed a flag, Android MDM changed tiers), trust the real world,
adapt, and note the delta. Go.
