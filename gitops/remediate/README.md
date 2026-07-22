# Claude-in-the-loop remediation

Close the compliance loop: **Fleet detects non-compliance → Claude triages and drafts a fix → a
human reviews and merges the PR.** Claude does the first-draft toil; the engineer keeps the
judgement and the merge button. Claude never applies to the fleet directly.

```
failing policy (Fleet API / Phase-8 failing-policies webhook)
        │
        ▼
 claude-remediate.ps1  ──►  claude -p  (triage + draft remediation, house style)
        │
        ▼
 gitops/remediate/drafts/<policy>.md  ──►  PR  ──►  human review + merge  ──►  apply.yml
```

## Run it

```powershell
# local (needs the `claude` CLI signed in + a Fleet session):
gitops/remediate/claude-remediate.ps1              # write drafts to drafts/
gitops/remediate/claude-remediate.ps1 -OpenPr      # + branch, commit, open a PR
```

`claude-remediate.ps1` pulls the live failing policies from the Fleet API, and for each one hands
Claude a tightly-scoped brief — the policy's name, osquery SQL, description, resolution,
failing-host count, and this repo's remediation conventions — asking for a **Triage / Remediation /
Risk & rollback** brief in the house style (idempotent `run-script` for Linux; CSP/profile for
Windows/macOS). [`.github/workflows/claude-remediate.yml`](../../.github/workflows/claude-remediate.yml)
runs it on the self-hosted runner on a schedule, on demand, and when the Phase-8 SOAR-lite receiver
`repository_dispatch`es a `failing-policy` event.

## Why this shape

- **Human-in-the-loop by construction** — the output is a *PR*, not an apply. Every fix is reviewed;
  rollback is a revert. That's the right trust boundary for a role sitting next to Corporate Security.
- **Grounded prompts** — Claude gets the exact SQL + the repo's conventions, so drafts reference real
  files (e.g. `lib/linux/scripts/install-auditd.sh`) and respect Free-tier constraints, instead of
  hallucinating.
- **It reuses what's here** — the same osquery signal that flips a dashboard red is the trigger; the
  same `run-script` path that promotes a canary applies the accepted fix.

## Worked example

[`drafts/example-enclave-aide.md`](drafts/example-enclave-aide.md) is a committed sample of exactly
what the loop produces — Claude's triage of the failing enclave AIDE control, a drafted
`install-aide.sh` remediation (correctly using `--no-install-recommends` to avoid the postfix `:25`
listener that policy #2 would flag), and a risk/rollback note. Live runs drop their drafts alongside
it and open a PR.
