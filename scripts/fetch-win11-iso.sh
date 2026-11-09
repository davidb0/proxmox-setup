#!/bin/bash
# Fetch the Windows 11 ISO into Proxmox ISO storage and verify its SHA256.
#
# Microsoft download links are time-signed and expire. Get a fresh one:
#   1. Open https://www.microsoft.com/software-download/windows11 in a browser
#      (the page is JS-driven; plain curl gets a 404 page).
#   2. Pick "Windows 11 (multi-edition ISO for x64 devices)" -> 64-bit Download.
#   3. Copy the resulting software.download.prss.microsoft.com URL below
#      or pass it as $1.
#
# Usage: ./fetch-win11-iso.sh [download-url]
set -euo pipefail

URL="${1:-}"
ISO="Win11_Client_x64_en-us_26300_9457.iso"
DIR="/var/lib/vz/template/iso"
SHA256="bd4307df32bc8af33b39ccecb1174aeb345386630f89a2b86c7a4e36b55ea650"

cd "$DIR"

# Already downloaded and verified?
if [ -f "$ISO" ]; then
  if echo "$SHA256  $ISO" | sha256sum -c --quiet -; then
    echo "ALREADY-VERIFIED $ISO"
    exit 0
  fi
  echo "existing copy has wrong hash; deleting" >&2
  rm -f "$ISO"
fi

if [ -z "$URL" ]; then
  echo "No URL given and no verified ISO present." >&2
  echo "Pass a fresh Microsoft download URL as \$1 (links expire ~24h)." >&2
  exit 1
fi

echo "== downloading $ISO (8.5 GB, resumable)"
wget -c -O "$ISO" "$URL"

echo "== verifying SHA256 (matches Microsoft's published hash)"
echo "$SHA256  $ISO" | sha256sum -c -

echo "== done. Attach with:"
echo "   qm set <vmid> --ide2 local:iso/$ISO,media=cdrom"
