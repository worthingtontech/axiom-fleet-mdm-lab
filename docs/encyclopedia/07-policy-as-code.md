# 📜 Policy-as-Code — osquery, Policies & Compliance
> Part of the **[Project AXIOM Encyclopedia](./README.md)** · Layer: Policy-as-Code (osquery · Policies · Compliance). How AXIOM turns "is this host compliant?" into version-controlled osquery SQL that Fleet evaluates, and how a real-world change becomes a red dot and a fired webhook.

This layer is where the lab's *opinions* live. Everything below it — the [Fleet server](./03-fleet-core.md), [TLS/PKI](./04-tls-and-pki.md), [GitOps](./06-gitops-and-cicd.md) — exists to safely deliver these opinions to endpoints and read the answers back. The unit of truth is an **osquery SQL query**: a scheduled query *collects* facts, a policy *judges* them pass/fail, a label *groups* hosts, and a webhook *reacts*. A running theme you should internalize before reading on: **every interaction here is host-initiated pull** — Fleet never reaches into a host; fleetd on each VM phones home over HTTPS and asks "anything for me?" The one deliberate exception is the outbound policy-automation webhook, called out in its own entry. A second running theme: this is **Fleet Free**, so several conveniences you'd reach for (teams, per-label policy scoping, the built-in CIS library, the "critical" flag) are Premium — and [ADR-0003](../adr/0003-free-tier-trust-tiering.md) is the load-bearing correction that makes honest tiering work anyway.

---

## 1. osquery tables & SQL — how a question becomes an answer

- **In one line** — osquery exposes the entire operating system as a live SQL database, so a `SELECT` is how any question about a host becomes a row of answer.
- **What it actually is** — `osqueryd`, an open-source agent (bundled inside [fleetd](./03-fleet-core.md)) that embeds a SQLite engine in front of hundreds of **virtual tables**. A virtual table like `processes`, `users`, `disk_encryption`, `os_version`, `bitlocker_info`, `interface_addresses`, or `file` is **not stored data** — it is a code generator that calls OS APIs *at query time* and materialises rows on demand. Analogy: it is a database whose tables are answered by asking the kernel the instant you run the query, not by reading a saved snapshot. A subset are **evented tables** (`file_events`, `ntfs_journal_events`, `process_events`) that instead drain a buffer filled asynchronously by a publisher.
- **Why it's in Project AXIOM** — it is the single portable query language spanning `gpu-node-1/2`, `ml-workstation`, `enclave-01` (Ubuntu 24.04), `corp-win-01/02` (Windows 11), and eventually `mac-studio` (macOS). One SQL dialect describes disk encryption on all of them. Every policy, scheduled query, live query, label, FIM check, and compliance control in this lab bottoms out in an osquery `SELECT`.
- **Where it sits in the stack** — the **agent layer** on each endpoint. Below it is the raw OS (procfs, WMI, FSEvents, the Windows registry). Above it and beside it: `orbit` (the fleetd supervisor that starts/stops `osqueryd` and hands it its flags), [Fleet Desktop](./03-fleet-core.md), and the [Fleet server](./03-fleet-core.md) that sends the SQL.
- **How it works** — SQL is parsed by SQLite; the planner routes each table reference to its generator; the generator calls the platform API and returns rows; joins/filters run in SQLite. Some tables are **constraint-required** (`file` returns nothing without a `path`/`directory`; `WHERE pid = …` is needed for many). Table availability is fixed by the **osquery version baked into fleetd**, so what you can query is a function of your pinned agent, not the Fleet server.
- **Who talks to it, and how** — nothing external talks to `osqueryd` directly; it is a **pull client**. The [Fleet server](./03-fleet-core.md) never opens a socket to a host. Instead `osqueryd` (via `orbit`) initiates outbound **HTTPS POST** to the external `FLEET_SERVER_URL` → **[Caddy](./04-tls-and-pki.md):443** terminates TLS → forwards plain HTTP to **fleet:1337**, hitting these endpoints:

  | Endpoint | Who calls | Carries |
  |---|---|---|
  | `POST /api/v1/osquery/enroll` | osqueryd once | enroll secret → gets a `node_key` |
  | `POST /api/v1/osquery/config` | osqueryd every `config_tls_refresh` | the schedule, flags, `file_paths` (Fleet agent options) |
  | `POST /api/v1/osquery/distributed/read` | osqueryd every `distributed_interval` (~10 s) | asks "any live/policy/label queries?" |
  | `POST /api/v1/osquery/distributed/write` | osqueryd | the result **rows** for those queries |
  | `POST /api/v1/osquery/log` | osqueryd | scheduled-query results / status logs |

  ```mermaid
  sequenceDiagram
    participant OS as OS APIs (kernel/WMI)
    participant OSQ as osqueryd (in fleetd)
    participant CAD as Caddy :443 (TLS)
    participant FLT as fleet :1337
    OSQ->>CAD: HTTPS POST /distributed/read (node_key)
    CAD->>FLT: plain HTTP (proxied)
    FLT-->>OSQ: {queries: {policy_42: "SELECT 1 FROM disk_encryption WHERE encrypted=1"}}
    OSQ->>OS: run generator for disk_encryption
    OS-->>OSQ: 1 row
    OSQ->>CAD: HTTPS POST /distributed/write (rows)
    CAD->>FLT: plain HTTP
    FLT->>FLT: interpret rows → pass/fail, write to MySQL
  ```
