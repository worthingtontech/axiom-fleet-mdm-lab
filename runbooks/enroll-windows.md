# Runbook — Enroll a Windows 11 client into Fleet (osquery + Windows MDM)

> **Project AXIOM, Phase 2.** Stand up `corp-win-01` (Windows 11 Enterprise Eval)
> as a headless VirtualBox VM that installs unattended and, at first logon,
> enrolls into Fleet for **both** osquery **and** Windows MDM — over validated
> mkcert TLS, with no manual "Access work or school" step.
>
> **Prereqs already true in this lab:** Fleet live at `https://fleet.axiom.lab`
> (Caddy + mkcert); **Windows MDM enabled server-side** (`windows_enabled_and_configured: true`,
> WSTEP identity CA set — see [ADR-0005](../docs/adr/0005-windows-mdm-enablement.md));
> the fleetd **MSI** built with the enroll secret + mkcert CA baked in
> (`--fleet-certificate`) at `provisioning/build/build/fleet-osquery.msi`;
> `rootCA.pem` at `infra/tls/rootCA.pem`.
>
> **Related:** [ADR-0005 Windows MDM enablement](../docs/adr/0005-windows-mdm-enablement.md) ·
> [ADR-0004 TLS termination & lab DNS](../docs/adr/0004-tls-termination-and-lab-dns.md) ·
> [provisioning/README.md](../provisioning/README.md) ·
> [encyclopedia/05-mdm](../docs/encyclopedia/05-mdm.md)

---

## Why this works (the load-bearing facts)

