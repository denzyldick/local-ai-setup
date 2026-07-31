#!/usr/bin/env bash
#
# setup.sh — One-command local AI setup for low-RAM laptops (ThinkPads etc.)
#
# Installs ollama + a RAM-appropriate model, installs opencode, and wires
# opencode to the local model. Optionally (--intel-gpu) sets up an OpenVINO
# GPU server for Intel iGPUs, since stock ollama's Vulkan backend is known to
# be broken on Meteor Lake.
#
# Usage: see --help
set -euo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_FILE="${LOG_FILE:-$HOME/setup-ollama.log}"
STATE_FILE="$HOME/.setup-ollama.state"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
OLLAMA_BASE_URL="http://127.0.0.1:11434/v1"
OLLAMA_PORT=11434

OV_PORT=8000
OV_BASE_URL="http://127.0.0.1:${OV_PORT}/v1"
OV_VENV="$HOME/openvino-env"
OV_SERVER_DIR="$HOME/.local/share/ollama-opencode-setup"
OV_SERVER_SOURCE="$SCRIPT_DIR/openvino_server.py"
OV_SERVICE_NAME="openvino-local"
OV_MODEL_NAME="Qwen2.5-Coder-1.5B-Instruct-int4"
OV_HF_MODEL="Qwen/Qwen2.5-Coder-1.5B-Instruct"

# --- Modes ------------------------------------------------------------------
DRY_RUN=0
YES=0
SKIP_MODEL=0
INTEL_GPU=0
NO_OPENCODE=0
DOCTOR=0
MODEL_OVERRIDE=""

