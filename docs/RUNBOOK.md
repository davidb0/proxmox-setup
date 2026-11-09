# RUNBOOK — Windows 11 Pro TV VM on Proxmox (Haswell HD 4600 passthrough)

End-to-end procedure for rebuilding the `win11pro` VM from scratch. Verified
2026-11-08 on: Dell OptiPlex 7020, i5-4590 (Haswell), 16 GB RAM, PVE 9.2.2
(kernel 7.0.2-6-pve, pve-qemu-kvm 11.0.0-3). Every step below is what
actually worked; see `FINDINGS.md` for the GPU Code 43 root-cause analysis
and `igpu_evidence/` for the backing diagnostics.

## Target end state

- Windows 11 Pro (build 26300) running at the physical TV: 1920x1080@60 over
  DisplayPort, driven by the passed-through Intel HD 4600 with hardware
  acceleration (driver healthy, no Code 43).
- All USB controllers + both audio controllers passed through (keyboard/mouse
  on the TV work natively).
- QEMU guest agent usable (`qm guest exec 103 -- powershell -c '...'` runs as
  SYSTEM) — the remote-management path.
- VM boots unattended (`onboot: 1`), survives reboots.

## Hard constraints (do not violate)

| Constraint | Why |
|---|---|
| VM RAM ≤ 12 GiB | A 14 GB allocation made the 16 GB host unbootable (needed GRUB masking of pve-guests.service) |
| One VM per passthrough set | Never start two VMs claiming the same `hostpci` devices |
| `machine: pc-i440fx-11.0` | `legacy-igd=1` is rejected on q35 |
| `vga: none` with `legacy-igd=1` | Required by PVE; no stdvga alongside IGD assignment |
| `romfile=` lives in `/usr/share/kvm/` | PVE resolves ROM paths only there |
| TPM `version=v2.0` | PVE enum is `v1.2\|v2.0`; `v2` is invalid |
| Never rebuild the Microsoft ISO | genisoimage output does not boot in this OVMF ("no bootable option found") |

## 0. Host prerequisites (already done on this host; verify when rebuilding)

- Early VFIO binding on the kernel cmdline: `vfio-pci.ids=8086:0412,...` with
  `blacklist i915` in modprobe — the iGPU sits on vfio-pci from boot.
  Check: `lspci -nnk -s 00:02.0` → "Kernel driver in use: vfio-pci".
- All six devices unbound from host drivers before any VM start.
- `pve-qemu-kvm` ≥ 10.0 for the IGD fw_cfg contract (11.0.0-3 here, OK).

## 1. Fetch install media

```bash
scripts/fetch-win11-iso.sh "<fresh microsoft url>"   # verifies SHA256 bd4307df…a650
```

Microsoft links are time-signed (~24 h). The download page is JS-driven —
fetching with plain curl gets a 404 page; use a browser or see the comments
in the script. Also grab `virtio-win.iso` (Fedora) for the guest
agent/virtio-serial drivers.

## 2. Create the VM

```bash
scripts/create-vm.sh        # VM 103, 128 GB, 12 GiB, TPM 2.0, all passthrough
```

Key config it encodes (see script for comments):

```
machine: pc-i440fx-11.0   bios: ovmf   cpu: x86-64-v3,hidden=1,hv-vendor-id=GenuineIntel
memory: 12288   boot: order=sata0   onboot: 1   vga: none
sata0: local-lvm:128G   efidisk0: 4M pre-enrolled-keys   tpmstate0: version=v2.0
hostpci0: 0000:00:02.0,legacy-igd=1,romfile=HSW_BDW_GOPv5_igd.rom
hostpci1..5: 00:03.0, 00:1b.0, 00:14.0, 00:1a.0, 00:1d.0
```

The script also downloads the IGD OpROM (`HSW_BDW_GOPv5_igd.rom`, SHA256
`504702d5…ab775`) into `/usr/share/kvm/`. **This ROM is mandatory** — see §5.

## 3. Install Windows 11 (manual, at the console)

