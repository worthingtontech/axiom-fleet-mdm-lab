# gitops/lib — the policy & profile library

This tree follows Fleet's idiomatic [GitOps library layout](https://github.com/fleetdm/fleet-gitops):
reusable policies, queries, scripts, and configuration profiles live here, organized per platform,
and are pulled into the applied config by `- path:` references from [`default.yml`](../default.yml).

**The empty `.keep` directories are deliberate scaffold, not unfinished work.** They pin the
canonical library structure (`<os>/policies`, `<os>/queries`, `<os>/scripts`,
`<os>/configuration-profiles`) so additions land in the right place and diffs stay predictable.
Populated today:

- [`linux/policies/canary-auditd.yml`](linux/policies/canary-auditd.yml) — the ADR-0009
  progressive-rollout worked example (canary-scoped auditd policy).
- [`linux/scripts/install-auditd.sh`](linux/scripts/install-auditd.sh) — its remediation,
  delivered via Fleet's free run-script API.
- [`windows/configuration-profiles/patch-deadline.xml`](windows/configuration-profiles/patch-deadline.xml)
  — Windows Update deadline CSP profile (authored + CI-validated; GitOps delivery of Windows
  profiles is Fleet Premium, so it ships wired-but-commented in `default.yml`).

Everything else in the applied config (the 22 inline policies, reports, labels, org settings)
lives directly in [`default.yml`](../default.yml) — see [ADR-0006](../../docs/adr/0006-gitops-cicd-architecture.md)
for why the split works this way.
