# Security Review — Project AXIOM Fleet MDM/GitOps Lab

**Subject:** `axiom-fleet-mdm-lab` (Fleet v4.89.1 Free, self-hosted; Docker: fleet + mysql + redis + caddy, mkcert TLS, LAN-only)
**Review date:** 2026-07-22
**Reviewer:** internal pre-public-flip review
**Repo status at review:** private (Apache-2.0), 32 commits in history, personal GitHub account (`worthingtontech`)

This report is written for a security-adjacent reader evaluating the repository as a portfolio
artifact. It states what was verified, how, and — where a claim could not be independently
re-executed in this session — says so plainly. It does not overclaim.

---

## 1. Scope & method

**In scope:** the Git repository only — tracked files, full commit history, secret-hygiene
controls, CI workflow trigger/runner topology, and the documented secret-management design. This
is a review of the *repository as it would appear when made public*, not a live-infrastructure
penetration test.

**Out of scope:** the running lab (containers, VMs, the live Fleet server, the operator's host and
LAN), Fleet upstream code, and third-party container images. GitHub organization/repository
*settings* (branch protection, environment reviewers, fork-PR approval policy) are configuration
that lives in the GitHub UI, not in the repo, and are called out where they are load-bearing but
could not be verified from files alone.

**Method / commands actually run this session (git-native, on the working host):**

```bash
# 1. What secret-shaped files are tracked in the working tree?
git ls-files | grep -iE '\.env$|\.key$|-key\.pem$|\.(msi|deb|iso|vdi)$'
#   -> infra/secrets.example.env        (only match; a placeholder template)

# 2. Was any secret-shaped file EVER added anywhere in history (all branches)?
git log --all --diff-filter=A --pretty=format: --name-only \
  | grep -iE '\.key$|-key\.pem$|rootCA.*\.pem$|(^|/)\.env$|\.(msi|deb|iso|vdi)$' | sort -u
#   -> (empty)  no secret/key/binary artifact was ever committed

# 3. Any PEM private-key material inline in tracked text?
git grep -lE 'BEGIN (RSA |EC |OPENSSL )?PRIVATE KEY'
#   -> (empty)

# 4. Are the live secret artifacts actually ignored?
git check-ignore -v infra/tls/rootCA.pem
#   -> .gitignore:19:rootCA*.pem   infra/tls/rootCA.pem   (matches a deny rule)
```

All four checks passed as shown. Workflow trigger/runner topology was read directly from the six
files in `.github/workflows/`. The mkcert CA material (`infra/tls/rootCA.pem`,
`fleet.axiom.lab-key.pem`) exists in the working tree but is untracked/ignored.

**gitleaks provenance (honest note):** the full-history secret scan *was* executed live during this
engineering session via the pinned `ghcr.io/gitleaks/gitleaks:v8.30.1` Docker image
(`git /repo --log-opts="--all"`), returning **0 leaks** across the history then present. The static
review pass that produced *this document* additionally re-verified the result with the four
git-native checks above — which need no `gitleaks` binary and read the *current* tree and history —
and they too come back clean. A final full-history re-scan on the exact commit being flipped is still
recommended as the last pre-public step (§6, rec. 7); the reproduction command is in §4.

---

## 2. Secret-hygiene posture

The governing rule, stated in `SECURITY.md`: **no secret, private key, certificate, or built
binary is ever committed to Git.** Every such artifact is generated locally at setup/build time and
is ignored. The design is *regenerate, do not commit* — the history contains the *system that
produces* the secrets, never the secrets.

### Three independent guards

1. **`.gitignore` (deny-by-pattern, with a narrow allowlist).** Explicit rules deny `*.env`,
   `*.key`, `*.pem`, `infra/tls/*-key.pem`, `infra/mdm/*.key`/`*.crt`, `rootCA*.pem`, VM images
   (`*.iso`, `*.vdi`, `*.vmdk`, `*.ova`, …), and fleetd build output (`provisioning/**/build/`,
   `*.msi`, `*.deb`, `*.rpm`, `*.pkg`). The only allowlist carve-outs are `!secrets.example.env` /
   `!*.example.env` (the placeholder template) and `!lib/**/*.pem` (reserved for public test certs;
   none currently present).

2. **gitleaks in CI.** `.github/workflows/gitleaks.yml` runs on `[push, pull_request,
   workflow_dispatch]` on `ubuntu-latest` (a GitHub-hosted ephemeral runner) against the repo's
   `.gitleaks.toml`. The config extends the bundled default ruleset (`useDefault = true`) and layers
   two intentional allowlists (see §3). Least-privilege token: the workflow grants only the
   permissions it needs.

