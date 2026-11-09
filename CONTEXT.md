# Context: Windows 11 GPU passthrough debugging (VM 103 "win11pro")

You are an AI assistant running INSIDE the Windows 11 guest (VS Code + Copilot) on VM 103 of a
Proxmox VE host. This file is the handoff from the host-side agent that built
this VM. The user relays messages between us.

## Mission
Get the Intel HD Graphics 4600 (Haswell iGPU, PCI passthrough from the Proxmox host) fully
working in this Windows guest: driver loads without error, 1920x1080@60 on the physical
DisplayPort (the TV), hardware acceleration. Everything else already works.

## Current state
- Windows 11 Pro 26H1 (build 26200.6584), boots fine, network fine, USB controllers
  (keyboard/mouse) passed through and working. Remote access via Apollo/Sunshine + Moonlight
  works (virtual display) - that is how the user sees this desktop.
- The iGPU shows in Device Manager with a yellow bang: **Code 43** ("Windows has stopped this
  device because it has reported problems"). The user saw the driver "crash" reporting 43.
- Installed/staged driver: **20.19.15.5144** = Intel's 15.40 branch (the newest driver that
  exists for the HD 4600), a Dell OEM build whose INF matches this exact device:
  `PCI\VEN_8086&DEV_0412&SUBSYS_05A51028`. Files: `C:\drv2\` (this package, use it).
  `C:\drv\` is an older Microsoft-repackaged variant that does NOT match the subsystem - ignore.
- TV on DisplayPort: "no signal". Windows startup sound plays (OS is fully up).

## Proxmox-side VM config (host-side agent owns this)
- pc-i440fx-11.0, OVMF (UEFI install), CPU x86-64-v3 with hidden=1 and hv-vendor-id=GenuineIntel
  (VM detection hidden), 12 GiB RAM, 128 GB SATA disk, swtpm 2.0, e1000e NIC.
- iGPU: `hostpci0: 0000:00:02.0,legacy-igd=1,romfile=igd-rom.bin` (romfile = the real Intel
  VBIOS extracted from the device). QEMU's "IGD legacy mode" quirk is CURRENTLY DISABLED via
  `--args '-set device.hostpci0.x-igd-legacy-mode=off'` (experiment in progress: the quirk is
  what feeds the driver the stolen-memory registers).
- Also passed: 00:03.0 (DP audio), 00:1b.0 (onboard audio), 00:14.0/00:1a.0/00:1d.0 (USB).
- Host: Dell OptiPlex 7020, i5-4590 (Haswell), QEMU 11.0.0-3 / PVE 9.2, kernel 7.0.2-6-pve.

## Already tried (all still Code 43)
1. Dell-matched signed driver 20.19.15.5144 bound to the device.
2. Hypervisor hidden (kvm=off) + Hyper-V vendor spoofed (defeats NVIDIA-style VM detection).
3. Real Intel VBIOS ROM attached to the device.
4. Win+P projector reset (phantom-display theory).
5. QEMU IGD legacy-mode quirk disabled (stolen registers now zeroed) - current state.

## Prime suspect (verify in Event Viewer!)
The chipset advertises "stolen memory"/GTT regions (BDSM=0xDD200000, BGSM=0xDD000000,
TSEGMB=0xDC000000 on host bridge 00:00.0) whose addresses fall inside ordinary guest RAM in
this 12 GiB VM. Linux i915 detects this and skips stolen memory - that is why a Linux guest on
this exact hardware drove the TV perfectly at 1080p. The Windows driver trusts the registers,
puts GPU state in pages the OS can recycle, the GPU hangs -> TDR -> Code 43.
Check: Event Viewer -> System/Display (TDR "Display driver ... stopped responding"),
`C:\Windows\INF\setupapi.dev.log` (search "igdlh"), device Properties -> Events tab.

## Useful commands
- pnputil /enum-devices /class display /drivers
- wevtutil qe system /c:400 /rd:true /f:text
- The account is admin with no password (elevated console available).

## Acceptance
Device Manager: HD 4600 "working properly"; TV shows the Windows desktop at 1920x1080 via
DisplayPort; hardware acceleration works. If the driver fundamentally cannot work on this OS
build, record the precise failure reason in C:\FINDINGS.md so the host-side agent can execute
the fallback (discrete GPU / SeaBIOS firmware switch).

## Coordination
Host-side agent reboots the VM and changes Proxmox config on request (SSH to the Proxmox host).
Leave findings in C:\FINDINGS.md; the user relays. Don't touch Proxmox-side settings.
