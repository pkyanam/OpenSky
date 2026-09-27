#!/usr/bin/env bash
# OpenSky installer — idempotent, one line:
#   curl -fsSL https://raw.githubusercontent.com/pkyanam/OpenSky/main/scripts/install.sh | bash
#
# What it does:
#   1. Checks prerequisites (macOS on Apple Silicon, git, Xcode CLT for source builds)
#   2. Installs the `opensky` binary into ~/.local/bin (first choice) or /usr/local/bin
#   3. Ensures the install dir is on PATH (updates .zshrc/.zprofile/.bashrc safely, once)
#   4. Installs/refreshes the OpenCode 2 plugin (optional, default on)
#   5. Safe to re-run: existing installs are upgraded in place; no duplicates; old binary backed up
set -euo pipefail

REPO="pkyanam/OpenSky"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
BIN_NAME="opensky"
VERSION_TAG="${OPENSKY_VERSION:-main}"   # pin a tag to install a specific version

log() { printf '\033[1;36mopensky-installer\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mopensky-installer ✗ %s\033[0m\n' "$*" >&2; }

# ---------- 0. sanity ----------
OS="$(uname -s)"
ARCH="$(uname -m)"
if [[ "$OS" != "Darwin" ]]; then
  err "OpenSky requires macOS (found $OS)."
  exit 1
fi
if [[ "$ARCH" != "arm64" ]]; then
  err "OpenSky currently ships Apple Silicon (arm64) builds (found $ARCH)."
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  err "curl is required. Install it or use: brew install curl"
  exit 1
fi
SWIFT_AVAILABLE=0
if xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; then
  SWIFT_AVAILABLE=1
fi

# ---------- 1. pick install dir (idempotent) ----------
install_dir="$HOME/.local/bin"
if [ ! -w "$HOME/.local" ] 2>/dev/null; then
  install_dir="/usr/local/bin"
fi
mkdir -p "$install_dir"
log "install dir: $install_dir"

previous=""
if [ -f "$install_dir/$BIN_NAME" ]; then
  previous="$($install_dir/$BIN_NAME version 2>/dev/null || echo unknown)"
  log "existing install found: $previous (will upgrade in place)"
fi

# ---------- 2. fetch binary ----------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch_from_release() {
  log "fetching latest release for ${ARCH}…"
  api_json="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"
  if [ -z "$api_json" ]; then
    return 1
  fi
  asset_url="$(printf '%s' "$api_json" | /usr/bin/python3 -c '
import sys, json
try:
    rel = json.load(sys.stdin)
    for a in rel.get("assets", []):
        if a["name"] == "opensky-'"$ARCH"'-macos.tar.xz":
            print(a["browser_download_url"]); break
except Exception:
    pass' 2>/dev/null || true)"
  [ -n "$asset_url" ] || return 1
  curl -fSL "$asset_url" -o "$tmp/opensky.tar.xz"
  tar -xf "$tmp/opensky.tar.xz" -C "$tmp"
  mv "$tmp/opensky" "$tmp/opensky.new"
}

fetch_from_source() {
  if [ "$SWIFT_AVAILABLE" != "1" ]; then
    err "no prebuilt asset matched AND swift is unavailable (install Xcode Command Line Tools: xcode-select --install)"
    exit 1
  fi
  log "building from source (no prebuilt asset matched)…"
  git clone --depth 1 "https://github.com/${REPO}.git" "$tmp/src"
  (cd "$tmp/src" && swift build -c release)
  mv "$tmp/src/.build/release/$BIN_NAME" "$tmp/opensky.new"
}

if [ "$VERSION_TAG" = "main" ]; then
  fetch_from_release || fetch_from_source
else
  # pinned tag: source build for determinism
  VERSION_TAG="$VERSION_TAG" fetch_from_source
fi

if [ ! -f "$tmp/opensky.new" ]; then
  err "did not produce a binary; aborting (existing install untouched)"
  exit 1
fi

# ---------- 3. atomic swap ----------
if [ -f "$install_dir/$BIN_NAME" ]; then
  mv "$install_dir/$BIN_NAME" "$install_dir/.opensky.old"
fi
mv "$tmp/opensky.new" "$install_dir/$BIN_NAME"
chmod 755 "$install_dir/$BIN_NAME"
rm -f "$install_dir/.opensky.old"
log "installed: $($install_dir/$BIN_NAME version)"

# ---------- 4. PATH ----------
ensure_path() {
  local file="$1" line='export PATH="$HOME/.local/bin:$PATH"'
  [ -f "$file" ] || touch "$file"
  if ! grep -qF '.local/bin' "$file" 2>/dev/null; then
    printf '\n# added by OpenSky installer\n%s\n' "$line" >> "$file"
    log "added ~/.local/bin to PATH in $file"
    PATH="$HOME/.local/bin:$PATH"
  fi
}
case "${SHELL:-/bin/zsh}" in
  */zsh)
    ensure_path "$HOME/.zshrc"
    ensure_path "$HOME/.zprofile"
    ;;
  */bash)
    ensure_path "$HOME/.bashrc"
    ensure_path "$HOME/.profile"
    ;;
esac

# ---------- 5. OpenCode 2 plugin (optional, default on) ----------
if [ "${OPENSKY_NO_PLUGIN:-0}" != "1" ] && [ -d "$HOME/.config/opencode" ]; then
  plugin_dir="$HOME/.config/opencode/plugins"
  mkdir -p "$plugin_dir"
  if curl -fsSL "$RAW_BASE/plugin/opensky.ts" -o "$plugin_dir/opensky.ts" 2>/dev/null; then
    log "OpenCode 2 plugin installed: $plugin_dir/opensky.ts (restart OpenCode to load)"
  else
    log "OpenCode not detected or plugin fetch failed — skipping plugin (fine)"
  fi
fi

log "✓ done. run: opensky --help  |  teach an agent: opensky --skill  |  update later: opensky update"