3. **Per-commit secret guard.** `SECURITY.md` documents a pre-commit grep for the live enroll
   secret, PEM private-key headers, GitHub tokens, and the specific generated lab passwords.
   *Accuracy note:* this is a **documented operator process, not a tracked git hook.** There is no
   committed `pre-commit` hook and no `core.hooksPath` set in the repo, so this guard is not
   self-enforcing for a fresh clone or a different operator. See §7 for the recommendation to make
   it enforceable.

### Regenerate-not-commit contract

Real secrets exist only in `infra/.env` (git-ignored), injected at runtime via `env_file` or at
build time via script parameters. A fresh clone is stood up with
`new-env.ps1 -> make-certs.ps1 -> new-wstep-ca.ps1 -> docker compose up -> build-packages.ps1`.
`new-env.ps1` fills `secrets.example.env` placeholders with cryptographically random values
(`System.Security.Cryptography` RNG) and refuses to overwrite an existing `infra/.env`.

### gitleaks full-history result

**Result: gitleaks v8.30.1, full history = 0 leaks.** Executed live this session against the pinned
`ghcr.io/gitleaks/gitleaks:v8.30.1` image with `--log-opts="--all"` (all commits, all branches; see
§1 provenance note). It is independently corroborated by the git-native checks in §1, which confirm
that no `.env`/`.key`/`-key.pem`/`rootCA*.pem`/image/binary artifact was ever added in any of the
commits across all branches, and that no PEM private-key header appears in any tracked file.

---

## 3. What is intentionally committed, and why

Three categories of "looks sensitive but is deliberately public" content exist. Each is safe by
construction:

- **Public Microsoft generic (KMS client-setup) product keys — allowlisted.** `.gitleaks.toml`
  explicitly allowlists three keys: Windows 11 Home (`YTMG3-…-8HVX7`), Pro (`VK7JG-…-3V66T`), and
  Enterprise (`XGVPP-…-8HV2C`). These are **published by Microsoft** (learn.microsoft.com volume
  activation) to select an edition during unattended install; they activate nothing and are not
  secrets. They appear in the Windows answer file/runbooks to document edition choice. gitleaks'
  entropy heuristic false-positives them as generic API keys, hence the allowlist.

- **`infra/secrets.example.env` — placeholders only.** This template is committed by design and
  contains only `__GENERATE__`-style tokens (e.g. `__GENERATE_MYSQL_ROOT_PASSWORD__`,
  `__GENERATE_FLEET_SERVER_PRIVATE_KEY__`, `__PASTE_API_ONLY_USER_TOKEN__`) plus non-secret
  configuration (hostnames, ports, the `172.28.0.0/16` trusted-proxy subnet). No real value is
  present; `new-env.ps1` replaces every placeholder into the git-ignored `infra/.env`.

- **The lab mkcert TLS CA is local and throwaway — and is *not* committed.** The CA/leaf material
  (`infra/tls/rootCA.pem`, `fleet.axiom.lab.pem`, `fleet.axiom.lab-key.pem`) is generated per-clone
  by `make-certs.ps1` and is git-ignored (verified: `rootCA*.pem` matches a deny rule). What *is*
  committed is only the generator and CA-install scripts. The CA is a disposable, per-machine trust
  anchor scoped to this LAN-only lab; it is never a trust anchor beyond the lab and is not shared
  between machines, so its blast radius is a single throwaway environment even in a
  worst-case local disclosure.

- **Throwaway lab passwords (documented).** Plaintext lab-only defaults are present in provisioning
  files — the Windows local-admin `P@ssw0rd!23` in `provisioning/windows/autounattend.xml`, and the
  `axiom` account default — each labeled in-file as a **LAB DEFAULT**. These gate only disposable,
  LAN-only VMs and are not real credentials. Acceptable to publish; a one-line callout in the
  README/SECURITY.md is recommended so a reviewer is not left guessing (see §7).

---

## 4. Findings

**No confirmed secret leak was found.** No private key, enroll secret, token, `.env`, certificate
key, or built package is present in the working tree or anywhere in the 32-commit history across all
branches. The one secret-shaped tracked file, `infra/secrets.example.env`, is a placeholder-only
template. This is the headline finding and it is a clean result.

Reproduce the clean result:

```bash
git ls-files | grep -iE '\.env$|\.key$|-key\.pem$|\.(msi|deb|iso|vdi)$'   # -> only secrets.example.env
git log --all --diff-filter=A --pretty=format: --name-only \
  | grep -iE '\.key$|-key\.pem$|rootCA.*\.pem$|(^|/)\.env$|\.(msi|deb|iso|vdi)$' | sort -u  # -> empty
git grep -lE 'BEGIN (RSA |EC |OPENSSL )?PRIVATE KEY'                        # -> empty
git check-ignore -v infra/.env infra/tls/rootCA.pem                        # -> each matches a deny rule
gitleaks detect --source . --log-opts="--all" --config .gitleaks.toml      # -> expect 0 leaks (needs gitleaks installed)
```

