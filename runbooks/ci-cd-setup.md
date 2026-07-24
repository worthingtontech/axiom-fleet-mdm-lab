# Runbook — GitOps CI/CD: self-hosted runner, secrets, and the acceptance demo

> **Project AXIOM, Phase 3.** Wire Git-as-source-of-truth for Fleet: register the
> **self-hosted LAN runner** that applies desired state to the live server, set the
> **repo secrets**, mint an **API-only global-admin token**, and run the
> **acceptance demo** (PR gates → broken profile fails → merge applies → drift job
> flags a UI change).
>
> **Prereqs already true in this lab:** Fleet live at `https://fleet.axiom.lab`
> (Caddy + mkcert, ADR-0004); Windows MDM enabled server-side (ADR-0005); the
> GitOps tree committed at `gitops/default.yml` + `gitops/fleets/unassigned.yml`;
> `mkcert -install` has trusted the root CA in the Windows store; `rootCA.pem` at
> `infra/tls/rootCA.pem`.
>
> **Related:** [ADR-0006 GitOps CI/CD architecture](../docs/adr/0006-gitops-cicd-architecture.md) ·
> [ADR-0007 Self-hosted runner security](../docs/adr/0007-self-hosted-runner-security.md) ·
> [encyclopedia/06-gitops-and-cicd](../docs/encyclopedia/06-gitops-and-cicd.md) ·
> repo `github.com/worthingtontech/axiom-fleet-mdm-lab`

---

## What runs where (the trust split — ADR-0006/0007)

| Workflow | Runner | Trigger | Touches the LAN? |
|---|---|---|---|
| `pr-ci.yml` (lint, profiles, osquery SQL, `gitops --dry-run`) | GitHub-hosted `ubuntu-latest` + **ephemeral Fleet** | `pull_request → main` | **No** — fully sandboxed |
| `gitleaks.yml` (secret scan) | GitHub-hosted `ubuntu-latest` | push / PR / dispatch | No |
| `apply.yml` (`fleetctl gitops`, real) | **self-hosted `[self-hosted, Windows, fleet-apply]`** | `push → main` + dispatch | **Yes** — applies to live |
| `drift-detection.yml` (nightly) | **self-hosted `[self-hosted, Windows, fleet-apply]`** | `schedule` + dispatch | **Yes** — reads live |

> The self-hosted runner only ever runs **main-only, post-merge / scheduled**
> jobs — never a fork PR (ADR-0007). Do not add `pull_request` to `apply.yml` or
> `drift-detection.yml`.

---

## Step 1 — Provision the runner host toolchain

The runner runs `apply.yml`/`drift-detection.yml` with `shell: bash` (Git Bash),
so put these on the machine PATH first:

- **git**, **Git Bash** (provides `bash`, `sed`, `find`, `curl`, `git diff`)
- **Node.js + npm** (LTS) — installs `fleetctl@4.89.1` per run
- **GitHub CLI (`gh`)** — used by the drift job to open issues

```powershell
winget install --id Git.Git -e
winget install --id OpenJS.NodeJS.LTS -e
winget install --id GitHub.cli -e
# verify (new shell so PATH refreshes):
git --version; node --version; npm --version; gh --version
```

### TLS trust for Git Bash tooling

`fleetctl` (Go TLS) validates against the **Windows cert store**, which
`mkcert -install` already populated — so `fleetctl` needs nothing extra. But
Git Bash `curl` and `npm` use their own CA bundles, so point them at the mkcert
root as **machine** environment variables:

```powershell
# From the repo root:
$rootCA = (Resolve-Path .\infra\tls\rootCA.pem).Path
[Environment]::SetEnvironmentVariable("CURL_CA_BUNDLE",     $rootCA, "Machine")
[Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $rootCA, "Machine")
```

> These persist for the runner **service** (which starts under a machine context).
> Set them **before** `svc.cmd install` so the service inherits them.

### `shell: bash` on a self-hosted Windows runner is NOT Git Bash by default

GitHub-hosted Windows runners map `shell: bash` to Git Bash. A **self-hosted** runner
just resolves `bash` from PATH — and on a stock Windows 11 box that finds the **WSL
shim** `C:\WINDOWS\system32\bash.EXE` first, which fails with
`WSL ERROR: execvpe(/bin/bash) failed` if the default distro has no `/bin/bash`
(e.g. `docker-desktop`). Every `shell: bash` step then dies before running a line.

Fix: the runner honors a **`.path` file in its root directory** — the PATH its jobs
see. Put Git's `bin` first (from the runner's account, PowerShell):

```powershell
Set-Content C:\actions-runner\.path -Value "C:\Program Files\Git\bin;$env:PATH" -Encoding ascii -NoNewline
```

