#!/usr/bin/env bash
# shellcheck disable=SC2015
#
# Runs INSIDE a distro container as root. Installs prerequisites, runs
# setup.sh with the given flags, and verifies the result.
#
# Usage: bash test/container-test.sh [flags for setup.sh]
set -euo pipefail


FLAGS="${1:---skip-model --yes}"
REPO_DIR="${REPO_DIR:-/opt/local-ai-setup}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ok:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

install_prereqs() {
    log "Installing prerequisites..."
    if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl ca-certificates python3 tar zstd
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates python3 python3-venv zstd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q curl ca-certificates python3 zstd
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive --gpg-auto-import-keys install curl ca-certificates python3 zstd tar gzip gawk findutils
    else
        die "Unsupported package manager"
    fi
}

cd "$REPO_DIR"
install_prereqs

log "Running: ./setup.sh ${FLAGS}"
# shellcheck disable=SC2086
./setup.sh $FLAGS

log "Verifying install..."
command -v ollama >/dev/null 2>&1 && ok "ollama binary present" || die "ollama binary missing"
curl -fsS --max-time 10 http://127.0.0.1:11434/api/version >/dev/null && ok "ollama API reachable" || die "ollama API unreachable"
ollama --version >/dev/null 2>&1 && ok "ollama runs" || die "ollama does not run"

export PATH="$HOME/.opencode/bin:$PATH"
command -v opencode >/dev/null 2>&1 && ok "opencode present" || die "opencode missing"

log "Verifying opencode config..."
python3 - <<'PY'
import json
import os

path = os.path.expanduser("~/.config/opencode/opencode.json")
cfg = json.load(open(path))
mem_kb = 0
with open("/proc/meminfo") as f:
    for line in f:
        if line.startswith("MemTotal"):
            mem_kb = int(line.split()[1])
mem_gb = mem_kb // 1024 // 1024
if mem_gb < 8:
    expected = "qwen2.5-coder:3b"
elif mem_gb < 16:
    expected = "qwen2.5-coder:7b"
else:
    expected = "qwen2.5-coder:14b"
assert cfg.get("model") == f"ollama/{expected}", (cfg.get("model"), expected)
assert "ollama" in cfg.get("provider", {}), cfg
assert cfg["provider"]["ollama"]["options"]["baseURL"] == "http://127.0.0.1:11434/v1", cfg
print("opencode config OK (model ollama/%s)" % expected)
PY

log "Running --doctor..."
./setup.sh --doctor

log "ALL CHECKS PASSED"
