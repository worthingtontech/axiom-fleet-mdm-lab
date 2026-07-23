# 🔁 GitOps & CI/CD
> Part of the **[Project AXIOM Encyclopedia](./README.md)** · Layer: GitOps & CI/CD. How the entire lab's *desired state* lives in one Git monorepo and is validated, then pushed into the running Fleet server by an automated pipeline — the "as-code" spine that makes the whole thing rebuildable from Git alone.

This layer is the **control loop** for Project AXIOM. Everything the other layers describe — Fleet settings, MDM profiles, policies, queries, labels, agent options — is authored as YAML in a Git repository, reviewed on a pull request, dry-run-validated by CI, and then applied to the live Fleet server by `fleetctl gitops`. Nothing is clicked into the Fleet UI as the source of truth; the UI is a read-only mirror and a debugging window. The two facts that shape *everything* here are (1) Fleet's GitOps apply is **declarative with automatic deletion** — absence in YAML means "delete it" — and (2) the Fleet server lives on a **private LAN** the GitHub cloud cannot reach, so the "apply" leg needs a self-hosted runner on the host. Read this layer as: *Git is the intended state, `fleetctl gitops` is the reconciler, and CI is the guardrail that stops a bad diff before it deletes something real.*

---

## 1. Git & the monorepo

- **In one line** — The version-control system, and the single repository that holds *every* artifact of the lab: infra scripts, cloud-init, Fleet YAML, policies, ADRs, and this encyclopedia.

- **What it actually is** — Git is a content-addressed, distributed version-control system: each commit is an immutable snapshot identified by a SHA-1/256 hash, chained to its parent, forming an append-only history. A *monorepo* is the decision to keep all of the lab's code in **one** repo rather than splitting infra, Fleet config, and docs into separate ones. Analogy: Git is a tamper-evident lab notebook where every page is glued in and cross-referenced by fingerprint; the monorepo is the decision to keep the *whole* lab in one notebook so a single `git clone` reproduces the world.

- **Why it's in Project AXIOM** — The prime directive is "$0, rebuildable **from Git alone**, on one machine." That is only true if there is exactly one place to clone. The monorepo means the disaster-recovery story is `git clone` → run the bootstrap → the lab exists. It also lets a single pull request touch a cloud-init file *and* the policy that checks the marker that cloud-init writes (see [ADR-0003 trust-tiering](../adr/0003-free-tier-trust-tiering.md)) in one reviewable unit — provisioning and enforcement move together.