if [ "$(id -u)" = 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# --- Model tiers (edit here when better models ship) ------------------------
declare -A MODEL_TIERS
MODEL_TIERS[small]="qwen2.5-coder:3b"     # <8GB RAM
MODEL_TIERS[medium]="qwen2.5-coder:7b"    # 8-16GB RAM
MODEL_TIERS[large]="qwen2.5-coder:14b"    # >=16GB RAM
MODEL_TIERS[tiny]="qwen2.5-coder:1.5b"    # slow-internet / very low RAM
MODEL_TIERS_FALLBACK="qwen2.5-coder:7b"

# --- Output helpers ----------------------------------------------------------
exec > >(tee -a "${LOG_FILE}") 2>&1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  ok:\033[0m %s\n' "$*"; }

has() { command -v "$1" >/dev/null 2>&1; }

run() {
    if [ "${DRY_RUN}" = 1 ]; then
        log "(dry-run) $*"
        return 0
    fi
    "$@"
}

confirm() {
    local prompt="$1" ans
    if [ "${YES}" = 1 ]; then
        return 0
    fi
    printf '%s [Y/n] ' "$prompt"
    read -r ans
    case "${ans:-y}" in
        [yY]*) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_default() {
    local prompt="$1" default="$2" ans
    printf '%s [%s] ' "$prompt" "$default"
    read -r ans
    printf '%s\n' "${ans:-$default}"
}

state_read() {
    [ -f "$STATE_FILE" ] || return 0
    sed -n "s/^${1}=//p" "$STATE_FILE" 2>/dev/null
}

state_write() {
    local key="$1" value="$2"
    if [ -f "$STATE_FILE" ] && grep -q "^${key}=" "$STATE_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$STATE_FILE"
    fi
}

require_sudo() {
    [ "${DRY_RUN}" = 1 ] && return 0
    [ -n "${SUDO}" ] || return 0
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    if confirm "This step needs sudo. Continue with sudo?"; then
        sudo -v
        return 0
    fi
    die "Sudo is required for this step."
}

# --- Pre-flight checks --------------------------------------------------------
check_disk() {
    local avail
    avail="$(df --output=avail -BG "$HOME" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
    if [ -n "$avail" ] && [ "$avail" -lt 10 ] 2>/dev/null; then
        warn "Only ${avail}GB free on $HOME. Models need 1-9GB. Consider freeing space."
    else
        log "Disk: ${avail:-?}GB free on $HOME"
    fi
}

check_ports() {
    if has ss; then
        if ss -tln 2>/dev/null | grep -q ":${OLLAMA_PORT}\s"; then
            warn "Port ${OLLAMA_PORT} (ollama) is already in use."
        fi
        if [ "${INTEL_GPU}" = 1 ] && ss -tln 2>/dev/null | grep -q ":${OV_PORT}\s"; then
            warn "Port ${OV_PORT} (OpenVINO) is already in use."
        fi
    fi
}

check_net() {
    if curl -fsS --max-time 8 -o /dev/null https://ollama.com 2>/dev/null; then
        return 0
    fi
    if has ollama && [ "${SKIP_MODEL}" = 1 ]; then
        warn "No internet. Continuing with existing ollama (offline mode)."
        return 0
    fi
    die "No internet connection detected. You need internet to install ollama/opencode and download models."
}

# --- Hardware detection --------------------------------------------------------
detect_hardware() {
    local mem_kb mem_gb cores gpu
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    mem_gb=$((mem_kb / 1024 / 1024))
    cores="$(nproc 2>/dev/null || echo "?")"
    gpu="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -n1 | sed 's/^[0-9:. ]*//' || echo "unknown")"

    if [ "$mem_gb" -lt 8 ]; then TIER=small
    elif [ "$mem_gb" -lt 16 ]; then TIER=medium
    else TIER=large
    fi
    RECOMMENDED_MODEL="${MODEL_TIERS[$TIER]}"

    log "Hardware detected: ${mem_gb}GB RAM, ${cores} cores"
    log "GPU: ${gpu}"
    log "Recommended model tier: ${TIER} -> ${RECOMMENDED_MODEL}"
    if printf '%s' "$gpu" | grep -qi intel; then
        log "Intel iGPU found. Note: stock ollama cannot accelerate Meteor Lake iGPUs"
        log "reliably (Vulkan is known-broken there). Use --intel-gpu for the OpenVINO path."
    fi
}

# --- ollama install ------------------------------------------------------------
install_ollama() {
    if has ollama; then
        log "ollama already installed ($(ollama --version 2>/dev/null | head -n1 || echo "unknown version"))"
        return 0
    fi
    log "ollama not found, installing..."
    require_sudo
    if has pacman; then
        for helper in paru yay aura; do
            if has "$helper"; then
                run "$helper" -S --noconfirm ollama
                has ollama && return 0
            fi
        done
        warn "No AUR helper found; using the official ollama installer"
    fi
    if ! has zstd; then
        warn "The official ollama installer needs 'zstd'. Install it first, e.g.:"
        warn "  Debian/Ubuntu: sudo apt-get install zstd"
        warn "  Fedora:        sudo dnf install zstd"
        warn "  openSUSE:      sudo zypper install zstd"
        die "zstd is required for ollama installation"
    fi
    run sh -c "curl -fsSL https://ollama.com/install.sh | ${SUDO} sh"
    has ollama || die "ollama install failed"
    ok "ollama installed"
}

setup_service() {
    log "starting ollama service"
    if has systemctl && systemctl list-unit-files 'ollama.service' >/dev/null 2>&1; then
        require_sudo
        run ${SUDO} systemctl enable --now ollama
    elif has systemctl && systemctl --user list-unit-files 'ollama.service' >/dev/null 2>&1; then
        run systemctl --user enable --now ollama
    else
        warn "No ollama service unit found; starting ollama in background"
        run nohup ollama serve >/dev/null 2>&1 &
    fi

    local tries=0
    log "waiting for ollama API on ${OLLAMA_BASE_URL}"
    while ! curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:${OLLAMA_PORT}/api/version" 2>/dev/null; do
        tries=$((tries + 1))
        [ "${DRY_RUN}" = 1 ] && break
        [ "$tries" -ge 30 ] && die "ollama API did not come up after 30s. Check the log."
        sleep 1
    done
    ok "ollama API is up"
}

# --- Model pick + pull ----------------------------------------------------------
validate_model() {
    local model="$1" name="${1%%:*}" tag="${1##*:}"
    curl -fsS -o /dev/null --max-time 8 "https://registry.ollama.ai/v2/library/${name}/manifests/${tag}" 2>/dev/null
}

pick_model() {
    local installed
    installed="$(state_read model)"

    if [ -n "$MODEL_OVERRIDE" ]; then
        PICKED_MODEL="$MODEL_OVERRIDE"
        log "Using model from --model: ${PICKED_MODEL}"
        return
    fi

    if [ -n "$installed" ] && [ "$installed" != "$RECOMMENDED_MODEL" ]; then
        log "You currently have ${installed} installed."
        log "A newer recommended model for this machine is ${RECOMMENDED_MODEL}."
    fi

    if [ "${YES}" = 1 ]; then
        PICKED_MODEL="$RECOMMENDED_MODEL"
        return
    fi

    printf '\nModel options:\n'
    printf '  [R] Recommended (%s, ~RAM-based)\n' "$RECOMMENDED_MODEL"
    printf '  [T] Tiny / slow-internet (%s)\n' "${MODEL_TIERS[tiny]}"
    printf '  [C] Custom (type your own model name)\n'
    printf '  [S] Skip model download (configure everything else)\n'
    printf 'Choose [R]: '
    read -r choice
    case "${choice:-r}" in
        [rR]) PICKED_MODEL="$RECOMMENDED_MODEL" ;;
        [tT]) PICKED_MODEL="${MODEL_TIERS[tiny]}" ;;
        [cC]) PICKED_MODEL="$(prompt_default 'Model name (e.g. qwen3:4b)' 'qwen3:4b')" ;;
        [sS]) SKIP_MODEL=1 ;;
        *) PICKED_MODEL="$RECOMMENDED_MODEL" ;;
    esac
}

