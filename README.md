# Windows 11 on unsupported hardware — with GPU passthrough

A complete, verified recipe for running **Windows 11 Pro on hardware Microsoft
declares unsupported** (4th-gen Intel "Haswell", no TPM 2.0, no Secure Boot
requirement met) — as a Proxmox VE VM, with the **Intel HD 4600 iGPU passed
through** to drive a physical display at full acceleration.

Why a VM instead of bare metal? Proxmox does the hardware cloaking Windows
refuses to do itself: a masked CPUID, an emulated TPM 2.0, and an OVMF/UEFI
boot path. And the single hardest problem — the Windows Intel iGPU driver
reporting **Code 43** under OVMF — has a known, verified fix documented here
(that fix is probably why you found this repo).

## Verified on

- Dell OptiPlex 7020, Intel Core i5-4590 (Haswell, 4C), 16 GB RAM
- Intel HD 4600 iGPU (PCI `8086:0412`), driving a TV over DisplayPort
- Proxmox VE 9.2.2, kernel 7.0.2-6-pve, pve-qemu-kvm 11.0.0-3
- Windows 11 Pro, build 26300 — running at 1920x1080@60 with hardware
  acceleration, all USB + audio controllers passed through

Any similar 4th-gen-era machine with an HD 4600/5000-series iGPU should work
the same way; adjust PCI IDs as needed.

## Contents

```
docs/RUNBOOK.md      Step-by-step procedure — start here
FINDINGS.md          GPU Code 43 root-cause analysis (the deep dive)
igpu_evidence/       Diagnostic artifacts backing FINDINGS.md
scripts/             One-shot provisioning + fetch + helper tooling
AGENTS.md            Guidance for AI agents assisting with the setup
CONTEXT.md           Original debug-session mission brief (historical)
```

## The three non-obvious things

1. **The IGD OpROM fix** — under OVMF, a passed-through Intel iGPU's driver
   fails with Code 43 unless guest firmware programs the IGD OpRegion /
   stolen-memory contract (fw_cfg keys `etc/igd-opregion` / `etc/igd-bdsm-size`).
   Stock EDK2/OVMF does not implement this (TianoCore bug #935). The fix:
   use the EFI OpROM `HSW_BDW_GOPv5_igd.rom` (bundles `IgdAssignmentDxe`) as
   the device ROM. See [FINDINGS.md](./FINDINGS.md).
2. **Hardware cloaking** — `x86-64-v3` CPU type (masks the old CPUID while
   exposing needed instruction sets) + swtpm 2.0 + LabConfig registry bypasses
   get Windows 11 installed on a CPU it officially refuses.
3. **A Windows-11-VM memory ceiling** — on a 16 GB host, allocating 14 GB to
   the guest can make the *host* unbootable. Stay at 12 GiB or below.

## Quick start

```bash
scripts/fetch-win11-iso.sh "<microsoft download url>"   # ISO + SHA256 verify
scripts/create-vm.sh                                     # VM + OpROM + passthrough
# then: docs/RUNBOOK.md §3 onward (install, driver, verification)
```

## Future work

The runbook §11 sketches a local persistence mechanism (scheduled task +
`setup.exe /product server` / `appraiserres.dll` handling) so future Windows
feature updates don't re-trigger the unsupported-hardware blocks.
