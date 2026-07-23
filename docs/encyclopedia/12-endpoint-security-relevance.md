# 🛡️ Endpoint-Security Relevance of the Deep Components
> Part of the **[Project AXIOM Encyclopedia](./README.md)** · Layer: Cross-cutting / endpoint-security relevance. The other files explain *what each component is and how it talks*; this one answers the security question a reviewer actually asks — **so what does it enforce or reveal on the machine, and why does that matter?** Every entry is deliberately shaped the same way: **WHAT IT IS → WHAT IT ENFORCES / REVEALS ON THE ENDPOINT → WHY IT MATTERS**, pinned to the *real* keys, tables, OMA-URIs, and files in this lab.

The deep components — the Windows registry, CSPs, osquery tables, MDM enrollment, the two CAs, policy-as-code, trust tiering — are usually taught at the *protocol* level: which port, which handshake, which XML envelope. That is necessary but not sufficient for a security engineer, who has to be able to point at a **specific byte on a specific host** and say "*this* is the setting that stops *that* attack, and *this* is how I know its true state." This file is that translation layer. It reads the repo's own controls — `gitops/default.yml`, `gitops/lib/windows/configuration-profiles/patch-deadline.xml`, the WSTEP CA under `infra/mdm/`, the canary gate in `gitops/promote/promote.ps1` — and for each one names the exact registry value, osquery table/column, or on-device artifact that carries the security fact. Where AXIOM is **detect-only** (the common Free-tier reality), it says so; where a control physically *changes* the device, it shows the write.

A single invariant frames everything below and is worth stating once: on Fleet Free, **osquery is the read path and MDM/CSP is the write path**. osquery *reveals* posture (it can only look); a CSP or profile *enforces* posture (it changes the OS). Most of AXIOM's live controls are on the read side — detection — because delivery of the write side (config profiles) is Premium ([05](./05-mdm.md), [07](./07-policy-as-code.md)). Keeping that split straight is the whole game.

---

## 1. The Windows registry as a posture surface

