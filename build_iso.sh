#!/usr/bin/env bash
# build_iso.sh — Build a bootable Ubuntu 24.04 Server autoinstall USB image
# that lays down Ubuntu, then runs odin-b70-setup.sh on first boot to bring up
# the full vLLM + 4x Intel Arc Pro B70 stack.
#
# Run this in WSL or any Linux box with: xorriso, 7z, wget, sed, mksquashfs.
# Output: arc-pro-b70-autoinstall.iso  (write to USB with Rufus / Balena / dd)
#
# Usage:
#   bash build_iso.sh                 # use default Ubuntu 24.04.2 mirror
#   ISO_URL=... bash build_iso.sh     # override source ISO

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/iso_build"
OUT_ISO="${SCRIPT_DIR}/arc-pro-b70-autoinstall.iso"
SETUP_SH="${SCRIPT_DIR}/odin-b70-setup.sh"

ISO_URL="${ISO_URL:-https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso}"
SRC_ISO="${WORK_DIR}/$(basename "$ISO_URL")"

if [[ ! -f "$SETUP_SH" ]]; then
    echo "ERROR: $SETUP_SH not found. Run this from the ProB70_Install directory."
    exit 1
fi

# --- Dependency check -------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; MISSING=1; }; }
MISSING=0
need xorriso
need wget
need 7z
need sed
if [[ "$MISSING" == "1" ]]; then
    echo ""
    echo "Install on Ubuntu/WSL with:"
    echo "  sudo apt-get update && sudo apt-get install -y xorriso p7zip-full wget"
    exit 1
fi

mkdir -p "$WORK_DIR"

# --- Download base ISO ------------------------------------------------------
if [[ ! -f "$SRC_ISO" ]]; then
    echo ">>> Downloading $(basename "$ISO_URL")"
    wget -O "$SRC_ISO" "$ISO_URL"
fi

# --- Extract ISO ------------------------------------------------------------
EXTRACT_DIR="${WORK_DIR}/iso_extracted"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
echo ">>> Extracting ISO contents"
7z -y x "$SRC_ISO" -o"$EXTRACT_DIR" >/dev/null
# 7z leaves a [BOOT] folder we don't need
rm -rf "${EXTRACT_DIR}/[BOOT]"

# --- Create cloud-init autoinstall payload ----------------------------------
NOCLOUD_DIR="${EXTRACT_DIR}/nocloud"
mkdir -p "$NOCLOUD_DIR"

# Empty meta-data (required by cloud-init nocloud datasource)
: > "${NOCLOUD_DIR}/meta-data"

# user-data — autoinstall config
# - Interactive disk selection (interactive-sections: [storage])
# - Default creds: user / changeme (hash for 'changeme')
# - Embeds odin-b70-setup.sh into /opt and registers a first-boot oneshot
# Hash generated with: mkpasswd -m sha-512 changeme
USER_HASH='$6$rounds=4096$abcdefgh$LcjyAtZUWHHEWVKvkKqvkLwLqYNqXMNwwsvtNZqfUmsRWlOQ4lHsT4F9rPzRkAcLbLbcc/jtWTOmXhk0vCAJ./'

cat > "${NOCLOUD_DIR}/user-data" <<USERDATA
#cloud-config
autoinstall:
  version: 1
  # Pause on storage so the operator picks the disk — protects against booting
  # the USB on the wrong machine and wiping it.
  interactive-sections:
    - storage
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: aiserver
    username: user
    password: "${USER_HASH}"
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - curl
    - wget
    - git
    - ca-certificates
    - gnupg
    - lsb-release
    - software-properties-common
  late-commands:
    # Copy our setup script + first-boot wrapper into the installed system
    - mkdir -p /target/opt/prob70
    - curl -sSL file:///cdrom/nocloud/odin-b70-setup.sh -o /target/opt/prob70/odin-b70-setup.sh || cp /cdrom/nocloud/odin-b70-setup.sh /target/opt/prob70/odin-b70-setup.sh
    - cp /cdrom/nocloud/firstboot.sh /target/opt/prob70/firstboot.sh
    - chmod +x /target/opt/prob70/odin-b70-setup.sh /target/opt/prob70/firstboot.sh
    - cp /cdrom/nocloud/prob70-firstboot.service /target/etc/systemd/system/prob70-firstboot.service
    - curtin in-target --target=/target -- systemctl enable prob70-firstboot.service
USERDATA

# First-boot wrapper — runs setup, logs everything, self-disables
cat > "${NOCLOUD_DIR}/firstboot.sh" <<'FIRSTBOOT'
#!/usr/bin/env bash
# First-boot installer for Intel Arc Pro B70 inference stack.
# Runs once after Ubuntu install completes, then disables itself.
set -e
LOG=/var/log/prob70-firstboot.log
exec > >(tee -a "$LOG") 2>&1
echo "===== $(date): prob70 first-boot starting ====="