Beyond the clean secret result, the following lower-severity, security-relevant observations stand.
None is a secret disclosure; they are hardening/hygiene items to resolve before or at the public
flip.

- **F-1 (Low — information disclosure): personal absolute paths leak the OS username.** Six tracked
  files embed `C:\Users\Sherlock\...` defaults (`provisioning/linux/new-linux-vm.ps1`,
  `provisioning/windows/new-windows-vm.ps1`, `provisioning/README.md`, `runbooks/ci-cd-setup.md`,
  `runbooks/enroll-windows.md`, and `FLEETDM_LAB_PROMPT.md`). These reveal the operator's local
  username and are non-portable. Recommend parameterizing to `$env`/relative paths or clearly
  labeling them operator-specific defaults.

- **F-2 (Informational): throwaway plaintext lab passwords are public.** As described in §3, these
  are documented lab-only defaults gating disposable VMs. Acceptable, but flag them explicitly in
  the README/SECURITY.md so a reviewer is not misled into thinking they are real credentials.

- **F-3 (Informational / operational): scheduled workflows target an unregistered self-hosted
  runner.** `drift-detection.yml` (daily cron), `promote.yml` (6h cron), and `claude-remediate.yml`
  (weekday cron) run on `[self-hosted, …, fleet-apply]`. Once public, if the runner is not
  registered these scheduled runs queue with no runner and read as failing on the public Actions
  tab. This is cosmetic/operational, not a vulnerability, but recommend gating the `schedule:`
  triggers behind an owner check (or commenting them out, keeping `workflow_dispatch`) before the
  flip. `pr-ci.yml` and `gitleaks.yml` are unaffected — they run cloud-hosted and pass.

- **F-4 (Design dependency, not verifiable from files): the self-hosted-runner safety controls that
  gate the public flip are GitHub *settings*, not repo files.** See §5. This is a finding only in
  the sense that a reviewer cannot confirm them by reading the repo; they must be checked in the
  GitHub UI.

---

## 5. Threat-model notes

### Self-hosted runner (ADR-0007)

The dominant repo-level threat at the private-to-public transition is the **self-hosted runner on
the lab LAN**. It is the only machine that can reach the LAN-only Fleet server
(`https://fleet.axiom.lab`) and it runs on the operator's Fleet host. On a *public* repo, a
malicious fork PR could otherwise run attacker code on that host — with reach to the mkcert CA, the
WSTEP identity CA, `FLEET_SERVER_PRIVATE_KEY` (which decrypts all MDM assets), enroll secrets, the
API-only admin token, and the LAN.

ADR-0007 states the load-bearing invariant: **no workflow triggerable by an untrusted contributor
may ever run on the self-hosted runner.** This review **verified the code-level half of that
invariant** directly from the workflow files:

| Workflow | Triggers | Runner | Fork-triggerable? |
|---|---|---|---|
| `pr-ci.yml` | `pull_request` | `ubuntu-latest` (cloud) | Yes — but cloud-only, never touches LAN |
| `gitleaks.yml` | `push`, `pull_request`, `workflow_dispatch` | `ubuntu-latest` (cloud) | Yes — cloud-only |
| `apply.yml` | `push:main`, `workflow_dispatch` | `[self-hosted, Windows, fleet-apply]` | No |
| `drift-detection.yml` | `schedule`, `workflow_dispatch` | `[self-hosted, …, fleet-apply]` | No |
| `promote.yml` | `schedule`, `workflow_dispatch` | `[self-hosted, fleet-apply]` | No |
| `claude-remediate.yml` | `schedule`, `workflow_dispatch` | `[self-hosted, fleet-apply]` | No |

The two `pull_request`-triggered workflows both run on cloud ephemeral runners; every self-hosted
job is `push:main`/`schedule`/`workflow_dispatch` only — all trusted, main-only, and not
fork-triggerable. This matches ADR-0007 and is the control that closes the fork-PR-to-host path.

**What this review could NOT verify (must be confirmed in the GitHub UI before the flip):** ADR-0007
checklist items #3 (*Require approval for all outside collaborators* on fork-PR workflows) and #5
(a `production` environment with required reviewers + a `main`-only deployment branch rule). These
are GitHub settings, not repo files. They are the human-gate half of the invariant and the explicit
Phase-9 gate; the flip should be blocked until they are confirmed. Item #8 (an ephemeral/disposable
runner) is documented as the target end-state and is **not** yet implemented — the standing runner
remains a residual liability (see §6).

### WSTEP CA vs TLS CA separation

The lab maintains **two distinct certificate authorities protecting two different channels**, and
neither CA's private key is ever committed:

