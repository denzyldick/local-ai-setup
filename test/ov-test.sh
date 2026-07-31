#!/usr/bin/env bash
# shellcheck disable=SC2015
#
# Runs INSIDE a container as root. Tests the --intel-gpu path: venv creation,
# OpenVINO deps install, systemd user service, and opencode config wiring.
#
# No GPU is available in CI, so the server is not expected to be reachable
# and --doctor is not asserted green.
set -euo pipefail



REPO_DIR="${REPO_DIR:-/opt/local-ai-setup}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ok:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates python3 python3-venv zstd

cd "$REPO_DIR"
./setup.sh --intel-gpu --skip-model --yes

log "Verifying OpenVINO setup..."
test -x "$HOME/openvino-env/bin/python3" && ok "venv created" || die "openvino-env missing"
"$HOME/openvino-env/bin/python3" -c "import openvino_genai, fastapi, uvicorn" \
    && ok "openvino deps import" || die "openvino deps missing"

test -f "$HOME/.config/systemd/user/openvino-local.service" && ok "systemd user service written" \
    || die "openvino-local.service missing"
grep -q "openvino_server.py" "$HOME/.config/systemd/user/openvino-local.service" && ok "service points at server" \
    || die "service does not reference openvino_server.py"

log "Verifying opencode config has openvino provider..."
python3 - <<'PY'
import json
import os

cfg = json.load(open(os.path.expanduser("~/.config/opencode/opencode.json")))
assert "openvino" in cfg.get("provider", {}), cfg
assert "Qwen2.5-Coder-1.5B-Instruct-int4" in cfg["provider"]["openvino"]["models"], cfg
print("openvino provider OK")
PY

grep -q "ov_gpu=1" "$HOME/.setup-ollama.state" && ok "state records ov_gpu=1" || die "state missing ov_gpu=1"

log "ALL OV CHECKS PASSED"
