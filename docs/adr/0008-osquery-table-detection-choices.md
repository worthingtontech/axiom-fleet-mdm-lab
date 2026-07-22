# ADR-0008 — Policy detection tables under `fleetd`'s osquery constraints

- **Status:** Accepted (2026-07-22)
- **Supersedes parts of:** the Phase 4 policy SQL seeded in ADR-0003 / the initial 22-policy bank
- **Related:** [compliance-matrix.md](../compliance-matrix.md), [test-plans.md](../test-plans.md)

## Context

Phase 4 authored 22 osquery-backed policies. Three Linux policies were written against tables that
**do not behave as the schema docs imply on the `fleetd`-bundled osquery (5.x) running on Ubuntu
24.04**. This was discovered empirically by running the exact policy SQL on the live enclave
(`enclave-01`) via `fleetctl run-script`, not from documentation:

1. **`augeas` ships no lenses in `fleetd` → 0 rows.** `SELECT count(*) FROM augeas` returns 0. The
   original firewall (#2) and SSH-root (#3) policies read `/etc/ufw/ufw.conf` and
   `/etc/ssh/sshd_config` through `augeas`, so **they could never pass** — a silent always-red. Even
   after `apt-get install augeas-lenses` (462 lenses, 37k+ nodes), osquery's autoload **still
   excludes those two specific files**. There is no reliable osquery-native read of them on this
   build, and requiring every host to ship lenses + an `augeas_lenses` agent-option flag + an
   osquery restart is a fragile dependency.
2. **`iptables` is empty on Ubuntu 24.04** (ufw uses the nftables backend; osquery reads the legacy
   path), even with ufw active. Confirmed live.
3. **`startup_items` can't distinguish ufw on/off** — `ufw.service` is a `RemainAfterExit` oneshot
   that stays `active` after `ufw disable`.
4. **`suid_bin` reports usrmerge aliases** — every binary appears under both `/bin/*` and
   `/usr/bin/*` (plus symlink aliases like `sudoedit`, `sg`). A per-path allowlist (#7) is therefore
   brittle and was **already failing at baseline** — a defect the Phase 4 adversarial-verify
   workflow independently flagged.

## Decision

Re-author the three affected policies onto **tables that are actually populated** on `fleetd`,
choosing observable signals over unobservable config-file contents:

| # | Was (broken) | Now (observable) | Rationale |
|---|---|---|---|
| 2 | `augeas` on `ufw.conf` `ENABLED=yes` | `listening_ports`: no non-loopback TCP listener outside `{22}` | Detects the firewall's **effect** (inbound attack surface). ufw stays enabled at provision. |
| 3 | `augeas` on `sshd_config` `PermitRootLogin no` | `shadow`: `password_status='locked'` for root | Observable proxy for "no direct root login"; provisioning also sets `PermitRootLogin no`. |
| 7 | `suid_bin` per-path allowlist | `suid_bin`: no SUID/SGID **outside OS-managed dirs** (`/bin`,`/usr/bin`,`/sbin`,`/usr/sbin`,`/usr/lib`,`/usr/libexec`) | Directory-scoped → robust to usrmerge aliasing and base-package churn; catches the realistic threat (rogue SUID in `/tmp`,`/opt`,`/usr/local`). |

## Consequences

- **Positive:** all three policies pass on a clean enclave **and** flip red under a real attack
  action — proven live (see test-plans.md). No extra packages, agent-option flags, or osquery
  restarts required. #2 additionally caught a real regression during the work (aide's `postfix`
  recommend opened `:25`), demonstrating the detection is live, not theoretical.
- **Trade-offs / scope:** #2 detects *effect*, not ufw's config bit — a firewall that is off but has
  no listeners would pass (acceptable: no reachable service = no inbound risk). #3 asserts the root
  account is locked, not the full `PermitRootLogin` setting (key-based root could still be
  configured; mitigated by provisioning `PermitRootLogin no`). #7 does not flag a SUID planted
  *inside* `/usr/bin` (requires prior root); it targets the common writable-dir drop.
- **General principle for later phases:** verify every policy's table against the live `fleetd`
  agent before trusting it. "The schema has a table" ≠ "the table is populated on this build."
