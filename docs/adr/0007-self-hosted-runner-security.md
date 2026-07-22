# ADR-0007: Self-hosted runner security — hardening before the public flip

- **Status:** Accepted (Phase 3)
- **Date:** 2026-07-22
- **Phase:** 3 — GitOps & CI/CD
- **Related:** ADR-0006 (GitOps CI/CD architecture), ADR-0004 (TLS/DNS —
  LAN-only server); [runbooks/ci-cd-setup.md](../../runbooks/ci-cd-setup.md);
  [GitHub: self-hosted runner security](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access#hardening-for-self-hosted-runners)

## Context

ADR-0006 puts one job class — **apply-on-merge and nightly drift** — on a
**self-hosted runner on the lab LAN**, because that runner is the only machine
that can reach the LAN-only Fleet server (`https://fleet.axiom.lab`). The runner
is registered on the operator's Windows host (the same box that runs the Fleet
compose stack).

The repo is **private now and goes public at Phase 9.** That transition is the
whole risk. GitHub's own guidance is blunt:

> **GitHub recommends that you only use self-hosted runners with _private_
> repositories.** On a public repo, a malicious fork PR can run arbitrary code on
> your runner.

The mechanism: on a public repo, **anyone can open a PR from a fork**, and a
`pull_request`-triggered workflow can run that fork's code. If such a workflow
targeted the self-hosted runner, an attacker would get **code execution on the
Fleet host** — able to read the mkcert CA and WSTEP identity CA, the
`FLEET_SERVER_PRIVATE_KEY` (which decrypts all MDM assets), every enroll secret,
and the API-only admin token, and to pivot onto the LAN. Self-hosted runners also
**do not guarantee a clean environment between jobs**, so one job can poison the
next.

This ADR defines the controls that make a self-hosted runner on a *soon-to-be-
public* repo acceptable — or explicitly defers the public flip until they are in
place.

## Decision

### The load-bearing invariant

> **No workflow that can be triggered by an untrusted contributor may ever run on
> the self-hosted runner.**

Everything below enforces that invariant. It is why ADR-0006 puts **all** PR CI
on GitHub-hosted ephemeral runners and restricts the self-hosted runner to
`push:main` (post-merge) and `schedule` — **both trusted, main-only, and never
fork-triggerable**.

### Hardening checklist (required BEFORE the public flip)

1. **Mutating jobs are `push:main` / `schedule` only.** `apply.yml` triggers on
   `push` to `main` (which only happens after a maintainer merges) and
   `workflow_dispatch`; `drift-detection.yml` on `schedule` + `workflow_dispatch`.
   **Neither runs on `pull_request`.** PR CI (`pr-ci.yml`) — the only
   fork-triggerable workflow — runs **exclusively** on `ubuntu-latest`.
2. **PR CI stays on a cloud ephemeral Fleet.** The untrusted path never sees the
   LAN, the host, or the self-hosted runner (ADR-0006 D1).
3. **Require approval for all outside collaborators.**
   *Settings → Actions → General → Fork pull request workflows from outside
   collaborators →* **"Require approval for all external contributors"** (tighten
   to *all* outside contributors, not just first-time). A maintainer must click
   before any fork PR workflow runs at all.
4. **A dedicated `fleet-apply` runner label.** Trusted workflows target
   `[self-hosted, Windows, fleet-apply]`; nothing else uses that label, so a
   stray/injected workflow cannot land on this runner by matching a generic
   `self-hosted` label.
5. **A `production` environment with human gates.** `apply.yml` declares
   `environment: production`, configured with **required reviewers** and a
   **deployment branch rule locked to `main`**. Every mutation of the live server
   waits on a human approval recorded in the deployment log.
6. **An API-only, scoped, rotated admin token.** The runner authenticates with an
   **API-only global-admin** token (Free requires global-admin for GitOps),
   stored as the `FLEET_API_TOKEN` secret, **not** a human's session token —
   minted headless, rotatable without a login, revocable independently (minting
   steps in the runbook).
7. **Least-privilege `GITHUB_TOKEN`.** Workflows set explicit `permissions:`
   (`contents: read`; drift adds `issues: write`; gitleaks adds
   `pull-requests`/`security-events: write`). No workflow gets blanket write.
8. **Ideal end state: an ephemeral / disposable runner.** Because self-hosted
   runners don't guarantee a clean environment between jobs, the target is a
   **just-in-time / ephemeral runner** (fresh VM or container per job, torn down
   after). Documented as the recommended hardening; the standing service is the
   pragmatic interim for a single-operator lab.

### The private-now / public-later plan

- **Now (private):** the repo is private, so fork-PR exposure does not yet exist;
  the self-hosted runner is acceptable and controls #1–#7 are implemented and
  committed. This is GitHub's own recommended posture (self-hosted ⇒ private).
- **Before flipping public (Phase 9 gate):** verify the entire checklist,
  **especially #3** (external-contributor approval) and #5 (`production`
  reviewers). Prefer #8 (ephemeral runner) if time allows.
- **Never** flip the repo public with a standing self-hosted runner and PR CI
  that could reach it. If #3/#5 are not in place, the flip is blocked.

## Consequences

**Positive**
- The untrusted attack path (fork PR → code exec on the Fleet host) is closed by
  construction: fork-triggerable jobs run only on disposable cloud runners.
- Live-server mutations carry a human approval + audit trail (`production`
  environment) and use a rotatable, non-human token.
- The design degrades safely: if a job is misrouted, the dedicated label and the
  environment gate stop it before it reaches the LAN.

**Negative / risks**
- A standing self-hosted runner is still a persistent liability (secrets on
  disk, shared environment between jobs). Mitigated by the checklist; fully
  retired only by the ephemeral-runner end state (#8).
- Operational cost: maintainers must approve `production` deployments and
  external-contributor runs — friction that is the point, but friction.
- The runner host is the Fleet host (single-operator lab). A compromise of either
  compromises both; a dedicated runner VM (#8) is the documented separation.

## Alternatives considered

- **Keep PR CI on the self-hosted runner** (simpler; one runner). *Rejected:*
  directly violates the invariant — fork PRs would run on the Fleet host. This is
  the anti-pattern the whole ADR exists to prevent.
- **Stay private forever.** *Rejected:* the portfolio value depends on a public,
  auditable repo. The controls here make public safe rather than avoiding it.
- **Cloud runner + tunnel into the LAN** (Tailscale/cloudflared) so even apply
  runs in the cloud. *Rejected:* opens the LAN to the public CI plane and couples
  apply to server reachability — trades a well-scoped self-hosted runner for a
  standing hole through the perimeter.
- **Manual, human-run `gitops.sh` only** (no apply workflow). *Rejected:* loses
  the audit trail, the enforced dry-run, and the "merge = deploy" story; the
  self-hosted apply job with a `production` gate keeps automation *and*
  accountability. (`gitops.sh` remains available for local use as a fallback.)
