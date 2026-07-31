#!/usr/bin/env bash
#
# Bootstrap for local-ai-setup. Downloads the project and runs setup.sh.
# Usage: curl -fsSL https://raw.githubusercontent.com/denzyldick/local-ai-setup/main/install.sh | bash
set -euo pipefail

REPO="denzyldick/local-ai-setup"
BRANCH="main"
INSTALL_DIR="${LOCAL_AI_SETUP_DIR:-$HOME/.local/share/local-ai-setup}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "Downloading local-ai-setup (${REPO}@${BRANCH})..."
curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}" -o "$TMP/repo.tar.gz"
tar -xzf "$TMP/repo.tar.gz" -C "$TMP"

mkdir -p "$(dirname "$INSTALL_DIR")"
rm -rf "$INSTALL_DIR"
mv "$TMP/local-ai-setup-${BRANCH}" "$INSTALL_DIR"

log "Installed to ${INSTALL_DIR}"
exec bash "$INSTALL_DIR/setup.sh" "$@"
