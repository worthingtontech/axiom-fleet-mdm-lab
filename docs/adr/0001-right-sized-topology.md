# ADR-0001: Right-sized lab topology for a 63 GB Windows 11 Home host

- **Status:** Accepted (Phase 0 — topology approved and implemented; the stack + enclave-01 run within budget)
- **Date:** 2026-07-20
- **Deciders:** Founding Infrastructure Security Engineer (operator)
- **Phase:** 0 — Recon & plan

## Context

Project AXIOM must run the entire device-management platform for a fictional
frontier-AI company as a **local, $0 lab** on one physical machine. Phase 0
requires inventorying the host and scaling the VM plan to fit.

Measured host (real recon output, 2026-07-20):

| Resource        | Value                                            |
|-----------------|--------------------------------------------------|
| OS              | Windows 11 **Home**, build 26200                 |
| CPU             | AMD Ryzen 9 6900HX — 8 physical cores / 16 threads |
| RAM             | **63.2 GB** total (36.8 GB free at recon)        |
| Disk `C:`       | 929.8 GB total, **303.9 GB free**                |
| Virtualization  | VT firmware **enabled**; `HypervisorPresent=True` (WSL2/VBS active) |
| VirtualBox      | **7.1.4** installed                              |
| WSL2            | Platform enabled (default v2), **no distro yet** |
| Docker Desktop  | **not installed** (Phase 1 installs it)          |
| git             | 2.45.2                                           |

Operator decisions captured in Phase 0:

1. **Apple hardware = YES** — a maxed 2025 Mac Studio is available, but the
   operator wants to **onboard it last** (clone the private GitHub repo onto it
   and join it to the lab in a later pass). Therefore macOS is a **real-but-
   deferred** platform, not a permanently-simulated one. iOS remains simulated
   (no physical iPhone/iPad + Apple Business Manager in scope yet).
2. **RAM dedicated to the lab = 36 GB** (of 63.2 GB). Leaves ~27 GB for the host
   OS and the operator's normal work.

## Decision

Adopt the topology below. Total concurrent peak is **~33 GB**, which fits inside
the 36 GB budget **with no forced rotation** — every node can run at once. Two
nodes are nevertheless marked *on-demand* so the operator can reclaim RAM for
host responsiveness without breaking any phase.

| Host name        | Kind                              | Segment / Trust tier      | vCPU | RAM    | Disk  | Always-on? |
|------------------|-----------------------------------|---------------------------|------|--------|-------|------------|
| `axiom-core`     | Docker Compose stack (WSL2 backend): Fleet + MySQL 8 + Redis + Caddy, plus Phase 5–7 add-ons (Grafana, Loki, Prometheus, Vector, Keycloak, automation receiver, device-trust app) | Server infrastructure | shared | ~10 GB cap | ~25 GB imgs/vols | **yes** |
| `gpu-node-1`     | Ubuntu 24.04 **server** VM (VBox)  | ML Infrastructure / Standard | 2 | 2 GB | 20 GB | yes |
| `gpu-node-2`     | Ubuntu 24.04 **server** VM (VBox)  | ML Infrastructure / Standard | 2 | 2 GB | 20 GB | yes |
| `ml-workstation` | Ubuntu 24.04 **desktop** VM (VBox) | ML Infrastructure / Standard | 2 | 3 GB | 25 GB | yes |
| `enclave-01`     | Ubuntu 24.04 server VM, **hardened** (VBox) | **High-Trust Enclave / Elevated** | 2 | 2 GB | 20 GB | yes |
| `corp-win-01`    | Windows 11 Enterprise **Eval** VM (VBox) | Corp (IT/Finance/People) / Standard | 2 | 5 GB | 40 GB | yes |
| `corp-win-02`    | Windows 11 Enterprise Eval VM (VBox) | Corp / Standard | 2 | 5 GB | 40 GB | **on-demand** |
| `android-byod`   | Android 14+ AVD (Android Studio emulator, WHPX) | Mobile BYOD | — | 4 GB | 12 GB | **on-demand** |
| `mac-studio`     | **Real macOS** on 2025 Mac Studio (native + optional UTM macOS VMs) | Research & Eng / Standard | — | (Mac's own RAM) | — | **deferred** (separate host) |
| `ios-device`     | iOS | Mobile BYOD | — | — | — | **simulated** (authored + CI-validated) |

RAM math (worst case, everything local on this host at once):
`10 (core) + 2 + 2 + 3 (Linux std) + 2 (enclave) + 5 + 5 (Windows) + 4 (Android) = 33 GB ≤ 36 GB`.

### High-Trust Enclave differentiation (Fleet Free has no teams — see ADR-0003)

`enclave-01` is tiered up via **self-scoping policy SQL keyed on a provisioned
tier marker** (`/etc/axiom/trust-tier=elevated` + the canary path), plus the
free `platform` field and label-targeted queries — **not** the master prompt's
label/enroll-secret scoping, which is Premium and silently ignored on Free
(this was the plan's single biggest correction; full rationale in ADR-0003). It
still carries its own enroll secret as a Premium-ready artifact (cosmetic for
segmentation on Free). Controls: FDE verified, screen-lock ≤ 5 min, no removable
media, osquery FIM on `/opt/axiom/weights-cache`, and elevated thresholds.

## Consequences

**Positive**
- Full-fidelity endpoints: real VMs (not containers) mean disk-encryption, FIM,
  USB-storage, and firewall policies evaluate against real block devices and
  kernels — the policies are meaningful, not theater.
- Comfortable headroom (27 GB) keeps the host usable while the lab runs.
- macOS becomes a genuine enrolled node later, strengthening the portfolio.

**Negative / risks**
- **Hyper-V coexistence:** because Docker Desktop (WSL2) keeps the Windows
  hypervisor active, VirtualBox 7.1 runs its VMs through the Hyper-V API rather
  than raw AMD-V. Guests boot and run but with a measurable performance penalty
  (VBox shows the "reduced performance" turtle). Accepted for a lab; mitigation
  options (temporarily disabling the hypervisor) are rejected because Docker
  Desktop depends on it. See ADR-0002.
- The Windows 11 Enterprise Eval license is **90 days** — VMs must be
  rebuildable from Git before expiry (reinforces the zero-touch Phase 6 goal).
- `mac-studio` reachability: for real MDM check-in the Mac must have network
  line-of-sight to `axiom-core` (same LAN, or a free tunnel such as Tailscale /
  cloudflared). Deferred to a networking ADR when the Mac is onboarded.

## Alternatives considered

- **Run the Linux fleet as WSL2 distros or Docker containers** (cheaper RAM, no
  Hyper-V penalty). *Rejected:* shared kernel / no real block devices makes
  disk-encryption, FIM, and USB-storage policies meaningless — defeats the point
  of a policy-as-code demo.
- **Reduced topology (< 32 GB path from the master prompt).** *Not needed:* the
  host has 63 GB and the operator dedicated 36 GB; the full fleet fits.
- **Second Windows VM always-on.** *Deferred to on-demand:* one Corp Windows
  host is enough to demonstrate osquery + Windows MDM; the second exists only to
  prove the zero-touch rebuild (Phase 6) and fleet-scale queries.