| # | Fact | Source |
|---|---|---|
| 1 | VBox detects a Win11 ISO as `Windows11_64` and applies `win_nt6_unattended.xml`: LabConfig **BypassTPM/SecureBoot/RAM/Storage/CPU** in windowsPE **and** specialize, a **local admin + AutoLogon**, and our `--post-install-command` at first logon. No registry hacks on our side. | [VBox unattended man](https://raw.githubusercontent.com/VirtualBox/virtualbox/refs/heads/main/doc/manual/en_US/man_VBoxManage-unattended.xml) |
| 2 | With Windows MDM on server-side, installing **fleetd** makes orbit perform **programmatic** Windows MDM enrollment (MS-MDE2 discovery → WSTEP → OMA-DM) automatically. | [Fleet: Windows MDM setup](https://fleetdm.com/guides/windows-mdm-setup) |
| 3 | MDM completes **only in a signed-in session** — a box at the lock screen reports MDM **Off**. AutoLogon (from the answer file) **is** that session, so no human sign-in is strictly required. | [Fleet: Windows MDM setup](https://fleetdm.com/guides/windows-mdm-setup) |
| 4 | The **OS MDM stack validates Fleet TLS against `LocalMachine\Root`** — so the mkcert root CA must be imported there. This is **separate** from the `--fleet-certificate` CA baked into the MSI, which only covers **osqueryd** (osqueryd ignores the OS store). | [MS on-prem MDM certs](https://learn.microsoft.com/en-us/intune/configmgr/mdm/get-started/set-up-certificates-on-premises-mdm) · [Fleet: certs in fleetd](https://fleetdm.com/guides/certificates-in-fleetd) |
| 5 | Inside a VBox **NAT** guest, `10.0.2.2` is the host's loopback where Caddy publishes :443. Map `fleet.axiom.lab → 10.0.2.2` in the guest hosts file (not the host LAN IP). TLS still validates on the SAN hostname. | [VBox manual ch06 (NAT)](https://www.virtualbox.org/manual/ch06.html) |
| 6 | Windows 11 **Home cannot MDM-enroll** — Pro/Enterprise/Education only. `corp-win-01` is **Enterprise Eval** (correct); the lab's Win11 **Home** box is the **host** running Caddy and is never enrolled. | [MS: MDM enrollment of Windows devices](https://learn.microsoft.com/en-us/windows/client-management/mdm-enrollment-of-windows-devices) |

The two scripts do exactly the three things the MSI alone does **not** guarantee
(hosts entry, `LocalMachine\Root` CA, a signed-in session) plus the silent install.

---

## Step 0 — Prerequisites on the host

- **VirtualBox 7.1.4** at `C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`
  (pin to stable 7.1.x — a dev **7.2.97** build crashes `0xc0000409` on Win11 25H2
  unattended, VBox issue #615). Verify: `& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' --version` → `7.1.4r...`.
- **Docker Desktop running** — the provisioning ISO is built in a throwaway
  `debian:stable-slim` container (the Windows host has no `mkisofs`).
- **Fleet stack up** at `https://fleet.axiom.lab` with Windows MDM enabled (ADR-0005).
- **fleetctl** configured with `--rootca` (already done in Phase 1):
  `%USERPROFILE%\.axiom-tools\fleetctl_v4.89.1_windows_amd64\fleetctl.exe`.

---

## Step 1 — Get the Windows 11 Enterprise Eval ISO

Download from the **Microsoft Evaluation Center**: *Windows 11 Enterprise,
version 25H2* — **x64 ISO**, a **90-day** evaluation that needs **no product key**
(activates as Eval). Save it to **`C:\vms\win11-eval.iso`**.

- <https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise>

```powershell
# after downloading, confirm the path the script expects:
Test-Path C:\vms\win11-eval.iso        # -> True

# (optional) confirm VBox detects it as Windows11_64 and see the edition index:
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' unattended detect --iso=C:\vms\win11-eval.iso --machine-readable
```

> The Enterprise Eval ISO is single-edition → `--image-index 1`, no `--key`. Only a
> multi-edition **retail** ISO needs an index/key (Win11 Home generic key
> `YTMG3-N6DKC-DKB77-7M9GH-8HVX7`); that would also fail #6 above (Home can't MDM).

---

## Step 2 — Power off the Linux VMs (NEM: one VM at a time)

Docker Desktop keeps the Windows Hypervisor Platform on, so VirtualBox runs in
**NEM coexistence**: slow, and reliably **one VM at a time**. A Win11 install
alongside a running VM will crawl or wedge (a second concurrent boot froze in
initramfs during Phase 2). Power the others off first:

```powershell
$vbox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
& $vbox list runningvms                                   # see what's up
& $vbox list runningvms | ForEach-Object { ($_ -split '"')[1] } |
    ForEach-Object { & $vbox controlvm $_ poweroff }      # power them all off
```

`new-windows-vm.ps1` also **detects running VMs and warns** (8 s grace) before proceeding.

---

## Step 3 — Provision the VM (one command)

From an **elevated** PowerShell (creating the VM + disk is fine unelevated, but
keep it elevated to match the lab convention):

```powershell
cd <repo-root>\provisioning\windows
powershell -ExecutionPolicy Bypass -File .\new-windows-vm.ps1
# defaults: -Name corp-win-01 -IsoPath C:\vms\win11-eval.iso -MemoryMB 6144 -Cpus 2
```

What it does (see the script header for the full rationale):

1. Builds the **AXIOMWIN provisioning ISO** — `\axiom\` = `first-logon.ps1` +
   `fleet-osquery.msi` + `rootCA.pem` (this is how the host-side MSI + CA reach the guest).
2. Idempotent teardown of any existing `corp-win-01` + stale disk.
3. Creates a `Windows11_64` VM: **EFI (efi64) + vTPM 2.0 + Secure Boot + 6 GB /
   2 CPU + NAT + serial log + `--paravirtprovider default`** (Hyper-V paravirt,
   best for Windows guests). Secure Boot enrolled via
   `modifynvram inituefivarstore / enrollmssignatures / enrollorclpk` while
   powered off ([modifynvram man](https://raw.githubusercontent.com/VirtualBox/virtualbox/refs/heads/main/doc/manual/en_US/man_VBoxManage-modifynvram.xml)) — tolerated if it misbehaves under NEM, since the LabConfig bypass carries the install.
4. `VBoxManage unattended install` **without `--start-vm`** (stages the answer file
   + install media; does **not** power on), then attaches the provisioning ISO on
   its own IDE controller, then **boots headless**.

**Timeline (NEM is slow):** Windows Setup + reboots ≈ **20–45+ min** headless —
**expected, not a hang**. Then AutoLogon fires → `first-logon.ps1` runs from the
AXIOMWIN ISO (hosts entry + rootCA into `LocalMachine\Root` + silent `msiexec /i
… /quiet /norestart`) → orbit auto-triggers Windows MDM enrollment.

### Watch a headless VM

```powershell
$vbox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
# screenshot the console without a window:
& $vbox controlvm corp-win-01 screenshotpng C:\vms\corp-win-01.png ; ii C:\vms\corp-win-01.png
```

In-guest logs once it is up (via a screenshot-driven look, RDP, or post-mortem):
`C:\vboxpostinstall.log` (VBox first-logon hook), **`C:\axiom\first-logon.log`**
(the AXIOM steps), `C:\axiom\fleetd-install.log` (msiexec verbose), and the marker
`C:\axiom\first-logon.done`.

---

## Step 4 — The interactive sign-in (usually automatic)

The answer file's **AutoLogon** already provides the signed-in session Windows MDM
needs (fact #3), so this is normally hands-off. **If** MDM stays **Off**, the box is
probably sitting at the lock screen — sign in once as **`axiom` / `P@ssw0rd!23`**
(lab default; change before this VM leaves the lab). MDM flips **On** ~30 s later.

To sign in / watch interactively, either open a GUI window (power the VM off and
start it with `--type gui` or `separate`), or enable VBox RDP if the Extension
Pack is installed (`VBoxManage modifyvm corp-win-01 --vrde on`) and connect to the
VRDE port with any RDP client.

---

## Step 5 — Verify enrollment

**From the host** (fleetctl already `--rootca`-configured):

```powershell
$fleetctl = "$env:USERPROFILE\.axiom-tools\fleetctl_v4.89.1_windows_amd64\fleetctl.exe"
& $fleetctl get hosts                     # corp-win-01 appears, platform: windows
& $fleetctl get hosts --mdm               # lists hosts enrolled in Fleet with MDM on
& $fleetctl get host corp-win-01          # MDM status should read On
```

Web UI: **Hosts → corp-win-01 → MDM status = On**. ([Fleet: enroll hosts](https://fleetdm.com/guides/enroll-hosts) · [Fleet: MDM commands](https://fleetdm.com/guides/mdm-commands))

**Inside the guest** (optional deep check):

```powershell
Get-Service 'Fleet osquery'                                    # Running
Get-ChildItem Cert:\LocalMachine\Root | ? Subject -like '*mkcert*'   # CA present
Get-Content C:\axiom\first-logon.done                          # marker: failures: 0
# Settings > Accounts > Access work or school -> "Connected to Fleet ... MDM"
mdmdiagnosticstool.exe -out C:\axiom\mdmdiag                   # full MDM report
```

**Definition of done:** `fleetctl get hosts` lists **corp-win-01** (online, platform
windows) **and** `fleetctl get host corp-win-01` shows **MDM: On**.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Install seems frozen for many minutes | **NEM is slow** — 20–45+ min is normal. Screenshot to confirm progress before assuming a hang. Make sure no other VM is running (Step 2). |
| Host in Fleet but **MDM Off** | (a) Not signed in — AutoLogon should cover it; sign in as `axiom` once. (b) `rootCA.pem` not in `LocalMachine\Root` — re-run `first-logon.ps1`, or `certutil -addstore -f Root C:\axiom\rootCA.pem`. Both must be true (fact #3/#4). |
| osquery reports in but MDM never enrolls (or vice-versa) | The **two trust chains** are independent: `--fleet-certificate` (baked into MSI) covers osqueryd; `LocalMachine\Root` covers the OS MDM stack. Doing only one yields a half-working host. |
| Enrollment error **`80180006`** on a fresh 25H2 build | Known MS-MDE2 discovery `RequestVersion` mismatch; fixed by recent Fleet accepting `>= 4.0`. Confirm the server is **v4.89.1** (it is, per LAB_STATE). |
| Host stuck **MDM "Pending"** (#12695) | Almost always the missing `LocalMachine\Root` CA or no interactive sign-in — recheck fact #3/#4. |
| `createvm` printed `VirtualBox.xml VERR_ACCESS_DENIED` | Transient VBoxSVC lock; the script verifies via `list vms` and continues. If it recurs, **close the VirtualBox GUI** and re-run. |
| Secure Boot enrollment errored | Expected under NEM; **tolerated**. The LabConfig bypass carries the install. Re-run with `-NoSecureBoot` to skip it entirely. |
| Command/profile delivery lags after enroll | Windows MDM uses **OMA-DM polling** (not push). Delivery arrives on the next poll; recent fleetd can start an on-demand session when commands are queued. Not Apple-APNs-instant. |

---

## Manual fallback (no `VBoxManage unattended install`)

If you install Win11 **by hand** (GUI boot / USB), use
[`provisioning/windows/autounattend.xml`](../provisioning/windows/autounattend.xml):
put it at the **root** of a FAT32 USB (or inject into the ISO root) and Setup
auto-detects it. It does the same LabConfig bypass + `BypassNRO` + local admin
`axiom` + AutoLogon + `ComputerName corp-win-01`, and its FirstLogonCommands will
run `\axiom\first-logon.ps1` **if** you also attach the AXIOMWIN provisioning ISO
(built by `new-windows-vm.ps1`, left at `C:\vms\winprov-corp-win-01.iso`). Otherwise
run `first-logon.ps1` by hand from an elevated shell after first boot.

---

## Teardown

```powershell
$vbox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
& $vbox controlvm corp-win-01 poweroff        # if running
& $vbox unregistervm corp-win-01 --delete     # removes VM + its disk
# optional clean slate:
Remove-Item C:\vms\winprov-corp-win-01.iso, C:\vms\corp-win-01-serial.log -Force -EA SilentlyContinue
Remove-Item C:\vms\winprov-corp-win-01, C:\vms\unattended-corp-win-01 -Recurse -Force -EA SilentlyContinue
```

Re-running `new-windows-vm.ps1 -Name corp-win-01` regenerates everything
(idempotent). To also **unenroll** in Fleet, delete the host from the UI /
`fleetctl` after teardown.

> **Second Windows box** (`corp-win-02`, on-demand): same flow,
> `.\new-windows-vm.ps1 -Name corp-win-02` — but boot it **alone** (NEM ceiling).
