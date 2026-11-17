#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

KSU_MANAGER_PACKAGE="${KSU_MANAGER_PACKAGE:-}"
KSU_NEXT_MANAGER_SIZE="${KSU_NEXT_MANAGER_SIZE:-}"
KSU_NEXT_MANAGER_HASH="${KSU_NEXT_MANAGER_HASH:-}"
APK_PATH=""
MAKEPKG_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [options] [-- makepkg-args...]

Options:
  --apk <path>         Extract manager signature size and sha256 from APK
  --pkg <name>         Set KSU_MANAGER_PACKAGE (e.g. spoofed package name)
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apk)
      APK_PATH="${2:?Missing path for --apk}"
      shift 2
      ;;
    --pkg)
      KSU_MANAGER_PACKAGE="${2:?Missing package name for --pkg}"
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

extract_apk_info() {
  local apk="$1"
  python3 - "$apk" <<'PYEOF'
import hashlib
import struct
import sys
import zipfile

apk_path = sys.argv[1]

with open(apk_path, "rb") as f:
    data = f.read()

eocd = data.rfind(b"PK\x05\x06")
if eocd == -1:
    sys.exit("Invalid APK: EOCD not found")

cd_off = struct.unpack_from("<I", data, eocd + 16)[0]
bsize = struct.unpack_from("<Q", data, cd_off - 24)[0]
p = cd_off - bsize
sig_size = sig_hash = None
while p < cd_off - 24:
    plen, pid = struct.unpack_from("<QI", data, p)
    if pid in (0x7109871a, 0xf05368c0):
        v = data[p + 12 : p + 8 + plen]
        off = 12 + struct.unpack_from("<I", v, 12)[0] + 4
        clen = struct.unpack_from("<I", v, off + 4)[0]
        cert = v[off + 8 : off + 8 + clen]
        sig_size = hex(clen)
        sig_hash = hashlib.sha256(cert).hexdigest()
        break
    p += 8 + plen

if not sig_size:
    sys.exit("APK v2/v3 signing block not found")

pkg_name = ""
with zipfile.ZipFile(apk_path) as z:
    m = z.read("AndroidManifest.xml")

_, sp_hdr_size, sp_size, str_count, _, flags, str_start, _ = struct.unpack_from("<HHIIIIII", m, 8)
utf8 = bool(flags & (1 << 8))
offsets = struct.unpack_from(f"<{str_count}I", m, 8 + sp_hdr_size)
base = 8 + str_start
strings = []
for off in offsets:
    pos = base + off
    if utf8:
        b = m[pos]
        pos += 2 if (b & 0x80) else 1
        blen = m[pos]
        pos += 1
        if blen & 0x80:
            blen = ((blen & 0x7f) << 8) | m[pos]
            pos += 1
        strings.append(m[pos : pos + blen].decode("utf-8", "ignore"))
    else:
        clen = struct.unpack_from("<H", m, pos)[0]
        pos += 2
        if clen & 0x8000:
            clen = ((clen & 0x7fff) << 16) | struct.unpack_from("<H", m, pos)[0]
            pos += 2
        strings.append(m[pos : pos + clen * 2].decode("utf-16le", "ignore"))

pos = 8 + sp_size
while pos + 8 <= len(m):
    ctype, chdr, csize = struct.unpack_from("<HHI", m, pos)
    if ctype == 0x0102:
        name_idx, _, attr_size, attr_count = struct.unpack_from("<IHHH", m, pos + 20)
        if strings[name_idx] == "manifest":
            apos = pos + chdr
            for i in range(attr_count):
                _, aname, rval = struct.unpack_from("<III", m, apos + i * attr_size)
                if strings[aname] == "package" and rval != 0xFFFFFFFF:
                    pkg_name = strings[rval]
                    break
            break
    pos += csize

print(f"{sig_size} {sig_hash} {pkg_name}")
PYEOF
}

if [ -n "$APK_PATH" ]; then
  if [ ! -f "$APK_PATH" ]; then
    echo "APK not found: $APK_PATH" >&2
    exit 1
  fi
  read -r KSU_NEXT_MANAGER_SIZE KSU_NEXT_MANAGER_HASH _apk_pkg < <(extract_apk_info "$APK_PATH")
  if [ -z "$KSU_MANAGER_PACKAGE" ] && [ -n "${_apk_pkg:-}" ]; then
    KSU_MANAGER_PACKAGE="$_apk_pkg"
  fi
  echo "Detected APK manager: package=${KSU_MANAGER_PACKAGE:-default} size=${KSU_NEXT_MANAGER_SIZE} hash=${KSU_NEXT_MANAGER_HASH}"
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

export KSU_MANAGER_PACKAGE KSU_NEXT_MANAGER_SIZE KSU_NEXT_MANAGER_HASH
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