# Wait for network
for i in $(seq 1 60); do
    if ping -c1 -W2 github.com >/dev/null 2>&1; then break; fi
    echo "Waiting for network ($i/60)..."
    sleep 5
done

cd /opt/prob70
bash ./odin-b70-setup.sh
RC=$?
echo "===== $(date): prob70 first-boot finished (rc=$RC) ====="

# Disable so it doesn't run again
systemctl disable prob70-firstboot.service || true
exit $RC
FIRSTBOOT

# Systemd unit for the first-boot wrapper
cat > "${NOCLOUD_DIR}/prob70-firstboot.service" <<'UNIT'
[Unit]
Description=Intel Arc Pro B70 inference stack first-boot installer
After=network-online.target docker.service
Wants=network-online.target
ConditionPathExists=/opt/prob70/firstboot.sh
ConditionPathExists=!/var/lib/prob70/installed

[Service]
Type=oneshot
ExecStart=/opt/prob70/firstboot.sh
ExecStartPost=/bin/bash -c 'mkdir -p /var/lib/prob70 && touch /var/lib/prob70/installed'
RemainAfterExit=yes
TimeoutStartSec=0
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# Embed the actual setup script
cp "$SETUP_SH" "${NOCLOUD_DIR}/odin-b70-setup.sh"

# --- Patch GRUB to point at our autoinstall payload -------------------------
# Adds a new default entry that boots with autoinstall + ds=nocloud
GRUB_CFG="${EXTRACT_DIR}/boot/grub/grub.cfg"
if [[ ! -f "$GRUB_CFG" ]]; then
    echo "ERROR: grub.cfg not found at $GRUB_CFG"
    exit 1
fi

# Insert our entry as the first menuentry and set as default
sed -i '0,/^menuentry/{s|^menuentry|menuentry "Install Intel Arc Pro B70 Inference Server (autoinstall)" {\n\tset gfxpayload=keep\n\tlinux\t/casper/vmlinuz quiet autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---\n\tinitrd\t/casper/initrd\n}\nmenuentry|}' "$GRUB_CFG"
sed -i 's/^set default=.*/set default="0"/' "$GRUB_CFG"
sed -i 's/^set timeout=.*/set timeout=10/' "$GRUB_CFG"

# Same for isolinux (legacy BIOS) if present
if [[ -f "${EXTRACT_DIR}/isolinux/isolinux.cfg" ]]; then
    sed -i '1i default autoinstall\nlabel autoinstall\n  menu label ^Install Intel Arc Pro B70 Inference Server (autoinstall)\n  kernel /casper/vmlinuz\n  append initrd=/casper/initrd quiet autoinstall ds=nocloud;s=/cdrom/nocloud/ ---' "${EXTRACT_DIR}/isolinux/isolinux.cfg" || true
fi

# --- Repack as hybrid ISO ---------------------------------------------------
echo ">>> Building $OUT_ISO"
cd "$EXTRACT_DIR"

# Locate boot images extracted by 7z (Ubuntu 24.04 layout)
EFI_IMG="boot/grub/efi.img"
BIOS_IMG="boot/grub/i386-pc/eltorito.img"

# Fall back to alternate paths if needed
[[ ! -f "$EFI_IMG" ]] && EFI_IMG=$(find . -name "efi.img" | head -1 | sed 's|^\./||')
[[ ! -f "$BIOS_IMG" ]] && BIOS_IMG=$(find . -name "eltorito.img" | head -1 | sed 's|^\./||')

xorriso -as mkisofs \
    -r -V "ARCB70_AUTOINSTALL" \
    -o "$OUT_ISO" \
    --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -partition_offset 16 \
    --mbr-force-bootable \
    -append_partition 2 0xef "$EFI_IMG" \
    -appended_part_as_gpt \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot.catalog' \
    -b "$BIOS_IMG" \
        -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:::' \
        -no-emul-boot \
    .

cd "$SCRIPT_DIR"
SIZE=$(du -h "$OUT_ISO" | cut -f1)
echo ""
echo "==============================================="
echo "Built: $OUT_ISO ($SIZE)"
echo ""
echo "Write to USB:"
echo "  Linux/WSL:   sudo dd if='$OUT_ISO' of=/dev/sdX bs=4M status=progress oflag=sync"
echo "  Windows:     Rufus or Balena Etcher (DD mode)"
echo ""
echo "On boot:"
echo "  1. Boot target machine from USB"
echo "  2. Select 'Install Intel Arc Pro B70 Inference Server (autoinstall)'"
echo "  3. Confirm disk when installer pauses on storage"
echo "  4. Login as user / changeme"
echo "  5. First-boot service runs odin-b70-setup.sh automatically"
echo "  6. Watch progress: sudo journalctl -fu prob70-firstboot"
echo "==============================================="
