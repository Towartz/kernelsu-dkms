#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

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
makepkg -si --noconfirm "$@"

echo "Done. Load the module with: sudo load-kernelsu"
