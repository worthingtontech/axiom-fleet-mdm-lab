# 🧭 Cross-Cutting Concepts & the Trust Model
> Part of the **[Project AXIOM Encyclopedia](./README.md)** · Layer: Cross-cutting concepts / trust-model. The vocabulary and design principles that span every other layer — what the lab is pretending to be, how it slices its fleet into trust tiers, and the four rules ($0, everything-from-Git, single-pane, zero-touch) that shape every technical decision below them.

The other ten files in this encyclopedia describe *components* — the hypervisor, the containers, the Fleet server, the CA, the policies. This file describes the *ideas that cut across all of them*. These are the entries you reach for when someone asks "why is the lab shaped like this?" rather than "what does this daemon do?". Each concept is grounded in a concrete interaction so it stays honest: a principle you can't trace to a packet on a port is just a slogan. Read this file first for orientation, or last to tie the components together.

---

## Project AXIOM — the frontier-AI framing

- **In one line** — a fictional frontier-AI company, "Axiom Intelligence", invented so the device-management lab has a *reason* to be strict, tiered, and paranoid.
- **What it actually is** — a narrative wrapper, not software. Axiom Intelligence is a made-up company that trains large models; the "crown jewels" are model weights. Framing the lab as *its* IT/security estate turns an otherwise abstract Fleet install into a scenario with stakes: some machines touch the weights (must be locked down hard), most don't (normal corporate hygiene), and phones are personal (BYOD, minimal reach). The analogy: a movie set. The walls are real 2×4s and drywall (real VMs, real osquery, real TLS), but the "bank" they form is a story that tells you where to put the vault door.
- **Why it's in Project AXIOM** — a flat "manage 10 identical laptops" lab exercises maybe three Fleet features. A frontier-AI company forces the interesting ones: a hardened enclave, weights-adjacent access control, trust tiering, file-integrity monitoring, compliance-as-code, and an honest reckoning with what you *can't* enforce for $0. The fiction is the requirements document.
- **Where it sits in the stack** — above everything; it is the top-level "why". It dictates the topology ([01](./01-host-hypervisor-virtualization.md)), the tier markers written into each host at first boot by cloud-init ([01](./01-host-hypervisor-virtualization.md)), and the policy set ([07](./07-policy-as-code.md)).
- **How it works** — the fiction is encoded, not just narrated. It shows up as concrete artifacts: hostnames (`enclave-01`, `gpu-node-1`, `corp-win-01`), the canary path `/opt/axiom/weights-cache/`, the marker file `/etc/axiom/trust-tier`, and the Windows registry value `HKLM\SOFTWARE\Axiom\TrustTier`. Every one of these is a place the story becomes bytes a policy can read.
- **Who talks to it, and how** — nothing "talks to" a fiction over a wire; the fiction talks to *you*, the builder, at design time, and then leaves fingerprints the machines read at runtime. Concretely: you (author) → write the story into Git-tracked provisioning YAML → cloud-init writes `/etc/axiom/trust-tier=elevated` onto `enclave-01` at first boot → later, osqueryd on that host reads the marker → reports it to Fleet on check-in → a self-scoping policy decides the host is in-scope for elevated controls. The narrative propagates from your head, through Git, into a file, into a query result, into a compliance verdict.
- **Gotchas / myth-busting** — the company is fictional but nothing about the *engineering* is faked or hand-waved. The VMs are real, the failures are real, and every Free-vs-Premium limitation is reported honestly rather than papered over with the story (see [$0 / free-tier-only](#-0--free-tier-only--and-never-silently-substitute)). Don't confuse "the company is pretend" with "the controls are pretend" — the latter would defeat the entire point.
- **See also** — [The reference fleet & its segments](#the-reference-fleet--its-segments) · [Model-weights protection](#model-weights-protection--why-the-lab-has-this-shape) · [ADR-0001 topology](../adr/0001-right-sized-topology.md)

---

## The reference fleet & its segments

- **In one line** — the 10-node inventory Fleet manages, sliced into functional *segments* (ML infra, Corp, Enclave, Mobile BYOD, Server) that mirror how a real frontier-AI company's estate is organized.
- **What it actually is** — "the fleet" is the set of all enrolled hosts; a "segment" is a human/organizational grouping of them by *what job the machine does*. Segments are a naming and dashboarding convenience — think folders, not firewalls. They are distinct from *trust tiers* (the security posture) even though they correlate: the ML-infra segment is mostly Standard tier, the one Enclave node is Elevated tier, phones are the BYOD tier.

  | Segment | Nodes | Kind | Default trust tier |
  |---|---|---|---|
  | Server infrastructure | `axiom-core` | Docker/WSL2 stack (Fleet+MySQL+Redis+Caddy +Phase 5-8 add-ons) | n/a (it *is* the control plane) |
  | ML infrastructure | `gpu-node-1`, `gpu-node-2`, `ml-workstation` | Ubuntu 24.04 VBox VMs | Standard |
  | High-Trust Enclave | `enclave-01` | Ubuntu 24.04 VBox VM, hardened | **Elevated** |
  | Corp (IT/Finance/People) | `corp-win-01`, `corp-win-02` (on-demand) | Windows 11 Enterprise Eval VMs | Standard |
  | Research & Eng | `mac-studio` | Real macOS (2025 Mac Studio) | Standard — **deferred** |
  | Mobile BYOD | `android-byod`, `ios-device` | Android Studio AVD; iOS **simulated** | BYOD |

- **Why it's in Project AXIOM** — segments give the lab a realistic shape at a size one 63 GB machine can actually run (~33 GB concurrent peak vs a 36 GB budget). Each segment exercises a different Fleet capability surface: Linux osquery, Windows osquery + Windows MDM, Android MDM, macOS MDM (deferred), and the server stack itself. Without segments the "fleet" is just an undifferentiated pile of VMs and the dashboards say nothing.
- **Where it sits in the stack** — the fleet is the *managed* plane; `axiom-core` is the *control* plane that watches it. Segments are a cross-cutting label over the host layer ([01](./01-host-hypervisor-virtualization.md)) surfaced through Fleet ([03](./03-fleet-core.md)).
- **How it works** — segment membership is expressed as Fleet **labels** (free, dynamic or manual) plus the free **`platform`** field, and by hostname convention. A dynamic label like `enclave` is a saved query (`SELECT 1 FROM file WHERE path='/etc/axiom/tier.d/elevated'…`, the elevated-only marker present on just `enclave-01`) that a host either matches or doesn't; Fleet re-evaluates it on check-in. (osquery's `file` table matches a path's *existence and metadata*, not its text — which is why tier scope is encoded as a path that either exists or doesn't, rather than a value read out of `/etc/axiom/trust-tier`.) Labels are then used for **query targeting** and **dashboard filtering** — both free.
- **Who talks to it, and how** — every non-server node runs **fleetd** (orbit + osqueryd + Fleet Desktop) that *initiates* an outbound TLS connection; Fleet is passive and never dials the hosts for osquery.

  ```mermaid
  flowchart LR
    subgraph host["Windows 11 host — Ryzen 9, 63 GB"]
      subgraph core["axiom-core (Docker / WSL2)"]
        caddy["Caddy :443 (TLS term)"]
        fleet["Fleet :1337 (plain HTTP)"]
        mysql[("MySQL 8 :3306")]
        redis[("Redis 6 :6379")]
      end
      subgraph vbox["VirtualBox VMs"]
        std["gpu-node-1/2, ml-workstation (Standard)"]
        enc["enclave-01 (Elevated)"]
        win["corp-win-01/02 (Standard)"]
      end
      avd["android-byod (AVD, BYOD)"]
    end
    mac["mac-studio (deferred)"]
    ios["ios-device (simulated)"]
    std -->|"fleetd: outbound HTTPS 443"| caddy
    enc -->|"fleetd + FIM: HTTPS 443"| caddy
    win -->|"fleetd + Win MDM: HTTPS 443"| caddy
    avd -->|"via Google AMAPI"| fleet
    caddy -->|"plain HTTP 1337"| fleet
    fleet --> mysql
    fleet --> redis
  ```

  The directional truth: agents pull. An osquery host opens the connection, presents its enroll secret (first time) then its node key, and asks "anything for me?"; Fleet answers from what it queued in Redis. Fleet writes host vitals and query results to MySQL. Segments are computed server-side from those results.
- **Free vs Premium** — segments-as-labels are **free**. What is *not* free is turning a segment into a real security boundary: **Teams** (Premium) would let a segment carry its own policies, profiles, and enroll-secret routing. On Free, all 10 hosts live in the single global "No team" no matter how you label them — the segment is cosmetic for *isolation* (see [trust tiers](#trust-tiers--standard-elevated-byod)).
- **Gotchas / myth-busting** — a label is a folder, not a fence. Putting a host in the `enclave` label does **not** scope a policy to it on Free (per-label policy scoping is Premium and silently ignored). `corp-win-02` is *on-demand* — a second Windows host spun up only when needed, purely for host-RAM comfort, not a separate tier; the Android AVD is likewise launched only while the BYOD path is being exercised. `mac-studio` and `ios-device` are in the inventory for completeness but are **deferred/simulated**; don't treat their dashboard tiles as live until Apple hardware is onboarded.
- **See also** — [Trust tiers](#trust-tiers--standard-elevated-byod) · [Single pane of glass](#single-pane-of-glass) · [Fleet labels & host vitals](./03-fleet-core.md) · [ADR-0001 topology](../adr/0001-right-sized-topology.md)

---

## Trust tiers — Standard, Elevated, BYOD

- **In one line** — three security-posture bands (Standard / Elevated / BYOD) that decide *how strict* the policy set is for a host, implemented on Fleet Free with self-scoping policy SQL rather than teams.
- **What it actually is** — a trust tier is the *answer to "what compliance bar does this machine have to clear?"*. Standard is baseline corporate hygiene (FDE present, screen lock, firewall on, up-to-date). Elevated adds enclave-grade controls (FDE *verified*, screen lock ≤ 5 min, no removable media, FIM on the weights cache, tighter thresholds). BYOD is the *lightest* touch — a personal phone gets work-container separation and a handful of health checks, not full-device control. Analogy: building zones — lobby (BYOD), general office floors (Standard), and the vault room with the mantrap (Elevated).

  | Tier | Applies to | Representative controls | Marker |
  |---|---|---|---|
  | **Standard** | ML infra, Corp, Research | FDE detected, screen lock set, firewall on, OS up-to-date, no critical CVEs | default (`/etc/axiom/trust-tier=standard`) |
  | **Elevated** | `enclave-01` | all Standard **plus** FDE verified, lock ≤ 5 min, USB-storage blocked, FIM on `/opt/axiom/weights-cache` | `/etc/axiom/tier.d/elevated` + canary path |
  | **BYOD** | `android-byod`, `ios-device` | work-profile present, OS version floor, screen-lock present, not rooted/jailbroken | platform + MDM enrollment type |

- **Why it's in Project AXIOM** — a frontier-AI company cannot hold every machine to enclave standards (it would grind normal work to a halt) nor hold the enclave to laptop standards (it would leak weights). Tiering is the whole reason the story has an enclave. It is also the lab's single biggest planning correction (ADR-0003) and therefore a portfolio centerpiece: *doing tiering honestly on Free is harder than it looks*.
- **Where it sits in the stack** — a cross-cutting concept realized in the policy layer ([07](./07-policy-as-code.md)), seeded by the provisioning layer ([01](./01-host-hypervisor-virtualization.md)), applied through GitOps ([06](./06-gitops-and-cicd.md)), and surfaced in telemetry/dashboards ([08](./08-telemetry-and-observability.md)).
- **How it works** — the mechanism has three free ingredients, because the "obvious" one is a trap:
  1. **A provisioned, host-intrinsic marker** written by Git-tracked provisioning: `/etc/axiom/trust-tier` (Linux/macOS), `HKLM\SOFTWARE\Axiom\TrustTier` (Windows), and the intrinsic canary path only `enclave-01` has. Tier membership is *declared in code*, never clicked in the UI.
  2. **Self-scoping policy SQL.** Because a Free policy always runs on *every* host, each tier-specific policy is written to **auto-pass out-of-scope hosts** and only really evaluate in-scope ones. Fleet's rule: **1 row returned = pass, 0 rows = fail.** So the canonical guard is `(host-not-in-scope) OR (host-compliant)`:
     ```sql
     SELECT 1 WHERE
           NOT EXISTS (SELECT 1 FROM file
                       WHERE path='/etc/axiom/tier.d/elevated' AND type='regular')
        OR EXISTS ( /* the real control, e.g. screen-lock <= 5 min */ );
     ```
     A Standard host has no `elevated` marker → the first clause is true → the policy returns a row → **pass**. Only a non-compliant *enclave* host returns zero rows → **fail**. The mirror `(in-scope) AND (compliant)` is used where a missing marker must **fail closed**.
  3. **The free `platform` field** (`linux|darwin|windows`) narrows OS-specific policies (LUKS only on Linux, BitLocker only on Windows), and **label-targeted queries** (free) carry Enclave-only *telemetry* even though *policies* can't be label-scoped.
- **Who talks to it, and how** — the tier is decided *on the host, at query time*, and travels to Fleet like any other result:

  ```mermaid
  sequenceDiagram
    participant CI as cloud-init (Git)
    participant Host as enclave-01 osqueryd
    participant Fleet
    participant DB as MySQL
    CI->>Host: first boot writes /etc/axiom/tier.d/elevated
    Host->>Fleet: check-in (HTTPS 443 via Caddy) — asks for scheduled work
    Fleet-->>Host: distributed queries incl. tier policies
    Host->>Host: runs guarded SQL, reads marker file locally
    Host->>Fleet: results (pass/fail rows)
    Fleet->>DB: store policy membership -> host shows compliant/failing
  ```

  No component "assigns" the tier over the wire — the host proves its own tier by whether the marker file exists when the guarded query runs.
- **Free vs Premium** — this is *the* Free-vs-Premium entry. On **Premium**, a real **Team** ("High-Trust Enclave") + team-routed enroll secret auto-segments hosts on enrollment, and you delete every `(out-of-scope) OR …` guard clause. On **Free**: per-label policy scoping is **silently ignored** (policy runs on all hosts, no error), enroll secrets **do not segment** (all hosts land in "No team", and no query even reveals which secret a host used), and teams don't exist. The upgrade is a *mechanical* diff, not a redesign (ADR-0003).
- **Gotchas / myth-busting** — the seductive wrong design is "labels + per-label policy scoping + a separate enroll secret per tier." **All three fail silently on Free** and produce *false-green* compliance. The enclave enroll secret is kept anyway — as a Premium-ready artifact and for rotation hygiene — but it is **cosmetic for segmentation on Free**; say so plainly. Second gotcha: the marker is host-local, so a host could tamper with its own marker and self-downgrade; acceptable for a lab, cross-checked against intrinsic signals (hostname prefix, canary path). Premium server-side teams remove this weakness.
- **See also** — [The High-Trust Enclave](#the-high-trust-enclave--weights-adjacent-access) · [Compliance-as-code](#compliance-as-code) · [Defense-in-depth & least privilege](#defense-in-depth--least-privilege) · [Policy-as-code & self-scoping SQL](./07-policy-as-code.md) · [ADR-0003 free-tier tiering](../adr/0003-free-tier-trust-tiering.md)

---

## The High-Trust Enclave & weights-adjacent access

- **In one line** — `enclave-01`, the single hardened node that stands in for "machines allowed near the model weights", carrying the Elevated tier and file-integrity monitoring on the weights cache.
- **What it actually is** — the Enclave is one Ubuntu 24.04 VirtualBox VM configured to a deliberately higher standard than its siblings, plus the *concept* of "weights-adjacent access": the small set of hosts, paths, and controls that surround the crown jewels. In the fiction, `enclave-01` is where model weights are staged/cached at `/opt/axiom/weights-cache/`; in reality that directory holds nothing secret but is watched as if it did. The analogy: the vault room. It's still just a room with a floor and walls (a normal VM), but it has the motion sensors, the logged door, and the "authorized personnel only" rule that the open-plan office doesn't.
- **Why it's in Project AXIOM** — a frontier-AI company's entire threat model centers on weights exfiltration. The Enclave is where the lab demonstrates that it can (a) hold a subset of hosts to a stricter bar, (b) *detect* tampering/access on a sensitive path, and (c) express both as code. It is the concrete anchor for the "trust tiering" and "model-weights protection" stories.
- **Where it sits in the stack** — a host in the ML-infra neighborhood but promoted to the Elevated tier. It sits beside the Standard Linux nodes ([01](./01-host-hypervisor-virtualization.md)), above the CA/TLS it trusts to enroll ([04](./04-tls-and-pki.md)), and feeds the FIM stream into telemetry ([08](./08-telemetry-and-observability.md)).
- **How it works** — three layers of hardening, all Git-expressed:
  1. **Provisioning-time hardening** via its own cloud-init seed (ADR-0002): distinct enroll secret, tighter sysctl/USB config, and the tier markers (`/etc/axiom/trust-tier=elevated`, `/etc/axiom/tier.d/elevated`, and the canary directory).
  2. **Elevated policy set** via the self-scoping guard pattern: FDE verified, lock ≤ 5 min, USB-storage blocked, OS current — each guarded so only the enclave is graded on them.
  3. **File-integrity monitoring (FIM)** on `/opt/axiom/weights-cache/` using osquery's **evented `file_events` table**: agent options declare `file_paths` for that directory and enable file events; osqueryd watches the filesystem (inotify on Linux) and records create/modify/delete/access events; a scheduled query against `file_events` ships those events to Fleet.
- **Who talks to it, and how** — same outbound-pull pattern as any node, plus an evented-telemetry stream:

  ```mermaid
  flowchart LR
    fs["/opt/axiom/weights-cache/*"] -->|"inotify event"| osq["osqueryd file_events (enclave-01)"]
    osq -->|"scheduled query on check-in, HTTPS 443"| caddy["Caddy :443"]
    caddy -->|"HTTP 1337"| fleet["Fleet"]
    fleet -->|"results log (filesystem)"| logs["/logs/osqueryd.results.log"]
    logs -->|"Phase 5"| vector["Vector"] --> loki["Loki"] --> graf["Grafana alert"]
  ```

  Nothing pushes *into* the enclave to inspect it — the enclave's own osqueryd initiates every upload. A tamper event on the weights path becomes a `file_events` row, rides the next check-in to Fleet, lands in the results log, and (Phase 5) flows to Loki where a Grafana rule can alert.
- **Free vs Premium** — FIM, evented tables, scheduled queries, labels, and the self-scoping policies are all **free**. What's Premium: making the enclave a real isolated **Team**, and *enforcing* (not just detecting) FDE/removable-media/OS-version. So the enclave **detects** a missing-encryption or USB-inserted condition and fails a policy; it cannot, on Free, *force* encryption on or *block* the USB device server-side.
- **Gotchas / myth-busting** — the enclave is hardened but not *isolated* from the rest of the fleet on Free (no teams). Its stricter posture is real (the guarded policies genuinely fail only it); its *segmentation* is emulated. Also: `file_events` is an **evented** table — it only reports events that happen **while osqueryd is running and watching**; it is not a retroactive scan of the directory. If the agent was down during a change, that change is invisible to FIM (a real osquery limitation, not a lab shortcut).
- **See also** — [Model-weights protection](#model-weights-protection--why-the-lab-has-this-shape) · [Trust tiers](#trust-tiers--standard-elevated-byod) · [FIM / evented tables](./07-policy-as-code.md) · [Telemetry pipeline](./08-telemetry-and-observability.md)

---

## Model-weights protection — why the lab has this shape

- **In one line** — the guiding threat model (protect the model weights) that explains, top to bottom, why the lab bothers with enclaves, FIM, tiering, and detection-grade controls at all.
- **What it actually is** — a design rationale, not a component. "Protect the weights" is the sentence that, when you keep asking "why?", generates the whole architecture: *why an enclave?* to concentrate weights-adjacent risk; *why FIM?* to notice reads/writes on the cache; *why tiering?* so the enclave can be strict without freezing everyone; *why detection-only?* because $0/Free can't enforce encryption but can still *observe* it. The weights are the lab's designated "asset worth $$$", and asset-centric security is the honest way to reason about controls.
- **Why it's in Project AXIOM** — it is the reason the fictional company is a *frontier-AI* company and not a generic SaaS. Model weights are (a) enormously expensive to produce, (b) trivially copyable once exfiltrated, and (c) irrevocable if leaked — the perfect crown jewel to organize a device-management lab around.
- **Where it sits in the stack** — the apex of the "why" chain, just under [Project AXIOM](#project-axiom--the-frontier-ai-framing) itself. It drives the Enclave (this layer), the policy set ([07](./07-policy-as-code.md)), the telemetry that would catch an incident ([08](./08-telemetry-and-observability.md)), and the IR drills ([10](./10-automation-and-ir.md)).
- **How it works** — the protection is expressed as concentric, observable controls around `/opt/axiom/weights-cache/`:
  - *Where the weights live* is constrained (only `enclave-01` has the path).
  - *Who/what may touch it* is narrowed by Elevated-tier controls (USB blocked, FDE verified, tight lock).
  - *Whether anything touched it* is observed by FIM (`file_events`).
  - *What happens when a control fails* is wired to automation (failing-policy webhook → SOAR-lite receiver → run a saved script), which is **free** end-to-end.
- **Who talks to it, and how** — the protective loop is detection → alert → response, and every hop is a real interaction:

  ```mermaid
  sequenceDiagram
    participant Enc as enclave-01 osqueryd
    participant Fleet
    participant Hook as SOAR-lite receiver
    participant Script as saved script (run-script API)
    Enc->>Fleet: file_events / failing policy on check-in (HTTPS 443)
    Fleet->>Hook: failing-policy webhook (HTTP POST, JSON)
    Hook->>Fleet: POST /api/.../scripts/run (global-admin token)
    Fleet-->>Enc: queue script; agent pulls & executes on next check-in
    Enc->>Fleet: script results
  ```

  Note the asymmetry: Fleet *pushes* a webhook **out** to the receiver (Fleet initiates that HTTP POST), but the *remediation script* still reaches the host by the host **pulling** it — Fleet never opens a socket to osqueryd.
- **Free vs Premium** — **detection** of the weights-cache posture (encryption state, USB devices, file events, OS version) is entirely **free**. **Enforcement** — forcing FileVault/BitLocker/LUKS on with key escrow, blocking the USB device at the OS-management layer, forcing an OS update — is **Premium**. So the lab's weights protection is honestly a *detect-and-remediate-by-script* model, not a *prevent-at-the-kernel* model. The remediation half (script execution + webhooks) is free, which is why Phase 8 auto-remediation works at $0.
- **Gotchas / myth-busting** — do not oversell this. The lab **detects and responds**; it does not cryptographically prevent weights exfiltration, and on Free it cannot enforce disk encryption or escrow keys. The `/opt/axiom/weights-cache/` directory contains no real weights — it is a **canary**, valuable precisely because *any* activity on it is suspicious. And FIM's evented nature (above) means "no FIM alert" is not proof "nothing happened" if the agent was down.
- **See also** — [The High-Trust Enclave](#the-high-trust-enclave--weights-adjacent-access) · [Compliance-as-code](#compliance-as-code) · [Failing-policy webhooks & SOAR-lite](./10-automation-and-ir.md) · [Detection-only policies](./07-policy-as-code.md)

---

## $0 / free-tier-only — and "never silently substitute"

- **In one line** — the hard constraint that the entire lab costs nothing and uses only open-source / free-tier software, paired with the discipline of *documenting* every place a $0 substitute stands in for a paid feature instead of pretending they're equivalent.
- **What it actually is** — two rules that travel together. Rule one: no licenses, no cloud bills, no Fleet Premium — everything runs on one already-owned machine and is rebuildable from Git. Rule two ("never silently substitute"): whenever Fleet Free can't do something the "real" design wants, the lab (a) uses the best free workaround **and** (b) writes down, in the open, exactly what was lost and what Premium would change. The analogy: a recipe that calls for an ingredient you don't have — you can substitute, but an honest cook writes "used yogurt instead of crème fraîche; slightly tangier" in the margin rather than serving it as the original.
- **Why it's in Project AXIOM** — it forces genuine understanding. Anyone can click "enable Teams" on Premium; doing tiering *honestly* on Free means understanding *why* labels don't scope policies and building the self-scoping-SQL workaround. The $0 rule is what makes the lab a learning artifact instead of a product demo. It also keeps the whole thing reproducible by anyone with a spare PC and no budget.
- **Where it sits in the stack** — a cross-cutting constraint over *every* component: it chose VirtualBox over paid hypervisors, mkcert over a public CA ([04](./04-tls-and-pki.md)), Keycloak over Okta ([09](./09-identity-and-access.md)), and a hand-built FastAPI receiver over Entra conditional access ([10](./10-automation-and-ir.md)).
- **How it works** — the substitution ledger is a first-class research output. The Phase 0 brief and ADRs enumerate every Free-vs-Premium boundary the lab touches; each substitution is tagged with what it does and doesn't buy. Representative entries:

  | Wanted (often Premium) | $0 substitute in AXIOM | Honestly lost |
  |---|---|---|
  | Teams (segmentation) | self-scoping policy SQL + markers | server-side isolation; enroll-secret routing |
  | Per-label policy scoping | `platform` field + guarded SQL | one-line label scoping (silently ignored on Free) |
  | CIS benchmark library | hand-authored compliance-matrix.md | vendor-maintained, audited content |
  | FDE / OS-update enforcement | detection-only osquery policies | actual enforcement + key escrow |
  | Vuln scores (CVSS/EPSS/KEV) | bare CVE IDs | severity ranking for SOAR |
  | Conditional access / device trust | custom FastAPI device-trust sketch | real IdP-enforced access gating |
  | ADE/ABM zero-touch (Apple) | manual enroll (deferred Mac) | true zero-touch Apple provisioning |

- **Who talks to it, and how** — this is a *principle*, so its "interactions" are documentation and gates, not packets. Concretely: you (author) → record each substitution in `docs/research/*` and the ADRs → CI ([06](./06-gitops-and-cicd.md)) enforces the free-only posture (e.g. `FLEET_LICENSE_KEY` empty, a check that tier policies contain the guard clause) → the runbooks state, at the point of use, "on Free this is cosmetic / detection-only." The principle "talks" by refusing to let a limitation go unrecorded.
- **Free vs Premium** — the whole entry *is* the Free-vs-Premium map. Free covers a surprising amount end-to-end: Windows MDM manual enroll, Apple MDM server-side, Android MDM (work-profile BYOD + fully-managed + Wipe), script execution, failing-policy webhooks, CVE detection, GitOps/REST/SAML, and filesystem osquery logs + Prometheus `/metrics` (the latter auth-gated by default). Premium is where *segmentation* (Teams, label/secret scoping) and *enforcement* (FDE/OS-update, software deployment, conditional access, CIS library, vuln scores, Apple ADE) live.
- **Gotchas / myth-busting** — the marketing pricing page is **not** authoritative and has shown Free-vs-Premium wrong (e.g. disk-encryption enforcement); the handbook `pricing-features-table.yml` in the repo is the source of truth. The most dangerous silent substitutions are the ones Fleet **accepts without error**: per-label policy scoping and enroll-secret segmentation both *appear* to work on Free and quietly don't. "$0" also does not mean "free of effort" — the free path is frequently *more* work than paying (self-scoping SQL vs a Team), which is the point.
- **See also** — [Everything from Git](#everything-from-git--rebuild-from-cold) · [Trust tiers](#trust-tiers--standard-elevated-byod) · [Compliance-as-code](#compliance-as-code) · [Fleet Free-vs-Premium reference](./03-fleet-core.md) · [Phase 0 research brief](../research/2026-07-20-phase0-1-fleet-brief.md)

---

## "Everything from Git" — rebuild-from-cold

- **In one line** — the rule that the lab's entire desired state lives in a Git repository, such that a cold machine can be restored to a running, enrolled, policy-governed fleet with a clone plus a couple of scripted commands.
- **What it actually is** — infrastructure-as-code taken to its literal conclusion: nothing that matters is clicked, and nothing that matters is undocumented. Compose files, Caddyfile, cloud-init YAML, `unattend.xml`, GitOps policy/query YAML, dashboards-as-JSON, and runbooks all live in Git; the only things *not* in Git are secrets (kept in a gitignored `.env`) and the mkcert CA private key. The analogy: flat-pack furniture with the full instruction booklet — the assembled desk can be lost entirely and rebuilt from the box and the manual.
- **Why it's in Project AXIOM** — three forcing functions. (1) The Windows 11 Enterprise Eval license is **90 days**, so VMs *must* be rebuildable before expiry. (2) The Mac Studio is onboarded later by cloning the repo onto it — the repo *is* the onboarding. (3) It is the ultimate test of "do you actually understand your own stack?" — if a step only exists in your head, rebuild-from-cold exposes it.
- **Where it sits in the stack** — a cross-cutting property enforced primarily through GitOps/CI-CD ([06](./06-gitops-and-cicd.md)) and the provisioning layer ([01](./01-host-hypervisor-virtualization.md)), with `LAB_STATE.md` as the human-readable resume index.
- **How it works** — the repo separates **desired state** (declarative YAML/JSON, committed) from **secrets** (local, gitignored) from **runtime state** (Docker volumes, VM disks — reproducible, not committed). Applying the repo *is* configuring the lab: `docker compose up` builds the control plane; `fleetctl gitops` reconciles Fleet's config to the YAML; `new-linux-vm.ps1` + cloud-init reconstitutes each endpoint. Because `fleetctl gitops` is **declarative with automatic deletion**, the applied YAML is the *complete* desired state — anything not in it is removed, so drift can't accumulate.
- **Who talks to it, and how** — the rebuild is a scripted sequence of components reading Git and reconciling reality to it:

  ```mermaid
  sequenceDiagram
    participant Op as Operator
    participant Git
    participant Compose as docker compose
    participant Fleet
    participant Runner as self-hosted CI runner
    participant VM as VBox + cloud-init
    Op->>Git: git clone <private repo>
    Op->>Compose: docker compose up (reads compose + Caddyfile)
    Compose->>Fleet: Fleet+MySQL+Redis+Caddy come up, migrate DB
    Op->>Git: git push main
    Git->>Runner: webhook triggers self-hosted runner (on LAN)
    Runner->>Fleet: fleetctl gitops -f default.yml -f teams/no-team.yml
    Op->>VM: new-linux-vm.ps1 -> cloud-init installs fleetd
    VM->>Fleet: fleetd enrolls on first boot (HTTPS 443)
  ```

  Two directions matter: the operator and CI *push* declarative config **into** Fleet, while each rebuilt endpoint *pulls itself* into the fleet by enrolling outbound. The self-hosted runner is required because GitHub's cloud runners can't reach the LAN-only Fleet server.
- **Free vs Premium** — GitOps, `fleetctl`, the REST API, webhooks, and SAML are all **free** with a **global-admin** token (the dedicated API-only GitOps role is Premium). So rebuild-from-cold is fully achievable at $0; the only cost is that the token is more privileged than least-privilege would like (noted under [defense-in-depth](#defense-in-depth--least-privilege)).
- **Gotchas / myth-busting** — "everything from Git" explicitly **excludes secrets and the CA key** — those are regenerated or restored out-of-band, never committed. One value is *sacred*: `FLEET_SERVER_PRIVATE_KEY` — it encrypts MDM assets, so regenerating it after MDM is enabled makes existing MDM assets undecryptable; back it up rather than "rebuild" it. And because GitOps auto-deletes anything absent from the applied files, a half-complete YAML set doesn't just "add less" — it can *delete* live config. Always `--dry-run` first.
- **See also** — [$0 / free-tier-only](#-0--free-tier-only--and-never-silently-substitute) · [Zero-touch provisioning](#zero-touch-provisioning) · [Compliance-as-code](#compliance-as-code) · [GitOps declarative apply](./06-gitops-and-cicd.md) · [FLEET_SERVER_PRIVATE_KEY & MDM](./05-mdm.md) · [LAB_STATE resume-from-cold](../../LAB_STATE.md)

---

## Compliance-as-code

- **In one line** — expressing "what compliant looks like" as version-controlled, testable osquery policies and a hand-authored control matrix, so compliance is a diffable artifact rather than a spreadsheet someone updates by hand.
- **What it actually is** — the practice of encoding each compliance control as a Fleet **policy** (a labeled SQL query with a pass/fail contract) checked into Git and applied via GitOps, backed by a `compliance-matrix.md` that maps each control to the framework it satisfies (CIS-aligned), the tier it applies to, and the query that tests it. Analogy: unit tests for your machines — each policy is an assertion ("screen lock ≤ 5 min"), the fleet is the system under test, and the dashboard is the green/red test report.
- **Why it's in Project AXIOM** — it makes the trust model *auditable*. Because Fleet Free has **no built-in CIS benchmark library** (that content ships in the Premium `ee/` tree), the lab hand-maps a compliance matrix — which is more educational anyway, since you learn *why* each control exists rather than importing an opaque pack. It also lets policy changes go through code review and CI like any other code.
- **Where it sits in the stack** — the policy-as-code layer ([07](./07-policy-as-code.md)) applied through GitOps ([06](./06-gitops-and-cicd.md)), consuming trust-tier markers (this layer) and feeding compliance state to dashboards ([08](./08-telemetry-and-observability.md)) and automation ([10](./10-automation-and-ir.md)).
- **How it works** — policies live in the platform-partitioned `lib/` tree (`lib/all|macos|windows|linux`) and are referenced from `default.yml` / `teams/no-team.yml`. Each policy has SQL (returns 1 row = pass), an optional `platform` scope, and — for tier-specific policies — the self-scoping guard clause. `fleetctl gitops` reconciles the live policy set to exactly the YAML. Fleet then schedules the policies; hosts evaluate them on check-in and report pass/fail; the matrix document ties each policy back to a control ID for the audit story.
- **Who talks to it, and how** — authoring and evaluation are separate flows:

  ```mermaid
  flowchart LR
    dev["author: policy SQL in lib/*.yml"] -->|"git push"| ci["CI: dry-run + guard-clause check"]
    ci -->|"fleetctl gitops (global-admin token)"| fleet["Fleet"]
    fleet -->|"scheduled policy on check-in"| host["osqueryd on each host"]
    host -->|"pass/fail rows, HTTPS 443"| fleet
    fleet -->|"compliance state"| dash["Grafana / Fleet UI"]
    fleet -->|"failing-policy webhook"| soar["SOAR-lite (Phase 8)"]
  ```

  The author *pushes* policy definitions into Fleet via GitOps; each host *pulls* the policies and *pushes back* results; Fleet then *pushes* failures out to automation. Three distinct initiators.
- **Free vs Premium** — authoring/evaluating policies, labels, the `platform` field, filesystem logs, and failing-policy webhooks are **free**. Premium adds the **CIS benchmark library** (hence the hand-authored matrix), **per-label/team policy scoping** (hence self-scoping SQL), and **enforcement** actions. Detection-grade compliance is fully free; enforcement-grade is not.
- **Gotchas / myth-busting** — a *green* policy on Free is only meaningful if you know its scope. Because Free ignores label scoping, a naive "enclave-only" policy actually runs fleet-wide — without the guard clause it will **falsely fail** Standard hosts for controls that don't apply to them (false red) or, worse, produce misleading greens. CI enforces that tier policies carry the guard. Also: **CVE detection is free but CVSS/EPSS/KEV scores are Premium**, so a compliance rule must not route severity on score fields it won't have.
- **See also** — [Trust tiers](#trust-tiers--standard-elevated-byod) · [Model-weights protection](#model-weights-protection--why-the-lab-has-this-shape) · [Policy-as-code & the compliance matrix](./07-policy-as-code.md) · [GitOps declarative apply](./06-gitops-and-cicd.md)

---

## Single pane of glass

- **In one line** — the principle that one console (Fleet's UI + API) shows and manages *every* platform in the fleet — Linux, Windows, macOS, Android, iOS — instead of a separate tool per OS.
- **What it actually is** — a consolidation goal. Rather than one tool for Linux osquery, another for Windows GPO/MDM, another for Apple MDM, and yet another for Android, Fleet is the single query, inventory, policy, and MDM surface for all of them. Analogy: the airport control tower — every aircraft type, regardless of make, appears on one radar and takes instructions from one controller, instead of each airline running its own private tower.
- **Why it's in Project AXIOM** — a frontier-AI company with Linux GPU nodes, Windows corp laptops, a Mac, and BYOD phones would otherwise juggle four dashboards. The single-pane goal is also *why Fleet's native Android MDM was chosen over the Headwind MDM fallback*: adopting Headwind would fragment the pane for no benefit, since Fleet's Android MDM is GA and free for the core path.
- **Where it sits in the stack** — the presentation/management apex of the Fleet-core layer ([03](./03-fleet-core.md)), aggregating osquery ([07](./07-policy-as-code.md)), MDM ([05](./05-mdm.md)), and telemetry ([08](./08-telemetry-and-observability.md)) into one view.
- **How it works** — Fleet normalizes wildly different data sources into one host model. osquery gives a uniform SQL schema across Linux/Windows/macOS; Windows MDM (MS-MDM/OMA-DM) and Apple MDM (APNs) and Android MDM (Google's Android Management API) each check in through Fleet; all of it lands in MySQL and is exposed through one UI and one REST API. Caddy fronts all of it on `:443` so there is one hostname (`FLEET_SERVER_URL`) for every platform.
- **Who talks to it, and how** — the pane is the *convergence point*; each platform reaches it by its own protocol, but through one door:

  | Platform | Who initiates | Path | Protocol / payload |
  |---|---|---|---|
  | Linux / Windows / macOS | fleetd (agent) | agent → Caddy:443 → Fleet:1337 | osquery TLS check-in; host vitals, query results |
  | Windows MDM | the device | device → Caddy:443 → Fleet | MS-MDE enroll + OMA-DM sync; SCEP for cert |
  | Apple MDM | Apple → device → Fleet | APNs push wakes device; device polls Fleet:443 | MDM check-in; profiles/commands |
  | Android MDM | Fleet ↔ Google; device ↔ Google | Fleet → Google AMAPI; device managed by Google | Android Management API calls |
  | Human operator | browser / fleetctl | → Caddy:443 → Fleet | HTTPS UI + REST/GitOps |

  Everything funnels to one Fleet instance behind one Caddy hostname — that convergence *is* the single pane.
- **Free vs Premium** — the unified UI/API, osquery across all OSes, Windows MDM, Apple MDM (server-side), and Android MDM (work-profile/fully-managed + Wipe) are all **free**, so the single pane is genuinely achievable at $0. Premium mostly deepens (Teams views, RBAC, ADE) rather than being required for the pane itself.
- **Gotchas / myth-busting** — "single pane" is about *visibility and management*, not *isolation* — seeing all hosts in one place is the opposite of segmenting them, which is why tiering has to be done in policy SQL, not by splitting consoles. Two platforms are not live in the pane yet: **macOS is deferred** (needs the Mac Studio onboarded) and **iOS is simulated** (no device + ABM), so their tiles are authored/CI-validated, not real check-ins. And the Android path is subtly different — Fleet manages Android *through Google's* Android Management API rather than a direct device connection, so "one pane" there means one UI over a Google-mediated backend.
- **See also** — [The reference fleet & its segments](#the-reference-fleet--its-segments) · [MDM across platforms](./05-mdm.md) · [Fleet UI & REST API](./03-fleet-core.md) · [Android MDM verdict / no Headwind](../research/2026-07-20-phase0-1-fleet-brief.md)

---

## Zero-touch provisioning

- **In one line** — bringing a machine from bare image to fully-enrolled, tier-marked Fleet host with **no interactive steps** — the human runs one script, and first boot does the rest.
- **What it actually is** — automated, hands-off onboarding. For Linux it's **cloud-init** driven by a **NoCloud seed ISO** built from Git-tracked `user-data`/`meta-data`; for Windows it's **`unattend.xml`** + a provisioning package (PPKG); for Apple the *true* zero-touch (ADE/ABM) is Premium-and-hardware-gated, so it's a documented runbook rather than a live path. Analogy: a self-assembling flat-pack — you drop the box (attach the seed) and the desk builds itself on power-up, no Allen key in hand.
- **Why it's in Project AXIOM** — it is how "everything from Git" reaches the *endpoints* (not just the server). It's also mandatory in practice: the 90-day Windows Eval license means VMs get rebuilt, and a rebuild that needed manual clicking wouldn't be reproducible. Provisioning is *where the trust tier is born* — cloud-init writes the marker file that the whole tiering model depends on.
- **Where it sits in the stack** — the provisioning layer over the host/hypervisor layer ([01](./01-host-hypervisor-virtualization.md)), producing hosts that enroll into Fleet ([03](./03-fleet-core.md)) trusting the mkcert CA ([04](./04-tls-and-pki.md)).
- **How it works** — VM lifecycle is scripted `VBoxManage` (create disk, NIC, attach seed ISO, boot) from `infra/`/`provisioning/`. The seed's cloud-init, on first boot: installs the Git-tracked fleetd `.deb`, imports the mkcert **rootCA.pem** into the OS trust store *and* (critically) relies on the CA baked into the fleetd package for osqueryd, writes the tier marker (`/etc/axiom/trust-tier`, plus `tier.d/elevated` for the enclave), sets the enroll secret from a gitignored env, and starts fleetd — which enrolls outbound. Windows does the analogous thing via `unattend.xml`/PPKG and a registry tier value.
- **Who talks to it, and how** — one operator command, then a fully autonomous first-boot chain:

  ```mermaid
  sequenceDiagram
    participant Op as Operator
    participant PS as new-linux-vm.ps1 (VBoxManage)
    participant VM as Ubuntu cloud image
    participant CI as cloud-init (NoCloud ISO)
    participant Fleet
    Op->>PS: run script (one command)
    PS->>VM: create/config VM, attach seed ISO, boot
    VM->>CI: first boot executes user-data
    CI->>VM: install fleetd (.deb), trust rootCA, write tier marker, set enroll secret
    VM->>Fleet: fleetd enrolls outbound HTTPS 443 -> Caddy -> Fleet:1337
    Fleet-->>VM: node key issued; host appears in single pane
  ```

  The only inbound-to-VM interaction is the operator's one script; everything after is the VM *pulling itself* into the fleet. Fleet is never told "here is a new host" — the host announces itself by enrolling.
- **Free vs Premium** — Linux cloud-init, Windows `unattend`/PPKG + manual MDM enroll, and fleetd packaging are all **free**. The genuinely zero-*touch* Apple flow (**ADE/ABM/DEP**) is **Premium** *and* needs Apple Business Manager + real hardware — so it's deferred and documented, not demoed. Android BYOD enroll is free but semi-interactive (scan a QR / open a link), so it's "low-touch", not fully zero-touch.
- **Gotchas / myth-busting** — the single most common failure isn't in cloud-init at all: it's the fleetd package's CA. **osqueryd ignores the OS system trust store** (orbit + Fleet Desktop honor it, osqueryd doesn't), so trusting rootCA.pem *inside the VM* is not enough — the CA must be baked into the package via `--fleet-certificate <rootCA.pem>` (the **CA, not the leaf**), or osquery enrollment fails even though the VM "trusts" the cert. There is no `--fleet-tls` flag. Also, `FLEET_SERVER_URL` and the cert SANs must match the hostname/IP the VM dials, or enrollment redirects break.
- **See also** — [Everything from Git](#everything-from-git--rebuild-from-cold) · [BYOD](#byod--bring-your-own-device) · [cloud-init & VirtualBox backend](./01-host-hypervisor-virtualization.md) · [fleetd packaging & the CA gotcha](./04-tls-and-pki.md) · [ADR-0002 VM backend](../adr/0002-vm-backend-virtualbox-cloudinit.md)

---

## BYOD — bring your own device

- **In one line** — the trust tier for *personally-owned* phones (Android now, iOS simulated), where the company manages a work container and a few health signals but deliberately does **not** control the whole device.
- **What it actually is** — a management posture built around a boundary: on a BYOD device the employer gets a **work profile** (a walled-off container for work apps/data) and can read limited compliance signals, but the personal side stays private and the company's reach is minimal. Analogy: a locked filing cabinet the company installs in your home office — they control the cabinet's contents and can repossess it, but they don't get keys to your house.
- **Why it's in Project AXIOM** — a frontier-AI company's staff carry personal phones; the lab needs to show it can pull those into the single pane *without* over-reaching into personal devices, and can do so at $0. It's also the lab's lightest-touch tier, a deliberate contrast to the Enclave's heaviest-touch posture — the two ends of the trust spectrum.
- **Where it sits in the stack** — the Mobile BYOD segment, managed via the MDM layer ([05](./05-mdm.md)) rather than osquery/fleetd (phones don't run fleetd), surfaced in the same single pane ([03](./03-fleet-core.md)).
- **How it works** — Android BYOD uses Fleet's native Android MDM, which sits on **Google's Android Management API**: Fleet connects an Android Enterprise binding (free via any work email / Google Workspace / M365 super-admin), and the user enrolls a **work profile** by scanning a QR / opening a link. The work profile is created and governed through Google; Fleet issues policy/commands via the API. Personal Apple BYOD enroll (account-driven, landed in Fleet 4.88.0) is the Apple analog but needs real Apple hardware, so iOS here is **simulated**.
- **Who talks to it, and how** — unlike a laptop, a BYOD phone is managed *through Google*, not by a direct outbound osquery check-in:

  ```mermaid
  sequenceDiagram
    participant User
    participant Phone as android-byod (work profile)
    participant Google as Android Management API
    participant Fleet
    Fleet->>Google: bind Android Enterprise (free subscription)
    User->>Phone: scan QR / open enroll link
    Phone->>Google: provision work profile, register device
    Fleet->>Google: push policy / Wipe command
    Google->>Phone: apply policy to work profile
    Phone->>Google: compliance status
    Google-->>Fleet: device state -> single pane
  ```

  The key directional difference from the rest of the fleet: **Google mediates**. Fleet talks to Google's API, Google talks to the phone; there is no fleetd and no direct device→Fleet osquery socket.
- **Free vs Premium** — Android MDM is **GA and free** for the core path: work-profile BYOD, fully-managed enrollment, and **Wipe** (company-owned) as of 4.87. Premium adds only `Lock` and `Clear passcode`. So a SOAR-lite response can *wipe* a lost BYOD device at $0, but not remotely *lock* it. Personal Apple BYOD enroll is free server-side but needs hardware (deferred).
- **Gotchas / myth-busting** — the device must be **Play Protect certified**, which means a **Google-Play-enabled Android Studio AVD (not an AOSP image)** or a real phone; an AOSP emulator will *not* enroll — a common lab dead-end. BYOD is a *lighter* touch than corporate management by design: don't expect full-device controls or osquery-grade telemetry from a work profile. And the Headwind MDM fallback is **explicitly rejected** — Fleet's native Android MDM is GA and free, so there's no reason to fragment the single pane.
- **See also** — [Trust tiers](#trust-tiers--standard-elevated-byod) · [Single pane of glass](#single-pane-of-glass) · [Zero-touch provisioning](#zero-touch-provisioning) · [Android & Apple MDM](./05-mdm.md) · [SOAR-lite remote actions](./10-automation-and-ir.md)

---

## Defense-in-depth & least privilege

- **In one line** — two classic security principles the lab tries to honor: stack independent layers so no single failure is fatal (defense-in-depth), and grant each actor only the access it needs (least privilege) — while being honest about where Fleet Free forces a compromise.
- **What it actually is** — *defense-in-depth* means the weights aren't guarded by one control but by a series (network trust, TLS, CA validation, enroll secret, tier policies, FIM, automated response), each of which an attacker must defeat. *Least privilege* means components and credentials are scoped down: the Fleet **server container** runs non-root as uid 100/gid 101 (which is why the `fleet-init` sidecar must chown its data volumes on first boot), VMs trust only the lab's own CA, and the enclave gets *more* controls, not more access — while the endpoint agent is the honest exception: orbit/osqueryd run as **root** (SYSTEM on Windows) because osquery needs it for privileged tables and the `file_events` FIM, a necessary privilege named rather than hidden. Analogy for depth: a castle with a moat, a wall, a portcullis, and a keep — breaching one buys you the next obstacle, not the throne.
- **Why it's in Project AXIOM** — protecting model weights is a layered problem; any single control ($0 detection-only FDE, say) is defeatable, so the lab leans on the *combination*. And demonstrating least privilege is part of the portfolio story — even where Free forces an over-privileged choice, naming it is the point.
- **Where it sits in the stack** — cross-cutting; it's the lens you apply to *every* layer, from the host firewall ([01](./01-host-hypervisor-virtualization.md)) through TLS/PKI ([04](./04-tls-and-pki.md)) to policy ([07](./07-policy-as-code.md)) and automation ([10](./10-automation-and-ir.md)).
- **How it works** — the concentric layers around a managed host, roughly outermost to innermost:

  | Layer | Control | What it stops on its own |
  |---|---|---|
  | Network | LAN-only Fleet; self-hosted runner | off-LAN access to the control plane |
  | Transport | Caddy terminates TLS with an mkcert leaf | passive eavesdropping / MITM |
  | Trust anchor | rootCA.pem baked into fleetd (osqueryd) + OS store (orbit) | connecting to an impostor Fleet |
  | Identity | enroll secret → node key | unauthorized enrollment |
  | Posture | tier policies (self-scoping SQL) | non-compliant hosts going unnoticed |
  | Integrity | FIM `file_events` on the weights cache | silent tampering/access on the crown jewels |
  | Response | failing-policy webhook → run-script | a detected failure sitting unremediated |

  Least privilege shows up as: the Fleet **server container** non-root (uid 100/gid 101; the `fleet-init` sidecar chowns its volumes to match), a dedicated (if cosmetic-on-Free) enclave enroll secret, the enclave getting stricter *controls* rather than broader *reach*, and `$FLEET_SECRET_*`-prefixed values encrypted server-side and injected only at delivery.
- **Who talks to it, and how** — each layer is a *distinct* interaction an attacker would have to individually beat: dial Fleet (blocked off-LAN) → present valid TLS (blocked without the CA) → enroll (blocked without the secret) → pass policies (failure is logged) → touch the weights cache (FIM event fires) → survive automated response (script runs). No single conversation gets you from "on the network" to "weights in hand"; that chaining *is* defense-in-depth.
- **Free vs Premium** — most depth layers are **free** (TLS, CA, enroll secret, policies, FIM, webhooks, scripts). The notable least-privilege **compromise on Free**: `fleetctl gitops` and the API require a **global-admin** token because the dedicated **API-only "GitOps" role is Premium**. So the CI credential that reconciles config is *more* privileged than least-privilege wants — a real, documented Free limitation, not an oversight.
- **Gotchas / myth-busting** — depth is not the same as *enforcement*: several layers here are **detection-only** on Free (FDE/OS-update posture, FIM), so they *notice* rather than *prevent* — the response layer is what closes the loop, and it's free. Least privilege has two honest asterisks in this lab: the **global-admin GitOps token** (Premium role would fix it) and the **host-local tier marker** a host could tamper with to self-downgrade (Premium server-side teams would fix it). Both are called out plainly rather than hidden — which is itself the "never silently substitute" principle applied to security posture.
- **See also** — [Trust tiers](#trust-tiers--standard-elevated-byod) · [Model-weights protection](#model-weights-protection--why-the-lab-has-this-shape) · [$0 / free-tier-only](#-0--free-tier-only--and-never-silently-substitute) · [TLS/PKI & the CA chain](./04-tls-and-pki.md) · [Enroll secrets & node keys](./03-fleet-core.md) · [SOAR-lite automation](./10-automation-and-ir.md)

---

> **Layer complete.** These twelve concepts are the connective tissue: [Project AXIOM](#project-axiom--the-frontier-ai-framing) sets the stakes, [the fleet & segments](#the-reference-fleet--its-segments) and [trust tiers](#trust-tiers--standard-elevated-byod) shape who's managed and how strictly, [the Enclave](#the-high-trust-enclave--weights-adjacent-access) and [weights protection](#model-weights-protection--why-the-lab-has-this-shape) define the crown jewels, and the four principles — [$0](#-0--free-tier-only--and-never-silently-substitute), [everything-from-Git](#everything-from-git--rebuild-from-cold), [single-pane](#single-pane-of-glass), [zero-touch](#zero-touch-provisioning) — plus [compliance-as-code](#compliance-as-code), [BYOD](#byod--bring-your-own-device), and [defense-in-depth](#defense-in-depth--least-privilege) constrain every component in files [01](./01-host-hypervisor-virtualization.md)–[10](./10-automation-and-ir.md). Back to the [Encyclopedia index](./README.md).
