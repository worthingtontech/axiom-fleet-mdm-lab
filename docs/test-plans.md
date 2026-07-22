# Project AXIOM — Per-Policy Test Plans (break → red → fix → green)

Companion to [`gitops/default.yml`](../gitops/default.yml) `policies:` and the
[compliance matrix](compliance-matrix.md). For **every** policy this document gives a concrete
way to **intentionally break compliance** so the policy flips **red**, and the command that
**restores** it so it flips **green** — the Phase 4 acceptance test.

## How Fleet evaluates these

- **Semantics:** a Fleet policy runs an osquery query; **≥1 row returned = PASS (green/compliant),
  0 rows = FAIL (red)**. Every query in the bank is written to return a row when the host is
  compliant.
- **Cadence:** `FLEET_OSQUERY_POLICY_UPDATE_INTERVAL=1m`, so a broken control flips within ~1
  minute. The Host Details **Refetch** button (`POST /api/latest/fleet/hosts/:id/refetch`) forces an
  immediate re-evaluation.
- **Delivery:** break/fix commands are pushed with Fleet's free **`fleetctl run-script`** API and run
  as **root** (Linux) / **SYSTEM** (Windows) via the `fleetd` agent — which must be built with
  `--enable-scripts` (see [`provisioning/build-packages.ps1`](../provisioning/build-packages.ps1)).
  No SSH required.
- **`live_verifiable`** = runnable *right now* on the online Ubuntu 24.04 enclave (`enclave-01`).
  macOS/Windows hosts aren't enrolled yet, so those plans are **documented-not-yet-live**.

---

## ✅ Proven live on `enclave-01` (2026-07-22)

All executed remotely via `fleetctl run-script`, each flip confirmed by Refetch + policy re-eval:

| Policy | Break → | Fix → | Result |
|---|---|---|---|
| **#8 weights-cache FIM canary** | `printf 'x' >> …/canary.bin` (sha256 → `04c4afd9…`) → **RED** | rewrite exact 16 bytes (sha256 → `7954095f…0b92`, the pinned value) → **GREEN** | ✅ green→red→green |
| **#2 host firewall effective** | `ufw disable` (config) / rogue listener → **RED** | `ufw --force enable` / kill listener → **GREEN** | ✅ verified |
| **#3 root account locked** | `echo 'root:…' \| chpasswd` (shadow → `active`) → **RED** | `passwd -l root` (shadow → `locked`) → **GREEN** | ✅ verified |
| **#7 unauthorized SUID** | `cp /bin/cp /usr/local/bin/rootcp && chmod u+s …` → **RED** | `rm -f /usr/local/bin/rootcp` → **GREEN** | ✅ verified |

---

## osquery reality on `fleetd` (why several policies were reworked)

These were discovered by querying the live agent (osquery 5.x bundled in `fleetd`), **not** assumed —
they materially shaped the policy SQL:

- **`augeas` table ships no lenses in `fleetd` → it returns 0 rows.** Installing the system
  `augeas-lenses` package populates 37k+ nodes, but osquery's autoload **still excludes**
  `/etc/ufw/ufw.conf` and `/etc/ssh/sshd_config`. There is therefore **no reliable osquery-native
  read of those config files** on this build. → #2 and #3 were re-authored off `augeas`.
- **`iptables` table is empty on Ubuntu 24.04** even with ufw active (nftables backend). → firewall
  posture is detected via **`listening_ports`** (attack surface), which *is* populated.
- **`startup_items` can't distinguish ufw on/off** — `ufw.service` is a `RemainAfterExit` oneshot
  that stays `active` after `ufw disable`. → not usable as the firewall signal.
- **`suid_bin` reports usrmerge aliases** — every binary appears under **both** `/bin/*` and
  `/usr/bin/*` (and symlink aliases like `sudoedit`, `sg`), so a per-path allowlist is brittle. →
  #7 is **directory-scoped** (flag SUID/SGID outside OS-managed dirs) instead.
- **`shadow` table works** and exposes `password_status` (`locked`/`active`) → the observable basis
  for #3 (no direct root login).

The rewritten policies pass on a clean enclave and still flip red under a real attack action — a
better outcome than a config-file check that can never observe its target.

---

## Linux — live-verifiable on `enclave-01`

| # | Policy | Break (→ RED) | Fix (→ GREEN) | Why the row count flips |
|---|---|---|---|---|
| 2 | host firewall effective (no unexpected listeners) | `nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &` | `pkill -f 'http.server 8080'` | a non-loopback TCP listener on :8080 appears in `listening_ports` outside the {22} allowlist → inner `EXISTS` true → outer `NOT EXISTS` → 0 rows |
| 3 | root account locked (no direct root login) | `echo 'root:AXIOMbreak123' \| chpasswd` | `passwd -l root` | setting a password makes `shadow.password_status='active'`; the query wants `'locked'` → 0 rows. `passwd -l` re-locks → 1 row |
| 6 | automatic security updates configured | `apt-get remove -y unattended-upgrades` | `apt-get install -y unattended-upgrades` | `deb_packages` row for `unattended-upgrades` loses `install ok installed` status (or is dropped) → 0 rows. *(needs NAT internet)* |
| 7 | no unauthorized SUID/SGID (outside system dirs) | `cp /bin/cp /usr/local/bin/rootcp && chmod u+s /usr/local/bin/rootcp` | `rm -f /usr/local/bin/rootcp` | a setuid file in `/usr/local/bin` (not an OS-managed dir) makes the inner subquery match → outer `NOT EXISTS` → 0 rows |
| 8 | enclave — weights-cache FIM canary unchanged | `printf 'x' >> /opt/axiom/weights-cache/canary.bin` | `printf 'AXIOM-CANARY-v1\n' > /opt/axiom/weights-cache/canary.bin` | appended byte changes the `hash.sha256`; it no longer equals the pinned value → 0 rows. Rewriting the exact 16 bytes restores the pin |
| 9 | enclave — no removable/USB media mounted | `mkdir -p /media/usbtest && mount -t tmpfs none /media/usbtest` | `umount /media/usbtest` | the tmpfs publishes a `/media/%` row in `mounts` → inner `EXISTS` → outer `NOT EXISTS` → 0 rows. A tmpfs under `/media` faithfully simulates a USB automount |
| 10 | enclave — AIDE host FIM installed (elevated bar) | `apt-get remove -y aide aide-common` | `apt-get install -y --no-install-recommends aide aide-common` | `deb_packages` loses the `aide` row → 0 rows. *(needs NAT internet)* |

