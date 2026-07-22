# Project AXIOM -- Policy-as-Code Compliance Matrix

This matrix maps the 22 hand-authored Fleet policies (see `gitops/default.yml`, top-level
`policies:` key) to their CIS benchmark controls, MITRE ATT&CK references, osquery tables, and
lab test posture. Fleet **FREE** v4.89.1.

## Why hand-mapping (the free-tier answer)

Fleet ships a curated **CIS Benchmark policy library**, but it is a **Premium** feature and, even
on Premium, the packaged coverage is **macOS and Windows only -- the Linux CIS set is empty**.
Because Project AXIOM's enrolled fleet is Linux-first (2x Ubuntu: `gpu-node-1` standard,
`enclave-01` elevated) and runs on the free tier, we cannot import that library. This document is
therefore the free-tier substitute: each policy is authored by hand and mapped here to the CIS
control and MITRE technique/mitigation it satisfies.

## Detection vs. enforcement (important caveat)

Every policy here is **detection-only** (`detection_only = Y` for all rows). A Fleet policy simply
runs a query and reports PASS/FAIL -- **a policy PASSES when its query returns at least one row (0
rows = FAIL); all SQL in the bank returns a row when the host is COMPLIANT.** Automatic
**enforcement / remediation** (scripts or profiles that auto-fix a failing host) is a Fleet
**Premium** capability and is out of scope on free tier. Treat these as an alerting/visibility
control, not a hard guardrail. The `critical` flag is set per policy but is **accepted-and-ignored
on free tier** (it only gates Premium features).

## Tiering, self-scoping, and platform pinning

- **Enclave self-scoping.** Policies #8-#10 are elevated-tier ("High-Trust Enclave") checks. Their
  SQL begins with `... WHERE NOT EXISTS (SELECT 1 FROM file WHERE path = '/etc/axiom/tier.d/elevated') OR ...`,
  so on standard hosts (which lack that sentinel file) the query returns a row and the policy
  **auto-passes**; only elevated hosts are actually evaluated. The sentinel is planted by the
  elevated cloud-init template and also drives the `high-trust-enclave` dynamic label.
- **Platform pinning is mandatory.** Every policy carries `platform:` (`linux` / `darwin` /
  `windows`). This is a free-tier osquery scheduling constraint: without it, a macOS/Windows query
  would be scheduled onto the Ubuntu hosts, hit nonexistent tables, error, and **false-FAIL**.
- **macOS / Windows are authored-only.** No macOS or Windows host is enrolled yet, so those rows
  are `N-A-until-enrolled` -- authored and shipped, but not yet observed live.

## Notes on the matrix columns

- **cis_benchmark** pins a specific benchmark document + version for traceability. Verify the pinned
  versions against your licensed CIS PDFs before an audit; the section numbers in **cis_control**
  come from the plan's research.
