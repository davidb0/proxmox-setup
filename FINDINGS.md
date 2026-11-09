# FINDINGS — Windows 11 guest, Intel HD 4600 passthrough (guest-side agent, 2026-11-08)

## TL;DR for the host-side agent

The driver is fine and the OS build is fine. The failure is a **missing firmware contract**:
QEMU's IGD legacy mode expects **guest firmware** to create the IGD OpRegion and a guest
"stolen memory" region and program two PCI config registers (ASLS 0xFC, BDSM 0x5C) from
fw_cfg keys `etc/igd-opregion` / `etc/igd-bdsm-size`. **Stock EDK2/OVMF does not implement
this** (upstream declined, TianoCore bug #935); SeaBIOS does. With OVMF + a raw host VBIOS
(`igd-rom.bin`), ASLS/BDSM are left at 0 — or at a stale *host* stolen value carried inside
the raw ROM — and `igdkmd64.sys` fails its init and reports PNP_DEVICE_FAILED (Code 43).
Linux i915 survives this because it skips stolen memory on conflict (and disables it under
VT-d for gen < 8); the Windows driver has no such fallback.

**Recommended fix (community-verified for exactly HD 4600 + OVMF + Windows 10/11):** replace
the raw VBIOS with an EFI OpROM that bundles `IgdAssignmentDxe` (it performs the fw_cfg
contract under OVMF), e.g. `HSW_BDW_GOPv5_igd.rom` from
https://github.com/LongQT-sea/intel-igpu-passthru/releases :

    qm set 103 --machine pc --vga none --bios ovmf --hostpci0 0000:00:02.0,legacy-igd=1,romfile=HSW_BDW_GOPv5_igd.rom

and **remove** the `--args '-set device.hostpci0.x-igd-legacy-mode=off'` experiment (legacy
mode ON is part of the verified combo). Keep: machine `pc` (i440fx), `--vga none` (no stdvga),
host i915 unbound, `disable_vga=1` NOT set. Verified reference: LongQT-sea/intel-igpu-passthru
issue #12 (i5-4460 / HD 4600, OVMF, 4 GiB, same ROM family → "Passthrough successful with
this rom: Windows 10, 11"); issue #31 ("the final piece … resolved the Code 43 error in
Windows" with the bundled-OpROM ROM).

**Alternatives:**
- Switch firmware to **SeaBIOS** (i440fx): SeaBIOS implements the contract natively
  (`intel_igd_setup` in coreboot/seabios `src/fw/pciinit.c` copies the OpRegion, reserves
  1 MiB-aligned e820 RESERVED memory, writes ASLS + BDSM). Historically documented working
  mode for IGD assignment.
- UEFI/UPT-style: `x-igd-legacy-mode=off,x-igd-lpc=on,romfile=<EFI oprom with IgdAssignmentDxe>`
  (QEMU `docs/igd-assign.txt` example).
- QEMU ≥ 10.0 required for the full fw_cfg behavior — host runs 11.0.0-3, OK.

Host-side sanity checks: QEMU log should show "IGD legacy mode enabled" and "OpRegion
detected on Intel display"; trace `vfio_pci_igd_vbios_patched` should fire — if it never
appears, `igd-rom.bin`'s byte pattern defeats QEMU's ROM patch and its saved **host** BDSM
(0xDD200000) leaks into guest init (see "Observed registers" below).

## Precise failure reason (guest-side evidence)

1. **Driver binding is correct.** Device `PCI\VEN_8086&DEV_0412&SUBSYS_05A51028&REV_06` at
   00:02.0 is bound to `oem2.inf` (= `igdlh64.inf`, 20.19.15.5144, Dell OEM, signer "Microsoft
   Windows Hardware Compatibility Publisher", rank 00D10001, section `iHSWD_w10`). Not a
   selection, signature or INF-match problem.
2. **The miniport fails its start and says so.** Problem code 43 = `CM_PROB_FAILED_POST_START`
   with `DEVPKEY_Device_ProblemStatus = 0` — the driver calls `IoInvalidateDeviceState` /
   `PNP_DEVICE_FAILED` (MS doc: "One of the drivers controlling the device told the OS the
   device failed"). A live `pnputil /restart-device` reproduces it instantly and **silently**:
   zero entries in System, Application and DxgKrnl logs. No WHEA errors ever.
3. **A TDR happened under the earlier configuration.** Recovered
   `C:\Windows\LiveKernelReports\WATCHDOG\WATCHDOG-20261108-1545.dmp` (617 MB) + WER report
   `Kernel_193` (copies in `C:\Users\admin\Desktop\ai\igpu_evidence\`). Dump header:
   pseudo-bugcheck **0x193 (video watchdog TDR live dump)**, P1=0x804,
   P2=0xFFFFFFFFC0000001 (STATUS_UNSUCCESSFUL), P3=0x108, P4=0xFFFFF80418179964. WER's
   inventory lists `igdkmd64.sys` 20.19.15.5144 as the display driver. No event-4101 entries
   were ever logged — the dump is the only trace of the hang.
4. **Two distinct failure modes, both explained by the stolen/OpRegion gap:**
   - Stale **host** stolen value visible (raw `igd-rom.bin` carries a saved host BDSM;
     QEMU's ROM-patch quirk zeroes it only if the byte pattern matches): the driver programs
     GPU state against host-stolen-relative addresses that fall inside ordinary guest RAM of
     the 12 GiB VM (BDSM=0xDD200000 etc.) → GPU hang → TDR (the 15:45 dump) → Code 43.
   - Registers zeroed (current `x-igd-legacy-mode=off` state): no stolen region and no
     OpRegion/VBT declaration at all → clean init failure → Code 43 (no TDR).
5. **Why the Linux guest worked:** i915 explicitly skips stolen memory when the advertised
   region conflicts with RAM and disables stolen usage under VT-d for gen < 8
   (`i915_gem_stolen.c`). igdkmd64 has no equivalent; no registry knob provides one
   (`IncreaseFixedSegment` is an Intel `IncFixedSegWA` display workaround with no documented
   relation to stolen init; `DedicatedSegmentSize` only resizes the reported segment).
6. **The guest cannot fix this.** ASLS/BDSM must be written by firmware at boot and the
   stolen region must be e820-reserved before the OS boots; the raw VBIOS is a QEMU-side
   `romfile=` option. Guest-side space is exhausted (driver/signature ✓, VM-detection hiding
   irrelevant — the driver does attempt init, Win+P/phantom displays irrelevant to init).

## Observed registers (from host-side agent's notes — interpretation)

BDSM=0xDD200000 / BGSM=0xDD000000 / TSEGMB=0xDC000000 on the host bridge are **host** values.
Upstream QEMU emulates guest BDSM as 0 and expects firmware to write a *guest* base; it does
not forward host GGC/BDSM/BGSM/TSEGMB and does not map host stolen memory into the guest
(`hw/vfio/igd.c`, `docs/igd-assign.txt` "Memory View"). If those values are visible inside
the guest, the likely source is the unpatched saved-BDSM inside `igd-rom.bin` (QEMU patches
that pattern out — `hw/vfio/igd.c` ROM quirk — but silently skips non-matching ROMs) — worth
confirming via the `vfio_pci_igd_vbios_patched` trace. Either way, guest stolen memory must
be a firmware-reserved region *inside the guest's* address space, which is exactly what the
OpROM/SeaBIOS fix establishes.

## Verification after the fix (guest side)

- `pnputil /enum-devices /class display /drivers` → HD 4600 "Started", no problem code;
  Device Manager "working properly".
- TV shows the Windows desktop at 1920x1080@60 over DisplayPort (test with a D3D app /
  dxdiag for hardware acceleration).
- If it still fails: re-run the evidence flow (`C:\Users\admin\AppData\Local\Temp\igpu_diag.ps1`
  pattern: enable `Microsoft-Windows-DxgKrnl/Diagnostic`, `pnputil /restart-device`, collect
  WER/LiveKernelReports) and check the QEMU log lines listed above.

## Open questions (please relay)

1. When exactly was `x-igd-legacy-mode=off` applied relative to today 15:45 (the TDR boot)?
   The two-mode interpretation assumes 15:45 ran with the earlier (quirk-enabled) config.
2. Does the TV show any firmware output (OVMF logo) during POST/boot? Pure "no signal" even
   at boot would additionally implicate the display pipe/GOP; a boot logo means only the
   Windows driver path is broken.
3. Did the QEMU trace `vfio_pci_igd_vbios_patched` ever fire with `igd-rom.bin`?

## Environment facts

- Windows "10" Pro N 26H2, build **26300.9711** (the handoff's "26H1/26200" is outdated),
  12 GiB RAM, UEFI/OVMF boot.
- Evidence copies: `C:\Users\admin\Desktop\ai\igpu_evidence\` — `elevated_log.txt` (restart
  capture), `WATCHDOG-20261108-1545.dmp`, WER `Kernel_193` report + `sysdata.xml`.
- `cphs` (Intel MEI client service) fails harmlessly ("No more data is available") — no
  00:16.0 HECI device passed through; unrelated to display init.
- `C:\drv2` / `C:\drv` were cleaned up post-install; the driver persists in the DriverStore
  (`igdlh64.inf_amd64_2bc85d0bf0dbeec0`).
- Elevation in the guest requires a UAC click (blank-password accounts can't be used for
  secondary logon); no QEMU guest agent installed.

## Key sources

- https://github.com/qemu/qemu/blob/master/docs/igd-assign.txt — firmware ABI
  (`etc/igd-opregion`, `etc/igd-bdsm-size`), "SeaBIOS has … support. However, the support is
  not accepted by upstream EDK2/OVMF" + IgdAssignmentDxe recommendation; memory view.
- https://github.com/qemu/qemu/blob/master/hw/vfio/igd.c — BDSM emulated/zeroed, ROM
  saved-BDSM patch quirk, legacy-mode gates.
- https://github.com/LongQT-sea/intel-igpu-passthru (+ issues #12, #31) — verified HD 4600 →
  Windows 10/11 with `HSW_BDW_GOPv5_igd.rom`, Proxmox recipe.
- https://github.com/tomitamoeko/VfioIgdPkg — `IgdAssignmentDxe` (sets OpRegion + BDSM).
- https://github.com/lf-edge/eve/blob/master/docs/INTEL-IGPU-PASSTHROUGH.md — "Why
  SeaBIOS/i440fx works / why UEFI fails without special handling"; "Nobody sets BDSM. Nobody
  allocates OpRegion memory. The OS driver fails to initialize."
- https://learn.microsoft.com/en-us/windows-hardware/drivers/install/cm-prob-failed-post-start
- https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/i915/gem/i915_gem_stolen.c
- https://vfio.blogspot.com/2016/07/intel-graphics-assignment.html (legacy-mode requirements)