- **Where it sits in the stack** — The bedrock beneath this entire layer. Below it is nothing but the host filesystem and the [host/virtualization layer](./01-host-hypervisor-virtualization.md) it runs on. Above/beside it sit [GitHub](#2-github-free--the-private-repo-needed-for-the-mac-studio) (the remote mirror), [GitOps](#3-gitops--git-as-the-single-source-of-truth) (the discipline of treating Git as truth), and [`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply) (the tool that consumes what Git holds).

- **How it works** — Working tree → `git add` → staging index → `git commit` (snapshot + parent pointer) → `git push` to the remote. Branches are cheap named pointers to commits; the merge of a feature branch into `main` is the event that (via CI) triggers an apply. Secrets are **kept out** via `.gitignore` (enroll secrets, the `FLEET_SERVER_PRIVATE_KEY`, mkcert keys) — the repo holds the *shape* of the lab, not its credentials.

- **Who talks to it, and how** — Git is local-first, so most interactions are a human or a script invoking the `git` binary against the on-disk `.git` directory — no network. The one network interaction is `git push`/`git pull`/`git fetch` between the local clone and [GitHub](#2-github-free--the-private-repo-needed-for-the-mac-studio), over **HTTPS:443** or **SSH:22**, carrying packfiles (compressed object deltas). Downstream, [`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply) and the cloud-init/VM scripts read the *checked-out working tree* on disk — they consume Git's output, they don't speak the Git protocol.

  ```mermaid
  flowchart LR
    W[Working tree] -->|git add| S[Staging index]
    S -->|git commit| L[(Local .git history)]
    L -->|git push HTTPS:443/SSH:22| GH[GitHub remote]
    L -->|checkout| WT[Files on disk]
    WT -->|read| FC[fleetctl gitops]
    WT -->|read| CI[cloud-init / VBoxManage scripts]
  ```

- **Free vs Premium** — Git itself is free and open-source; irrelevant to Fleet's licensing.

- **Gotchas / myth-busting** — A monorepo is **not** a mono*lith*: the pipeline can (and does) run different jobs for different paths. The classic footgun is committing a secret; because Git history is immutable, a leaked enroll secret or private key survives even after you "delete" the file, so rotation (not just deletion) is the fix. Keep `FLEET_SERVER_PRIVATE_KEY` out entirely — regenerating it after MDM assets exist makes them undecryptable (see [MDM layer](./05-mdm.md)).

- **See also** — [GitHub & the private repo](#2-github-free--the-private-repo-needed-for-the-mac-studio) · [conventional commits](#11-conventional-commits) · [ADR](#12-adr--architecture-decision-record) · [host & virtualization](./01-host-hypervisor-virtualization.md)

---

## 2. GitHub (Free) & the private repo (needed for the Mac Studio)

- **In one line** — The cloud host for the monorepo's remote, plus the CI/CD engine (GitHub Actions) — all on the **free** tier, in a **private** repo.

- **What it actually is** — GitHub is a hosted Git remote with pull requests, code review, issues, and an automation engine (Actions). "Private repo" means only invited accounts can read it. Analogy: GitHub is the shared, off-site vault copy of the lab notebook, plus a robot (Actions) that runs checks whenever a new page is proposed.

- **Why it's in Project AXIOM** — Two concrete reasons. (1) **CI/CD**: GitHub Actions is the free automation that runs the dry-run gate on every PR and the apply on merge. (2) **The Mac Studio onboarding**, called out explicitly: the deferred real-macOS node ([ADR-0001](../adr/0001-right-sized-topology.md)) is a *separate physical machine*. To join it to the lab you `git clone` the repo onto it — that clone must come from somewhere reachable off the host LAN, i.e. GitHub. A private repo keeps the lab's topology, hostnames, and CA-trust choices from being world-readable while still letting the Mac pull them.

- **Where it sits in the stack** — The off-host anchor of this layer. It sits *beside* the local [Git](#1-git--the-monorepo) clone (as its `origin` remote) and *above* [GitHub Actions](#7-github-actions--workflow--job--step--runner), which it hosts. It is the boundary between "the cloud" and "the LAN" — a boundary that forces the [self-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) decision.

- **How it works** — You push commits to `origin` (GitHub). Opening a PR against `main` fires `pull_request` events; merging fires `push`-to-`main` events. Those events trigger workflows defined in `.github/workflows/`. Branch protection on `main` requires the CI checks to pass before merge — that's what makes the dry-run gate *mandatory* rather than advisory. Secrets (the Fleet admin token, enroll secrets) live in GitHub **Actions Secrets / Environments**, injected into jobs as env vars — never in the repo.

- **Who talks to it, and how** —

  | Initiator | → Target | Direction / protocol | Payload |
  |---|---|---|---|
  | Operator's `git` | → GitHub | outbound HTTPS:443 / SSH:22 | push/pull packfiles |
  | Operator's browser | → GitHub | outbound HTTPS:443 | open/review/merge PRs |
  | **Self-hosted runner** on the host | → GitHub | **outbound** HTTPS:443 long-poll | "any jobs for me?" then logs/results |
  | Mac Studio (later) | → GitHub | outbound HTTPS:443 | `git clone` the private repo |

  The critical asymmetry: **GitHub never initiates a connection into the LAN.** Every arrow points *outward* to GitHub. That is precisely why a runner behind the home NAT works with zero inbound firewall rules (detailed in [entry 8](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one)).

- **Free vs Premium** — GitHub Free gives unlimited private repos, unlimited collaborators, and **self-hosted runner minutes are free/unmetered** (only GitHub-*hosted* runner minutes are metered, and private-repo free tier includes a monthly allotment). The whole AXIOM pipeline fits in GitHub Free. This is orthogonal to *Fleet* Free vs Premium.

- **Gotchas / myth-busting** — "Private repo = safe to commit secrets" is **wrong**: private limits *who can read*, but a leak, a fork, or a compromised token still exposes committed secrets, and history is forever. Keep secrets in Actions Secrets, not files. Also: a PR from a fork does **not** receive your repo secrets by default (a GitHub safety feature) — which is exactly why AXIOM's PR dry-run runs against an [ephemeral throwaway Fleet](#10-ephemeral-fleet-service-container--pr-time-dry-run) that needs no real credentials.

- **See also** — [self-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) · [GitHub Actions](#7-github-actions--workflow--job--step--runner) · [identity / API tokens](./09-identity-and-access.md) · [ADR-0001 topology](../adr/0001-right-sized-topology.md)

---

## 3. GitOps — Git as the single source of truth

- **In one line** — The operating discipline where the *desired* state of the system lives in Git, and an automated agent continuously makes the *running* system match it.

- **What it actually is** — GitOps is a control-loop pattern borrowed from Kubernetes-land: (1) declared state in Git, (2) a reconciler that reads that state and applies it, (3) reviews/rollbacks done as Git operations (PR, revert). The point is that a change is not "done" when someone clicks a button — it is done when it is *merged*, because merge is what triggers the reconciler. Analogy: a thermostat. Git holds the set-point (68°F); `fleetctl gitops` is the thermostat that reads the set-point and drives the furnace until the room matches. You change the temperature by changing the set-point (a commit), not by lighting a fire by hand.

- **Why it's in Project AXIOM** — It makes the lab **auditable, reviewable, and rebuildable**. Every configuration change to Fleet has a commit, an author, a diff, and a review. There is no "who turned off that policy in the UI three weeks ago?" — the answer is `git blame`. It also enforces the portfolio's core claim: the environment is *reproducible from code*, not from a pile of manual clicks nobody wrote down.

- **Where it sits in the stack** — It is the *philosophy* that binds this layer together; not a binary you install. It sits above [Git](#1-git--the-monorepo)/[GitHub](#2-github-free--the-private-repo-needed-for-the-mac-studio) (its storage and trigger) and above [`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply) (its reconciler), and it governs how the [policy-as-code](./07-policy-as-code.md), [MDM](./05-mdm.md), and [telemetry](./08-telemetry-and-observability.md) layers are actually changed.

- **How it works** — The loop: author YAML → PR → CI **dry-run** (proposed diff, no changes) → review → merge → CI **apply** (reconcile live Fleet to Git) → optional scheduled re-apply/dry-run to catch [drift](#6-drift-detection--live-state-vs-git). The reconciler is *level-triggered* (it drives toward the whole declared state) not *edge-triggered* (it doesn't just replay your diff), which is why deletion is automatic — see [entry 4](#4-desired-state--declarative-apply--the-auto-delete-footgun).

  ```mermaid
  sequenceDiagram
    participant Dev as Operator
    participant Git as Git/GitHub
    participant CI as CI pipeline
    participant Fleet as Live Fleet server
    Dev->>Git: commit + open PR
    Git->>CI: pull_request event
    CI->>CI: fleetctl gitops --dry-run (ephemeral Fleet)
    CI-->>Git: check ✅/❌ (proposed diff)
    Dev->>Git: merge to main
    Git->>CI: push event
    CI->>Fleet: fleetctl gitops (apply) via self-hosted runner
    Fleet-->>Fleet: reconcile to declared state
  ```

- **Who talks to it, and how** — GitOps has no daemon of its own; it choreographs three actors, and every arrow runs *one way, outbound*. (1) **Operator → GitHub** (HTTPS:443): pushes commits and merges PRs — the only sanctioned human write. (2) **GitHub → runner**: a `push`/`schedule` event dispatches the reconciler job, but the [runner long-polls GitHub outbound](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one), so GitHub never reaches into the LAN. (3) **Reconciler ([`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply)) → Fleet**: it initiates an authenticated call to the Fleet REST API (Caddy:443 → fleet:1337) to read live state and write the reconciled objects. Crucially, **Fleet never calls back toward Git** — there is no return path — and the Fleet **UI is strictly a read-only downstream viewer** (operator's browser → Caddy:443, no authority). The whole circuit is *Git → reconciler → Fleet*, never the reverse.

- **Free vs Premium** — GitOps as a *workflow* is fully available on **Fleet Free** — `fleetctl gitops`, the REST API it calls, webhooks, and SAML SSO are all Free. The **catch**: the dedicated "GitOps" **API-only role is Premium**, so on Free the pipeline authenticates with a **global-admin** API token (a lesser role gets 403s). See [entry 5](#5-fleetctl-gitops--dry-run--apply) and the [identity layer](./09-identity-and-access.md).

- **Gotchas / myth-busting** — GitOps ≠ "I keep my YAML in Git." It only becomes GitOps when Git is the *authority* and the UI is *downstream*. If someone edits a policy in the Fleet UI, the next `fleetctl gitops` apply will **overwrite or delete** their change to match Git — that is the feature working, not a bug. Treat the UI as read-only for anything under GitOps management.

- **See also** — [desired state & declarative apply](#4-desired-state--declarative-apply--the-auto-delete-footgun) · [drift detection](#6-drift-detection--live-state-vs-git) · [policy-as-code](./07-policy-as-code.md) · [cross-cutting trust model](./11-concepts-and-trust-model.md)

---

## 4. Desired state & declarative apply — the AUTO-DELETE footgun

- **In one line** — Fleet's GitOps is *declarative*: the applied YAML is the **complete** intended state, so anything present in the live server but **absent** from the YAML is **deleted** on apply — with no flag to ask for it.

- **What it actually is** — *Imperative* config says "add policy X" (a verb, a delta). *Declarative* config says "here is the entire set of policies that should exist" (a noun, a whole). Fleet's `fleetctl gitops` is declarative and **level-triggered**: it diffs the whole declared set against the whole live set and reconciles by *creating, updating, AND deleting*. Analogy: it's not "edit this shopping list," it's "the fridge must contain exactly what this list says" — items not on the list get thrown out.

- **Why it's in Project AXIOM** — This is the single most dangerous behavior in the whole GitOps layer and the reason CI gates exist. AXIOM's YAML *is* the truth, so declarative apply is desirable — but it means a careless PR that drops a `policies:` block doesn't "leave those policies alone," it **wipes every policy**. The lab documents this loudly because it directly threatens the [policy-as-code](./07-policy-as-code.md) and [MDM profile](./05-mdm.md) state.

- **Where it sits in the stack** — A property of the [`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply) reconciler and the [YAML file structure](./07-policy-as-code.md) it consumes. It is *why* [drift detection](#6-drift-detection--live-state-vs-git) and the [CI gates](#9-ci-gates--yamllint-actionlint-osqueryi-syntax-profile-validation) matter.

- **How it works** — The distinction that saves you:

  | YAML shape | Meaning |
  |---|---|
  | Key present with items | "These exactly should exist" — extras in live Fleet are **deleted** |
  | Key present but **empty** (`policies: []`) | "Manage this section — **delete everything** in it" |
  | Key **omitted** entirely | "Leave this section **unmanaged** — don't touch it" |

  The difference between *empty key* and *omitted key* is the whole game. `policies:` with nothing under it is a command to delete all policies; deleting the `policies:` line entirely leaves them alone. The lab's `default.yml` + `teams/no-team.yml` split (`fleetctl gitops -f default.yml -f teams/no-team.yml`) declares global org settings and the single "No team" scope respectively; `lib/` is platform-partitioned (`lib/all|macos|windows|linux`) and referenced by relative `path:`/`paths:`.

- **Who talks to it, and how** — This is a *semantic* of the apply, so the interaction is: [`fleetctl`](#5-fleetctl-gitops--dry-run--apply) reads the union of the `-f` files, builds the full desired-state object, and sends it to the Fleet REST API; the **server** computes the create/update/delete set against MySQL and executes it. The operator's only lever is *what the YAML contains* — there is no per-apply "please don't delete" switch to reach for.

- **Free vs Premium** — The auto-delete behavior is identical on Free and Premium. Note two related flags: there is **no `--delete-missing` flag** (deletion is unconditional, not opt-in), and **`--delete-other-teams` is Premium** (Free has only the single "No team," so cross-team deletion is moot).

- **Gotchas / myth-busting** — The myth is "GitOps only applies my diff." It does **not** — it reconciles the whole declared world. Corollary myths busted: (a) there is no `--delete-missing` flag to forget; deletion just happens. (b) An **empty** top-level key is **not** the same as an **omitted** one — one nukes the section, the other ignores it. (c) `--dry-run` is not optional hygiene here; it is the only way to *see* the delete set before it runs. Always dry-run, and read the delete count.

- **See also** — [`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply) · [drift detection](#6-drift-detection--live-state-vs-git) · [CI gates](#9-ci-gates--yamllint-actionlint-osqueryi-syntax-profile-validation) · [policy-as-code YAML](./07-policy-as-code.md)

---

## 5. `fleetctl gitops` — dry-run → apply

- **In one line** — The Fleet CLI subcommand that reads the desired-state YAML and reconciles the live Fleet server to it — with a `--dry-run` mode that computes and prints the diff *without* changing anything.

- **What it actually is** — `fleetctl` is Fleet's command-line client (a Go binary that speaks Fleet's REST API); `gitops` is its declarative-apply subcommand. It parses one or more `-f` YAML files into a single desired state, then makes authenticated API calls to create/update/delete Fleet objects to match. `--dry-run` runs the same parse + server-side validation and reports the would-be changes, then stops. This is the **reconciler** from [entry 3](#3-gitops--git-as-the-single-source-of-truth).

- **Why it's in Project AXIOM** — It is the *only* sanctioned way to change Fleet in the lab. The canonical command is fixed:
  ```bash
  fleetctl gitops -f default.yml -f teams/no-team.yml --dry-run   # validate/preview
  fleetctl gitops -f default.yml -f teams/no-team.yml             # apply
  ```
  Everything the operator wants Fleet to do — policies, queries, labels, MDM profiles, agent options — flows through this one command, run by CI.

- **Where it sits in the stack** — The reconciler at the heart of this layer. Below it: the [Git working tree](#1-git--the-monorepo) it reads. Above/beside it: the [Fleet REST API](./03-fleet-core.md) it drives, reached through [Caddy TLS](./04-tls-and-pki.md). It is invoked by [GitHub Actions](#7-github-actions--workflow--job--step--runner) on a [runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one).

- **How it works** — Read `-f` files → merge into one desired state → resolve `lib/` `path:`/`paths:` references (relative to the referencing file) → for `--dry-run`, make the same API calls in a **dry-run mode the server honors** — it parses, validates, and computes the diff but **persists nothing** — and print the result; for a real apply, execute the create/update/**delete** set (see [entry 4](#4-desired-state--declarative-apply--the-auto-delete-footgun)). Version skew matters: run `fleetctl 4.89.x` against `fleet:v4.89.1` — a newer CLI can emit YAML keys the server rejects, and an older CLI can silently drop newer keys.

- **Who talks to it, and how** — `fleetctl` is a **client**; it always initiates. It reads three environment inputs — `FLEET_URL`, `FLEET_API_TOKEN` (a **global-admin** token on Free), and any `$FLEET_SECRET_*` / enroll-secret vars the YAML references — then:

  ```mermaid
  flowchart LR
    FC["fleetctl gitops<br/>(on the runner)"] -->|HTTPS POST :443<br/>Bearer token + desired-state JSON| CADDY[Caddy]
    CADDY -->|plain HTTP :1337| FLEET[Fleet server]
    FLEET -->|SQL create/update/delete| MYSQL[(MySQL 8)]
    FLEET -.->|--dry-run: validate only,<br/>no writes| FLEET
  ```

  Directional detail: `fleetctl` → **Caddy:443** (TLS terminated with the mkcert leaf) → forwards plain HTTP to **fleet:1337** → Fleet validates, and on a real apply writes the reconciled objects to **MySQL:3306**. On `--dry-run`, Fleet performs validation and diff computation but commits **no** writes. The Bearer token authenticates the call; the payload is the parsed desired state as JSON.

- **Free vs Premium** — The command is Free. **But the token must be global-admin on Free** — the least-privilege "GitOps" API-only role is **Premium** and a lesser role returns 403. Also Premium: `--delete-other-teams` and per-team routing. Free drives the *whole* single-"No team" lab through this command with a global-admin token (documented as an accepted lab compromise; a Premium upgrade would swap in a scoped GitOps token — see [identity layer](./09-identity-and-access.md)).

- **Gotchas / myth-busting** — (1) `--dry-run` validates *against a real server* — it needs a reachable, migrated Fleet (which is why AXIOM stands up an [ephemeral one](#10-ephemeral-fleet-service-container--pr-time-dry-run) for PRs). It is not a pure offline lint. (2) A green dry-run does **not** mean "no deletions" — it means "these are the changes, including deletions"; read them. (3) Do **not** confuse `fleetctl gitops` (declarative whole-file) with the older `fleetctl apply -f` (which it replaced). (4) `fleetctl package` (agent builds) is a *different* subcommand and uses `--fleet-certificate` with the **CA** (`rootCA.pem`), not the leaf — covered in the [MDM](./05-mdm.md) / [PKI](./04-tls-and-pki.md) layers, don't cross the wires.

- **See also** — [declarative apply](#4-desired-state--declarative-apply--the-auto-delete-footgun) · [Fleet core & REST API](./03-fleet-core.md) · [Caddy / TLS](./04-tls-and-pki.md) · [identity / tokens](./09-identity-and-access.md) · [policy-as-code](./07-policy-as-code.md)

---

## 6. Drift detection — live state vs Git

- **In one line** — Catching the case where the *running* Fleet server no longer matches Git — typically because someone changed something in the UI — by periodically asking "would an apply change anything?"

- **What it actually is** — "Drift" is any divergence between declared state (Git) and actual state (live Fleet). Fleet Free has **no dedicated drift API**; drift detection is *emergent* from the reconciler: run `fleetctl gitops --dry-run` on a schedule, and if it reports a non-empty diff, the live server has drifted. Analogy: it's a periodic bank-statement reconciliation — you re-add the ledger (Git) and compare to the balance (live Fleet); any difference is unexplained activity.

- **Why it's in Project AXIOM** — GitOps is only honest if Git *actually* reflects reality. Someone poking the UI, a half-finished manual experiment, or a partial apply can silently desync the two. A scheduled drift check turns "Git is the source of truth" from an aspiration into a *monitored invariant* — the lab can prove, nightly, that live Fleet == Git (or get alerted).

- **Where it sits in the stack** — A scheduled use of [`fleetctl gitops --dry-run`](#5-fleetctl-gitops--dry-run--apply), driven by [GitHub Actions on the self-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) (it must hit the *live* LAN Fleet, so it can't be a throwaway ephemeral one). It feeds signals to the [telemetry](./08-telemetry-and-observability.md) / [automation](./10-automation-and-ir.md) layers if you wire an alert.

- **How it works** — A `schedule:` (cron) workflow runs `fleetctl gitops --dry-run` against the **live** server on the self-hosted runner. Interpret the output:

  | Dry-run result | Meaning |
  |---|---|
  | No changes | Live Fleet matches Git — no drift |
  | Would create/update | Something in Git isn't applied yet (or was reverted in UI) |
  | Would **delete** | Something exists live that Git doesn't declare (drift *into* the server) |

  The stock `fleetdm/fleet-gitops` workflow ships a nightly `cron: '0 6 * * *'` schedule (06:00 UTC) — but note its `dry-run-only` input is `true` **only** for `pull_request` events, so the *scheduled* run actually performs a full **apply**: it silently re-reconciles live Fleet to Git every night (auto-remediation, not detection). AXIOM's variant instead forces `--dry-run` on the schedule so drift is **reported and decided on**, not silently overwritten. Remediation is then a deliberate re-apply (make live match Git) *or* a commit (make Git match an intentional live change) — never a silent UI edit.

- **Who talks to it, and how** — Identical call path to a normal dry-run: GitHub's scheduler fires the workflow → the **self-hosted runner** (already on the LAN) runs `fleetctl gitops --dry-run` → `fleetctl` → **Caddy:443** → **fleet:1337** → validation/diff against **MySQL**, **no writes**. The *result* (diff or clean) is the signal; you can fail the job or POST to a [webhook receiver](./10-automation-and-ir.md) to alert.

  ```mermaid
  sequenceDiagram
    participant Cron as GitHub schedule (06:00 UTC)
    participant R as Self-hosted runner (on host)
    participant Fleet as Live Fleet (LAN)
    Cron->>R: trigger drift workflow
    R->>Fleet: fleetctl gitops --dry-run
    Fleet-->>R: diff (empty = no drift)
    R-->>Cron: pass (clean) / fail (drift) → alert
  ```

- **Free vs Premium** — Fully doable on **Free** — it's just scheduled `--dry-run` + a global-admin token. There is no premium "drift dashboard"; the mechanism is the CLI diff.

- **Gotchas / myth-busting** — (1) Drift detection needs the **live** server, so unlike the PR gate it **cannot** run against an [ephemeral Fleet](#10-ephemeral-fleet-service-container--pr-time-dry-run) and **cannot** run on a GitHub-hosted runner (no LAN reachability) — it must use the self-hosted runner. (2) A drift "delete" line is not necessarily bad — it's telling you the UI has state Git doesn't know about; decide whether to codify it or wipe it. (3) This is detection, not prevention — the only real prevention is discipline + branch protection so changes go through PRs, not the UI.

- **See also** — [`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply) · [declarative apply](#4-desired-state--declarative-apply--the-auto-delete-footgun) · [self-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) · [automation / IR](./10-automation-and-ir.md)

---

## 7. GitHub Actions — workflow / job / step / runner

- **In one line** — GitHub's built-in CI/CD engine: YAML-defined **workflows** made of **jobs** made of **steps**, executed on **runners** in response to repo events.

- **What it actually is** — A hierarchy: a **workflow** (`.github/workflows/*.yml`) is triggered by events (`on: pull_request`, `on: push`, `on: schedule`, `on: workflow_dispatch`); it contains one or more **jobs**; each job runs on a **runner** (a machine/VM) and is an ordered list of **steps**; a step is either a shell command (`run:`) or a reusable **action** (`uses:`). Jobs run in parallel by default and get fresh, isolated runner environments. Analogy: workflow = recipe, job = a cook at a station, step = one instruction, runner = the kitchen the cook works in.

  | Term | Is | AXIOM example |
  |---|---|---|
  | Workflow | The whole automation file + its triggers | `gitops.yml` on PR/push/schedule |
  | Job | A unit that runs on one runner | `validate` (dry-run), `apply` |
  | Step | One command or action | `uses: actions/checkout@v4`; `run: fleetctl gitops …` |
  | Runner | The machine executing the job | GitHub-hosted `ubuntu-latest` **or** self-hosted host |

- **Why it's in Project AXIOM** — It is the free automation that turns the GitOps *discipline* into an enforced *pipeline*: PR → dry-run gate (blocking), merge → apply, nightly → drift check. Without Actions, "run `fleetctl gitops` on merge" would be a manual chore someone forgets; with it, it's an invariant.

- **Where it sits in the stack** — Hosted by [GitHub](#2-github-free--the-private-repo-needed-for-the-mac-studio), driving [`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply). Its runners are either GitHub-cloud VMs or the [self-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) on the AXIOM host. It orchestrates the [CI gates](#9-ci-gates--yamllint-actionlint-osqueryi-syntax-profile-validation) and the [ephemeral Fleet](#10-ephemeral-fleet-service-container--pr-time-dry-run).

- **How it works** — An event (PR opened, push to `main`, cron tick) → GitHub queues the matching workflow's jobs → runners pick up jobs → steps execute top-to-bottom, sharing a workspace and env → job status (pass/fail) reports back as a commit/PR **check**. Secrets are injected as masked env vars. `concurrency:` prevents two applies racing. Conditional expressions pick behavior per event, e.g. AXIOM's PR-vs-merge split: `dry-run-only: ${{ github.event_name == 'pull_request' && 'true' || 'false' }}`.

- **Who talks to it, and how** — GitHub's control plane dispatches jobs; **runners initiate outbound** to fetch them (see [entry 8](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one)). Inside a job, steps talk to whatever they invoke: `actions/checkout` → GitHub API (clone), `fleetctl` → the Fleet server, a lint step → nothing external. Results (logs, check status) flow back to GitHub over HTTPS:443. The operator interacts only through Git events (push, PR, merge) and the Actions UI.

- **Free vs Premium** — Unrelated to Fleet licensing. GitHub Actions is free for the AXIOM usage pattern (private repo free-tier minutes for the small GitHub-hosted validation jobs; **self-hosted runner minutes are unmetered**).

- **Gotchas / myth-busting** — (1) Jobs are **isolated** — state doesn't carry between jobs unless you pass artifacts or use a shared service; two steps in the *same* job share a workspace, two *jobs* do not. (2) `pull_request` from a fork runs with **restricted permissions and no secrets** by design — plan the PR gate to need neither (hence the ephemeral Fleet). (3) `ubuntu-latest` is a *GitHub-hosted* runner in the cloud — it **cannot** see the LAN Fleet; conflating "the job ran" with "the job reached my server" is the classic mistake [entry 8](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) exists to prevent.

- **See also** — [GitHub-hosted vs self-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) · [CI gates](#9-ci-gates--yamllint-actionlint-osqueryi-syntax-profile-validation) · [ephemeral Fleet container](#10-ephemeral-fleet-service-container--pr-time-dry-run) · [containers/docker](./02-containers-and-docker.md)

---

## 8. GitHub-hosted vs self-hosted runner — why the LAN needs one

- **In one line** — GitHub-hosted runners are throwaway VMs in GitHub's cloud (great for validation, blind to your LAN); a **self-hosted** runner is a runner agent you install on the AXIOM host, which *can* reach the live Fleet server — so the **apply** and **drift** legs must run there.

- **What it actually is** — Both are just an agent process that pulls jobs from GitHub and runs their steps. The difference is *where it lives and what it can reach*. GitHub-hosted: a fresh Ubuntu/Windows/macOS VM per job, provisioned and destroyed by GitHub, living in Azure. Self-hosted: the same agent binary running on **your** machine (the AXIOM host), persistent, with your network access. Analogy: GitHub-hosted is a rented, spotless workshop across town that has no key to your house; self-hosted is a workbench *inside* your house — it can touch the actual furnace (Fleet) on your LAN.

- **Why it's in Project AXIOM** — Decisive and load-bearing: **the Fleet server is on the private LAN** (`https://fleet.axiom.lab`, resolvable/reachable only on the host's network). A GitHub-hosted `ubuntu-latest` runner in Azure **cannot route to it** — the apply would hang/timeout. Therefore AXIOM installs a **self-hosted runner on the host** to run the real `fleetctl gitops` apply (and the nightly drift dry-run). The stock `fleetdm/fleet-gitops` workflow uses `ubuntu-latest`; AXIOM's variant flips the apply job to `runs-on: self-hosted`. This is the layer's biggest deployment-shape decision.

- **Where it sits in the stack** — The bridge between [GitHub Actions](#7-github-actions--workflow--job--step--runner) (cloud) and the [Fleet server](./03-fleet-core.md) (LAN). The runner process sits on the [host](./01-host-hypervisor-virtualization.md), beside the [Docker stack](./02-containers-and-docker.md) that runs Fleet; it reaches Fleet through the same [Caddy:443](./04-tls-and-pki.md) front door the agents use.

- **How it works** — The runner agent, once registered with a token, opens a **long-poll HTTPS:443 connection outbound to GitHub** and waits. When a job targeting `self-hosted` is queued, GitHub answers the poll; the runner downloads the job, executes the steps **locally on the host**, streams logs back over HTTPS, and reports status. Because it *initiates* the connection, **no inbound firewall port is ever opened** — it works behind home NAT. And because it runs on the host, `fleetctl` inside the job resolves `fleet.axiom.lab` and reaches Caddy just like any LAN client.

  ```mermaid
  flowchart LR
    subgraph Cloud[GitHub cloud]
      GHA[Actions control plane]
      HOSTED["ubuntu-latest<br/>(hosted runner)"]
    end
    subgraph LAN[AXIOM host / LAN]
      SR[Self-hosted runner]
      CADDY[Caddy:443] --> FLEET[Fleet:1337]
    end
    SR -->|outbound long-poll HTTPS:443| GHA
    GHA -. cannot reach .-x CADDY
    HOSTED -. cannot reach .-x CADDY
    SR -->|fleetctl gitops apply| CADDY
  ```

- **Who talks to it, and how** — **Self-hosted runner → GitHub** (outbound HTTPS:443, "give me jobs" + logs). **Self-hosted runner → Caddy:443 → Fleet:1337** (the apply/drift `fleetctl` calls, on the LAN). **GitHub-hosted runner → GitHub** (same job-fetch) but its `fleetctl` can only reach an **[ephemeral Fleet](#10-ephemeral-fleet-service-container--pr-time-dry-run)** it spins up *inside its own VM* — never the LAN. So the division of labor is: PR **validation** → GitHub-hosted + ephemeral Fleet; **apply** and **drift** → self-hosted + live Fleet.

- **Free vs Premium** — Purely a GitHub concept; **free** either way. Self-hosted minutes are unmetered. (Unrelated to Fleet Free/Premium.)

- **Gotchas / myth-busting** — (1) The myth "CI can just apply my Fleet config from the cloud" is false for a LAN Fleet — you *must* have a self-hosted runner (or a tunnel like Tailscale/cloudflared, which AXIOM avoids for simplicity). (2) A self-hosted runner **executes arbitrary workflow code on your host** — never enable it to run untrusted fork PRs; scope it to the trusted `apply`/`drift` jobs on `main`/schedule, and keep PR validation on disposable hosted runners. (3) Registering the runner needs an outbound path to GitHub only; if the apply "can't reach GitHub," it's the runner's *outbound* 443, not an inbound rule.

- **See also** — [GitHub Actions](#7-github-actions--workflow--job--step--runner) · [ephemeral Fleet container](#10-ephemeral-fleet-service-container--pr-time-dry-run) · [Caddy / TLS](./04-tls-and-pki.md) · [host & virtualization](./01-host-hypervisor-virtualization.md) · [ADR-0001 topology](../adr/0001-right-sized-topology.md)

---

## 9. CI gates — yamllint, actionlint, osqueryi syntax, profile validation

- **In one line** — The fast, cheap checks that run on every PR to catch typos and broken artifacts *before* the expensive dry-run — so a malformed file never gets near the live server.

- **What it actually is** — A set of lint/validate steps layered from cheapest to most thorough:
  - **yamllint** — is the YAML even well-formed and consistently indented? (catches tabs, duplicate keys, bad nesting).
  - **actionlint** — are the `.github/workflows/*.yml` files valid GitHub Actions syntax? (catches bad `uses:` refs, undefined `needs:`, expression typos).
  - **osqueryi syntax check** — do the SQL strings in policies/queries actually parse? Run each through a local `osqueryi --json "<sql>"` so a broken policy query fails the PR, not the fleet.
  - **profile validation** — are the MDM configuration profiles well-formed? (macOS `.mobileconfig` = valid plist/XML; Windows CSP profiles = valid SyncML/XML), so a bad profile is caught before Fleet tries to push it.

  Analogy: airport security layers — the metal detector (yamllint) is quick and stops the obvious; the full bag search (dry-run) is slower and thorough. You want the cheap gate to catch 90% so the expensive gate rarely trips.

- **Why it's in Project AXIOM** — Given the [auto-delete footgun](#4-desired-state--declarative-apply--the-auto-delete-footgun), a syntactically broken YAML that *parses wrong* could drop a section and delete state. And a policy SQL typo would produce a *false-green* compliance result — especially dangerous with AXIOM's [self-scoping trust-tier SQL](../adr/0003-free-tier-trust-tiering.md), where a broken guard clause could silently mis-scope a policy. These gates make the pipeline fail *loudly and early* on the host's own terms, before any server contact.

- **Where it sits in the stack** — The first steps in the PR [workflow](#7-github-actions--workflow--job--step--runner), running on a **GitHub-hosted** runner (they need no LAN access — they're static analysis). They precede the [ephemeral-Fleet dry-run](#10-ephemeral-fleet-service-container--pr-time-dry-run). They validate artifacts owned by the [policy-as-code](./07-policy-as-code.md), [MDM](./05-mdm.md), and [telemetry](./08-telemetry-and-observability.md) layers.

- **How it works** — Each gate is a `run:` step (or a small `uses:` action) invoking a linter against the checked-out tree; a non-zero exit fails the job and blocks the PR (via branch protection). They are **offline** — pure static checks against files, no network, no server — which is why they're fast and can run on any runner, including forks with no secrets. Order them cheapest-first so feedback is quick.

  | Gate | Tool | Reaches network? | Catches |
  |---|---|---|---|
  | YAML lint | `yamllint` | no | indentation, dup keys, tabs |
  | Workflow lint | `actionlint` | no | invalid Actions syntax |
  | Query syntax | `osqueryi` | no | un-parseable policy/query SQL |
  | Profile validate | plist/XML validator | no | malformed `.mobileconfig` / CSP XML |

- **Who talks to it, and how** — Triggered by the `pull_request` event → GitHub-hosted runner runs each linter step against the local working tree → each writes pass/fail as the step's exit code → the aggregate becomes a required **check** on the PR. No component *outside* the runner is contacted; these gates deliberately talk to nothing but the files.

- **Free vs Premium** — All open-source tooling, all free; independent of Fleet licensing. (The **built-in CIS benchmark policy library** *is* Premium — so AXIOM hand-authors CIS-aligned queries and lints *those* here; see [policy-as-code](./07-policy-as-code.md).)

- **Gotchas / myth-busting** — (1) Passing lint ≠ passing dry-run: yamllint proves the file is *well-formed*, not that Fleet *accepts the schema* — that's the dry-run's job. Keep both. (2) `osqueryi` syntax-checks SQL but can't prove the query is *semantically right* for policy scoping — a query can parse and still be a false-green; pair it with the ADR-0003 guard-clause check. (A subtlety about osqueryi itself: osquery's tables are **compiled per-platform**, so a Windows-only table like `bitlocker_info` is *not* registered in a Linux `osqueryi` build — on a `ubuntu-latest` runner it **errors with `no such table`** rather than returning an empty result. A single Linux gate therefore *false-fails* Windows/macOS queries; to syntax-check cross-platform SQL you must run each query through a **platform-matched** osquery build per target OS, and even a clean parse can't prove the table suits the OS the policy targets.) (3) These run on hosted runners precisely *because* they need no secrets or LAN — don't move them to the self-hosted runner "to be consistent"; keep the trusted host's workload minimal.

- **See also** — [ephemeral Fleet dry-run](#10-ephemeral-fleet-service-container--pr-time-dry-run) · [declarative apply footgun](#4-desired-state--declarative-apply--the-auto-delete-footgun) · [policy-as-code](./07-policy-as-code.md) · [MDM profiles](./05-mdm.md) · [ADR-0003 self-scoping SQL](../adr/0003-free-tier-trust-tiering.md)

---

## 10. Ephemeral Fleet service container — PR-time dry-run

- **In one line** — A throwaway Fleet+MySQL+Redis stack spun up *inside the CI job* so a PR's `fleetctl gitops --dry-run` validates against a real, pristine Fleet server — with no LAN access and no real credentials.

- **What it actually is** — GitHub Actions can start **service containers** alongside a job (the `services:` key, or a `docker compose` step). AXIOM's PR job brings up `mysql:8` + `redis:6` + `fleetdm/fleet:v4.89.1` as disposable containers on the runner, runs `fleet prepare db`, bootstraps a first admin, then dry-runs the repo's YAML against *that* server. When the job ends, the containers vanish. Analogy: a **flight simulator** — a full, realistic cockpit to test your changes in, that you can crash with zero consequences because it's not the real plane.

- **Why it's in Project AXIOM** — [`fleetctl gitops --dry-run` needs a live, migrated Fleet to validate against](#5-fleetctl-gitops--dry-run--apply) — it's not pure offline linting. But you do **not** want PR validation touching the *production* LAN Fleet, and PRs (especially from forks) **get no secrets** and **can't reach the LAN**. Standing up an ephemeral Fleet on a GitHub-hosted runner solves all three at once: real schema validation, zero blast radius, zero credentials. It's how AXIOM makes "validate on every PR" both meaningful *and* safe.

- **Where it sits in the stack** — Lives *inside* a [GitHub-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) job, using the [Docker/containers layer](./02-containers-and-docker.md) mechanics (the same images as the real [Fleet core](./03-fleet-core.md) stack, minus Caddy — the dry-run hits Fleet directly). It runs *after* the [cheap CI gates](#9-ci-gates--yamllint-actionlint-osqueryi-syntax-profile-validation) and is the PR-side mirror of the self-hosted [apply](#5-fleetctl-gitops--dry-run--apply).

- **How it works** — Job steps: (1) start `mysql:8` (≥8.0.44 — 9.6.0 is incompatible) and `redis:6` as services with healthchecks; (2) start `fleet:v4.89.1` with a throwaway `FLEET_SERVER_PRIVATE_KEY` and `FLEET_MYSQL_ADDRESS`/`FLEET_REDIS_ADDRESS` pointing at the service containers, running `fleet prepare db --no-prompt && fleet serve` (migration baked in, same as the real stack); (3) create the first admin (`fleetctl setup`) and grab an API token; (4) `fleetctl gitops -f default.yml -f teams/no-team.yml --dry-run` against `http://localhost:PORT`. Because the server is pristine, the dry-run exercises the *full* declarative parse and server-side validation — it will surface schema errors a linter can't. TLS is unnecessary here (plain HTTP to localhost inside the job), so no Caddy/mkcert.

  ```mermaid
  sequenceDiagram
    participant PR as pull_request event
    participant R as GitHub-hosted runner
    participant DB as mysql:8 + redis:6 (services)
    participant EF as Ephemeral fleet:v4.89.1
    PR->>R: start validation job
    R->>DB: docker up (healthcheck)
    R->>EF: fleet prepare db && serve
    R->>EF: fleetctl setup (bootstrap admin token)
    R->>EF: fleetctl gitops --dry-run (repo YAML)
    EF-->>R: diff / validation result
    R-->>PR: check ✅/❌ (then tear everything down)
  ```

- **Who talks to it, and how** — Everything is **localhost inside the job**: `fleetctl` → ephemeral `fleet:1337` (plain HTTP), ephemeral Fleet → `mysql:3306` / `redis:6379` service containers. **Nothing** leaves the runner toward the LAN, and **no** production token is used (the admin token is created fresh for the throwaway server). The only external talk is the runner ↔ GitHub for job control/logs.

- **Free vs Premium** — Entirely Free: same public images and `fleetctl` the lab already pins. No Fleet license key needed for a dry-run (Free features validate fine; Premium-only keys in YAML would be flagged regardless).

- **Gotchas / myth-busting** — (1) This validates **schema and structure**, not real-world *effect* — the ephemeral server has **no enrolled hosts**, so it can't prove a policy actually flags the right machines; that still requires the real fleet. (2) Match the ephemeral image to the pinned `v4.89.1` — validating against a different Fleet version can pass/fail on keys that differ from production. (3) Respect the MySQL floor (≥8.0.44); grabbing `mysql:latest` (9.6.x) reproduces the documented incompatibility and the job fails to boot Fleet. (4) This is the **PR** path; the **merge/apply** and **drift** paths deliberately use the live server on the [self-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) instead.

- **See also** — [`fleetctl gitops`](#5-fleetctl-gitops--dry-run--apply) · [CI gates](#9-ci-gates--yamllint-actionlint-osqueryi-syntax-profile-validation) · [self-hosted runner](#8-github-hosted-vs-self-hosted-runner--why-the-lan-needs-one) · [containers/docker](./02-containers-and-docker.md) · [Fleet core stack](./03-fleet-core.md)

---

## 11. Conventional commits

- **In one line** — A lightweight convention for writing commit messages as `type(scope): summary` (e.g. `feat(policy): add enclave FDE check`) so history is machine-readable and human-scannable.

- **What it actually is** — A spec that structures the first line of every commit: a **type** (`feat`, `fix`, `docs`, `chore`, `refactor`, `ci`, `test`…), an optional **scope** in parens, a colon, and a concise summary; a `!` or `BREAKING CHANGE:` footer marks breaking changes. Analogy: it's the Dewey-decimal label on each commit — a tiny agreed-upon prefix that lets both people and tools file and find changes without reading the whole diff.

- **Why it's in Project AXIOM** — With one monorepo spanning infra, Fleet YAML, policies, and docs, `git log --oneline` becomes navigable when every entry is tagged by *what kind* of change it is and *which part* it touched (`feat(mdm):`, `fix(gitops):`, `docs(encyclopedia):`). It makes the lab's history a legible narrative — a portfolio virtue — and enables automated changelog/release notes with no extra bookkeeping.

- **Where it sits in the stack** — A convention layered on [Git](#1-git--the-monorepo) commit messages; consumed by humans reading history and optionally by tooling (commitlint, changelog generators) in the [CI](#7-github-actions--workflow--job--step--runner) layer. It pairs naturally with [ADRs](#12-adr--architecture-decision-record) (the *why* in a doc, the *what* in the commit prefix).

- **How it works** — You write the message by hand following the grammar; optionally a **commitlint** step in CI (or a local commit-msg hook) parses each message and fails on violations. Release tooling can read the types to bump versions (feat→minor, fix→patch, breaking→major) and assemble a changelog by grouping types — though AXIOM uses it mainly for legibility, not semver automation.

- **Who talks to it, and how** — The operator *writes* the convention into each commit. If enabled, a **commitlint** step on the runner *reads* the pushed commits and reports pass/fail as a PR check. Changelog generators *read* the log to emit release notes. All of this is local/CI-side text parsing — no server, no network beyond GitHub.

- **Free vs Premium** — Not a Fleet feature; free tooling, no licensing dimension.

- **Gotchas / myth-busting** — It's a *convention*, not magic: unless you add a commitlint gate, nothing *enforces* it — drift into freeform messages is easy. Keep it low-ceremony; the value is the `type(scope):` prefix being consistent, not exhaustive footers on every trivial commit.

- **See also** — [Git & the monorepo](#1-git--the-monorepo) · [ADR](#12-adr--architecture-decision-record) · [CI gates](#9-ci-gates--yamllint-actionlint-osqueryi-syntax-profile-validation)

---

## 12. ADR — Architecture Decision Record

- **In one line** — A short, numbered, immutable Markdown document capturing *one* significant decision — its context, the choice, and the consequences — committed alongside the code it governs.

- **What it actually is** — An ADR is a dated record with a fixed shape: **Status** (Proposed/Accepted/Superseded), **Context** (the forces at play), **Decision** (what was chosen), **Consequences** (the trade-offs accepted), and often **Alternatives considered**. It is *append-only in spirit*: you don't rewrite a past ADR, you supersede it with a new one. Analogy: a court opinion — it doesn't just state the ruling, it records the reasoning and the dissent, so a future reader understands *why*, not just *what*.

- **Why it's in Project AXIOM** — The lab is full of non-obvious, research-driven choices that a naive reader (or a future you) would otherwise second-guess. The ADRs are where the *reasoning* lives so the code can stay lean. The headline example is **[ADR-0003](../adr/0003-free-tier-trust-tiering.md)**: it records that the "labels + per-label policy scoping + separate enroll secrets = free team emulation" plan is **wrong on Fleet Free** (per-label policy scoping is Premium and *silently ignored*; enroll secrets don't segment hosts on Free), and that AXIOM instead uses self-scoping policy SQL keyed on a provisioned marker file. Others: **[ADR-0001](../adr/0001-right-sized-topology.md)** (the 10-node topology sized to the 36 GB dedicated to VMs) and **[ADR-0002](../adr/0002-vm-backend-virtualbox-cloudinit.md)** (VirtualBox + cloud-init NoCloud as the VM backend). Without ADRs, these hard-won corrections would be invisible tribal knowledge.

- **Where it sits in the stack** — Documentation that lives in the monorepo (`docs/adr/NNNN-*.md`), *beside* the [Git history](#1-git--the-monorepo) and this [encyclopedia](./README.md). It's the *why* companion to [conventional commits'](#11-conventional-commits) *what*, and it directly governs choices in the [policy-as-code](./07-policy-as-code.md), [host/virtualization](./01-host-hypervisor-virtualization.md), and [trust-model](./11-concepts-and-trust-model.md) layers.

- **How it works** — When a decision is significant and irreversible-ish, you write the next-numbered ADR, set its Status, and commit it in the *same* PR as the change it justifies — so review covers the reasoning and the implementation together. If a later decision overrides it, you write a new ADR that marks the old one **Superseded** (with a link) rather than editing history. The numbering (`0001`, `0002`, …) gives a stable citation target.

- **Who talks to it, and how** — Humans *read* ADRs to understand intent; the encyclopedia and commit messages *link* to them by number. Occasionally a [CI check](#9-ci-gates--yamllint-actionlint-osqueryi-syntax-profile-validation) enforces process ("a change to `policies/` should reference an ADR"), but ADRs are primarily a *human* protocol — no service consumes them at runtime. They flow one way: decision → doc → future reader.

- **Free vs Premium** — N/A — a documentation practice, not a product feature.

- **Gotchas / myth-busting** — (1) An ADR records *a* decision at *a* point in time — a superseded ADR is **not** wrong to keep; the trail of superseded decisions *is* the value. Don't delete or silently edit them. (2) ADRs are for *architecturally significant* choices, not every commit — over-producing them dilutes the signal. (3) Note the on-disk filename is authoritative for links: e.g. the trust-tiering ADR is [`0003-free-tier-trust-tiering.md`](../adr/0003-free-tier-trust-tiering.md) (an earlier draft cited it as `0003-free-tier-tiering.md` — use the real path).

- **See also** — [ADR-0001](../adr/0001-right-sized-topology.md) · [ADR-0002](../adr/0002-vm-backend-virtualbox-cloudinit.md) · [ADR-0003](../adr/0003-free-tier-trust-tiering.md) · [conventional commits](#11-conventional-commits) · [cross-cutting trust model](./11-concepts-and-trust-model.md)

---

> **Layer recap.** Git holds the desired state; `fleetctl gitops` reconciles the live Fleet to it (declaratively — *absence means deletion*); CI gates + an ephemeral Fleet catch bad diffs on PRs from a hosted runner; and a **self-hosted runner on the host** performs the real apply and nightly drift check because the LAN Fleet is unreachable from GitHub's cloud. On Fleet **Free** this all works with a **global-admin** token (the scoped GitOps role is Premium). Next: [Policy-as-Code →](./07-policy-as-code.md) for the YAML this layer applies, and [Automation & IR →](./10-automation-and-ir.md) for what happens when a policy fails.
