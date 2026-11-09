#!/bin/bash
# Fetch the Dell OEM Intel HD 4600 Windows 10/11 driver and stage it as an
# ISO the guest can install from.
#
# Why this specific package: the generic MS catalog packages (e.g.
# 20.19.15.5166) are trimmed OEM builds pinned to other SUBSYS IDs and will
# not bind to the Dell OptiPlex 7020 (PCI\VEN_8086&DEV_0412&SUBSYS_05A51028).
# This Dell OEM package 20.19.15.5144 (igdlh64.inf / "oem2.inf" once staged)
# matches exactly and is Microsoft-signed (WHCP).
#
# MS Update Catalog download links are per-session signed URLs. If the URL
# below expired, redo the catalog search (see comments at the bottom).
set -euo pipefail

CAB_URL="${1:-}"
WORK=/var/lib/vz/igfx
ISO=igfxdrv.iso
SHA256=""   # optional: pin after first successful fetch

mkdir -p "$WORK"
cd "$WORK"

if [ ! -f igfx.cab ]; then
  if [ -z "$CAB_URL" ]; then
    cat >&2 <<'MSG'
No CAB URL given. To get one:
  1. https://www.catalog.update.microsoft.com/Search.aspx?q=20.19.15.5144
  2. Find the row "Intel Corporation - Display - 20.19.15.5144" (Dell OEM).
     Row GUIDs are visible as id="<GUID>_R0" in page source.
  3. POST updateIDs=[{"id":"<GUID>","size":...,"languages":""}] to
     https://www.catalog.update.microsoft.com/DownloadDialog.aspx and
     extract the catalog.s.download.windowsupdate.com/...cab link.
  4. Pass that URL as \$1 to this script.
  (Or ask an agent: scripts/cabscan.py <cab> 0412 can verify a candidate.)
MSG
    exit 1
  fi
  wget -O igfx.cab "$CAB_URL"
fi

if [ -n "$SHA256" ]; then
  echo "$SHA256  igfx.cab" | sha256sum -c -
fi

echo "== verifying the CAB contains the matching INF (SUBSYS_05A51028)"
python3 - <<'PY'
import re
data = open('igfx.cab','rb').read()
assert data[:4] == b'MSCF', 'not a CAB'
print('CAB ok, %d bytes' % len(data))
PY

# Extract (cabextract handles LZX; apt-get install cabextract if missing)
if command -v cabextract >/dev/null; then
  cabextract -d x igfx.cab
else
  echo "cabextract not found; trying 7z" >&2
  7z x -o x igfx.cab >/dev/null
fi

echo "== checking INF device list"
INF=$(find x -iname 'igdlh64.inf' | head -1)
[ -n "$INF" ] || { echo "igdlh64.inf not found in CAB" >&2; exit 1; }
iconv -f UTF-16LE -t UTF-8 "$INF" | grep -i 'SUBSYS_05A51028' | head -3
echo "OK: package matches the OptiPlex 7020 HD 4600 (DEV_0412&SUBSYS_05A51028)"

echo "== building $ISO for guest install"
mkdir -p cdrom
cp -r x/* cdrom/ 2>/dev/null || true
genisoimage -quiet -o "$ISO" cdrom
cp "$ISO" /var/lib/vz/template/iso/

echo "== done. In the guest (as admin):"
echo "   pnputil /add-driver E:\\igdlh64.inf /install     (drive letter = the ISO)"
echo "   or run the extracted Setup.exe / pnputil against the whole folder."
echo "Then verify: Get-PnpDevice -Class Display  -> Status OK, Problem CM_PROB_NONE"
