# Local AI Setup for Low-RAM Laptops

One command to turn a fresh Linux laptop (ThinkPads and similar, 8–16 GB RAM,
integrated graphics, possibly slow internet) into a working local AI machine:
**ollama + a RAM-appropriate model + opencode**, all wired together. Optional
Intel GPU acceleration via OpenVINO.

Built for laptops like the ThinkPad with Intel Meteor Lake iGPUs, where stock
ollama cannot reliably use the GPU (its Vulkan backend is known-broken there).

---

## What you end up with

- **ollama** running locally at `http://127.0.0.1:11434` (auto-starts on boot)
- A **coder model** picked for your RAM (default `qwen2.5-coder:7b`)
- **opencode** installed and configured to use the local model — fully offline,
  no API keys, no cloud
- Optional (`--intel-gpu`): an **OpenVINO GPU server** at `http://127.0.0.1:8000`
  that accelerates small models on Intel iGPUs

## Requirements

- Linux (Arch/CachyOS, Debian/Ubuntu, Fedora, openSUSE tested paths; any distro
  works via the official installers)
- 8+ GB RAM (the script picks a smaller model for less RAM)
- ~2–9 GB free disk (depends on model)
- `sudo` access for the ollama install step
- Python 3.9–3.13 (only needed for `--intel-gpu`)
- Node.js 18+ (only needed to install opencode if it isn't already installed)

## Quick start

```bash
git clone <your-repo-url> local-ai-setup
cd local-ai-setup
./setup.sh --yes
```

Interactive mode (pick a model yourself):

```bash
./setup.sh
```

That's it. After it finishes: **quit and restart opencode**, then just run
`opencode` — it uses your local model.

## How the model is chosen

The script reads your RAM and recommends a tier (all are coder-optimized for
opencode use):

| RAM        | Model                | Size    |
|------------|----------------------|---------|
| < 8 GB     | `qwen2.5-coder:3b`   | ~2 GB   |
| 8–16 GB    | `qwen2.5-coder:7b`   | ~4.7 GB |
| ≥ 16 GB    | `qwen2.5-coder:14b`  | ~9 GB   |
| slow internet | `qwen2.5-coder:1.5b` | ~1 GB |

Use any other model with `--model <name>` (e.g. `--model qwen3:4b`). The tiers
live at the top of `setup.sh` — when newer/better models ship, just update that
table and re-run; the script will offer the upgrade.

## Flags

| Flag             | What it does                                             |
|------------------|----------------------------------------------------------|
| `--model <name>` | Use a specific model, skip the picker                    |
| `--skip-model`   | Configure everything, defer model downloads (slow internet) |
| `--intel-gpu`    | Also set up the OpenVINO GPU server for Intel iGPUs      |
| `--no-opencode`  | ollama only, don't touch opencode                        |
| `--yes`          | Non-interactive, accept recommended defaults             |
| `--doctor`       | Diagnose an existing setup and exit                      |
| `--dry-run`      | Print what would happen, change nothing                  |
| `-h, --help`     | Show usage                                               |

## Slow internet? Download later

```bash
./setup.sh --skip-model --yes --intel-gpu
```

This installs and configures everything now. When you have bandwidth, run:

```bash
ollama pull qwen2.5-coder:7b            # main chat/code model
systemctl --user start openvino-local   # GPU model (auto-downloads on first start)
```

Ollama pulls are **resumable** — an interrupted download continues next time,
and the script retries failed pulls automatically.

## Intel GPU (OpenVINO)

Why not just enable the GPU in ollama? Because on Intel **Meteor Lake** iGPUs,
ollama's Vulkan backend produces garbage output, and Intel's own ollama fork
(IPEX-LLM) is no longer maintained. The working path for Intel iGPUs is an
OpenVINO inference server, which is what `--intel-gpu` sets up:

```bash
./setup.sh --intel-gpu --yes
```

- Creates a Python venv (`~/openvino-env`) with `openvino-genai`
- Installs an OpenAI-compatible server as a systemd user service on port 8000
- First start downloads/exports `Qwen2.5-Coder-1.5B-Instruct` (INT4, ~1 GB)
- Adds an `openvino` provider to your opencode config

Use the GPU model with:

```bash
opencode --model openvino/Qwen2.5-Coder-1.5B-Instruct-int4
```

Reality check: on a shared-RAM laptop iGPU, GPU acceleration only meaningfully
beats CPU for small models (≤ 4B). The 7B default still runs on CPU via
ollama — which is fine and reliable.

## Upgrading / re-running

The script is idempotent — safe to run again at any stage. On re-run it:

- Skips anything already installed
- Tells you if a newer recommended model exists and offers the upgrade
- Re-verifies the opencode config

## Troubleshooting

Run the built-in check:

```bash
./setup.sh --doctor
```

| Symptom | Fix |
|---------|-----|
| `opencode` still uses cloud models | Quit and restart opencode — it loads config on startup |
| `opencode: command not found` | Open a new terminal (the installer updates `PATH`) |
| Model answers slowly | Normal on CPU; use `--intel-gpu` for ≤4B models or pick a smaller model |
| Port 11434/8000 in use | Another server occupies it — stop it or pick a different port |
| Pull interrupted | Just re-run `./setup.sh` or `ollama pull <model>` — it resumes |
| OpenVINO server won't start | `systemctl --user status openvino-local`, check `~/setup-ollama.log` |

The script logs everything to `~/setup-ollama.log` — include it if you report
an issue.

## Uninstall / cleanup

```bash
sudo systemctl disable --now ollama
systemctl --user disable --now openvino-local   # if you used --intel-gpu
sudo rm /usr/local/bin/ollama                    # or remove via your package manager
rm -rf ~/.ollama ~/openvino-env ~/.local/share/ollama-opencode-setup
# restore your opencode config if you want the pre-setup version back:
cp ~/.config/opencode/opencode.json.bak ~/.config/opencode/opencode.json
```

## Contributing

Keep the model tiers current. When a better coder model ships that fits
low-RAM laptops, update `MODEL_TIERS` at the top of `setup.sh` — that's the
whole maintenance surface. Benchmarks for the Intel GPU path on Meteor Lake are
welcome in the README.
