# Agent Guidelines

Guidance for AI agents assisting a user through this setup. The repo documents
a verified procedure; follow it rather than re-deriving. The target is a live
Proxmox host and a physical display — actions can brick the host or leave the
user without a working TV/monitor, so verify before destructive steps.

## Read order

1. [docs/RUNBOOK.md](./docs/RUNBOOK.md) — the verified procedure. Follow it.
2. [FINDINGS.md](./FINDINGS.md) — GPU Code 43 root cause; read before
   touching anything about the iGPU, ROM file, or display issues.

## Working on the user's host

- You will typically be running over SSH to the Proxmox host as root. Inspect
  real state (`qm config <vmid>`, `qm status <vmid>`, `lspci -nnk`) before
  assuming anything — the user's config may differ from the runbook's example
  VMID 103.
- Guest admin (Windows): `qm guest exec <vmid> -- powershell -c '...'` runs as
  SYSTEM once the guest agent channel is up. If it times out, the virtio-serial
  driver is missing — RUNBOOK §4.
- If you change meaningful state, tell the user what changed and how to undo it.

## Hard rules

- **Never exceed 12 GiB guest RAM on a 16 GB host** — a 14 GB allocation was
  observed to make the host unbootable.
- **One VM per passthrough set** — never run two VMs claiming the same `hostpci`
  devices simultaneously. Check which VM owns them before starting anything.
- **Never rebuild the Microsoft Windows ISO** — genisoimage output does not
  boot under this OVMF ("no bootable option found"). Always use the original
  ISO; re-download if corrupt (SHA256 pins are in the scripts).
- **Don't automate the Windows installer GUI** — emulated keyboard/mouse input
  is broken on this QEMU/Haswell combo (HMP sendkey, QMP input-send-event, PS/2
  and USB HID are all ignored). Hand interactive steps to the human (Shift+F10
  registry lines in RUNBOOK §3) and do everything else from the host side.
- **No credentials in this repo or in files you commit to it** — it is public.
- The IGD `romfile=` must be an EFI OpROM (`HSW_BDW_GOPv5_igd.rom`) in
  `/usr/share/kvm/`, never a raw VBIOS; `legacy-igd=1` stays ON; `vga: none`.

## PVE API gotchas

- TPM version string is `v2.0`, not `v2` (enum is `v1.2|v2.0`).
- `romfile=` resolves relative to `/usr/share/kvm/` only.
- `legacy-igd=1` requires i440fx machine + `vga: none` (PVE refuses q35).
- Stale `--args` entries break VM start after device edits —
  `qm set <id> --delete args`.
- `qm monitor screendump` writes PPM only (host QEMU lacks libpng); use
  `scripts/shot.py` to convert for vision-based monitoring.

## PowerShell/ssh quoting

`$vars` and `$(...)` inside double quotes get eaten by the local shell when
piping to ssh. Use here-strings (`@'...'@ | ssh ... bash`) and bash-side
substitutions; strip stray `\r` from generated scripts.

## Definition of done (VM work)

RUNBOOK §8: display shows the Windows desktop at the target resolution over
DisplayPort, the iGPU reports `CM_PROB_NONE`, the guest agent responds, and
the state survives a reboot. If you cannot verify the physical display, say
so explicitly rather than assuming success.