pull_model() {
    if [ "$SKIP_MODEL" = 1 ]; then
        log "Skipping model download (--skip-model). Pull later with: ollama pull ${PICKED_MODEL:-$RECOMMENDED_MODEL}"
        return 0
    fi

    if ollama list 2>/dev/null | grep -q "^${PICKED_MODEL}\s"; then
        log "model ${PICKED_MODEL} already present"
        return 0
    fi

    if ! validate_model "$PICKED_MODEL"; then
        warn "Could not confirm '${PICKED_MODEL}' exists in the registry."
        if ! confirm "Try the known-good fallback '${MODEL_TIERS_FALLBACK}' instead?"; then
            warn "Leaving model uninstalled. Pull later with: ollama pull ${PICKED_MODEL}"
            return 1
        fi
        PICKED_MODEL="$MODEL_TIERS_FALLBACK"
    fi

    log "pulling ${PICKED_MODEL} (resumable if interrupted; may take a while)..."
    local attempt=1 max=3
    while [ "$attempt" -le "$max" ]; do
        if run ollama pull "$PICKED_MODEL"; then
            break
        fi
        if [ "$attempt" -lt "$max" ]; then
            warn "Pull failed (attempt ${attempt}/${max}). Retrying in $((attempt * 5))s..."
            sleep "$((attempt * 5))"
        else
            die "Failed to pull ${PICKED_MODEL} after ${max} attempts. Re-run this script to resume."
        fi
        attempt=$((attempt + 1))
    done
    state_write model "$PICKED_MODEL"
    ok "model ${PICKED_MODEL} is installed"
}

# --- opencode -------------------------------------------------------------------
ensure_opencode_path() {
    if [ -d "$HOME/.opencode/bin" ]; then
        case ":${PATH}:" in
            *":$HOME/.opencode/bin:"*) ;;
            *) export PATH="$HOME/.opencode/bin:$PATH" ;;
        esac
    fi
}

install_opencode() {
    if has opencode; then
        log "opencode already installed"
        return 0
    fi
    if [ "${NO_OPENCODE}" = 1 ]; then
        warn "Skipping opencode install (--no-opencode)"
        return 0
    fi
    log "opencode not found, installing..."
    run bash -c 'curl -fsSL https://opencode.ai/install | bash'
    ensure_opencode_path
    if ! has opencode; then
        warn "opencode install script did not add it to PATH."
        if confirm "Install via npm instead?" && has npm; then
            run npm install -g opencode-ai
        fi
    fi
    # shellcheck disable=SC2015
    has opencode && ok "opencode installed" || warn "opencode not found in PATH after install"
}

