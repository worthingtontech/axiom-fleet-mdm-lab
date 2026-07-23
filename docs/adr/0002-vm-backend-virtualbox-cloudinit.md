# ADR-0002: VirtualBox + cloud-init (NoCloud) as the VM backend

- **Status:** Proposed (Phase 0)
- **Date:** 2026-07-20
- **Phase:** 0 — Recon & plan
- **Related:** ADR-0001 (topology)

## Context

The master prompt allows "VirtualBox (or Multipass with the VirtualBox
backend)" and calls for a **cloud-init**-driven Linux zero-touch story (Phase 2
/ Phase 6). The host is Windows 11 **Home** with VirtualBox 7.1.4 already
installed and Docker Desktop (WSL2) about to be installed, so a Windows
hypervisor will be active.

Constraints that shape the choice:
- $0, reproducible **from Git alone**.
- Windows 11 **Home** — no Hyper-V Manager; Multipass's primary Windows backend
  (Hyper-V) is therefore awkward, and its VirtualBox backend has been an
  intermittently-supported second-class path on Windows.
- Linux nodes must be real VMs (per ADR-0001) and must install `fleetd` on
  **first boot with zero interactive steps**.

## Decision

Use **VirtualBox 7.1 driven by scripted `VBoxManage`**, with **cloud-init via a
NoCloud seed ISO** built from Git-tracked `user-data` / `meta-data` YAML, booting
the official **Ubuntu 24.04 cloud image**.

- VM lifecycle (create / configure / attach seed ISO / start / destroy) is a
  committed PowerShell + `VBoxManage` script under `infra/` and `provisioning/`.
- Per-node cloud-init YAML lives in `provisioning/` and encodes: install fleetd
  from the Git-tracked `.deb`, trust the mkcert root CA, set the enroll secret
  (from a gitignored env, not the repo), and assign the node's Fleet label.
- The **High-Trust Enclave** node uses a distinct seed (its own enroll secret +
  hardening cloud-init).
- **Windows** Eval VMs also run under VirtualBox (Phase 6 uses
  `unattend.xml` + a provisioning package, not cloud-init).
- The **Android** emulator is out of scope for this backend — it runs under
  Android Studio using WHPX (coexists with the active Windows hypervisor).

## Consequences

**Positive**
- One fewer dependency to install; nothing beyond the already-present VirtualBox.
- Fully transparent and reproducible: every byte of VM config is a `VBoxManage`
  flag or a cloud-init line in Git — no opaque Multipass state.
- cloud-init NoCloud is the same mechanism real cloud/MAAS provisioning uses, so
  the artifact is production-idiomatic and doubles as the Linux zero-touch story.

**Negative / risks**
- More boilerplate than `multipass launch` (must script VM creation, disk, NIC,
  and seed-ISO attach). Mitigated by a reusable `new-linux-vm.ps1` helper.
- Hyper-V coexistence performance penalty (see ADR-0001). Accepted.
- Building the NoCloud seed ISO on Windows needs an ISO tool; will use
  `oscdimg` (Windows ADK) or a small `mkisofs`/`genisoimage` in WSL — decided at
  implementation time and noted in Phase 2.

## Alternatives considered

- **Multipass (VirtualBox backend).** Nicer ergonomics (`multipass launch
  --cloud-init`), but on Windows 11 Home the VirtualBox backend is a fragile,
  less-documented path and Multipass abstracts networking in ways that
  complicate "the Fleet server can reach this endpoint." *Rejected* for
  reproducibility and transparency; re-evaluate if raw VBox scripting proves
  painful.
- **Vagrant + VirtualBox.** Mature, but adds Ruby/Vagrant as a dependency and
  its own box-versioning story; cloud-init NoCloud on raw VBox covers the need
  without it.
- **WSL2 / containers as "Linux hosts."** Rejected in ADR-0001 (no real block
  devices → meaningless FDE/FIM policies).

## Operational finding (2026-07-22): NEM soft-lockups wedge the agent, not the network

The Hyper-V-coexistence penalty noted above has a sharp failure mode worth recording, because chasing
it the wrong way costs hours.

**Symptom.** Recently-provisioned VMs (`corp-win-01`, `canary-01`) finished cloud-init but never
appeared in Fleet — while *earlier* VMs (`gpu-node-1`, `enclave-01`) had enrolled fine on the same
setup. It looked like a networking regression.

**Red herring — it was NOT NAT/TLS.** The tempting hypothesis (VBox NAT `10.0.2.2` can't reach the
host's Docker-published Caddy `:443`, which showed IPv6-only in `Get-NetTCPConnection`) was
**disproven**: baking the `axiom-lab` SSH key into cloud-init + a temporary
`VBoxManage controlvm <vm> natpf1 "ssh,tcp,127.0.0.1,2222,,22"` gives a guest shell despite NAT, and
from inside the guest `curl --cacert /opt/orbit/fleet.pem https://fleet.axiom.lab/healthz` returned
**HTTP 200 in ~15 ms**. NAT + TLS + Caddy + Fleet all work; `/etc/hosts` + DNS resolve correctly.

**Actual root cause.** `orbit` was `active` but `osqueryd` was `inactive`, and the orbit process was
**wedged and unkillable** — it had consumed **1h11m of CPU** and survived `SIGKILL`
("Processes still around after SIGKILL", "Failed to kill control group: Invalid argument"). That is a
**NEM CPU soft-lockup** leaving the agent stuck in uninterruptible (D) state, so it never launches
osqueryd or enrolls. The guest clock was correct (ruling out TLS-validity skew).

**Mitigation (proven).** A hard `VBoxManage controlvm <vm> reset` clears the wedge; a fresh `orbit`
enrolls within a minute (`canary-01` came up `online` immediately after the reset). Rules of thumb:
provision/boot **one VM at a time**, avoid heavy concurrent Docker/Hyper-V load during first boot,
and if a VM enrolls-then-stalls, **reset it** rather than debugging the network. Keep the SSH key +
the `natpf1` shell trick handy — it is the only way into a headless, Guest-Additions-less VM under NAT.

**Durable fix.** The soft-lockup is intrinsic to VBox-under-NEM (Docker Desktop keeps the Windows
hypervisor on). The real escape is a **native hypervisor for the client VMs** — the deferred Mac
Studio (macOS/iOS) and/or bare-metal Hyper-V/KVM, which ADR-0001 already routes those platforms
toward. For the Linux lab, reset-on-wedge is an acceptable $0 mitigation.