- **mitre_attack** uses ATT&CK **technique** IDs (T####) where the research pinned them (#8, #9) and
  ATT&CK **Mitigation** IDs (M####) elsewhere, since most of these controls are ATT&CK mitigations
  (e.g., M1041 Encrypt Sensitive Information, M1037 Filter Network Traffic).
- **status** advances through the pipeline `authored -> applied -> enrolled-verified`. All rows are
  currently `authored` (Phase 4: policy-as-code committed; not yet applied by CI or verified against
  live hosts).
- **live_testable**: `yes` = an enrolled host of that platform exists and results are observable now;
  `posture-only` = enrolled but the negative case cannot easily be exercised in the lab;
  `N-A-until-enrolled` = no host of that platform enrolled yet.

## Matrix (ordered by platform, then policy number)

| policy_id | policy_name | platform | tier | cis_benchmark | cis_control | mitre_attack | detection_only | live_testable | osquery_tables | status | notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| linux-luks-fde | Linux -- full-disk encryption (LUKS) present | linux | all | CIS Controls v8 | 3.6 | M1041 | Y | yes | disk_encryption | authored | Both Ubuntu hosts enrolled; may FAIL in lab if the VM disk is not LUKS (expected detection). |
| linux-ufw-enabled | Linux -- host firewall (ufw) enabled | linux | all | CIS Ubuntu Linux 24.04 LTS Benchmark v1.0.0 | 4.2.x | M1037 | Y | yes | augeas | authored | Reads /etc/ufw/ufw.conf via the augeas table. |
| linux-ssh-permitrootlogin-disabled | Linux -- SSH PermitRootLogin disabled | linux | all | CIS Ubuntu Linux 24.04 LTS Benchmark v1.0.0 | 5.1.20 | M1026 | Y | yes | augeas | authored | Reads sshd_config via the augeas lens; lower(value)='no'. |
| linux-os-baseline-2404 | Linux -- OS at or above 24.04 baseline | linux | all | CIS Ubuntu Linux 24.04 LTS Benchmark v1.0.0 | 1.2.2.1 | M1051 | Y | yes | os_version | authored | major>24 OR (major=24 AND minor>=4). |
| linux-fleetd-present | Linux -- fleetd agent package present | linux | all | CIS Controls v8 | 8, 13 | M1047 | Y | yes | deb_packages | authored | Package name pinned to fleet-osquery. |
| linux-auto-security-updates | Linux -- automatic security updates configured | linux | all | CIS Ubuntu Linux 24.04 LTS Benchmark v1.0.0 | 1.2.2.1 | M1051 | Y | yes | deb_packages | authored | unattended-upgrades installed. |
| linux-no-unauthorized-suid | Linux -- no unauthorized SUID binaries | linux | all | CIS Ubuntu Linux 24.04 LTS Benchmark v1.0.0 | 7.1.13 | M1022 | Y | yes | suid_bin | authored | Allowlist embedded in the query; tune per golden image. |
| enclave-weights-cache-fim-canary | AXIOM enclave -- weights-cache FIM canary unchanged | linux | enclave | N/A (MITRE ATT&CK) | - | T1565.001 | Y | yes | file, hash | authored | Self-scopes on /etc/axiom/tier.d/elevated so standard hosts auto-pass; canary seeded byte-exactly by the elevated cloud-init (sha256 pinned). |
| enclave-no-removable-media | AXIOM enclave -- no removable/USB media mounted | linux | enclave | N/A (MITRE ATT&CK) | - | T1091, T1052.001, M1034 | Y | posture-only | file, mounts | authored | Self-scopes to elevated; negative case hard to exercise in lab (no USB attach). Checks /media, /run/media, /mnt. |
| enclave-aide-installed | AXIOM enclave -- AIDE host FIM installed (elevated bar) | linux | enclave | CIS Ubuntu Linux 24.04 LTS Benchmark v1.0.0 | 6.1.x | M1047 | Y | yes | file, deb_packages | authored | Self-scopes to elevated (elevated bar); standard tier is not required to run AIDE. |
| macos-filevault-enabled | macOS -- FileVault enabled | darwin | all | CIS Apple macOS 14.0 Sonoma Benchmark v1.0.0 | 2.6.6 | M1041 | Y | N-A-until-enrolled | disk_encryption | authored | platform: darwin keeps this off the Ubuntu hosts. |
| macos-app-firewall-on | macOS -- Application Firewall on | darwin | all | CIS Apple macOS 14.0 Sonoma Benchmark v1.0.0 | 2.2.1 | M1037 | Y | N-A-until-enrolled | alf | authored | global_state >= 1. |
| macos-gatekeeper-enabled | macOS -- Gatekeeper enabled | darwin | all | CIS Apple macOS 14.0 Sonoma Benchmark v1.0.0 | 2.6.5 | M1038 | Y | N-A-until-enrolled | gatekeeper | authored | assessments_enabled AND dev_id_enabled. |
| macos-sip-enabled | macOS -- SIP enabled | darwin | all | CIS Apple macOS 14.0 Sonoma Benchmark v1.0.0 | 2.6.x | M1046 | Y | N-A-until-enrolled | sip_config | authored | config_flag='sip' AND enabled=1. |
| macos-screen-lock-5min | macOS -- screen lock <=5 min (password on wake) | darwin | all | CIS Apple macOS 14.0 Sonoma Benchmark v1.0.0 | 2.10.x | M1026 | Y | N-A-until-enrolled | managed_policies | authored | Requires an MDM-delivered configuration profile; idleTime <=300 and no conflicting >300 policy. |
| macos-min-os-version | macOS -- minimum OS version | darwin | all | CIS Apple macOS 14.0 Sonoma Benchmark (patch posture) | - | M1051 | Y | N-A-until-enrolled | os_version | authored | Minimum 14.6 (major>14 OR major=14 AND minor>=6). |
| windows-bitlocker-os-drive | Windows -- BitLocker on OS drive | windows | all | CIS Microsoft Windows 11 Enterprise Benchmark v3.0.0 | 18.10.9 | M1041 | Y | N-A-until-enrolled | bitlocker_info | authored | drive_letter='C:' AND protection_status=1. |
| windows-firewall-all-profiles | Windows -- Firewall on (all profiles) | windows | all | CIS Microsoft Windows 11 Enterprise Benchmark v3.0.0 | 9.x | M1037 | Y | N-A-until-enrolled | registry | authored | Domain + Private + Public EnableFirewall policy keys all = 1. |
| windows-defender-realtime-on | Windows -- Defender real-time protection on | windows | all | CIS Microsoft Windows 11 Enterprise Benchmark v3.0.0 | 18.10.42.x | M1049 | Y | N-A-until-enrolled | registry | authored | PASS when DisableRealtimeMonitoring is absent or not 1. |
| windows-inactivity-lock-5min | Windows -- machine inactivity lock <=5 min | windows | all | CIS Microsoft Windows 11 Enterprise Benchmark v3.0.0 | 2.3.7.4 | M1026 | Y | N-A-until-enrolled | registry | authored | InactivityTimeoutSecs <=300 and !=0. |
| windows-uac-enabled | Windows -- UAC enabled | windows | all | CIS Microsoft Windows 11 Enterprise Benchmark v3.0.0 | 2.3.17.6 | M1052 | Y | N-A-until-enrolled | registry | authored | EnableLUA=1. |
| windows-min-os-build | Windows -- minimum OS build | windows | all | CIS Microsoft Windows 11 Enterprise Benchmark (patch posture) | - | M1051 | Y | N-A-until-enrolled | os_version | authored | Build >= 22631 (Windows 11 23H2 baseline). |

_Free tier v4.89.1. 22 policies: 10 Linux (3 enclave-scoped), 6 macOS, 6 Windows. All detection-only; enforcement is Premium._