# --- opencode wiring (JSON merge, validated) --------------------------------------
wire_opencode() {
    if [ "${NO_OPENCODE}" = 1 ]; then
        return 0
    fi
    if ! has opencode; then
        warn "opencode is not installed; skipping config wiring"
        return 0
    fi
    log "wiring opencode to ${PICKED_MODEL:-$RECOMMENDED_MODEL}"

    local json_tool=""
    if has python3; then json_tool="python3"
    elif has node; then json_tool="node"
    else die "Need python3 or node to update opencode config"; fi

    if [ -f "$OPENCODE_CONFIG" ]; then
        run cp "$OPENCODE_CONFIG" "${OPENCODE_CONFIG}.bak"
    fi

    local target_model="${PICKED_MODEL:-$RECOMMENDED_MODEL}"
    if [ "$json_tool" = "python3" ]; then
        run python3 - "$OPENCODE_CONFIG" "$target_model" "$INTEL_GPU" "$OV_MODEL_NAME" <<'PY'
import json, os, sys
path, model, intel_gpu, ov_model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    cfg = json.load(open(path))
except FileNotFoundError:
    cfg = {"$schema": "https://opencode.ai/config.json"}
except Exception:
    sys.exit("Existing config is not valid JSON. Fix it (or restore the .bak) and re-run.")
cfg.setdefault("provider", {})
providers = cfg["provider"]
providers["ollama"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Local Ollama",
    "options": {"baseURL": "http://127.0.0.1:11434/v1"},
    "models": {model: {"name": model}},
}
cfg["model"] = "ollama/" + model
if intel_gpu == "1":
    providers["openvino"] = {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Local OpenVINO (Intel GPU)",
        "options": {"baseURL": "http://127.0.0.1:8000/v1"},
        "models": {ov_model: {"name": ov_model}},
    }
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
json.dump(cfg, open(path, "w"), indent=2)
PY
    else
        run node - "$OPENCODE_CONFIG" "$target_model" "$INTEL_GPU" "$OV_MODEL_NAME" <<'JS'
const [path, model, intelGpu, ovModel] = process.argv.slice(2);
const fs = require("fs");
const cfg = fs.existsSync(path) ? JSON.parse(fs.readFileSync(path)) : {};
cfg.provider = cfg.provider || {};
cfg.provider.ollama = {
  npm: "@ai-sdk/openai-compatible",
  name: "Local Ollama",
  options: { baseURL: "http://127.0.0.1:11434/v1" },
  models: { [model]: { name: model } },
};
cfg.model = `ollama/${model}`;
if (intelGpu === "1") {
  cfg.provider.openvino = {
    npm: "@ai-sdk/openai-compatible",
    name: "Local OpenVINO (Intel GPU)",
    options: { baseURL: "http://127.0.0.1:8000/v1" },
    models: { [ovModel]: { name: ovModel } },
  };
}
fs.mkdirSync(require("path").dirname(path), { recursive: true });
fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
JS
    fi

    if [ -f "${OPENCODE_CONFIG}.bak" ] && grep -q "local-setup/sync-on-launch" "${OPENCODE_CONFIG}.bak" 2>/dev/null; then
        warn "You use the opencode local-setup wrapper (sync-models). It may re-sync providers on"
        warn "launch and overwrite this static config. That is fine — run 'sync-models' to refresh."
    fi
    ok "opencode config updated at ${OPENCODE_CONFIG}"
}

