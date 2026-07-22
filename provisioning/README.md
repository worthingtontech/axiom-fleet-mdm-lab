# AXIOM provisioning — zero-touch Linux enrollment

Scripts that stand up the lab's Ubuntu 24.04 Linux nodes and have them **enroll into
Fleet on first boot with zero interactive steps**, via `cloud-init` (NoCloud) on a seed
ISO. This is the concrete implementation of
[ADR-0002 — VirtualBox + cloud-init as the VM backend](../docs/adr/0002-vm-backend-virtualbox-cloudinit.md).
For the deep mental model of every moving part (Hyper-V coexistence, cloud-init, the
osquery trust-store split, node keys), read the encyclopedia:
[layer 01 host/hypervisor/virtualization](../docs/encyclopedia/01-host-hypervisor-virtualization.md),
[layer 03 Fleet core](../docs/encyclopedia/03-fleet-core.md),
[layer 04 TLS & PKI](../docs/encyclopedia/04-tls-and-pki.md),
[layer 07 policy-as-code](../docs/encyclopedia/07-policy-as-code.md).

> Validated end-to-end: `gpu-node-1` enrolled ONLINE through this exact flow. The scripts
> below only parameterize + harden that proven recipe.

---

## What this provisions

| Host | RAM / CPU | Tier | Command |
|---|---|---|---|
| `gpu-node-1` | 2048 / 2 | standard | *(already enrolled — the validation run)* |
| `gpu-node-2` | 2048 / 2 | standard | `.\new-linux-vm.ps1 -Name gpu-node-2` |
| `ml-workstation` | 3072 / 2 | standard | `.\new-linux-vm.ps1 -Name ml-workstation -MemoryMB 3072` |
| `enclave-01` | 2048 / 2 | **elevated** | `.\new-linux-vm.ps1 -Name enclave-01 -Tier elevated` |

Defaults: `-MemoryMB 2048 -Cpus 2 -Tier standard`. Because of the first-boot performance
hit (below), **provision/boot these a couple at a time, not all at once.**

### Files

```
provisioning/
  build/build/fleet-osquery_1.58.0_amd64.deb   fleetd .deb (CA baked via --fleet-certificate)
  linux/
    build-base-vdi.ps1                          one-time: Ubuntu 24.04 cloud image -> noble-base.vdi
    new-linux-vm.ps1                            per-node: seed ISO + VBox VM + headless boot
    cloud-init/
      user-data.standard.yaml                   standard-tier template (__HOSTNAME__, __ROOTCA_PEM__)
      user-data.elevated.yaml                   elevated-tier template (+ /etc/axiom markers)
    labels/
      high-trust-enclave.label.yaml             dynamic Fleet label for the elevated tier
  README.md                                     this file
```

---

## Usage

### 0. Prerequisites
- **VirtualBox 7.1** at `C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`.
- **Docker Desktop running** (the QCOW2->VDI conversion and the seed-ISO build both run in
  a throwaway `debian:stable-slim` container — the Windows host has no `qemu-img`/`genisoimage`).
- The **Fleet stack up** at `https://fleet.axiom.lab` (see `infra/`).
- The **fleetd .deb** built with `--fleet-certificate <rootCA.pem>` (already present).

### 1. Build the base image — once
```powershell
cd provisioning\linux
powershell -ExecutionPolicy Bypass -File .\build-base-vdi.ps1
```
Downloads `ubuntu-24.04-server-cloudimg-amd64.img` to `C:\vms\noble.img` (skips if a valid
QCOW2 is already there) and converts it to `C:\vms\noble-base.vdi`. Idempotent.

> Image URL note: the `noble-server-cloudimg` name **404s** under `/releases/` — the working
> artifact is `ubuntu-24.04-server-cloudimg-amd64.img`. `VBoxManage convertfromraw` rejects
> QCOW2, so `qemu-img` does the conversion inside the container.

### 2. Provision each node
```powershell
.\new-linux-vm.ps1 -Name gpu-node-2
.\new-linux-vm.ps1 -Name ml-workstation -MemoryMB 3072
.\new-linux-vm.ps1 -Name enclave-01 -Tier elevated
```
Each run renders the tier's cloud-init template, builds the CIDATA seed ISO (with the .deb
on it), clones + resizes the base disk to 20 GB, creates + configures the VM, and boots it
headless. **Idempotent** — re-running a Name tears down the old VM + disk first.

### 3. Watch it enroll
```powershell
# Boot / cloud-init console:
Get-Content -Wait C:\vms\gpu-node-2-serial.log

# Poll Fleet (first boot is slow — see below; poll up to ~600s):
$fleetctl = 'C:\Users\Sherlock\.axiom-tools\fleetctl_v4.89.1_windows_amd64\fleetctl.exe'
& $fleetctl get hosts | Select-String gpu-node-2
```

### 4. Elevated tier only — apply the dynamic label once
```powershell
& $fleetctl apply -f .\labels\high-trust-enclave.label.yaml
```
Membership re-evaluates on `osquery_label_update_interval` (default **1h**), so a freshly
booted `enclave-01` joins the label within the hour.

---

## Why it works (the load-bearing decisions)

