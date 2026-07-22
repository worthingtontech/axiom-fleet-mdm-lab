# Remediation draft: AXIOM enclave -- AIDE host FIM installed (elevated bar)

> Auto-drafted by Claude (claude-remediate.ps1) from live Fleet state. 1 host(s) failing.
> **Review before merging** -- Claude drafts, a human decides. *(worked example committed as
> a sample of the loop's output; live runs land under this dir and open a PR.)*

- platform: `linux`
- policy SQL: `SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM file WHERE path='/etc/axiom/tier.d/elevated') OR EXISTS (SELECT 1 FROM deb_packages WHERE name='aide' AND status LIKE '%installed%');`

---

## Triage

The policy is enclave-scoped: it self-passes on any host lacking the elevated sentinel
`/etc/axiom/tier.d/elevated`, so a **failing** result means an *elevated* host is missing AIDE.
The observable is `deb_packages`, which reflects `/var/lib/dpkg/status`; it returns no row for
`name='aide' AND status LIKE '%installed%'`, i.e. the AIDE package is genuinely not installed on
the flagged enclave node. Root cause: the host was provisioned before the elevated cloud-init began
installing AIDE, or the install was skipped/failed. This is a real elevated-bar gap, not a detection
artifact.

## Remediation

Install AIDE via the run-script API (root). Match the house style already used in the elevated
cloud-init: `--no-install-recommends` is deliberate — the default recommends pull in **postfix**,
whose SMTP daemon opens `0.0.0.0:25`, which policy #2 (no unexpected inbound listeners) would then
correctly flag. Save as `gitops/lib/linux/scripts/install-aide.sh`:

```sh
#!/bin/sh
# Elevated-bar remediation: install AIDE host FIM (policy #10). Idempotent.
set -e
if dpkg -s aide >/dev/null 2>&1; then echo "[axiom] aide already installed"; exit 0; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends aide aide-common
# aideinit builds the baseline DB (slow, full-fs scan); run detached so run-script
# returns and the policy flips green as soon as deb_packages shows 'aide'.
setsid sh -c 'aideinit -y -f >/var/log/axiom-aideinit.log 2>&1' </dev/null >/dev/null 2>&1 &
echo "[axiom] aide installed; baseline DB initialising in the background"
```

Deliver: `fleetctl run-script --host <enclave> --script-path gitops/lib/linux/scripts/install-aide.sh`,
then Refetch. The policy flips green as soon as `deb_packages` reports `aide` installed.

## Risk & rollback

- **Blast radius:** one enclave host; installs two packages. No service disruption.
- **Idempotency:** re-running is a no-op (the `dpkg -s aide` guard).
- **Watch-outs:** `aideinit` is CPU/IO heavy and can exceed the 300s run-script limit — hence the
  detached background init. Confirm no `postfix` was pulled (`dpkg -l postfix` should be empty),
  else policy #2 will flag `:25`.
- **Rollback:** `apt-get purge -y aide aide-common` (the host then correctly reports the elevated-bar
  gap again).