# --- Intel GPU / OpenVINO path ------------------------------------------------------
install_openvino() {
    if [ "${INTEL_GPU}" != 1 ]; then
        return 0
    fi
    log "Setting up Intel GPU (OpenVINO) inference server..."

    if [ ! -d "$OV_VENV" ]; then
        log "creating Python venv at ${OV_VENV}"
        run python3 -m venv "$OV_VENV"
    else
        log "venv already exists at ${OV_VENV}"
    fi

    if [ "$("$OV_VENV/bin/python3" -c 'import openvino_genai, fastapi, uvicorn; print("ok")' 2>/dev/null)" != "ok" ]; then
        log "installing openvino-genai + fastapi + uvicorn + optimum-intel (large download)..."
        run "$OV_VENV/bin/pip" install --upgrade pip
        run "$OV_VENV/bin/pip" install openvino-genai fastapi uvicorn optimum-intel
    else
        log "OpenVINO dependencies already installed"
    fi

    run mkdir -p "$OV_SERVER_DIR"
    if [ ! -f "$OV_SERVER_SOURCE" ]; then
        die "openvino_server.py not found next to this script (${OV_SERVER_SOURCE})"
    fi
    if [ ! -f "$OV_SERVER_DIR/openvino_server.py" ] || ! cmp -s "$OV_SERVER_SOURCE" "$OV_SERVER_DIR/openvino_server.py"; then
        log "installing openvino_server.py"
        run cp "$OV_SERVER_SOURCE" "$OV_SERVER_DIR/openvino_server.py"
    fi

    local service_file="$HOME/.config/systemd/user/${OV_SERVICE_NAME}.service"
    run mkdir -p "$HOME/.config/systemd/user"
    log "creating systemd user service ${OV_SERVICE_NAME}"
    if [ ! -f "$service_file" ]; then
        run tee "$service_file" >/dev/null <<'UNIT'
[Unit]
Description=OpenVINO Local LLM Server (Intel GPU)
After=network.target

[Service]
Type=simple
ExecStart=__OV_VENV__/bin/python3 __OV_SERVER_DIR__/openvino_server.py --device GPU --port __OV_PORT__
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
        if [ "$DRY_RUN" != 1 ] && [ -f "$service_file" ]; then
            sed -i "s|__OV_VENV__|${OV_VENV}|; s|__OV_SERVER_DIR__|${OV_SERVER_DIR}|; s|__OV_PORT__|${OV_PORT}|" "$service_file"
        fi
    fi

    if [ "${SKIP_MODEL}" = 1 ]; then
        log "Skipping OpenVINO model export (--skip-model)."
        log "Start it later: systemctl --user start ${OV_SERVICE_NAME}  (first start auto-exports ${OV_HF_MODEL} to INT4)"
        run systemctl --user daemon-reload 2>/dev/null || true
        run systemctl --user enable "${OV_SERVICE_NAME}" 2>/dev/null || true
        state_write ov_gpu "1"
        return 0
    fi

    if has systemctl; then
        run systemctl --user daemon-reload 2>/dev/null || true
        run systemctl --user enable --now "${OV_SERVICE_NAME}" 2>/dev/null || {
            warn "Could not start via systemd; launching server in background instead"
            run nohup "$OV_VENV/bin/python3" "$OV_SERVER_DIR/openvino_server.py" --device GPU --port "$OV_PORT" >/dev/null 2>&1 &
        }
    else
        warn "systemd not found; launching OpenVINO server in background"
        run nohup "$OV_VENV/bin/python3" "$OV_SERVER_DIR/openvino_server.py" --device GPU --port "$OV_PORT" >/dev/null 2>&1 &
    fi

    local tries=0
    log "waiting for OpenVINO server on ${OV_BASE_URL} (first start exports the model, be patient)..."
    while ! curl -fsS --max-time 2 -o /dev/null "${OV_BASE_URL}/models" 2>/dev/null; do
        tries=$((tries + 1))
        [ "${DRY_RUN}" = 1 ] && break
        if [ "$tries" -ge 600 ]; then
            warn "OpenVINO server did not come up in 10 minutes. First-run model export can be slow."
            break
        fi
        sleep 1
    done
    [ "$tries" -lt 600 ] && ok "OpenVINO GPU server is up at ${OV_BASE_URL}"
    state_write ov_gpu "1"

    if command -v loginctl >/dev/null 2>&1; then
        run loginctl enable-linger "$USER" 2>/dev/null || true
    fi
    warn "Use the GPU model in opencode with: opencode --model openvino/${OV_MODEL_NAME}"
}

# --- smoke test ---------------------------------------------------------------------
smoke_test() {
    if [ "$SKIP_MODEL" = 1 ]; then
        return 0
    fi
    local model="${PICKED_MODEL:-$RECOMMENDED_MODEL}"
    log "smoke test: asking ${model} to say hello"
    if ! run timeout 180 ollama run "$model" "Reply with exactly: hello from ollama" 2>/dev/null; then
        warn "Smoke test failed. The model may still be loading or the pull incomplete."
        warn "Retry with: ollama run ${model}"
    else
        ok "smoke test passed"
    fi
}

# --- summary --------------------------------------------------------------------------
summary() {
    printf '\n\033[1;32mSetup complete!\033[0m\n'
    printf '  Chat with the model:      ollama run %s\n' "${PICKED_MODEL:-$RECOMMENDED_MODEL}"
    printf '  opencode (local model):   opencode\n'
    printf '  opencode API:             %s\n' "${OLLAMA_BASE_URL}"
    printf '  Switch model:             opencode --model ollama/<name>  (e.g. --model ollama/qwen3:4b)\n'
    if [ "${INTEL_GPU}" = 1 ]; then
        printf '  GPU (OpenVINO) model:    opencode --model openvino/%s\n' "${OV_MODEL_NAME}"
        printf '  GPU server status:       systemctl --user status %s\n' "${OV_SERVICE_NAME}"
    fi
    printf '  Re-run anytime:           %s\n' "$0"
    printf '  Log:                      %s\n' "${LOG_FILE}"
    printf '\n  Next steps:\n'
    printf '  1. If you just installed opencode, open a new terminal (PATH changes).\n'
    printf '  2. Quit and restart opencode so it picks up the new config.\n'
    printf '  3. Run %s --doctor anytime to verify this setup.\n' "$0"
}

