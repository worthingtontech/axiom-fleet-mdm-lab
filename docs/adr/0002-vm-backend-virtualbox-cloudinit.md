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
