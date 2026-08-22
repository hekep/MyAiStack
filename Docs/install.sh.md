# install.sh — Local AI coding stack installer (universal, function-based)

## What it does

Interactive, **re-runnable** installer that builds a local-AI coding
environment on any Apple Silicon Mac: Homebrew → Ollama → server (localhost or
LAN binding) → uv → mlx-lm → a **RAM-aware model download menu** →
verification. It detects the host's memory and only ever offers models that
actually fit that machine. One y/n question at a time; nothing installs
silently.

## How it works — one function per step

Run the file for the full pipeline, or `source install.sh` and call any
function alone. Every function checks its own prerequisites, detects work
already done, and proposes an update when one is available — so both the
script and each individual function can be run any number of times.

| Function | What | Gate / re-run behavior |
|---|---|---|
| `installOllamaSanity` | Platform check + **host RAM detection**; sets `TOTAL_GB` and `GPU_GB` (~75 % of RAM, the macOS GPU allocation) used by the model menu | Aborts under 16 GB RAM or non-Apple-Silicon |
| `installOllamaDiskGate` | **HARD BLOCK** below 25 GB free (60+ recommended). Shows shortfall + measured disk hogs, loops *Enter = re-check / q = quit*. No bypass. | Passes instantly when already met |
| `installOllamaHomebrew` | Homebrew present or offered | Skips if present |
| `installOllamaEngine` | Ollama runtime. Detects install kind: standalone .app → offers brew migration (models in `~/.ollama` preserved); brew-managed → checks `brew outdated` and **proposes upgrade only if one exists**; missing → offers install | Idempotent |
| `installOllamaServer` | Server + **network exposure choice**: localhost-only (default) or LAN-only — binds the Mac's private IP (refuses non-RFC-1918), warns Ollama has **no authentication**, notes the DHCP caveat, installs a dedicated LaunchAgent (`local.ollama.lan.plist`) since `brew services` drops env vars. Prints actual listening sockets from `lsof`. | Leaves a running server alone |
| `installOllamaUv` | uv (prerequisite of mlx-lm); proposes upgrade if brew reports one | Idempotent |
| `installOllamaMlx` | mlx-lm via uv; offers `uv tool upgrade` when already installed | Idempotent |
| `installOllamaModels` | **Merged model step — see below** | Loops until "N" |
| `installOllamaVerification` | Full status summary (versions, server, models) + optional `--verbose` throughput test | Pure read/report |
| `installOllama` | **Wrapper** — runs all of the above in order; hard-fails on sanity/disk/brew/engine, degrades gracefully on the rest | — |

## The model menu (`installOllamaModels`)

Replaces the old fixed "step 7 + step 8" model pulls with a universal,
hardware-aware chooser:

1. **Scans Ollama** for what is already downloaded (`ollama list`).
2. Builds a numbered menu from a curated catalog (~23 models, biggest →
   smallest), showing only models that:
   - **fit this host** — estimated need (`size × 1.3 + 2 GB` for KV-cache and
     runtime) must be within the GPU allocation (`GPU_GB`); and
   - are **not yet downloaded**.
3. Menu is capped at **25 options**, ordered **biggest to smallest**, each line
   showing download size, estimated RAM need, and a one-line description.
   Last option is always **N) No download**.
4. After each pull the menu **re-renders** (the just-downloaded model
   disappears) and the question **loops until "N"** is chosen.
5. Disk is re-checked (`size + 5 GB` headroom) immediately before every pull.

Example behavior on this 48 GB machine (36 GB GPU allocation): the 70B–120B
entries are filtered out as not fitting; already-present `qwen3.6:35b-a3b` and
`qwen2.5-coder:7b` are skipped; seven candidates remain from `qwen3:32b`
(28 GB need) down to `qwen2.5-coder:1.5b` (3 GB need). On a 128 GB Mac the
same script would offer the 70B/120B tier too — nothing is hardcoded to one
host.

## Why it is necessary

- **The machine's original Ollama was a 19-month-old standalone .app** that
  `brew upgrade` couldn't see and that predated modern MoE support; the
  migration is easy to get wrong by hand (one wrong `rm` deletes the models).
- **Disk reality:** a single model is ~20 GB and this disk was at 3 GB free
  when the project started. The hard gate prevents half-downloaded blobs from
  filling the disk.
- **Hardware-aware menus prevent the classic local-LLM failure**: pulling a
  model that loads, swaps, and generates at 1 token/s. The fit rule bakes the
  memory math in before any bytes are downloaded.
- **Exposure defaults matter:** many tutorials suggest `OLLAMA_HOST=0.0.0.0`,
  which opens an unauthenticated API to every network. Localhost is the
  default; LAN exposure is an explicit, guarded choice.

## Usage

```bash
./install.sh                  # full pipeline
```

```bash
source install.sh             # à la carte, e.g.:
installOllamaModels           # just the model menu
```

Companions: [AI_CompatibilityReport.md](../AI_CompatibilityReport.md) (model
rationale), [uninstall.sh.md](uninstall.sh.md) (reversal),
[aiModelLauncher.sh.md](aiModelLauncher.sh.md) (day-to-day launching).
