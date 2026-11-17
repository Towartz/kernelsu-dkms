#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

KSU_PACKAGE_NAME="${KSU_PACKAGE_NAME:-}"
KSU_EXPECTED_SIZE="${KSU_EXPECTED_SIZE:-}"
KSU_EXPECTED_HASH="${KSU_EXPECTED_HASH:-}"
APK_PATH=""
MAKEPKG_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [options] [-- makepkg-args...]

Options:
  --next, --ksu-next   Configure manager signature for KernelSU-Next
                       (com.rifsxd.ksunext, size 0x3e6)
  --apk <path>         Extract manager signature size and sha256 from APK
  --pkg <name>         Override KSU_PACKAGE_NAME (e.g. spoofed package name)
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --next|--ksu-next)
      : "${KSU_PACKAGE_NAME:=com.rifsxd.ksunext}"
      KSU_EXPECTED_SIZE="0x3e6"
      KSU_EXPECTED_HASH="79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7"
      shift
      ;;
    --apk)
      APK_PATH="${2:?Missing path for --apk}"
      shift 2
      ;;
    --pkg)
      KSU_PACKAGE_NAME="${2:?Missing package name for --pkg}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      MAKEPKG_ARGS+=("$@")
      break
      ;;
    *)
      MAKEPKG_ARGS+=("$1")
      shift
      ;;
  esac
done

extract_apk_sig() {
  local apk="$1"
  python3 - "$apk" <<'PYEOF'
import hashlib
import struct
import sys

with open(sys.argv[1], "rb") as f:
    data = f.read()

eocd = data.rfind(b"PK\x05\x06")
if eocd == -1:
    sys.exit("Invalid APK: EOCD not found")

cd_off = struct.unpack_from("<I", data, eocd + 16)[0]
bsize = struct.unpack_from("<Q", data, cd_off - 24)[0]
p = cd_off - bsize
while p < cd_off - 24:
    plen, pid = struct.unpack_from("<QI", data, p)
    if pid in (0x7109871a, 0xf05368c0):
        v = data[p + 12 : p + 8 + plen]
        off = 12 + struct.unpack_from("<I", v, 12)[0] + 4
        clen = struct.unpack_from("<I", v, off + 4)[0]
        cert = v[off + 8 : off + 8 + clen]
        print(f"{hex(clen)} {hashlib.sha256(cert).hexdigest()}")
        sys.exit(0)
    p += 8 + plen

sys.exit("APK v2/v3 signing block not found")
PYEOF
}

if [ -n "$APK_PATH" ]; then
  if [ ! -f "$APK_PATH" ]; then
    echo "APK not found: $APK_PATH" >&2
    exit 1
  fi
  read -r KSU_EXPECTED_SIZE KSU_EXPECTED_HASH < <(extract_apk_sig "$APK_PATH")
  if [ -z "$KSU_PACKAGE_NAME" ] && [[ "$(basename "$APK_PATH")" == *KernelSU_Next* || "$(basename "$APK_PATH")" == *ksunext* ]]; then
    KSU_PACKAGE_NAME="com.rifsxd.ksunext"
  fi
fi

install_modloader() {
  if command -v modloader >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing modloader (required by load-kernelsu to resolve non-exported symbols)..."
  if command -v paru >/dev/null 2>&1; then
    paru -S --needed --noconfirm modloader
  elif command -v yay >/dev/null 2>&1; then
    yay -S --needed --noconfirm modloader
  else
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    git clone https://aur.archlinux.org/modloader.git "$tmpdir/modloader"
    (cd "$tmpdir/modloader" && makepkg -si --noconfirm)
  fi
}

install_modloader

if command -v waydroid >/dev/null 2>&1; then
  waydroid session stop >/dev/null 2>&1 || true
fi
if systemctl is-active --quiet waydroid-container 2>/dev/null; then
  sudo systemctl stop waydroid-container
fi

export KSU_PACKAGE_NAME KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
makepkg -sfi --noconfirm "${MAKEPKG_ARGS[@]}"

PKGVER=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
KVER=$(uname -r)

sudo dkms remove "kernelsu/${PKGVER}" --all || true
sudo dkms add "kernelsu/${PKGVER}"
sudo dkms install "kernelsu/${PKGVER}" -k "$KVER"

sudo mkdir -p "/usr/lib/modules/${KVER}/extra"
if [ -f "/usr/lib/modules/${KVER}/updates/dkms/kernelsu.ko.zst" ]; then
  sudo zstd -d -f "/usr/lib/modules/${KVER}/updates/dkms/kernelsu.ko.zst" -o "/usr/lib/modules/${KVER}/extra/kernelsu.ko"
elif [ -f "/usr/lib/modules/${KVER}/updates/dkms/kernelsu.ko.xz" ]; then
  sudo xz -dc "/usr/lib/modules/${KVER}/updates/dkms/kernelsu.ko.xz" | sudo tee "/usr/lib/modules/${KVER}/extra/kernelsu.ko" >/dev/null
elif [ -f "/usr/lib/modules/${KVER}/updates/dkms/kernelsu.ko.gz" ]; then
  sudo gzip -dc "/usr/lib/modules/${KVER}/updates/dkms/kernelsu.ko.gz" | sudo tee "/usr/lib/modules/${KVER}/extra/kernelsu.ko" >/dev/null
elif [ -f "/usr/lib/modules/${KVER}/updates/dkms/kernelsu.ko" ]; then
  sudo cp -f "/usr/lib/modules/${KVER}/updates/dkms/kernelsu.ko" "/usr/lib/modules/${KVER}/extra/kernelsu.ko"
fi

echo "Done. Load the module with: sudo load-kernelsu"