- **mkcert TLS root CA** (`infra/tls/`, `make-certs.ps1`) — guards the **transport/telemetry +
  enroll channel**. It is baked into fleetd's trust store so agents trust the Fleet server. If it
  were forgeable, a rogue Fleet could harvest host inventory and the enroll secret. Throwaway,
  per-machine, LAN-scoped.

- **WSTEP Windows MDM identity CA** (`infra/mdm/`, `new-wstep-ca.ps1`) — signs each Windows device's
  MDM **identity** certificate, which authenticates the OMA-DM **management** channel. This is the CA
  that gates *who may issue privileged CSP writes / lock / wipe* to a device. Its `.key` is secret
  and git-ignored (`infra/mdm/*.key`).

Keeping transport trust and management-authority trust in separate CAs is a deliberate,
defensible separation: compromise of the LAN-only transport CA does not confer device-management
authority, and vice versa.

### `FLEET_SERVER_PRIVATE_KEY` permanence

This key encrypts Fleet's MDM assets at rest in MySQL. It is not a TLS key and not the enroll
secret. Per the warning in `secrets.example.env`, once any MDM asset exists, regenerating or losing
it renders those assets permanently undecryptable — there is no recovery path. This is an
**availability** risk (single point of unrecoverable failure), correctly documented, mitigated only
by out-of-band backup.

---

## 6. Residual risk & recommendations

**Residual risk (accepted or pending):**

- **Standing self-hosted runner.** Even with the ADR-0007 controls, a persistent self-hosted runner
  holds secrets on disk and does not guarantee a clean environment between jobs. Fully retired only
  by the ephemeral-runner end-state (ADR-0007 #8), which is not yet implemented.
- **Human-gate controls unverifiable from the repo.** ADR-0007 #3/#5 live in GitHub settings; a
  file-level review cannot attest to them (F-4).
- **Per-commit guard is process, not enforcement.** No committed hook backs the documented
  pre-commit grep, so it does not protect a fresh clone or a second operator (§2).
- **`FLEET_SERVER_PRIVATE_KEY`** is an unrecoverable single point of failure for MDM assets if lost
  (§5) — an availability, not confidentiality, risk.
- **gitleaks re-scan on the flip commit still pending.** The full-history scan ran clean live this
  session (§2), and the git-native checks corroborate the *current* tree, but the final sweep should
  be re-run on the exact commit being flipped to public (§6, rec. 7).

**Recommendations, roughly in priority order:**

1. **Before the public flip, confirm ADR-0007 #3 and #5 in the GitHub UI** (external-contributor
   approval; `production` environment with required reviewers and a `main`-only branch rule). Block
   the flip until both are in place. Prefer the ephemeral runner (#8) if time allows.
2. **Make the per-commit secret guard enforceable** — commit a `pre-commit` hook (or a
   `core.hooksPath` under version control, e.g. via a `pre-commit` framework config) so the third
   guard protects any clone, not just the original operator's muscle memory.
3. **Neutralize the scheduled self-hosted workflows for the public tab** (F-3): guard `schedule:`
   with `if: github.repository_owner == '…'` or comment them out while keeping `workflow_dispatch`.
4. **Scrub/parameterize the `C:\Users\Sherlock\...` paths** in the six tracked files (F-1).
5. **Add a one-line callout** in README/SECURITY.md that the plaintext lab passwords are throwaway
   lab-only defaults (F-2).
6. **Keep `FLEET_SERVER_PRIVATE_KEY` backed up out-of-band** together with a note that it pairs with
   the `mysql-data` volume; never regenerate over a live `infra/.env`.
7. **Re-run `gitleaks detect --log-opts="--all"` on a host that has it installed** as the final
   pre-flip sweep, and confirm the CI gitleaks job is green on the flipping commit.
8. **Revisit the gitleaks allowlist scope** when convenient: the `*.example.ya?ml` / `fixtures/`
   path allowlist means a real secret accidentally placed under those paths would be ignored.
   Acceptable for a placeholder-only repo today; tighten to specific fixture files if fixtures ever
   carry near-real data.

---

## 7. Bottom line

The repository meets its stated bar: **no secret, key, certificate, or built binary is committed,
in the working tree or across full history**, verified by independent git-native checks and
consistent with the recorded gitleaks v8.30.1 full-history 0-leak result and the standing CI scan.
Intentionally public content (Microsoft generic keys, placeholder env template, throwaway lab
passwords) is safe by construction, and the self-hosted-runner CI topology correctly keeps every
fork-triggerable job off the LAN host. The remaining work before a public flip is hardening and
hygiene — confirming the GitHub-settings-level runner gates, making the third secret guard
enforceable, and cosmetic cleanup — not remediation of any exposed secret.