> Enclave policies #8–#10 self-scope on `/etc/axiom/tier.d/elevated`; standard-tier hosts (no
> sentinel) **auto-pass** the first `NOT EXISTS(file …)` branch and are never evaluated.

## Linux — reprovision-only (documented; not a runtime toggle)

| # | Policy | Break | Fix | Note |
|---|---|---|---|---|
| 1 | full-disk encryption (LUKS) present | reprovision onto a non-LUKS root | reprovision with LUKS (subiquity encrypted-LVM / `cryptsetup luksFormat`) | FDE can't be toggled on a mounted root. **Standing expected-FAIL** on the throwaway cloud image — enforcement/escrow is a Fleet **Premium** capability; here we **detect** the gap. |
| 4 | OS at or above 24.04 baseline | reprovision an Ubuntu < 24.04 | `do-release-upgrade` to 24.04+ | spoofing `/etc/os-release` is not a valid test — it corrupts host identity for every query. |
| 5 | fleetd agent package present | `apt-get remove -y fleet-osquery` (self-defeating — the host stops reporting) | reinstall the enroll `.deb` | removing the telemetry agent is destructive/nonsensical to demo live. |

---

## macOS — documented (no host enrolled yet)

Runs as root on a real Mac once enrolled; several are reprovision/Recovery-gated as noted.

| # | Policy | Break (→ RED) | Fix (→ GREEN) | Note |
|---|---|---|---|---|
| 11 | FileVault enabled | `fdesetup disable -user <admin> -inputplist …` | `fdesetup enable -user <admin> -inputplist …` | needs a Secure-Token user + reboot; bare command hangs on a password prompt. |
| 12 | Application Firewall on | `socketfilterfw --setglobalstate off` | `socketfilterfw --setglobalstate on` | cleanest runtime break of the six — pure root, no GUI/reboot. A firewall config-profile would revert it. |
| 13 | Gatekeeper enabled | `spctl --master-disable` (Sonoma 14.x) | `spctl --master-enable` | **Sequoia 15+** removed `--master-disable` (GUI-only) — not run-script-able there. |
| 14 | SIP enabled | Recovery only: `csrutil disable` + reboot | Recovery only: `csrutil enable` + reboot | never remotely breakable — Recovery + console required. |
| 15 | screen lock ≤5 min (password on wake) | remove/replace the screen-lock **config profile** (idleTime>300) | re-push the compliant profile (idleTime ≤300) | reads `managed_policies` (MDM-sourced); `defaults write` does **not** move it (root reads 0 from the user domain). MDM action, not a shell command. |
| 16 | minimum OS version | reprovision < 14.6 (no downgrade command) | `softwareupdate -i -a --restart` (fix direction is runtime) | macOS can't be downgraded at runtime. |

## Windows — documented (no host enrolled yet)

Runs as SYSTEM via run-script; all read the `registry`/WMI-backed tables.

| # | Policy | Break (→ RED) | Fix (→ GREEN) | Note |
|---|---|---|---|---|
| 17 | BitLocker on OS drive | `manage-bde -protectors -disable C:` | `manage-bde -protectors -enable C:` | **suspend/resume** flips `protection_status` instantly with no decrypt wait — avoid `-off`/`-on` (full re/decrypt). |
| 18 | Firewall on (all profiles) | `reg add …\WindowsFirewall\PublicProfile /v EnableFirewall /d 0 /f` | set Domain+Private+Public `EnableFirewall` back to `1` | policy reads the GPO **Policies** hive, not live service state; the fix must set `1` (deleting → NULL ≠ '1' also fails). Any one profile suffices to break. |
| 19 | Defender real-time protection on | `reg add …\Real-Time Protection /v DisableRealtimeMonitoring /d 1 /f` | `reg delete … /v DisableRealtimeMonitoring /f` | inverted policy (`NOT EXISTS`). Tamper Protection may block/revert the write — verify persistence. |
| 20 | machine inactivity lock ≤5 min | `reg add …\System /v InactivityTimeoutSecs /d 900 /f` | `reg add … /v InactivityTimeoutSecs /d 300 /f` | registry read flips on next eval; OS enforcement waits for policy refresh. |
| 21 | UAC enabled | `reg add …\System /v EnableLUA /d 0 /f` | `reg add … /v EnableLUA /d 1 /f` | registry read flips without reboot; UAC *enforcement* needs a reboot. |
| 22 | minimum OS build | not runtime-breakable (reimage older build) | Windows Update to build ≥ 22631 | `os_version.build` is API-derived; don't spoof `CurrentBuildNumber`. |

---

## Test-plan provenance

Authored + **adversarially verified** by a 25-agent workflow (3 platform authors → 22 per-policy
skeptics). The verify pass **rejected the original #7 plan** — it proved the SUID allowlist was
incomplete for a stock 24.04 image, which drove the directory-scoped redesign above. #2/#3 were
reworked after the live augeas findings. 21/22 plans passed verification unchanged.