Restart the runner afterward (`.path`, like `.env`, is read at startup). Related:
`actions/checkout@v4`'s temp-dir cleanup also intermittently hits
`EBUSY: resource busy or locked` on Windows self-hosted runners (file-lock races) —
the LAN workflows sync with **plain `git fetch`/`reset`** instead, which needs no
temp staging and no auth on a public repo.

---

## Step 2 — Register the self-hosted runner

Mint a short-lived registration token (expires in ~1 hour) with `gh`:

```bash
gh api \
  repos/worthingtontech/axiom-fleet-mdm-lab/actions/runners/registration-token \
  --method POST --jq .token
```

Download and configure the runner (Windows x64). Use the current
`actions-runner-win-x64-*.zip` from the repo's *Settings → Actions → Runners →
New self-hosted runner* page (it names the exact version + hash):

```powershell
mkdir C:\actions-runner; cd C:\actions-runner
# ...download + extract actions-runner-win-x64-<ver>.zip per the Runners page...

# Configure against the repo, with the dedicated fleet-apply label:
.\config.cmd `
  --url https://github.com/worthingtontech/axiom-fleet-mdm-lab `
  --token <REGISTRATION_TOKEN> `
  --name axiom-fleet-runner `
  --labels fleet-apply `
  --unattended
```

> The runner's implicit labels are `self-hosted` + `Windows`; `--labels
> fleet-apply` adds the dedicated one the workflows target
> (`[self-hosted, Windows, fleet-apply]`). Nothing else uses `fleet-apply`
> (ADR-0007 #4).

Install and start it as a service (starts on boot, survives logoff):

```powershell
.\svc.cmd install
.\svc.cmd start
.\svc.cmd status        # -> Running
```

Confirm it shows **Idle** under *Settings → Actions → Runners*.

---

## Step 3 — Mint an API-only global-admin token

GitOps on Free needs a **global-admin** token. Use a dedicated **API-only** user
(not a human session token) so it is headless, rotatable, and revocable
(ADR-0007 #6).

1. **Create the API-only user** — Fleet UI → *Settings → Users → Add user*:
   - Name `gitops-ci`, email `gitops-ci@axiom.lab`
   - **Global role: Admin**
   - Check **"API-only user"**, set a strong password.

2. **Mint the token** — log in as that user with a throwaway fleetctl context and
   read back the stored token:

   ```bash
   fleetctl config set --context ci --address https://fleet.axiom.lab \
     --rootca infra/tls/rootCA.pem
   fleetctl login --context ci --email gitops-ci@axiom.lab --password '<PASSWORD>'
   # the token is now stored in the context; print it:
   fleetctl config get --context ci | grep -i token
   ```

   (Equivalently: `POST /api/v1/fleet/login` returns `{"token": "..."}`.)
   API-only user tokens are long-lived — rotate by resetting the user's password
   and re-logging-in, which invalidates the old token.

---

## Step 4 — Set the repo secrets

Four secrets back the workflows. Set them with `gh secret set` (paste the value
when prompted — nothing lands in shell history):

```bash
# The live server + the API-only token from Step 3 (used by apply + drift):
gh secret set FLEET_URL       --repo worthingtontech/axiom-fleet-mdm-lab   # https://fleet.axiom.lab
gh secret set FLEET_API_TOKEN --repo worthingtontech/axiom-fleet-mdm-lab   # <token from Step 3>

# The real global enroll secret gitops/default.yml expands at apply time:
gh secret set FLEET_GLOBAL_ENROLL_SECRET --repo worthingtontech/axiom-fleet-mdm-lab

# Free gitleaks license (required for gitleaks-action on an ORG repo) from gitleaks.io:
gh secret set GITLEAKS_LICENSE --repo worthingtontech/axiom-fleet-mdm-lab
```

| Secret | Used by | Notes |
|---|---|---|
| `FLEET_URL` | `apply.yml` → `gitops.sh` | `https://fleet.axiom.lab` |
| `FLEET_API_TOKEN` | `apply.yml`, `drift-detection.yml` | API-only global-admin (Step 3) |
| `FLEET_GLOBAL_ENROLL_SECRET` | `apply.yml` → `gitops.sh` | expanded into `default.yml` |
| `GITLEAKS_LICENSE` | `gitleaks.yml` | free key from gitleaks.io (ORG repos) |

> `GITHUB_TOKEN` / `github.token` are provided automatically — do not set them.

---

## Step 5 — Configure the `production` environment (ADR-0007 #5)

*Settings → Environments → New environment → `production`*:

- **Required reviewers:** add yourself (the maintainer gate on every apply).
- **Deployment branches:** *Selected branches* → `main` only.