### Networking — NAT + `10.0.2.2` + hostname-SAN TLS
The VM uses a **VirtualBox NAT** adapter (`--nic1 nat`). cloud-init appends
`10.0.2.2 fleet.axiom.lab` to `/etc/hosts`; **`10.0.2.2` is the NAT gateway == the Windows
host**, which runs Caddy on :443. TLS **still validates** because verification is on the
**hostname** `fleet.axiom.lab` (present in the mkcert leaf's SAN), not on the IP. Bridged
networking was rejected — the host is on Wi-Fi and bridging was flaky. (See ADR-0002 and
[ADR-0004 — TLS termination & lab DNS](../docs/adr/0004-tls-termination-and-lab-dns.md).)

### Package delivery — the `.deb` rides ON the seed ISO
`new-linux-vm.ps1` copies the fleetd `.deb` into the seed directory, so it is written onto
the **CIDATA** ISO alongside `user-data`/`meta-data`. cloud-init mounts the seed by label
and installs the package **offline** (`apt-get install -y /mnt/seed/fleet-osquery.deb`); the
VM still has NAT internet to resolve apt dependencies. **No HTTP file server needed.**

### The CA is baked into fleetd (and also trusted OS-wide)
**osqueryd ignores the OS trust store**, so the mkcert root CA must be baked into the fleetd
package at build time via `fleetctl package --fleet-certificate <rootCA.pem>` — already done
for the committed `.deb`. As belt-and-suspenders, the cloud-init `ca_certs.trusted` block
also installs the CA at the OS level (for `curl`, apt-over-https, etc.). The templates carry
a `__ROOTCA_PEM__` placeholder that the script fills from `infra/tls/rootCA.pem`.

### Trust tiering (Free) — markers + a dynamic label
The **elevated** template writes two files (per [ADR-0003](../docs/adr/0003-free-tier-trust-tiering.md)):
- `/etc/axiom/trust-tier` = `elevated` — human/audit-readable, and the key that Phase-4
  **self-scoping policy SQL** reads (per-label policy scoping is Premium and silently ignored
  on Free — do not rely on it).
- `/etc/axiom/tier.d/elevated` — an empty **sentinel path**. osquery's `file` table has **no
  content column**, so the dynamic `high-trust-enclave` label matches on the *presence of
  this path* (`SELECT 1 FROM file WHERE path = '/etc/axiom/tier.d/elevated'`). The label's
  `platform` **must be `""`** — `"linux"` is invalid and rejected.

---

## Known issues the scripts already handle

1. **First boot is slow (Hyper-V coexistence / NEM).** With a Windows hypervisor active,
   VirtualBox runs in NEM mode; the first boot once produced a ~373 s CPU **soft-lockup**
   (VM near-frozen ~6 min) but **recovered and enrolled**. Mitigation baked in:
   `--paravirtprovider kvm` (better Linux clock/timing under NEM). **Set expectations:
   first-boot enrollment can take 5-8 min; poll up to ~600 s, not 300 s.** A one-time
   soft-lockup message on the serial console is expected.
2. **`VirtualBox.xml VERR_ACCESS_DENIED` on register.** `createvm --register` can print
   `Failed to replace ...\VirtualBox.xml VERR_ACCESS_DENIED` (a transient VBoxSVC lock) yet
   still register + start + enroll fine. The script therefore **does not treat a nonzero
   `createvm` exit as fatal** — it verifies with `showvminfo` and proceeds. If it recurs,
   **close the VirtualBox GUI** and re-run.
3. **Idempotency.** Before creating, the script powers off + `unregistervm --delete`s any VM
   of the same Name and removes a stale `C:\vms\<Name>.vdi` (`closemedium --delete` then a
   retry-delete to ride out VBox's brief file lock).

---

## Teardown
```powershell
$vbox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
& $vbox controlvm gpu-node-2 poweroff       # if running
& $vbox unregistervm gpu-node-2 --delete    # removes VM + its cloned disk
```
Leftover seed artifacts (`C:\vms\seed-<Name>\`, `C:\vms\seed-<Name>.iso`,
`C:\vms\<Name>-serial.log`) are safe to delete; re-running `new-linux-vm.ps1 -Name <Name>`
regenerates them.

---

## VM create sequence (reference)

`new-linux-vm.ps1` runs, per VM, the validated `VBoxManage` sequence (absolute path,
`--paravirtprovider kvm` added):

```
clonemedium disk C:\vms\noble-base.vdi C:\vms\<name>.vdi        # unique UUID per VM
modifymedium disk C:\vms\<name>.vdi --resize 20480             # growpart auto-extends
createvm --name <name> --ostype Ubuntu_64 --register          # verify via showvminfo
modifyvm <name> --memory <MB> --cpus <N> --ioapic on --firmware efi \
                --nic1 nat --uart1 0x3F8 4 --uartmode1 file C:\vms\<name>-serial.log \
                --paravirtprovider kvm
storagectl <name> --name SATA --add sata --controller IntelAhci --portcount 2
storageattach <name> --storagectl SATA --port 0 --device 0 --type hdd --medium C:\vms\<name>.vdi
storageattach <name> --storagectl SATA --port 1 --device 0 --type dvddrive --medium C:\vms\seed-<name>.iso
startvm <name> --type headless
```
