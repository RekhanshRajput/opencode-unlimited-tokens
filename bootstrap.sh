#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  OPENCODE UNLIMITED TOKENS — remote bootstrap
#  curl -fsSL https://raw.githubusercontent.com/RekhanshRajput/opencode-unlimited-tokens/main/bootstrap.sh | bash
# ─────────────────────────────────────────────────────────────
set -euo pipefail

REPO="${UT_REPO:-RekhanshRajput/opencode-unlimited-tokens}"
REF="${UT_REF:-main}"

say()  { printf '\033[0;36m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "fetching $REPO@$REF"
curl -fsSL --max-time 120 "https://github.com/$REPO/archive/refs/heads/$REF.tar.gz" -o "$TMP/src.tar.gz" \
  || die "download failed (repo or network)"

tar -xzf "$TMP/src.tar.gz" -C "$TMP"
SRC="$TMP/$(basename "$REPO")-$REF"
if [ ! -f "$SRC/install.sh" ]; then
  SRC="$(find "$TMP" -mindepth 2 -maxdepth 2 -name install.sh -printf '%h\n' | head -1)"
fi
[ -f "${SRC:-}/install.sh" ] || die "install.sh not found in archive"

say "running installer"
bash "$SRC/install.sh" "$@"

printf '\n\033[0;32m[✓]\033[0m done. log: ~/.config/opencode/memory/unlimited-tokens.log\n'
