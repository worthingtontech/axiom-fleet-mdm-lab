# Going Public — Flipping `axiom-fleet-mdm-lab` from PRIVATE to PUBLIC

**Repo:** `github.com/worthingtontech/axiom-fleet-mdm-lab` (personal account `worthingtontech`, not an org yet)
**License:** Apache-2.0 · **Current visibility:** PRIVATE · **Goal:** publish as a portfolio artifact for an IT / Client Platform Engineer application.

This is an **ordered, gated runbook**. Do the phases top to bottom. Each gate has a hard pass/fail condition — do **not** flip visibility until every command in Phase 1 passes and every item in Phase 2 (must-fix) is done. Commands are given for **PowerShell** (primary shell) and the **`gh`** CLI. Run them from the repo root.

---

## Phase 0 — Snapshot before you touch anything

Make the flip reversible and auditable.

```powershell
# Confirm you are on the intended remote and branch
git remote -v                 # expect origin -> worthingtontech/axiom-fleet-mdm-lab
git status                    # working tree should be clean before the audit
git rev-parse HEAD            # record this SHA — the exact commit you are publishing
git branch -a                 # note stray branches (e.g. promote/canary-auditd-*)
```

- Record the current HEAD SHA somewhere outside the repo. If anything goes wrong post-flip, this is the point you audited.
- Decide the fate of the stray `promote/canary-auditd-*` branch: either merge/close its PR or delete it before going public so browsers don't land on a dangling WIP branch. Delete remote branch with `git push origin --delete <branch>` once you're sure.

---

## Phase 1 — Pre-flight SAFETY checklist (HARD GATE)

**Nothing below this line proceeds until all four checks pass.** A public repo exposes *full git history*, not just the working tree — a secret in any past commit is a leak even if the current tree is clean.

### 1.1 — Secret scan, full history (must return 0 leaks)

```powershell
# Uses the repo's own .gitleaks.toml (default rules + intentional $FLEET_* placeholder allowlist)
gitleaks detect --source . --config .gitleaks.toml --redact -v
# Expect: "no leaks found". Exit code 0.
```

If `gitleaks` isn't on PATH, run it via Docker:

```powershell
docker run --rm -v "${PWD}:/repo" zricethezav/gitleaks:latest detect --source /repo --config /repo/.gitleaks.toml --redact -v
```

**PASS = "no leaks found", exit 0.** Any finding that is not a known `$FLEET_*` placeholder must be scrubbed from history (`git filter-repo`) before continuing — do not allowlist a real secret away.

### 1.2 — No secret-bearing file types are tracked

```powershell
# Should list ONLY the example template, nothing else
git ls-files | Select-String -Pattern '\.(env|pem|key|crt|p12|pfx|mobileprovision)$'
# Expect exactly one line: infra/secrets.example.env  (the safe template)
```

**PASS = only `infra/secrets.example.env` appears** (its `!secrets.example.env` / `!*.example.env` un-ignore rules are intentional). Zero `.pem/.key/.crt/.p12/.pfx` files tracked.

### 1.3 — Live secrets are still gitignored (not accidentally staged)

```powershell
# Each of these should print the file path back = it IS ignored (good)
git check-ignore infra/.env infra/tls/rootCA.pem infra/tls/fleet.axiom.lab-key.pem infra/mdm/wstep-ca.key
```

**PASS = every path echoes back** (meaning `.gitignore` is catching the real, per-machine secret material). A path that prints nothing is NOT ignored — investigate before flipping.

### 1.4 — PII / personal-path / hostname sweep

The lab is public-bound and must carry **no job-search, resume, or PII content** (per the lab/job-search split), and should not leak the OS username via absolute paths.

```powershell
# Personal absolute paths (leak the OS username, non-portable) — expands to the
# operator's actual username at run time:
git grep -in "$env:USERNAME"

# Personal email / resume terms that must NOT be in a public lab repo
# (substitute your own email's local part for <email-prefix>):
git grep -niE "<email-prefix>|resume|curriculum vitae|clearance|TS/SCI"
```

- The name **Aaron W. Perkins** is *expected and fine* in `LICENSE`/`NOTICE` (copyright attribution) — that is not PII in the leak sense.
- Any hit for a personal `C:\Users\<username>\...` path is a **must-fix or must-label** (see Phase 2 / Phase 3).
- Any hit for email, resume, or clearance terms is a **hard stop** — remove before flipping. This repo must never carry job-search content.