`apply.yml` declares `environment: production`, so every apply now waits on a
recorded human approval.

Then, in *Settings → Actions → General*:

- **Fork pull request workflows from outside collaborators →** *"Require approval
  for all external contributors."* (Essential before the public flip — ADR-0007 #3.)

---

## Step 6 — Acceptance demo (the four-beat story)

Run this end-to-end to prove the pipeline. Work on a branch off `main`.

### Beat 1 — A clean PR shows all gates green

```bash
git switch -c demo/ci-proof
# make a trivial, valid change (e.g. tweak a comment in gitops/default.yml)
git commit -am "demo: trivial gitops change"
git push -u origin demo/ci-proof
gh pr create --fill
gh pr checks --watch      # lint, profiles, osquery-sql, dry-run-ephemeral, gitleaks -> all pass
```

Expect: **`dry-run-ephemeral`** spins up a throwaway Fleet and reports a clean
`fleetctl gitops --dry-run`; every other gate is green. **No** self-hosted job
runs (this is a PR).

### Beat 2 — A broken profile FAILS the PR

Introduce a deliberately invalid artifact and confirm a gate catches it:

```bash
# break osquery SQL: add a policy querying a non-existent table
#   -> the osquery-sql gate greps "no such table" and fails
# or drop an invalid <Replace> fragment under gitops/lib/windows/... 
#   -> the profiles (xmllint) gate fails
git commit -am "demo: intentionally broken artifact"
git push
gh pr checks --watch      # the relevant gate turns RED; PR is blocked
```

Revert the break before merging:

```bash
git revert --no-edit HEAD && git push
```

### Beat 3 — Merge applies to the live server

```bash
gh pr merge --squash --delete-branch
```

The merge lands a `push` on `main` → **`apply.yml`** queues on the self-hosted
runner and **waits for `production` approval**. Approve it
(*Actions → the run → Review deployments → Approve*). `gitops.sh` then dry-runs
and applies:

```bash
gh run watch      # apply.yml: fleetctl gitops --dry-run, then apply -> Done.
```

Verify on the server:

```bash
fleetctl get config | grep -i windows_enabled_and_configured   # true (C1 key applied)
```

### Beat 4 — Drift job flags a UI change

Make an out-of-band change in the Fleet **UI** (e.g. edit the org name, or toggle
a setting), then run the drift job on demand:

```bash
gh workflow run drift-detection.yml
gh run watch
```

Expect: the job regenerates GitOps from live state, diffs it against committed
`gitops/`, writes a fenced diff to the **job summary**, opens a **`drift`-labelled
issue** titled `Fleet drift <date>`, and **exits 1**. Revert the UI change (or
`gh workflow run apply.yml` to re-assert desired state) and re-run — it reports
**"No drift"** and passes.

---

## Definition of done

- Runner shows **Idle** under Settings → Actions → Runners.
- All four secrets set; `production` environment has a required reviewer + `main`
  deployment branch; external-contributor approval is required.
- A clean PR is all-green; a broken artifact fails the right gate; merge applies
  (after approval); an on-demand drift run flags a UI change and files an issue.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `apply.yml` never starts | It waits on `production` approval — *Actions → run → Review deployments → Approve*. Only `main` pushes trigger it. |
| `fleetctl gitops` fails: *"variable used but not set"* | A `$FLEET_*` token in the YAML (even in a comment) is unexported. Export it in the job; never write a bare `$FLEET_...` in a comment (ADR-0006 D6). |
| Windows MDM flips **off** after a rebuild | `controls.windows_enabled_and_configured: true` missing from `default.yml`. It is hand-maintained (the generator may omit it — ADR-0006 D3); re-add and re-apply. |
| Drift job diffs on the enroll secret | It shouldn't — the normalizer redacts `secret:` on both sides. If it does, check the committed baseline is generator-seeded (ADR-0006 D2). |
| `gitleaks` job fails immediately on the org repo | Missing/invalid `GITLEAKS_LICENSE`. Get a free key at gitleaks.io and set the secret (Step 4). |
| `npm`/`curl` TLS errors on the runner | `CURL_CA_BUNDLE` / `NODE_EXTRA_CA_CERTS` not set (Step 1) — set them machine-wide and restart the runner service. |
| Runner offline after reboot | `cd C:\actions-runner; .\svc.cmd status` → `.\svc.cmd start`. Service runs under a machine context (env vars from Step 1 apply). |

> **Hardening reminder (ADR-0007):** before flipping the repo **public** (Phase 9),
> re-verify the entire checklist — especially external-contributor approval and
> `production` reviewers — and prefer an **ephemeral/disposable runner**. A
> standing self-hosted runner reachable by fork PRs on a public repo is the exact
> exposure this design forbids.