- **What it is** — the registry is Windows' hierarchical, kernel-backed configuration database (hives like `HKEY_LOCAL_MACHINE`). Security-relevant OS state — is UAC on? is the firewall enabled per profile? is Defender's real-time engine allowed to run? — is not scattered in text files as on Linux; it is a **typed value at a well-known path**. Crucially, the *policy-managed* form of each setting lives under a `\Policies\` subtree (`HKLM\SOFTWARE\Policies\...` and `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\...`), which is where Group Policy **and** MDM/CSP writes land and which takes precedence over the user-facing toggle.
- **What it reveals on the endpoint** — AXIOM's Windows policies ([`gitops/default.yml`](../../gitops/default.yml)) read these exact values through osquery's `registry` table. Each row is one security fact:

  | Control | Registry path (all under `HKEY_LOCAL_MACHINE`) | Compliant value | osquery in the repo |
  |---|---|---|---|
  | **UAC on** | `\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\EnableLUA` | `data = '1'` | `registry` — pass iff `EnableLUA=1` |
  | **Defender real-time on** | `\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection\DisableRealtimeMonitoring` | value **absent or ≠ 1** | `registry` — pass iff `NOT EXISTS(... data='1')` |
  | **Firewall on (all 3 profiles)** | `\SOFTWARE\Policies\Microsoft\WindowsFirewall\{Domain,Private,Public}Profile\EnableFirewall` | each `= '1'` | `registry` — three-way AND |
  | **Inactivity lock ≤ 5 min** | `\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs` | `1 ≤ CAST(data) ≤ 300` | `registry` — `<=300 AND !=0` |
  | **BitLocker OS-drive encryption** | *(policy form)* `\SOFTWARE\Policies\Microsoft\FVE\*` | — | read instead via the `bitlocker_info` table (see below) |

  Two subtleties the repo's SQL encodes deliberately. **Defender is checked by absence** (`NOT EXISTS ... data='1'`): the tamper you care about is something *setting* `DisableRealtimeMonitoring=1`, so "the disable flag is not asserted" is the true health signal, and a never-touched host correctly passes. **Inactivity uses `!= 0`** because `InactivityTimeoutSecs = 0` means "never lock" — a zero must fail, not pass, so the guard is `<= 300 AND != 0`, not just `<= 300`.
- **Why it matters** — these five keys are, concretely, the difference between a hardened corporate laptop and an open one: UAC off means silent privilege escalation, a disabled Defender engine means malware runs unwatched, a firewall-off profile means inbound attack surface, and "never lock" means an unattended session is a walk-up compromise. Because they live at fixed registry paths, they are **machine-readable posture** — you don't have to trust a screenshot or a user's word; osquery reads the kernel's own answer. That is *why* the `registry` table exists in Fleet's schema and why AXIOM leans on it: it turns "is this box configured safely?" into a `SELECT` that returns 1 row (pass) or 0 (fail). → the pass/fail mechanics live in [07 §2](./07-policy-as-code.md); the *write* that would set these keys is the CSP in §2 below.
- **Gotcha** — osquery's `registry` returns everything as a **string** (`data`), so numeric comparisons need `CAST(... AS INTEGER)` (as the inactivity policy does). And the registry read is **detection only** — osquery cannot *set* a key; flipping `EnableLUA` back on is either a script (run-script API) or a Policy-CSP write (Premium delivery). See [§6](#6-policy-as-code--remediation--the-detect--enforce-loop).
- **See also** — [Windows CSP](./05-mdm.md) · [osquery tables](#3-osquery-tables-as-a-posture-lens) · [ADR-0008 table realities](../adr/0008-osquery-table-detection-choices.md)

---

## 2. Configuration profiles / CSPs — what they physically do to a device

- **What it is** — a **CSP (Configuration Service Provider)** is the Windows-side handler that turns an inbound MDM instruction into a real OS change ([05 §8](./05-mdm.md)). You address a CSP node by an **OMA-URI** — a path like `./Device/Vendor/MSFT/Policy/Config/Update/ConfigureDeadlineForQualityUpdates` — and a SyncML `Replace` carrying a typed value lands on it. A **configuration profile** is a Git-tracked bundle of such writes; AXIOM's one real profile is [`gitops/lib/windows/configuration-profiles/patch-deadline.xml`](../../gitops/lib/windows/configuration-profiles/patch-deadline.xml).
- **What it enforces on the endpoint** — the worked example is patch-deadline enforcement via the **Update (Policy) CSP**. The profile issues five `Replace` ops:

  | OMA-URI (`./Device/Vendor/MSFT/Policy/Config/Update/…`) | Value | Effect on the device |
  |---|---|---|
  | `ConfigureDeadlineForQualityUpdates` | `7` | quality (security) updates **must** install within 7 days |
  | `ConfigureDeadlineForFeatureUpdates` | `14` | feature updates must install within 14 days |
  | `ConfigureDeadlineGracePeriod` | `2` | 2-day active-hours grace, then… |
  | `ConfigureDeadlineNoAutoReboot` | `0` | …an **automatic restart is allowed** so the patch actually lands |
  | `AllowAutoUpdate` | `4` | auto-download and scheduled-install |

  Physically, when the enrolled OMA-DM client dispatches these to the Update CSP, the CSP writes the corresponding values under the device's **`HKLM\SOFTWARE\Microsoft\PolicyManager\...\Update`** policy store — the same policy-managed registry subtree from §1, now *written by the server* instead of *read by osquery*. That is the concrete answer to "what does a CSP do to a machine": it is a remote, authenticated write into the policy hive that the OS then obeys. A BitLocker CSP write (`./Device/Vendor/MSFT/BitLocker/RequireDeviceEncryption`) analogously lands under `HKLM\SOFTWARE\Policies\Microsoft\FVE` and triggers encryption.
- **How macOS differs** — Apple has no registry; the equivalents are **`.mobileconfig`** profiles (imperative "install these payloads" — a passcode payload sets `pwpolicy` state, a restrictions payload disables USB mass storage) and **DDM declarations** (JSON the device evaluates itself and reports on unprompted) — see [05 §5](./05-mdm.md). The security-meaningful difference from Windows: a macOS profile is only **"verified"** once the *device re-reports* the setting (osquery/MDM read-back), so "applied" and "confirmed enforced" are two distinct states. On Windows the CSP returns a SyncML `Status` code per node instead. Either way, **read-back is the proof of enforcement** — a queued write is not a landed write.
- **Why it matters** — patch latency is one of the most reliably-exploited gaps in real fleets; an unenforced "please update eventually" is how a month-old CVE stays live on a laptop. The CSP converts that from a hope into a **deadline the OS enforces with a forced reboot**. More generally, CSPs/profiles are the *only* way (short of a login script) to make a setting **sticky** — the OS remembers the server owns it and reverts local tampering, which a one-shot remediation script cannot do.
- **AXIOM reality (honest scope)** — this profile is **authored and CI-validated but not live-delivered**: delivering Windows MDM configuration profiles via GitOps is **Fleet Premium** ("missing or invalid license" on Free), and no Windows host has finished the enrollment last mile yet ([ADR-0005](../adr/0005-windows-mdm-enablement.md), [ADR-0002](../adr/0002-vm-backend-virtualbox-cloudinit.md)). So in this lab the **enforcement mechanism** is proven-as-code while the **patch posture** is detected for free by the min-OS-build policy (`Windows -- minimum OS build`, `build >= 22631`). The `default.yml` `controls.windows_settings.configuration_profiles` block is committed but commented, with `windows_enabled_and_configured: true` as the one hand-added toggle that turns Windows MDM on server-side.
- **See also** — [OMA-DM / SyncML](./05-mdm.md) · [Detection vs enforcement](./07-policy-as-code.md) · [Registry posture](#1-the-windows-registry-as-a-posture-surface)

---

## 3. osquery tables as a posture lens

- **What it is** — osquery presents the OS as SQL virtual tables ([07 §1](./07-policy-as-code.md)); a *posture* query is one whose single row answers a security question. Below is the exact set AXIOM's policies and reports read, each with the one security fact it reveals. Read this as the lab's detection surface.

  | Table (platform) | The security fact it reveals |
  |---|---|
  | **`disk_encryption`** (linux/darwin) | data-at-rest protection — `encrypted=1` proves LUKS FDE (Linux) / `filevault_status='on'` proves FileVault; a lost or seized disk is unreadable. |
  | **`bitlocker_info`** (windows) | Windows OS-drive encryption — `drive_letter='C:' AND protection_status=1`; the Windows analog of `disk_encryption`, WMI-backed not registry. |
  | **`alf`** (darwin) | the macOS Application Firewall is on — `global_state >= 1`; inbound network exposure is filtered. |
  | **`gatekeeper`** (darwin) | only signed/notarized code runs — `assessments_enabled=1 AND dev_id_enabled=1`; blocks unsigned malware execution. |
  | **`sip_config`** (darwin) | System Integrity Protection is on — `config_flag='sip' AND enabled=1`; root itself cannot tamper with system files/processes. |
  | **`managed_policies`** (darwin) | an MDM setting **actually applied** — e.g. `com.apple.screensaver / idleTime <= 300`; this is the read-**back** that proves a profile landed, not merely that it was sent. |
  | **`shadow`** (linux) | root cannot be logged into directly — `username='root' AND password_status='locked'`; forces accountable per-user sudo (ADR-0008 proxy for `PermitRootLogin no`). |
  | **`listening_ports`** (linux) | inbound attack surface — no non-loopback TCP listener outside `{22}`; reveals the firewall's *effect* because `iptables` is empty on 24.04's nftables backend (ADR-0008). |
  | **`suid_bin`** (linux) | privilege-escalation footholds — any SUID/SGID binary *outside* OS-managed dirs (`/tmp`, `/opt`, `/usr/local`…); directory-scoped to survive usrmerge aliasing (ADR-0008). |
  | **`deb_packages`** (linux) | required security software present — `fleet-osquery` (the agent itself), `unattended-upgrades` (auto-patching), `aide` (host FIM) each installed. |
  | **`hash`** (linux) | integrity of a specific file — the enclave weights-cache canary `sha256` matches its pinned value; any change is tamper/exfil-staging. |
  | **`registry`** (windows) | the five Windows posture keys of §1 (UAC, Defender, firewall ×3, inactivity) — Windows' equivalent of reading a config file. |

- **What it reveals vs. what it enforces** — every table above is **read-only**. osquery is a camera, not a lock ([05 §1](./05-mdm.md)): `disk_encryption` tells you FileVault is *off*, it cannot turn it *on*. That is the entire reason AXIOM's Phase-4 posture is honestly "**detect**, then remediate by script/CSP," not "prevent at the kernel" ([11 model-weights protection](./11-concepts-and-trust-model.md)).
- **Why it matters — and the ADR-0008 lesson** — the highest-value teaching here is that **"the schema has a table" ≠ "the table is populated on this build."** AXIOM discovered live, on `enclave-01`, that the *obvious* table silently fails on `fleetd`'s bundled osquery on Ubuntu 24.04:
  - **`augeas` ships no lenses** → `SELECT count(*) FROM augeas` returns 0, so reading `ufw.conf`/`sshd_config` through it is a permanent false-red. Re-authored onto `listening_ports` (firewall effect) and `shadow` (root locked).
  - **`iptables` is empty** (ufw uses the nftables backend; osquery reads the legacy path) even with ufw active → posture read from `listening_ports` instead.
  - **`suid_bin` double-counts** usrmerge aliases (`/bin` == `/usr/bin`) → a per-path allowlist is brittle, so the policy is **directory-scoped** to writable dirs.

  A posture query is only as good as the table under it actually being populated on *your* pinned agent — the lesson is to verify every table against the live `fleetd` before trusting a green.
- **See also** — [osquery tables & SQL](./07-policy-as-code.md) · [ADR-0008 detection choices](../adr/0008-osquery-table-detection-choices.md) · [Registry posture](#1-the-windows-registry-as-a-posture-surface) · [FIM canary](#7-fim--auditd--integrity-on-the-crown-jewels)

---

## 4. MDM enrollment — the trust and control it establishes

- **What it is** — enrollment is the one-time ceremony that turns a stranger device into one Fleet is *authorized to command* ([05 §2](./05-mdm.md)). On `corp-win-01` this is the **Free manual path**: *Settings → Accounts → Access work or school → Enroll only in device management* (MDM without an Entra tenant), and it is turned on server-side by `windows_enabled_and_configured: true` in [`gitops/default.yml`](../../gitops/default.yml).
- **What it establishes on the endpoint** — three concrete, durable artifacts land on the device, and they are the whole point:
  1. **A device identity certificate** (minted via **WSTEP** on Windows, SCEP on Apple) is written into the machine's **certificate store**. This becomes the credential the device presents on **every** subsequent OMA-DM check-in — it is the answer to "which host is calling?" and it is *not* the same as the fleetd enroll secret (that belongs to the osquery channel).
  2. **A poll schedule** — the **DMClient CSP** writes the management-server URL and check-in cadence into the registry, so the OMA-DM client knows when and where to phone home.
  3. **Delegated authority** — enrollment is what grants the server permission to write **privileged CSP nodes**: BitLocker, RemoteWipe, the Update deadlines of §2. Before enrollment those nodes are unreachable; after it, the server can encrypt, lock, or wipe. Enrollment is the "power of attorney" that makes §2 possible at all.
- **Why it matters** — this is the moment a device moves from *observed* (osquery telemetry) to *controllable* (MDM). The identity cert is the trust anchor: lose control of the issuing CA and an attacker can impersonate an enrolled device or, worse, stand up a rogue management server. That is exactly why the two CAs are kept separate (next entry). It also explains a real AXIOM limitation — a **manually** enrolled Mac is **not supervised**, so the strongest Apple commands (EraseDevice on Apple silicon) are unavailable regardless of license ([05 §6/§12](./05-mdm.md)).
- **AXIOM reality** — enrollment is the **documented last mile**: `corp-win-01` installs and AutoLogons fine, but the osquery/MDM enroll didn't complete because Hyper-V/NEM coexistence can soft-lock `orbit` (ADR-0002 operational finding); a hard reset clears the wedge (that is how `canary-01` enrolled). So the Windows write-path is authored and server-enabled, awaiting a clean enroll.
- **See also** — [Enrollment & WSTEP](./05-mdm.md) · [The two CAs](#5-two-cas-two-different-things-they-protect) · [Windows CSP authority](./05-mdm.md)

---

## 5. Two CAs, two different things they protect

- **What it is** — the lab runs **two independent certificate authorities** that are easy to conflate but guard entirely different channels:
  - the **mkcert root CA** (`rootCA.pem`), the transport/TLS anchor ([04](./04-tls-and-pki.md));
  - the **WSTEP identity CA** ([`infra/mdm/fleet-mdm-win-wstep.crt`](../../infra/mdm/) + `.key`, generated by [`infra/scripts/new-wstep-ca.ps1`](../../infra/scripts/new-wstep-ca.ps1)).
- **What each protects on the endpoint** —
  - The **mkcert root** is baked into the fleetd package's `certs.pem` and validates Caddy's leaf on every osquery check-in. It guards the **telemetry + enroll channel**: without it pinned, a rogue Fleet could harvest full host inventory and the enroll secret. It authenticates *the server to the agent* (osqueryd ignores the OS trust store, so this CA must be baked in — [04](./04-tls-and-pki.md)).
  - The **WSTEP identity CA** signs the Windows **device identity certificate** issued at enrollment (§4). It authenticates *the device to the management server* on the **OMA-DM management channel** — i.e. it gates **who may receive privileged CSP writes, lock, or wipe**. It is the anchor of the *control* plane, where mkcert is the anchor of the *observation* plane.
- **Why it matters** — the split is a clean least-privilege boundary: compromising the transport CA lets you eavesdrop/impersonate the *read* path; compromising the WSTEP CA lets you forge a *managed device's* control identity. Keeping them separate means one breach doesn't grant both. It also maps to the two "who is calling?" credentials that trip people up — the **fleetd enroll secret** (osquery channel) and the **MDM identity cert** (management channel) are different secrets on different CAs for different planes.
- **See also** — [TLS & PKI / the certs.pem split](./04-tls-and-pki.md) · [MDM enrollment](#4-mdm-enrollment--the-trust-and-control-it-establishes) · [Defense-in-depth layers](./11-concepts-and-trust-model.md)

---

## 6. Policy-as-code + remediation — the detect → enforce loop

- **What it is** — the closed loop that makes detection *actionable*: a version-controlled osquery **policy** judges posture pass/fail ([07 §2](./07-policy-as-code.md)); a **failing-policy webhook** or **run-script automation** reacts ([07 §9](./07-policy-as-code.md), [10](./10-automation-and-ir.md)); a re-evaluation confirms the fix. Because osquery can only *read*, remediation is where the "enforce" half of a $0 fleet actually happens.
- **What it enforces on the endpoint** — the loop is: **osquery reads a posture fact → Fleet marks the host red → a script runs on the host → the fact flips → the host goes green.** Concretely in this repo the remediation is a real host script (e.g. [`gitops/lib/linux/scripts/install-auditd.sh`](../../gitops/lib/linux/scripts/) installs and enables `auditd`), delivered via the **free run-script API** and pulled/executed by `orbit` on the host. There are two live remediation flavors: the classic webhook→receiver→run-script SOAR loop, and AXIOM's built **Claude-in-the-loop** path ([`gitops/remediate/claude-remediate.ps1`](../../gitops/remediate/) + workflow), which drafts a fix as a reviewable PR rather than auto-applying — human-gated enforcement.
- **Why it matters** — this is the honest answer to "you can only detect on Free, so what good is it?" Detection without response is a dashboard; the run-script API turns a red policy into a **corrected machine** at $0. It is also why the lab's weights protection is honestly a *detect-and-remediate* model, not a *prevent-at-the-kernel* model ([11](./11-concepts-and-trust-model.md)): the kernel-level enforcement (forced FDE, blocked USB) is Premium, but the detect→script→verify loop closes the gap for free. The MTTR — webhook to green — is the metric that makes it real.
- **Gotcha (timing)** — the loop is not instant: a policy can stay red for up to the policy-update interval (~1h) and a webhook may wait up to the automation interval (~24h) before firing ([07 §12](./07-policy-as-code.md)). Fast demos lower those intervals; production accepts the latency by design.
- **See also** — [Policy pass/fail](./07-policy-as-code.md) · [Automation & IR](./10-automation-and-ir.md) · [Model-weights protection loop](./11-concepts-and-trust-model.md)

---

## 7. FIM + auditd — integrity on the crown jewels

- **What it is** — file-integrity monitoring on the enclave's model-weights canary, paired with process-level auditing. Two osquery mechanisms cooperate: the **evented `file_events`** table (inotify) watches the path in real time, and a **`hash`-based policy** checks the canary against a pinned digest ([07 §10](./07-policy-as-code.md), [11 enclave](./11-concepts-and-trust-model.md)).
- **What it reveals on the endpoint** — the live control in [`gitops/default.yml`](../../gitops/default.yml) is *"AXIOM enclave -- weights-cache FIM canary unchanged"*: it passes iff `sha256` of `/opt/axiom/weights-cache/canary.bin` equals the pinned `7954095f...0b92`, so **any** modification of that file flips it red. `file_events` needs three agent-option flags to reveal anything: `--disable_events=false`, `--enable_file_events=true`, and a `file_paths` glob (`weights: ["/opt/axiom/weights-cache/%%"]`) — miss any one and the table is silently empty. The process-level companion is [`gitops/lib/linux/policies/canary-auditd.yml`](../../gitops/lib/linux/policies/canary-auditd.yml), which installs `auditd` on the canary cohort as the syscall-audit layer alongside inotify FIM.
- **Why it matters** — model weights are the fictional crown jewel; the canary is valuable precisely because it holds nothing secret, so *any* activity on it is inherently suspicious (a honeytoken). The pinned hash makes tamper detection binary and unforgeable-without-notice. The `auditd` pairing matters because `file_events` is **evented** — it only sees changes that happen *while osqueryd is watching*, so "no FIM alert" is not proof "nothing happened" if the agent was down; syscall auditing narrows that blind spot.
- **See also** — [FIM & evented tables](./07-policy-as-code.md) · [The enclave](./11-concepts-and-trust-model.md) · [hash table](#3-osquery-tables-as-a-posture-lens)

---

## 8. Trust tiering + canary — blast-radius controls

- **What it is** — two mechanisms that bound *how far a bad change can spread* before it is caught: **trust tiering** (self-scoping policy SQL keyed on the provisioned marker `/etc/axiom/tier.d/elevated`) that grades the enclave against a stricter bar without touching Standard hosts ([07 §6](./07-policy-as-code.md), ADR-0003), and the **canary cohort** (keyed on `/etc/axiom/canary`) that proves a new control on a tiny population before it goes fleet-wide (ADR-0009).
- **What it enforces on the endpoint** — tiering is enforced *in the query*: a tier policy returns a row (pass) for any host lacking the `elevated` marker, so only `high-trust-enclave` members can go red on enclave-grade controls — the blast radius of a strict new rule is one host, not the fleet. The canary control ([`canary-auditd.yml`](../../gitops/lib/linux/policies/canary-auditd.yml)) auto-passes any host without `/etc/axiom/canary`, so it truly grades only the canary cohort. Promotion to production is **telemetry-gated** by [`gitops/promote/promote.ps1`](../../gitops/promote/promote.ps1): three PromQL checks against the custom `fleet-exporter` — `axiom_exporter_up == 1` (telemetry alive), `axiom_label_hosts{label="canary"} >= 1` (cohort exists), and `max_over_time(axiom_policy_failing_hosts{policy=P}[soak]) == 0` (zero failures, soaked) — must all hold before the query is widened fleet-wide. This loop was proven live end-to-end on `canary-01`: fail → gate **HOLD** → run-script remediate → pass → gate **PROMOTE**.
- **Why it matters** — these are the classic **blast-radius / progressive-rollout** controls that separate a mature change process from "push to prod and pray." Tiering means the enclave can be paranoid without freezing normal work (and normal work can't drag the enclave down); canary means a mis-authored policy or a bad remediation is caught on one node under telemetry watch, not discovered as a fleet-wide false-red. Both are the same idea applied to *space* (which hosts) and *time* (rollout order): limit the damage a single mistake can do before a human or a gate stops it.
- **AXIOM reality** — the marker is **host-local**, so a host could self-downgrade by deleting its own marker; acceptable for a lab, cross-checked against intrinsic signals (hostname prefix, canary path) and named as a known limitation that Premium server-side Teams would remove ([07 §6](./07-policy-as-code.md), [11](./11-concepts-and-trust-model.md)).
- **See also** — [Self-scoping SQL / ADR-0003](./07-policy-as-code.md) · [Trust tiers](./11-concepts-and-trust-model.md) · [Progressive rollout gate (ADR-0009)](../adr/0009-canary-progressive-rollout.md) · [Telemetry / fleet-exporter](./08-telemetry-and-observability.md)

---

> **Layer complete.** The through-line: **osquery reveals, MDM/CSP enforces, and the registry / tables / OMA-URIs are where each becomes a concrete byte you can point at.** UAC/Defender/firewall/inactivity are specific `HKLM\...\Policies\...` values read by the `registry` table; BitLocker/LUKS/FileVault are `bitlocker_info`/`disk_encryption`; the patch-deadline profile is five `Update`-CSP `Replace` writes into the policy hive; enrollment plants an identity cert (on the **WSTEP** CA, distinct from the **mkcert** transport CA) that unlocks privileged CSP writes; policy-as-code + run-script close the detect→enforce loop at $0; and tiering + canary bound the blast radius in space and time. Where AXIOM is detect-only or delivery-Premium or awaiting the Windows enroll last-mile, the text says so. Back to the [Encyclopedia index](./README.md).
