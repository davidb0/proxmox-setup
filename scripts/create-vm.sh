#!/bin/bash
# One-shot provisioning of VM 103 "win11pro" — Windows 11 Pro TV VM with
# Intel HD 4600 (Haswell) passthrough on Proxmox VE.
#
# Run as root on the Proxmox host. Idempotent-ish: refuses to clobber an
# existing VM unless you set FORCE=1.
#
# This encodes the exact config that was verified working on 2026-11-08.
# Read docs/RUNBOOK.md before changing anything here.
set -euo pipefail

VMID="${VMID:-103}"
NAME="${NAME:-win11pro}"
STORAGE="${STORAGE:-local-lvm}"
ISO_STORAGE="${ISO_STORAGE:-local}"
WIN11_ISO="${WIN11_ISO:-Win11_Client_x64_en-us_26300_9457.iso}"
MEM_MB="${MEM_MB:-12288}"          # NEVER 14336 — 14 GB made this 16 GB host unbootable
CORES="${CORES:-4}"

# --- IGD OpROM (the fix for Windows Code 43 under OVMF) --------------------
# Stock OVMF does not implement the IGD OpRegion/stolen-memory fw_cfg contract
# (TianoCore #935); this EFI OpROM bundles IgdAssignmentDxe which does.
# Full story: FINDINGS.md
OPROM_URL="https://github.com/LongQT-sea/intel-igpu-passthru/releases/download/v0.1/HSW_BDW_GOPv5_igd.rom"
OPROM_SHA256="504702d564cb1b152d23df04f163f24681f65ed18b64519612fb08dce0fab775"
OPROM="HSW_BDW_GOPv5_igd.rom"

echo "== installing IGD OpROM to /usr/share/kvm (romfile paths resolve there only)"
if [ ! -f "/usr/share/kvm/$OPROM" ]; then
  curl -sL -o "/usr/share/kvm/$OPROM" "$OPROM_URL"
fi
echo "$OPROM_SHA256  /usr/share/kvm/$OPROM" | sha256sum -c -

if qm status "$VMID" >/dev/null 2>&1; then
  if [ "${FORCE:-0}" != "1" ]; then
    echo "VM $VMID already exists; set FORCE=1 to destroy and recreate." >&2
    exit 1
  fi
  qm stop "$VMID" >/dev/null 2>&1 || true
  sleep 3
  qm destroy "$VMID" --purge --destroy-unreferenced-disks 1
fi

echo "== creating VM $VMID ($NAME)"
# machine pc-i440fx-11.0: legacy-igd=1 requires i440fx; PVE hard-errors on q35.
# cpu hidden=1,hv-vendor-id: masks the Haswell CPU ID from guest software.
qm create "$VMID" \
  --name "$NAME" \
  --machine pc-i440fx-11.0 \
  --bios ovmf \
  --ostype win11 \
  --memory "$MEM_MB" \
  --cores "$CORES" \
  --sockets 1 \
  --cpu "x86-64-v3,hidden=1,hv-vendor-id=GenuineIntel" \
  --net0 "e1000e,bridge=vmbr0" \
  --agent enabled=1 \
  --keyboard en-us \
  --onboot 1 \
  --boot order=sata0

# Disk + firmware + TPM. TPM enum is v1.2|v2.0 — "v2" is invalid.
qm set "$VMID" --sata0 "$STORAGE:128"
qm set "$VMID" --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=1"
qm set "$VMID" --tpmstate0 "$STORAGE:1,version=v2.0"

echo "== GPU + USB passthrough (all six devices; this VM owns them exclusively)"
# vga none is REQUIRED with legacy-igd=1.
# romfile must be in /usr/share/kvm/ (PVE resolves relative paths there).
qm set "$VMID" --vga none
qm set "$VMID" --hostpci0 "0000:00:02.0,legacy-igd=1,romfile=$OPROM"
qm set "$VMID" --hostpci1 "0000:00:03.0"    # DisplayPort audio
qm set "$VMID" --hostpci2 "0000:00:1b.0"    # analog audio
qm set "$VMID" --hostpci3 "0000:00:14.0"    # xHCI USB
qm set "$VMID" --hostpci4 "0000:00:1a.0"    # EHCI USB
qm set "$VMID" --hostpci5 "0000:00:1d.0"    # EHCI USB

echo "== attaching install media"
qm set "$VMID" --ide2 "$ISO_STORAGE:iso/$WIN11_ISO,media=cdrom"
qm set "$VMID" --ide3 "$ISO_STORAGE:iso/virtio-win.iso,media=cdrom"

echo "== done. Verify before starting:"
qm config "$VMID"
cat <<'EOF'

Next steps (see docs/RUNBOOK.md):
  1. qm start 103 && qm monitor 103  -> screendump to watch install
  2. Install Windows 11 manually at the console (input injection is broken
     on this QEMU/host combo — do NOT try to automate the GUI).
     At the first "This PC can't run Windows 11" screen press Shift+F10 and:
       reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
       reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
       reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f
       reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f
       reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f
     Then rerun setup. At OOBE network screen, Shift+F10 -> OOBE\BYPASSNRO
     to allow offline account. No product key needed.
  3. After first boot: install VirtIO serial driver from ide3 (E:\vioserial)
     so the QEMU guest agent channel works: qm guest exec 103 -- ...
  4. Install the Intel HD 4600 driver (see RUNBOOK "GPU driver").
EOF
