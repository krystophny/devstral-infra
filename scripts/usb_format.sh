#!/usr/bin/env bash
# Format a USB stick as exFAT and lay down the slopcode skeleton on it.
#
# Usage:
#   scripts/usb_format.sh /dev/sdX "QWENSTACK"
#
# Requires root (mkfs.exfat wants raw device access). The script refuses to
# touch anything that looks like a system disk and requires a typed "YES"
# confirmation that includes the device path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

DEV="${1:-}"
LABEL="${2:-QWENSTACK}"
[[ -n "${DEV}" ]] || die "usage: $0 /dev/sdX [LABEL]"
[[ -b "${DEV}" ]] || die "not a block device: ${DEV}"

case "${DEV}" in
  /dev/sda|/dev/sda[0-9]*|/dev/nvme0*|/dev/mmcblk0*) die "refusing to touch ${DEV} (looks like system disk)" ;;
esac

have mkfs.exfat || die "mkfs.exfat missing; install exfatprogs (pacman -S exfatprogs)"
have sudo || die "sudo required"
have lsblk || die "lsblk required"

echo "target device:"
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT "${DEV}" || true
echo
echo "This will ERASE ALL DATA on ${DEV} and reformat it to exFAT (label '${LABEL}')."
printf 'type "YES ERASE %s" to confirm: ' "${DEV}"
read -r reply
[[ "${reply}" == "YES ERASE ${DEV}" ]] || die "aborted"

# Unmount anything on that device first.
while read -r mp; do
  [[ -n "${mp}" ]] && sudo umount "${mp}" 2>/dev/null || true
done < <(lsblk -no MOUNTPOINT "${DEV}")

sudo wipefs -a "${DEV}"
sudo mkfs.exfat -n "${LABEL}" "${DEV}"

mnt="$(mktemp -d)"
sudo mount "${DEV}" "${mnt}"
sudo install -d -o "$(id -u)" -g "$(id -g)" "${mnt}/models" "${mnt}/linux-cuda" "${mnt}/mac-m1" "${mnt}/windows-arc"
sudo chown -R "$(id -u):$(id -g)" "${mnt}"
cat > "${mnt}/README.txt" <<'EOF'
Empty slopcode bundle skeleton. Populate with:
  scripts/build_bundle.sh all --out <this-directory>
EOF
sudo umount "${mnt}"
rmdir "${mnt}"

echo "formatted ${DEV} as exFAT (${LABEL}) and laid down empty skeleton."