**The emulated keyboard/mouse is broken on this platform** (HMP sendkey, QMP
input-send-event, PS/2 and USB HID all ignored by firmware and guests — a
QEMU 11.0.0-3/Haswell bug). Do not burn tokens trying to automate the GUI.
Drive the Proxmox web console (or `qm monitor` + `screendump` to watch).

1. Boot the Win11 ISO. At "This PC can't run Windows 11" press **Shift+F10**:

   ```cmd
   reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck     /t REG_DWORD /d 1 /f
   reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
   reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck     /t REG_DWORD /d 1 /f
   reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck     /t REG_DWORD /d 1 /f
   reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f
   ```

   Close cmd, retry setup. (These keys also exist in
   `scripts/unattend/autounattend*.xml` if you later want unattended installs;
   the BIOS variant is the one validated against a single-Primary-partition
   disk. Note the first autounattend attempt failed because `xmlns:wcm` was
   missing — keep the declaration.)

2. At OOBE "Let's connect you to a network": Shift+F10 → `OOBE\BYPASSNRO`
   (reboots; then "I don't have internet" → local account).
3. No product key — skip activation.

## 4. Guest agent + remote access

1. Mount `virtio-win.iso` (ide3), install the **VirtIO serial driver** from
   `E:\vioserial` (the qemu-ga MSI alone leaves the channel dead — service
   "running" but `qm guest exec` times out).
2. `msiexec /i E:\guest-agent\qemu-ga-x86_64.msi /qn` (silent by design).
3. Verify: `qm guest cmd 103 ping` → `"running"`. Then all host-side admin is
   `qm guest exec 103 -- powershell -c '...'` (runs as SYSTEM).
4. Optional but recommended: Apollo/Sunshine in-guest + Moonlight client —
   gives you a remote desktop that survives GPU resets. A virtual display
   adapter appears alongside the Intel one; it is harmless.

## 5. GPU: why plain passthrough fails, and the fix