# --- doctor -----------------------------------------------------------------------------
doctor() {
    log "Running diagnostics..."
    local okc=0 fail=0
    check() { # desc, status
        if [ "$2" = 0 ]; then ok "$1"; okc=$((okc + 1)); else warn "FAIL: $1"; fail=$((fail + 1)); fi
    }

    if has ollama; then check "ollama binary present" 0; else check "ollama binary present" 1; fi
    if curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${OLLAMA_PORT}/api/version" 2>/dev/null; then
        check "ollama API reachable" 0
    else
        check "ollama API reachable" 1
    fi
    if has ollama && [ -n "$(ollama list 2>/dev/null)" ]; then
        check "at least one model installed" 0
    else
        warn "No models installed yet. Pull one with: ollama pull ${RECOMMENDED_MODEL}"
    fi
    if has opencode; then check "opencode present" 0; else check "opencode present" 1; fi
    if [ -f "$OPENCODE_CONFIG" ]; then
        check "opencode config exists" 0
    else
        check "opencode config exists" 1
    fi
    if [ "$(state_read ov_gpu)" = "1" ]; then
        if [ -d "$OV_VENV" ]; then check "OpenVINO venv present" 0; else check "OpenVINO venv present" 1; fi
        if curl -fsS --max-time 3 -o /dev/null "${OV_BASE_URL}/models" 2>/dev/null; then
            check "OpenVINO GPU server reachable" 0
        else
            check "OpenVINO GPU server reachable" 1
        fi
    fi

    printf '\n\033[1;32m%s passed, %s failed\033[0m\n' "$okc" "$fail"
    printf 'Check the log for details: %s\n' "${LOG_FILE}"
    [ "$fail" = 0 ]
}

# --- help ----------------------------------------------------------------------------------
usage() {
    cat <<'EOF'
setup.sh — local AI setup for low-RAM laptops (ollama + opencode + optional Intel GPU)

Usage: ./setup.sh [options]

Options:
  --model <name>        Use a specific model (skips the picker)
  --skip-model          Configure everything, defer model downloads
                        (slow internet: run now, pull the model later)
  --intel-gpu           Also set up the OpenVINO GPU server for Intel iGPUs
                        (stock ollama cannot accelerate Meteor Lake iGPUs)
  --no-opencode         Install/configure ollama only
  --yes                 Non-interactive, accept recommended defaults
  --doctor              Diagnose an existing setup and exit
  --dry-run             Print what would happen, change nothing
  -h, --help            Show this help

Examples:
  ./setup.sh                                   Interactive install
  ./setup.sh --yes                             Non-interactive install
  ./setup.sh --skip-model --intel-gpu --yes    Full setup, defer all downloads
  ./setup.sh --doctor                          Verify an existing setup

Model tiers (by RAM, edit at the top of this script):
  <8GB qwen2.5-coder:3b | 8-16GB qwen2.5-coder:7b | >=16GB qwen2.5-coder:14b
EOF
}

# --- main -----------------------------------------------------------------------------------
main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --model) MODEL_OVERRIDE="${2:-}"; shift 2 ;;
            --skip-model) SKIP_MODEL=1; shift ;;
            --intel-gpu) INTEL_GPU=1; shift ;;
            --no-opencode) NO_OPENCODE=1; shift ;;
            --yes|-y) YES=1; shift ;;
            --doctor) DOCTOR=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) warn "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [ ! -t 0 ] && [ "${YES}" != 1 ] && [ "${DOCTOR}" != 1 ] && [ "${DRY_RUN}" != 1 ]; then
        warn "Non-interactive terminal detected; assuming --yes"
        YES=1
    fi

    log "${SCRIPT_NAME} v${SCRIPT_VERSION} (log: ${LOG_FILE})"

    if [ "${DOCTOR}" = 1 ]; then
        if doctor; then exit 0; else exit 1; fi
    fi

    check_disk
    check_net
    detect_hardware
    check_ports

    install_ollama
    setup_service
    pick_model
    pull_model
    install_opencode
    wire_opencode
    install_openvino
    smoke_test

    state_write script_version "$SCRIPT_VERSION"
    state_write ov_gpu "${INTEL_GPU}"
    summary
}

main "$@"