> **Gate:** All of 1.1–1.4 pass → proceed. Otherwise fix and re-run the whole phase.

---

## Phase 2 — MUST-FIX before public (portfolio-disqualifying if skipped)

These come straight from the public-readiness audit. A portfolio repo is judged on first impression; each of these is visible on the landing page or first click.

1. **Write a root `README.md` (the #1 blocker — none exists today).** GitHub renders the landing page from it; without it the repo is a bare file list. It must lead as the artifact and contain, at minimum:
   - One-paragraph "what this is": the fictional frontier-AI-company scenario (tiered trust zones, model-weights protection, compliance-as-code) and that it is a local, $0, fully-git-rebuildable FleetDM MDM / GitOps / policy-as-code lab.
   - A top-level architecture diagram (mermaid, or reuse `docs/brand/axiom-mark.svg`).
   - An **honest scope table** — this is load-bearing for credibility, do not overclaim:
     - **PROVEN LIVE:** Phases 0/1/4/5 + canary telemetry-gated progressive rollout (fail → HOLD → remediate → PROMOTE, proven on `canary-01`).
     - **AUTHORED-ONLY:** Windows client enroll last-mile, macOS/Windows policies, patch-deadline CSP profile.
     - **BLOCKED / DEFERRED:** self-hosted runner not registered (so apply/drift/promote/remediate are inert); macOS/iOS deferred for lack of Apple hardware.
   - Quickstart / "rebuild from git alone": clone → `infra/scripts/new-env.ps1` → `make-certs.ps1` → `docker compose up` → `fleetctl login`, with the note that fleetd packages carry the enroll secret and are gitignored, so they must be rebuilt locally.
   - Skills-to-JD mapping (MDM, GitOps, policy-as-code, CI/CD gating, telemetry/observability, IR automation).
   - Links to the ADRs (`docs/adr/`), compliance matrix, test plans, and `SECURITY.md`; a one-line note that **`LAB_STATE.md` is the internal engineering journal, not the entry point**.
   - License footer: Apache-2.0, © 2026 Aaron W. Perkins (matching `LICENSE` + `NOTICE`).

2. **Fix the 4 broken internal markdown links** (all point to wrong filenames of files that *do* exist):
   - `LAB_STATE.md` L98 → `docs/adr/0005-windows-mdm-enablement.md` (was `...-wstep.md`)
   - `LAB_STATE.md` L99 → `docs/adr/0006-gitops-cicd-architecture.md` (was `...-ci-architecture.md`)
   - `docs/adr/0009-canary-progressive-rollout.md` L4 → `0006-gitops-cicd-architecture.md`
   - `docs/research/2026-07-20-phase0-1-fleet-brief.md` → `../adr/0003-free-tier-trust-tiering.md` (was `...-free-tier-tiering.md`)

3. **Resolve the origin prompt at the repo root — ✅ done 2026-07-23.** The AI master prompt was
   moved to [`docs/origin-prompt.md`](origin-prompt.md), its personal path scrubbed, and reframed
   as an appendix ("prompt-as-spec" is part of the story; the README leads). The root no longer
   greets visitors with the raw build prompt.

> **Gate:** README renders, all four links resolve (✅ fixed 2026-07-23), and the origin prompt is
> relocated/scrubbed (✅) → proceed. Re-run `git grep -in "$env:USERNAME"` — expect zero hits.

---

## Phase 3 — Cosmetic / polish (nice-to-have, not blocking the flip)

Do these if time allows; none block visibility, but each raises the artifact's finish. Batch a few and commit before flipping so the public first-view is already clean.

- **Parameterize / label personal-path defaults — ✅ done 2026-07-23.** Provisioning-script
  defaults now derive from `$PSScriptRoot` / `$env:USERPROFILE`, runbooks use repo-relative and
  `%USERPROFILE%` paths, and the relocated origin prompt is scrubbed. The username sweep
  (`git grep -in "$env:USERNAME"`) returns zero hits.
- **Neutralize the 3 scheduled workflows so the public Actions tab stays clean.** `drift-detection.yml` (daily cron), `promote.yml` (6h cron), and `claude-remediate.yml` (weekday cron) all target the unregistered `[self-hosted, fleet-apply]` runner; once public their scheduled runs queue with no runner and read as amber/failing to a browser. **Comment out the `schedule:` triggers (keep `workflow_dispatch`)**, or guard with `if: github.repository_owner == 'worthingtontech'`. Same consideration for `apply.yml` (dispatch-only already, but still targets the self-hosted runner). **Keep `pr-ci.yml` and `gitleaks.yml` active — they run GitHub-hosted and pass.**
- **Reconcile doc-staleness nits:** `enclave` vs `high-trust-enclave` label (ADR-0003); 22 vs 23 policy count (live tree has 23 incl. `canary-auditd` — align `compliance-matrix.md` + `test-plans.md`); 5GB vs 6GB Windows RAM (ADR-0001 vs provisioner default 6GB); `LAB_STATE.md` "Running now" lists only `enclave-01` though later sections enroll `gpu-node-1` and `canary-01`.
- **Add 1–2 screenshots** (Fleet UI + a Grafana dashboard) to the README/docs — a platform-engineering portfolio benefits enormously from visible proof of the running telemetry/compliance dashboards. None exist today.
- **Add a one-line README inside `gitops/lib/`** explaining the 10+ empty `.keep` scaffold dirs (idiomatic Fleet gitops layout) so a browser doesn't read them as unfinished. **Do not delete them — they are the load-bearing library path structure.**
- **Add a one-line callout in README / `SECURITY.md`** that the committed plaintext lab passwords (`axiom` in cloud-init, `P@ssw0rd!23` in `autounattend.xml` / `new-windows-vm.ps1`) are documented throwaway lab-only defaults, not real credentials — reassures a security reviewer.

---

## Phase 4 — README / LICENSE / NOTICE readiness (confirm, don't rebuild)

- **`LICENSE`** — Apache-2.0 full text present. ✔ No change needed.
- **`NOTICE`** — "Project AXIOM … Copyright 2026 Aaron W. Perkins", Apache-2.0 boilerplate. ✔ Year/author correct. No change needed.
- **`SECURITY.md`** — present; keep as-is (add the throwaway-password callout from Phase 3 if doing polish).
- **`README.md`** — created in Phase 2; its footer must state Apache-2.0 + © 2026 Aaron W. Perkins to match `LICENSE`/`NOTICE`.
- **Must-preserve set (disable/delete NOTHING here):** `SECURITY.md`, `.gitignore`, `.gitleaks.toml`, `.yamllint.yml`, `infra/secrets.example.env`, the `pr-ci.yml` + `gitleaks.yml` workflows, and the `gitops/lib/**/.keep` scaffold dirs.

---

## Phase 5 — Commit the readiness work

```powershell
git switch -c public-readiness        # do the work on a branch, not straight on main
# ... make Phase 2 (and any Phase 3) edits ...
git add -A
git commit -m "Public-readiness: root README, link fixes, origin-prompt relocation, workflow guards"
git push -u origin public-readiness
# open a PR so pr-ci.yml + gitleaks.yml run green on the exact commit you will publish
gh pr create --fill
# after CI is green:
gh pr merge --squash
git switch main && git pull
```

**Re-run the entire Phase 1 gate on the final `main` HEAD** — the commit you flip must be the commit you audited.

---

## Phase 6 — Flip visibility to PUBLIC (exact steps)

**Option A — `gh` CLI (fastest):**

```powershell
# Sanity: confirm which repo and current visibility
gh repo view worthingtontech/axiom-fleet-mdm-lab --json name,visibility,defaultBranchRef

# Flip
gh repo edit worthingtontech/axiom-fleet-mdm-lab --visibility public --accept-visibility-change-consequences

# Confirm
gh repo view worthingtontech/axiom-fleet-mdm-lab --json visibility   # expect "PUBLIC"
```

**Option B — GitHub web UI:**
1. Go to the repo → **Settings**.
2. Scroll to the bottom → **Danger Zone**.
3. **Change repository visibility** → **Change to public**.
4. Read the warning, type the repo name to confirm, and submit.

---

## Phase 7 — Post-public verification (immediately after the flip)

Open the repo in a **logged-out / incognito browser** (this is what a recruiter sees) and confirm:

- [ ] `README.md` renders as the landing page with the scenario, diagram, honest scope table, and quickstart.
- [ ] A couple of internal doc links resolve (e.g. a `docs/adr/000*` link and the compliance matrix).
- [ ] **Actions tab is clean** — only `pr-ci` and `gitleaks` runs, no amber/failing self-hosted queue.
- [ ] **No secret files are browsable** — spot-check that `infra/.env`, any `*.pem/*.key`, and fleetd packages are absent; only `infra/secrets.example.env` shows as a template.
- [ ] No personal `C:\Users\<username>` path visible in the rendered README or origin prompt.
- [ ] License shows as **Apache-2.0** in the repo sidebar.

---

## Phase 8 — Post-public hygiene (lock it down for the long term)

1. **Branch protection on `main`** (a public repo invites drive-by PRs):

   ```powershell
   gh api -X PUT repos/worthingtontech/axiom-fleet-mdm-lab/branches/main/protection `
     -H "Accept: application/vnd.github+json" `
     -f "required_status_checks[strict]=true" `
     -F "required_status_checks[contexts][]=Secret scan" `
     -F "required_status_checks[contexts][]=pr-ci" `
     -f "enforce_admins=true" `
     -F "required_pull_request_reviews[required_approving_review_count]=0" `
     -f "restrictions=null"
   ```

   Or via UI: **Settings → Branches → Add rule** for `main` → require PR + require `gitleaks` (Secret scan) and `pr-ci` status checks to pass before merge. This keeps `gitleaks` **enforced as a merge gate**, not just an informational run.

2. **Gitleaks stays enforced.** `gitleaks.yml` already runs on `push`, `pull_request`, and `workflow_dispatch` with full history (`fetch-depth: 0`). Do not remove it. With branch protection (step 1) requiring the "Secret scan" check, no PR can merge a leak. Periodically re-run the Phase 1.1 full-history scan locally as well.

3. **`GITLEAKS_LICENSE` — needed only after moving under the LLC org.** The `gitleaks.yml` workflow already references `GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}`. On the current **personal** account this secret is absent and the line is a harmless no-op — `gitleaks-action` requires a (free) license key **only for organization-owned repos**. When the repo is transferred under the future LLC GitHub org:
   - Get a free key at **https://gitleaks.io**.
   - Add it as an **org or repo secret** named `GITLEAKS_LICENSE` (Settings → Secrets and variables → Actions → New secret).
   - No workflow edit is required — the reference is already wired; it simply starts resolving.
   - Without it, the action will **fail on the org-owned repo**, which (given branch protection) would block merges — so add the secret *as part of* the org transfer, not after.

4. **Secret-scanning + push protection (GitHub-native, free on public repos):** Settings → Code security → enable **Secret scanning** and **Push protection**. This is defense-in-depth on top of the gitleaks action.

5. **Disable/limit Actions on forks & set the default workflow token to read-only:** Settings → Actions → General → set "Workflow permissions" to **read-only** and require approval for fork PR workflows, so a public fork can't abuse the self-hosted-runner-targeting workflows.

6. **Repo metadata for discoverability:** add a one-line description, topics (`fleetdm`, `mdm`, `gitops`, `policy-as-code`, `osquery`, `platform-engineering`, `observability`), and the tagline. `gh repo edit --description "..." --add-topic fleetdm --add-topic mdm ...`.

---

## Phase 9 — Share it

- **Primary link:** the repo root — `https://github.com/worthingtontech/axiom-fleet-mdm-lab`. The README is the artifact; that URL is the whole pitch.
- **Deep-links for specific claims** (so a reader can substantiate a capability without hunting):
  - Progressive rollout / CI gating → `docs/adr/0009-canary-progressive-rollout.md` + the green promote PR.
  - Policy-as-code → `gitops/` + `docs/compliance-matrix.md`.
  - Architecture decisions → `docs/adr/`.
  - Security posture → `SECURITY.md`.
- **Keep the mapping honest:** point readers at the README scope table. The "Proven live" rows are what was demonstrated end-to-end; the "Authored / Deferred" rows show scope judgment under a $0 / no-Apple-hardware constraint — which reads as *maturity*, not as a gap.
- **Do not** put personal-application content of any kind into this repo at any point — it is public. Notes on where and how the lab is referenced live outside this repository.

---

### One-line summary of the gates
1. Phase 1 secret/PII scan passes (0 leaks, only `infra/secrets.example.env` tracked, live secrets ignored, no personal paths/PII) → 2. Root README + 4 link fixes + origin-prompt relocated → 3. (optional polish) → 6. `gh repo edit --visibility public` → 7. verify logged-out → 8. branch protection + gitleaks enforced + `GITLEAKS_LICENSE` queued for the org move.