- **Free vs Premium** — osquery is fully open-source; **every table is available on Fleet Free**. No table is paywalled.
- **Gotchas / myth-busting** — (1) A query is a **point-in-time snapshot**, not a subscription — re-running it re-asks the OS. (2) Many tables are **empty without a constraint**; a bare `SELECT * FROM file` returns nothing by design. (3) Tables are **platform-specific**: `bitlocker_info` is Windows-only, `mounts` is *nix, `disk_encryption` spans platforms but reports differently — always pair OS-specific policies with the free `platform` field. (4) `osqueryd` does **not** use the OS system trust store, which is why fleetd packages must bake in `rootCA.pem` — see [TLS/PKI](./04-tls-and-pki.md).
- **See also** — [Fleet policy](#2-fleet-policy--passfail-semantics-1-row--pass) · [osquery intervals](#12-osquery-intervals--how-fast-a-policy-flips-redgreen) · [fleetd / the agent](./03-fleet-core.md) · [Fleet server core](./03-fleet-core.md)

---

## 2. Fleet policy — pass/fail semantics (1 row = pass)

- **In one line** — a Fleet **policy** is a yes/no compliance question expressed as an osquery query, where **returning ≥1 row = pass (compliant)** and **returning 0 rows = fail**.
- **What it actually is** — a saved osquery `SELECT` plus a boolean interpretation and a resolution note. It differs from a scheduled query in *what Fleet does with the rows*: a scheduled query stores them as telemetry; a policy collapses "did any rows come back?" into a per-host **pass / fail / no-response** verdict. Analogy: a policy is a query wearing a traffic light.
- **Why it's in Project AXIOM** — it is the atomic unit of Phase 4. FDE-present, screen-lock ≤ 5 min, no removable storage, OS-is-up-to-date, firewall-on, and the Enclave FIM-canary control are each **one policy**. Green/red per host is the lab's compliance signal, surfaced in the dashboard (Phase 5) and fed to automations (Phase 8).
- **Where it sits in the stack** — squarely in this layer. Below: the [osquery tables](#1-osquery-tables--sql--how-a-question-becomes-an-answer) that answer the query. Beside: [labels](#4-labels-dynamic--manual--grouping-not-policy-scope-on-free) (grouping) and [scheduled queries](#3-scheduled-queries--query-packs--telemetry-vs-policy) (telemetry). Above: the dashboard, [compliance-matrix.md](#8-compliance-matrixmd--the-hand-mapped-free-tier-answer), and [policy automations](#9-critical-flag--policy-automations-webhooks). Policy definitions are stored in **MySQL** and delivered as YAML via [GitOps](./06-gitops-and-cicd.md).
- **How it works** — Fleet tags a query as a policy and schedules it at `FLEET_OSQUERY_POLICY_UPDATE_INTERVAL` (default **1 hour**). When a host's `distributed/read` arrives and the interval has elapsed, the server includes the policy SQL in the response. osquery runs it and `distributed/write`s the rows. The server counts rows: **≥1 → pass**, **0 → fail**, and **null/no-response** if the host hasn't answered yet (rendered as `—`, distinct from fail). Membership is stored and rolled up into pass/fail counts.
- **Who talks to it, and how** — identical **host-pull** path as osquery tables: fleetd → HTTPS → [Caddy:443](./04-tls-and-pki.md) → fleet:1337, over `/distributed/read` (SQL out) and `/distributed/write` (rows in). Fleet then writes verdicts to **MySQL** and, if a [policy automation](#9-critical-flag--policy-automations-webhooks) is attached, may later initiate an **outbound** webhook. Authors talk to it via [GitOps](./06-gitops-and-cicd.md) (`fleetctl gitops`) or the UI/REST API with a global-admin token.
- **Free vs Premium** — writing and evaluating policies is **Free**. Premium adds: scoping a policy to a **team** or to **labels** (`labels_include_any/all`, `labels_exclude_any`), the **"critical"** flag, and **calendar-event** automations. On Free a policy runs on **every enrolled host** — the fact that drives entry #6.
- **Gotchas / myth-busting** — (1) **The polarity is inverted from intuition.** You must write the query so a *healthy* host returns a row. `SELECT 1 FROM disk_encryption WHERE encrypted = 1` passes an encrypted host; a query that "returns the bad thing" would mark violators as *compliant*. (2) A policy must be a **single query** that returns rows (no multi-statement scripts). (3) **No-response ≠ fail** — a freshly enrolled or offline host shows `—`, not red. (4) On Free, a `labels_include_any` key in your policy YAML is **silently ignored** ([ADR-0003](../adr/0003-free-tier-trust-tiering.md)) — the policy still runs everywhere.
- **See also** — [self-scoping policy SQL](#6-self-scoping-policy-sql--the-enclave-tiering-trick-adr-0003) · [osquery intervals](#12-osquery-intervals--how-fast-a-policy-flips-redgreen) · [critical flag & automations](#9-critical-flag--policy-automations-webhooks) · [GitOps policy-as-code](./06-gitops-and-cicd.md)

---

## 3. scheduled queries & query packs — telemetry vs policy

- **In one line** — a **scheduled query** runs an osquery `SELECT` on a fixed cadence and ships the *rows themselves* to a log destination for trend/inventory/hunting — data collection, not a pass/fail verdict.
- **What it actually is** — a query with an `interval` (seconds) whose results are logged rather than judged. **Query packs** are the older grouping construct for scheduled queries; they were **removed from the Fleet UI** (kept API-only for back-compat) and are superseded by individual scheduled queries that can be **targeted by label**. Analogy: a policy is a smoke *alarm* (binary); a scheduled query is a temperature *logger* (a time series).
- **Why it's in Project AXIOM** — Phase 5 telemetry. Scheduled queries collect `processes`, `listening_ports`, `logged_in_users`, `installed software`, and the Enclave's `file_events` (FIM) stream, which [Vector](./08-telemetry-and-observability.md) forwards into Loki/Grafana for dashboards and hunting.
- **Where it sits in the stack** — the seam between this layer and [Telemetry](./08-telemetry-and-observability.md). Below: osquery tables. Beside: policies (same SQL substrate, different disposition). Above: the log pipeline (`/logs` → Vector → Loki).
- **How it works** — the schedule ships to the host inside **Fleet agent options** (the osquery config); osquery runs each query at its interval and **POSTs results to `/api/v1/osquery/log`**; Fleet hands them to the configured log plugin. In this lab that plugin is `filesystem` (`FLEET_FILESYSTEM_RESULT_LOG_FILE=/logs/osqueryd.results.log`), which [Vector](./08-telemetry-and-observability.md) tails. Results can be **snapshot** (full current state each run) or **differential** (only what changed).
- **Who talks to it, and how** — pull for config, push for results: osquery `POST /api/v1/osquery/config` fetches the schedule; osquery `POST /api/v1/osquery/log` ships rows — both via fleetd → [Caddy:443](./04-tls-and-pki.md) → fleet:1337. Fleet then writes to `/logs`; the read side is entirely downstream in [Telemetry](./08-telemetry-and-observability.md).
- **Free vs Premium** — scheduled queries are **Free**, and crucially **query targeting by label is Free** — so the Enclave FIM query can be scoped to the `enclave` label at $0 even though *policies* can't be label-scoped. Query packs are deprecated but free.
- **Gotchas / myth-busting** — (1) Don't confuse the two dispositions: putting compliance logic in a scheduled query gives you a log line, not a red dot. (2) **Packs are gone from the UI** — author scheduled queries instead. (3) Interval is in **seconds**; a tight interval on a heavy query (e.g. full `processes` every 10 s) is a real load footgun. (4) Differential logging needs osquery to retain prior state (`--events`/log retention); a restarted host re-emits.
- **See also** — [FIM & the weights-cache canary](#10-file-integrity-monitoring-fim--the-weights-cache-canary) · [labels](#4-labels-dynamic--manual--grouping-not-policy-scope-on-free) · [Telemetry pipeline](./08-telemetry-and-observability.md) · [osquery intervals](#12-osquery-intervals--how-fast-a-policy-flips-redgreen)

---

## 4. labels (dynamic / manual) — grouping, NOT policy scope on Free

- **In one line** — a **label** is a host group defined either by an osquery query (**dynamic**) or by an explicit host list (**manual**); on Fleet Free it groups and targets *queries*, but it does **not** scope *policies*.
- **What it actually is** — a **dynamic label** is itself an osquery `SELECT`; a host is a member iff the query returns a row on it (e.g. `SELECT 1 FROM file WHERE path='/etc/axiom/tier.d/elevated'` defines the `enclave` label). A **manual label** is a hand-picked host set. Fleet also ships **built-in** labels (per-platform, "All hosts", MDM-enrolled).
- **Why it's in Project AXIOM** — the `enclave` label drives Phase 5 **dashboard filtering** and **targets the FIM scheduled query** to `enclave-01`. Platform labels group Linux vs Windows nodes for humans. Labels are the lab's cheap, free grouping primitive.
- **Where it sits in the stack** — beside policies and scheduled queries in this layer; membership is computed by the [Fleet server](./03-fleet-core.md) from osquery answers and stored in MySQL.
- **How it works** — Fleet includes each dynamic label's query in `distributed/read`; osquery returns a row (member) or nothing (not); the server updates membership. Manual labels are static assignments. Scheduled/live queries can then be **targeted at a label** so only members run them.
- **Who talks to it, and how** — same host-pull path (`/distributed/read` → `/distributed/write`); membership evaluation is **server-side** in Fleet against the returned rows. Analysts reference labels in [GitOps](./06-gitops-and-cicd.md) YAML and the UI.
- **Free vs Premium** — **all label *types* are Free.** What is **Premium** is using a label to **scope a policy, a config profile, or software** (`labels_include_any/all`, `labels_exclude_any`). **Query targeting** by label is Free.
- **Gotchas / myth-busting** — **THE central correction of this layer:** *labels ≠ policy scope on Free.* Per-label policy scoping is Premium and **silently ignored** on Free — the policy simply evaluates on every host, no error, producing false-green/false-red ([ADR-0003](../adr/0003-free-tier-trust-tiering.md)). Also: dynamic labels re-evaluate on their own cadence (not instant), and a manual label won't auto-include a newly matching host.
- **See also** — [self-scoping policy SQL](#6-self-scoping-policy-sql--the-enclave-tiering-trick-adr-0003) · [teams (Premium)](#5-teams-premium--and-why-we-dont-have-them) · [scheduled queries](#3-scheduled-queries--query-packs--telemetry-vs-policy) · [ADR-0003](../adr/0003-free-tier-trust-tiering.md)

---

## 5. teams (Premium) — and why we don't have them

- **In one line** — **teams** are Fleet's Premium host-segmentation unit — each team owns its own policies, profiles, agent options, and enroll-secret routing — and Project AXIOM has **none**: every host lives in the single global **"No team."**
- **What it actually is** — a first-class scoping boundary. On Premium, an **enroll secret routes a host into a team at enrollment**, and policies/profiles/scripts attach to that team so they apply only to its members. It is the clean, server-authoritative way to say "the Enclave gets stricter rules." (Terminology note: **v4.82.0 renamed "teams"→"fleets" and "queries"→"reports"** across the UI, API, CLI, and GitOps, and deprecated `no-team.yml` in favour of `unassigned.yml`. Our pinned **v4.89.1** carries these new names, but the old ones still resolve as **deprecated aliases** — so AXIOM keeps the familiar `teams/no-team.yml` layout. It is the same construct with the same Premium gating; only the label on the tin changed.)
- **Why it's in Project AXIOM** — as the **thing we emulate, not the thing we have.** Constraint #1 is $0/Free, so teams are off the table; documenting them frames the [self-scoping SQL](#6-self-scoping-policy-sql--the-enclave-tiering-trick-adr-0003) workaround and the Premium upgrade path.
- **Where it sits in the stack** — it *would* sit at the [Fleet server](./03-fleet-core.md) scoping layer, above policies/labels. In AXIOM its slot is filled by **self-scoping policy SQL + the free `platform` field + provisioned tier markers**.
- **How it works (on Premium)** — a secret maps to a team on enroll; the host's team membership is server-side and tamper-resistant; team-scoped policies never even ship to non-members. Team-level agent options let you enable, say, FIM flags for just the Enclave team.
- **Who talks to it, and how** — not applicable at runtime in this lab. Conceptually: enrollment (`/api/v1/osquery/enroll`) carries the secret that *would* select the team; on Free that secret is accepted but selects nothing.
- **Free vs Premium** — **Premium-only.** On **Free**, all hosts land in global "No team" regardless of which enroll secret they used, **no query reveals which secret a host used**, and secrets carry **zero segmentation power** — a long-documented Free-tier limitation, not a config you can flip.
- **Gotchas / myth-busting** — the seductive-but-wrong plan is "multiple enroll secrets = teams for free." Multiple secrets *are* allowed on Free (good rotation hygiene) but they do **not** segment hosts. AXIOM keeps a distinct `enclave-01` secret purely as a **Premium-ready, cosmetic** artifact so the upgrade is a config change, not a redesign — the runbooks say so plainly.
- **See also** — [self-scoping policy SQL](#6-self-scoping-policy-sql--the-enclave-tiering-trick-adr-0003) · [labels](#4-labels-dynamic--manual--grouping-not-policy-scope-on-free) · [enroll secrets & GitOps](./06-gitops-and-cicd.md) · [ADR-0003](../adr/0003-free-tier-trust-tiering.md)

---

## 6. self-scoping policy SQL — the Enclave tiering trick (ADR-0003)

- **In one line** — the lab's biggest plan change: because a Free policy runs on *all* hosts, each tier-specific policy is written to **auto-pass out-of-scope hosts** and only meaningfully evaluate in-scope ones, faking policy scope without teams or label scoping.
- **What it actually is** — a SQL idiom keyed on a **provisioned, host-intrinsic tier marker**. Canonical shape:
  ```sql
  -- Elevated-only control. Returns a row (PASS) when the host is NOT elevated-tier
  -- OR it satisfies the control. Returns 0 rows (FAIL) only for an in-scope host
  -- that actually violates the control.
  SELECT 1 WHERE
        NOT EXISTS (SELECT 1 FROM file
                    WHERE path = '/etc/axiom/tier.d/elevated' AND type = 'regular')
     OR EXISTS ( /* the real check, e.g. screen-lock <= 5 min */ );
  ```
  The marker is `/etc/axiom/trust-tier` (`standard|elevated`) plus `/etc/axiom/tier.d/elevated` on Linux/macOS, `HKLM\SOFTWARE\Axiom\TrustTier` on Windows, and the Enclave canary path `/opt/axiom/weights-cache/` (which only `enclave-01` has).
- **Why it's in Project AXIOM** — to give `enclave-01` genuinely stricter, **honest** compliance (FDE verified, screen-lock ≤ 5 min, no removable media, FIM canary) at $0, without falsely marking the Standard Ubuntu/Windows nodes non-compliant for controls that don't apply to them.
- **Where it sits in the stack** — the **policy-content** sublayer, composed with two free scoping primitives: the built-in **`platform` field** (narrows OS-specific checks) and **label-targeted queries** (for Enclave *telemetry*). The markers themselves are provisioned upstream by [cloud-init / unattend](./01-host-hypervisor-virtualization.md) as part of the same Git-tracked build that installs fleetd — so tier membership is **declared in code**.
- **How it works** — remember **1 row = pass**. The `(out-of-scope) OR (compliant)` guard makes every non-Enclave host return a row (always green for that policy), so the policy can only go red on a non-compliant Enclave host. The mirror idiom `(in-scope) AND (compliant)` is used where a control must **fail closed** if the marker is missing.

  ```mermaid
  flowchart TD
    A[Policy runs on ALL hosts - Free] --> B{marker /etc/axiom/tier.d/elevated present?}
    B -- no, e.g. gpu-node-1 --> P[guard true -> return row -> PASS]
    B -- yes, enclave-01 --> C{control satisfied?}
    C -- yes --> P
    C -- no --> F[0 rows -> FAIL - red only here]
  ```
- **Who talks to it, and how** — same host-pull evaluation as any policy (`/distributed/read` → osquery reads the marker via the `file`/`registry` table → `/distributed/write`). The **markers are written once at provisioning time** by cloud-init (Linux/macOS) or unattend (Windows) — see [Host & Virtualization](./01-host-hypervisor-virtualization.md) and [GitOps](./06-gitops-and-cicd.md). No component pushes tier state at runtime.
- **Free vs Premium** — this idiom **exists only because** team/label policy scoping is Premium. On **Premium** you'd create a "High-Trust Enclave" team, route the Enclave secret to it, and **delete every guard clause** — the SQL simplifies mechanically; it is not a rewrite.
- **Gotchas / myth-busting** — (1) The marker is **host-local**, so a host could self-downgrade by deleting its own marker; acceptable for a lab, mitigated by cross-checking intrinsic signals (hostname prefix `enclave-*`, canary-path presence) and noted as a known limitation. (2) Tier policies are **verbose** — every one carries a guard; a CI check asserts the guard is present. (3) Do **not** try to substitute `labels_include_any` here — it's silently ignored on Free ([ADR-0003](../adr/0003-free-tier-trust-tiering.md)).
- **See also** — [Fleet policy semantics](#2-fleet-policy--passfail-semantics-1-row--pass) · [labels](#4-labels-dynamic--manual--grouping-not-policy-scope-on-free) · [teams (Premium)](#5-teams-premium--and-why-we-dont-have-them) · [Trust model](./11-concepts-and-trust-model.md) · [ADR-0003](../adr/0003-free-tier-trust-tiering.md)

---

## 7. CIS Benchmarks & controls

- **In one line** — **CIS Benchmarks** are consensus, per-OS hardening baselines (numbered controls); Fleet's *built-in* CIS policy library is Premium, so AXIOM **hand-authors** CIS-aligned osquery policies for the controls it cares about.
- **What it actually is** — the Center for Internet Security publishes benchmark documents (e.g. "CIS Ubuntu 24.04", "CIS Microsoft Windows 11 Enterprise") as numbered, tiered (Level 1/Level 2) recommendations like "ensure a screen-lock timeout is configured." Fleet **Premium** ships these pre-written as a policy library in `ee/`; **Free does not**.
- **Why it's in Project AXIOM** — the lab wants a credible compliance story. Since the library is paywalled, Phase 4 **hand-maps a chosen subset** of CIS controls to osquery policy queries and records coverage in [compliance-matrix.md](#8-compliance-matrixmd--the-hand-mapped-free-tier-answer).
- **Where it sits in the stack** — the **policy-content** sublayer: CIS is the *source* of what a policy should check; the [Fleet policy](#2-fleet-policy--passfail-semantics-1-row--pass) is the *mechanism* that checks it.
- **How it works** — each in-scope CIS control becomes one hand-written policy query (often paired with the `platform` field and, for Enclave-only controls, a [self-scoping guard](#6-self-scoping-policy-sql--the-enclave-tiering-trick-adr-0003)). The queries are stored as YAML under `lib/` (platform-partitioned) and applied via [GitOps](./06-gitops-and-cicd.md).
- **Who talks to it, and how** — no runtime component "is" CIS. The controls flow as ordinary policies down the host-pull path; the mapping between "CIS 1.1.1" and "policy X" lives in the [compliance matrix](#8-compliance-matrixmd--the-hand-mapped-free-tier-answer) and policy descriptions, consumed by humans and CI.
- **Free vs Premium** — **built-in CIS library = Premium.** Hand-authoring CIS-aligned policies = **Free**. Note this is *policy content*, distinct from disk-encryption/OS-update **enforcement**, which is also Premium — so several CIS controls become **detection-only** in this lab.
- **Gotchas / myth-busting** — a hand-mapped subset is **not** a certified CIS benchmark; don't claim full CIS coverage. Document exactly which controls are covered, which are detection-only (no enforcement on Free), and which are out of scope.
- **See also** — [compliance-matrix.md](#8-compliance-matrixmd--the-hand-mapped-free-tier-answer) · [MITRE ATT&CK alignment](#11-mitre-attck-alignment) · [Fleet policy](#2-fleet-policy--passfail-semantics-1-row--pass) · [GitOps `lib/`](./06-gitops-and-cicd.md)

---

## 8. compliance-matrix.md — the hand-mapped free-tier answer

- **In one line** — a Git-tracked Markdown table that maps each control (CIS / MITRE / internal) → the exact AXIOM policy that satisfies it → its Free-tier status (detect vs enforce), serving as the lab's *compliance report* since built-in reporting is Premium.
- **What it actually is** — a curated document (not a runtime component). Roughly: `Control ID | Description | AXIOM policy name | platform/tier scope | Free capability (detect/enforce/none) | notes`. It is the $0 stand-in for a compliance dashboard and for the built-in CIS mapping.
- **Why it's in Project AXIOM** — because on Free there is **no** built-in CIS library and **no** premium compliance reporting; the matrix is where "are we compliant, and against what?" is answered honestly, including a candid **Free-vs-Premium delta column** (e.g. "FDE: detected via osquery, *enforcement/escrow is Premium*").
- **Where it sits in the stack** — documentation adjacent to [GitOps](./06-gitops-and-cicd.md); it references the same policy names that live in `lib/`.
- **How it works** — maintained by hand; a **CI check** can cross-validate that every policy name cited in the matrix actually exists in the applied YAML (and vice-versa), preventing drift between the report and reality.
- **Who talks to it, and how** — humans (portfolio reviewers, the operator) read it; **CI** reads it during [GitOps](./06-gitops-and-cicd.md) validation. It has no network interactions and no host contact.
- **Free vs Premium** — the *need* for it is created by Premium gating (CIS library + compliance UI). The document itself is $0. Where Premium would auto-generate this, Free hand-maintains it.
- **Gotchas / myth-busting** — its only failure mode is **staleness**: if a policy is renamed/deleted via GitOps but the matrix isn't updated, the report lies. Guard with the CI cross-check. It is a *claim of coverage*, not evidence of enforcement.
- **See also** — [CIS Benchmarks](#7-cis-benchmarks--controls) · [MITRE ATT&CK alignment](#11-mitre-attck-alignment) · [GitOps / CI](./06-gitops-and-cicd.md) · [Trust model](./11-concepts-and-trust-model.md)

---

## 9. critical flag & policy automations (webhooks)

- **In one line** — **policy automations** make Fleet take action when a policy is *newly failing* — fire an outbound **webhook** or **run a script**; the **"critical"** flag that would prioritise a policy is **Premium**, but the automations themselves are **Free**.
- **What it actually is** — a server-side reaction bound to a policy. Two free flavours: a **webhook** (Fleet POSTs JSON to a URL) and **run-script** (a native automation since Fleet **v4.58.0** that queues a saved script on the failing host — [script execution is Free](./10-automation-and-ir.md), but the host's fleetd must have scripts enabled: `--enable-scripts`, on by default once MDM is enabled). The **"critical" policy flag** and the `failing_critical_policies`/`critical` webhook fields are **Premium**.
- **Why it's in Project AXIOM** — this is the engine of Phase 8 **SOAR-lite auto-remediation** at $0: a host fails "firewall enabled" → Fleet POSTs to the [automation receiver](./10-automation-and-ir.md) (a FastAPI service in `axiom-core`) → the receiver decides and calls Fleet's `run-script` API to remediate.
- **Where it sits in the stack** — the bridge from this layer into [Automation / IR](./10-automation-and-ir.md). Below: the [policy](#2-fleet-policy--passfail-semantics-1-row--pass) whose verdict triggers it. Beside: [telemetry](./08-telemetry-and-observability.md) (an alternative reaction path).
- **How it works** — Fleet tracks per-host policy state. On a configurable **automation interval** (`webhook_settings.interval`, default **24 h**), it looks for policies that are **newly failing** — a host that went `no-response → fail` or `pass → fail` — and POSTs to the `destination_url` configured under `webhook_settings.failing_policies_webhook` (keys: `enable_failing_policies_webhook`, `destination_url`, `policy_ids`, `host_batch_size`). **By default one HTTP request is sent per newly-failing host.** Automations fire on **scheduled** policy runs, not on ad-hoc live queries.
- **Who talks to it, and how** — **this is the layer's one outbound exception.** Everywhere else the host pulls; here the **Fleet server initiates** an outbound **HTTP POST** to the receiver's URL (in-cluster to the FastAPI container, or via Caddy), carrying a JSON payload identifying the policy and the host(s). The receiver then **calls back into Fleet's REST API** (`/api/v1/fleet/scripts/run`) to remediate — closing the loop.

  ```mermaid
  sequenceDiagram
    participant FLT as Fleet server
    participant RCV as Automation receiver (FastAPI)
    participant API as Fleet REST API
    Note over FLT: policy 'firewall on' newly FAILS on corp-win-01
    FLT->>RCV: HTTP POST webhook {host_id, host_display_name, failing_policies:[{id,name}]}
    RCV->>RCV: decide remediation
    RCV->>API: POST /api/v1/fleet/scripts/run (host_id, script_id)
    API-->>RCV: 200 (queued)
    Note over API: host pulls the script on next check-in and runs it
  ```
- **Free vs Premium** — **Free:** failing-policy webhooks, run-script automations, "newly failing" triggering. **Premium:** the **"critical"** flag and `failing_critical_policies` payload field, **calendar-event** automations, and *continuous* (every-run, not just newly-failing) triggering.
- **Gotchas / myth-busting** — (1) **Only *newly* failing triggers by default** — a host that stays red does **not** re-fire; don't expect a webhook on every interval. (2) **Not instant** — the default check is ~daily; tune the interval if you want faster reaction (still bounded by [policy intervals](#12-osquery-intervals--how-fast-a-policy-flips-redgreen)). (3) The **current payload is per-host** — `timestamp`, `host_id`, `host_display_name`, `host_serial_number`, and a `failing_policies` array of `{id, name}` — one POST per newly-failing host (an older Fleet shape used a single `policy` object plus a `hosts[]` array, so **curl-test what v4.89.1 actually emits** before wiring the receiver; Fleet issues #20447 and #32870 document version-specific webhook-delivery bugs). (4) Fleet must be able to **reach** the receiver URL — a DNS/routing miss is a silent no-op.
- **See also** — [Automation / IR (receiver, run-script)](./10-automation-and-ir.md) · [Fleet policy](#2-fleet-policy--passfail-semantics-1-row--pass) · [osquery intervals](#12-osquery-intervals--how-fast-a-policy-flips-redgreen) · [Telemetry alerting](./08-telemetry-and-observability.md)

---

## 10. File Integrity Monitoring (FIM) & the weights-cache canary

- **In one line** — **FIM** uses osquery's *evented* tables to record create/modify/delete on watched paths; the Enclave watches `/opt/axiom/weights-cache/` as a **model-weights canary** for tamper/exfil detection.
- **What it actually is** — osquery FIM is platform-specific: **`file_events`** (Linux via **inotify**, macOS via **FSEvents**), **`ntfs_journal_events`** (Windows via the NTFS change journal), and **`process_file_events`** (Linux via the audit subsystem). These are **evented tables**: a background publisher fills a buffer that a query later drains — unlike the on-demand `file` table.
- **Why it's in Project AXIOM** — `enclave-01` is the High-Trust node holding model weights. FIM on `/opt/axiom/weights-cache/` detects unexpected writes/deletes to that cache (tampering, exfil staging). Neatly, that **canary path doubles as the Enclave's intrinsic tier marker** for [self-scoping SQL](#6-self-scoping-policy-sql--the-enclave-tiering-trick-adr-0003).
- **Where it sits in the stack** — the **evented-telemetry** edge of this layer, feeding [Telemetry](./08-telemetry-and-observability.md); a policy can also assert on it. The config that enables it is delivered as **Fleet agent options** via [GitOps](./06-gitops-and-cicd.md).
- **How it works** — three things must be true, all delivered through Fleet agent options: **(1)** events on — `--disable_events=false`; **(2)** the FIM publisher enabled — `--enable_file_events=true` on Linux/macOS (`--enable_ntfs_event_publisher=true` on Windows) — these go in agent-options `command_line_flags`; **(3)** a **`file_paths`** block naming the watched categories (e.g. `weights: ["/opt/axiom/weights-cache/%%"]`) in the osquery config. The inotify/FSEvents publisher then streams change events into the `file_events` buffer; a **scheduled query** `SELECT * FROM file_events;` drains it and ships rows to `/logs` for [Loki/Grafana](./08-telemetry-and-observability.md).

  ```mermaid
  flowchart LR
    G[GitOps agent options] -->|/api/v1/osquery/config| OSQ[osqueryd on enclave-01]
    K[inotify watches /opt/axiom/weights-cache] -->|change events| BUF[(file_events buffer)]
    OSQ -->|scheduled query drains| BUF
    OSQ -->|POST /api/v1/osquery/log| FLT[Fleet -> /logs -> Vector -> Loki]
  ```
- **Who talks to it, and how** — osquery **pulls** the FIM config from `/api/v1/osquery/config`; the **kernel publisher** (inotify) feeds the buffer locally; osquery **pushes** drained events via `/api/v1/osquery/log`. The FIM scheduled query is **label-targeted to `enclave`** so only the Enclave runs it — and **label-targeting queries is Free**.
- **Free vs Premium** — osquery FIM is **entirely Free** (it's osquery, not a Fleet paywall), and Enclave-scoping via label-targeted queries is Free. Caveat: this is **detection/telemetry**, not enforcement — Fleet cannot *prevent* the write on Free.
- **Gotchas / myth-busting** — (1) **`file_events` is empty unless you enable events *and* set `file_paths`** — the single most common FIM mistake. (2) It is **differential** — only events *after* the publisher starts; it won't retroactively report past changes. (3) **`%%`** means recursive-wildcard; `%` is single-level — mismatched globs silently watch nothing. (4) **Windows uses `ntfs_journal_events`, not `file_events`** — don't reuse the Linux config verbatim. (5) File-**access** monitoring (`file_accesses`) is a separate opt-in and can **flood** — enable only if needed. (6) inotify has real overhead on large/busy trees.
- **See also** — [scheduled queries](#3-scheduled-queries--query-packs--telemetry-vs-policy) · [self-scoping policy SQL](#6-self-scoping-policy-sql--the-enclave-tiering-trick-adr-0003) · [Telemetry pipeline](./08-telemetry-and-observability.md) · [MITRE ATT&CK alignment](#11-mitre-attck-alignment) · [Enclave hardening](./01-host-hypervisor-virtualization.md)

---

## 11. MITRE ATT&CK alignment

- **In one line** — mapping AXIOM's policies and detections to **MITRE ATT&CK** technique IDs so the lab expresses its coverage in the common adversary-behavior taxonomy — a documentation/annotation practice, not a Fleet feature.
- **What it actually is** — ATT&CK is a public knowledge base of adversary tactics and techniques (`Txxxx`, e.g. `T1005` Data from Local System, `T1052` Exfiltration Over Physical Medium, `T1200` Hardware Additions). Fleet has **no native ATT&CK feature** on Free; alignment is done by **tagging** policies/scheduled queries (in their YAML descriptions) with technique IDs and rolling them up in [compliance-matrix.md](#8-compliance-matrixmd--the-hand-mapped-free-tier-answer) or a Grafana panel.
- **Why it's in Project AXIOM** — it lets the portfolio say *what adversary behaviors* the controls address, not just *which settings* they check. E.g. the [weights-cache FIM](#10-file-integrity-monitoring-fim--the-weights-cache-canary) → `T1005`/`T1530`; a "no removable storage" policy → `T1052`/`T1200`; a listening-ports scheduled query → discovery/lateral-movement techniques.
- **Where it sits in the stack** — a **documentation overlay** on the policy and telemetry content; it produces no runtime behavior.
- **How it works** — each control gets a technique-ID annotation in its GitOps YAML `description`/tags; a build step (or the matrix) aggregates them into an ATT&CK coverage view. Purely declarative and human-curated.
- **Who talks to it, and how** — **humans and CI** only; no host contact, no ports. The annotations ride along inside the same policy YAML that [GitOps](./06-gitops-and-cicd.md) applies.
- **Free vs Premium** — no native ATT&CK capability exists at either tier in this lab's toolset; the hand-mapping is **Free**.
- **Gotchas / myth-busting** — mapping a control to a technique is an **aspirational coverage claim**, not proof of detection efficacy; a passing policy doesn't mean the technique is truly blocked. Don't overstate coverage; keep the mapping honest in the matrix.
- **See also** — [compliance-matrix.md](#8-compliance-matrixmd--the-hand-mapped-free-tier-answer) · [CIS Benchmarks](#7-cis-benchmarks--controls) · [FIM canary](#10-file-integrity-monitoring-fim--the-weights-cache-canary) · [Telemetry / hunting](./08-telemetry-and-observability.md) · [Trust model](./11-concepts-and-trust-model.md)

---

## 12. osquery intervals — how fast a policy flips red/green

- **In one line** — a small set of independent timers governs the **latency** between a real change on a host and a red/green policy (and a fired webhook) — mostly `distributed_interval`, `FLEET_OSQUERY_POLICY_UPDATE_INTERVAL`, `config_tls_refresh`, and the automation interval.
- **What it actually is** — not one clock but several:

  | Interval | Default | Governs | Set where |
  |---|---|---|---|
  | `distributed_interval` | ~10 s | how often osquery **checks in** for live/policy/label queries | agent options |
  | `FLEET_OSQUERY_POLICY_UPDATE_INTERVAL` | **1 hour** | how often the server **re-asks** a host to run its policies | Fleet server env |
  | `config_tls_refresh` | ~30–60 s (version-dependent) | how often osquery **re-fetches** its config/schedule/`file_paths` over TLS | agent options / fleetd flags |
  | scheduled-query `interval` | per query (seconds) | telemetry cadence | the query |
  | policy-automation interval | ~1 day | how often Fleet checks for **newly-failing** → webhook | Fleet automation settings |

- **Why it's in Project AXIOM** — to set correct expectations. When you fix a violation on `corp-win-01`, it can stay **red for up to an hour** (until the next policy update), and a webhook may not fire for **up to a day** — that is by design, not a bug.
- **Where it sits in the stack** — cross-cutting timing that ties this layer to [fleet-core](./03-fleet-core.md) and [automation/IR](./10-automation-and-ir.md).
- **How it works** — end-to-end worst-case latency for a policy flip ≈ time until the **policy update interval** elapses (≤ 1 h) + one `distributed_interval` round-trip (~10 s). Then a webhook adds up to the **automation interval** (~1 day) before it fires. A **live query** bypasses all of this (near-immediate) but does **not** update stored *policy* membership.
- **Who talks to it, and how** — these intervals are the metronome for the same host-pull traffic already described: osquery decides *when* to POST `/distributed/read`, `/config`, and `/log` based on `distributed_interval` / `config_tls_refresh`; the Fleet server decides *when* to include a policy based on the policy update interval.
- **Free vs Premium** — all of these are **Free** and configurable; nothing about tuning cadence is paywalled.
- **Gotchas / myth-busting** — (1) The **1-hour policy default surprises people** who expect real-time compliance — lower `FLEET_OSQUERY_POLICY_UPDATE_INTERVAL` for a snappier lab demo, at the cost of load. (2) A **live query returning green does not mark the policy green** — different code path. (3) Shrinking `distributed_interval` too far multiplies check-in load across all hosts. (4) `config_tls_refresh` gates how fast a **new** policy/FIM config even reaches a host — a just-applied GitOps change isn't instant.
- **See also** — [Fleet policy](#2-fleet-policy--passfail-semantics-1-row--pass) · [critical flag & automations](#9-critical-flag--policy-automations-webhooks) · [Fleet server config](./03-fleet-core.md) · [scheduled queries](#3-scheduled-queries--query-packs--telemetry-vs-policy)

---

> **Free-tier honesty footer.** Everything above runs at **$0 on Fleet v4.89.1 Free** *except*: teams, per-label/team policy scoping, the built-in CIS library, the "critical" policy flag + `failing_critical_policies`, calendar-event/continuous automations, and disk-encryption/OS-update **enforcement** — all Premium. AXIOM substitutes [self-scoping policy SQL](#6-self-scoping-policy-sql--the-enclave-tiering-trick-adr-0003), the free `platform` field, label-targeted queries, hand-authored CIS policies, and a hand-maintained [compliance-matrix.md](#8-compliance-matrixmd--the-hand-mapped-free-tier-answer). Re-verify any surprising schema/flag against [fleetdm.com/docs](https://fleetdm.com/docs) at the pinned tag before each phase — Fleet ships ~every 3 weeks.
