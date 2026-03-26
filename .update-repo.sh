#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/Oculto54/Utils/main"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
SCRIPT="$TMPDIR/update.sh"
info() { printf "\033[0;32m[INFO]\033[0m %s\n" "$1"; }
info "Downloading update.sh..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$REPO_URL/update.sh" -o "$SCRIPT"
elif command -v wget >/dev/null 2>&1; then
  wget -q --timeout=30 -O "$SCRIPT" "$REPO_URL/update.sh"
else
  printf "\033[0;31m[ERROR]\033[0m curl or wget required\n" >&2
  exit 1
fi
chmod +x "$SCRIPT"
info "Executing latest update.sh"
bash "$SCRIPT"