With OVMF + raw VBIOS (or no ROM), the Intel driver installs but reports
**Code 43**. Root cause: QEMU's IGD legacy mode expects *guest firmware* to
create the IGD OpRegion + stolen-memory region and program ASLS/BDSM PCI
registers from fw_cfg keys (`etc/igd-opregion`, `etc/igd-bdsm-size`).
Stock EDK2/OVMF does not implement this (TianoCore bug #935); SeaBIOS does.
Without the contract the driver fails init → PNP_DEVICE_FAILED; with a raw
VBIOS carrying the *host's* stolen address it instead wedges the GPU → TDR →
Code 43. Linux i915 survives by skipping stolen memory; igdkmd64 does not.
Full evidence: `FINDINGS.md`, `igpu_evidence/`.

**Fix (community-verified for HD 4600 + OVMF + Win10/11):** use the EFI OpROM
that bundles `IgdAssignmentDxe` — `HSW_BDW_GOPv5_igd.rom` from
<https://github.com/LongQT-sea/intel-igpu-passthru/releases> — as `romfile=`
with `legacy-igd=1` kept ON. `scripts/create-vm.sh` does all of this.

Sanity check at VM start (QEMU log/stderr must show both lines):

```
info: OpRegion detected on Intel display 412.
info: IGD legacy mode enabled, use x-igd-legacy-mode=off to disable it if unwanted.
```

## 6. GPU driver in-guest

1. The package must match `PCI\VEN_8086&DEV_0412&SUBSYS_05A51028` (Dell
   OptiPlex 7020). Use `scripts/fetch-intel-driver.sh` → Dell OEM
   **20.19.15.5144** ("15.40 branch" naming; `igdlh64.inf`).
   Generic catalog builds (e.g. 20.19.15.5166) are pinned to other SUBSYS IDs
   and won't bind.
2. `pnputil /add-driver E:\igdlh64.inf /install` (as admin).
3. Verify:

   ```powershell
   Get-PnpDevice -Class Display            # Intel HD 4600: Status OK, CM_PROB_NONE
   Get-CimInstance Win32_VideoController   # 1920x1080, ~59 Hz
   Get-CimInstance -Namespace root\wmi WmiMonitorConnectionParams
   # VideoOutputTechnology 10 = DisplayPort (the TV)
   ```

## 7. Post-install hardening

- `powercfg /change monitor-timeout-ac 0` (the display-off timer looks like a
  GPU hang in screenshots) + standby/hibernate timeouts to 0. Note: OVMF
  exposes no S-states anyway, so the VM cannot sleep.
- Boot order `sata0` only once installed; detaching the ISOs is optional.
- BitLocker device-encryption is ON by default on Win11 — offline NTFS mounts
  of the VM disk from the host will fail. Use the guest agent.

## 8. Verification checklist (definition of done)

- [ ] `qm status 103` running; QEMU log shows the two OpROM lines above
- [ ] `qm guest cmd 103 ping` works (guest agent channel up)
- [ ] `Get-PnpDevice -Class Display` → HD 4600 Status OK, `CM_PROB_NONE`
- [ ] TV shows the Windows desktop at 1920x1080 over DisplayPort
- [ ] Hardware acceleration confirmed (a D3D app/dxdiag runs smoothly)
- [ ] USB keyboard/mouse work on the TV (passthrough), audio plays
- [ ] Reboot once; all of the above persist

## 9. Known failure modes & quick diagnosis

| Symptom | Cause / fix |
|---|---|
| No bootable device from ISO | A rebuilt ISO — never rebuild; use the Microsoft original |
| Setup says no TPM 2.0 | `tpmstate0` detached or wrong version string (`v2` ≠ `v2.0`) |
| Driver installs, Code 43 | Missing/incorrect `romfile=`; check for the two OpROM log lines |
| Black TV even at POST | ROM is a legacy raw VBIOS (can't execute under OVMF — no CSM); use the EFI OpROM |
| GPU hangs → TDR dump → Code 43 | Stale host stolen-memory in ROM; the HSW_BDW GOPv5 ROM fixes this |
| `qm guest exec` times out | VirtIO serial driver missing (`E:\vioserial`); MSI alone is not enough |
| Host won't boot after VM changes | RAM ballooned past ~12 GiB — keep MEM_MB=12288 |
| VM fails to start with QEMU args error | Stale `--args '-set device.hostpci0…'` after hostpci0 edits — `qm set 103 --delete args` |
| Screen freezes in screenshots | Windows monitor-off timer — `powercfg /change monitor-timeout-ac 0` |

## 10. Tooling in `scripts/`

| File | Purpose |
|---|---|
| `create-vm.sh` | One-shot VM creation incl. OpROM install (§2) |
| `fetch-win11-iso.sh` | ISO download + SHA256 verify (§1) |
| `fetch-intel-driver.sh` | Dell OEM driver fetch + match verify (§6) |
| `shot.py` | `qm monitor screendump` PPM→PNG converter — vision monitoring (host QEMU lacks libpng) |
| `qmpkey.py` | QMP `input-send-event` keystroke injector (mostly useless here — see §3 — but kept for other VMs) |
| `cabscan.py` | Minimal MSZIP CAB/INF device-ID scanner (driver hunting) |
| `unattend/*.xml` | Autounattend answer files (LabConfig + BypassNRO baked in) |

## 11. Future work: update-persistence bypass (not yet implemented)

Windows feature updates may re-run hardware checks on this unsupported CPU.
Planned local mechanism (pick one, implement as a scheduled task):

1. **`setup.exe /product server` trick** — running the upgrade with a Server
   product type skips consumer appraiser gates.
2. **`appraiserres.dll` neutralization** — zero/replace the compat appraiser
   DLL in the `$WINDOWS.~BT` payload before upgrade.
3. **LabConfig re-application** — re-add the five LabConfig keys at every
   boot via a scheduled task so any setup phase inherits them.

Host-side coordination is via `qm guest exec`; keep a working directory in
the guest for notes and evidence.
