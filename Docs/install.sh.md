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
| `installOllamaServer` | Server + **network exposure choice**: localhost-only or LAN-only — binds the Mac's private IP (refuses non-RFC-1918), warns Ollama has **no authentication**, notes the DHCP caveat, installs a dedicated LaunchAgent (`local.ollama.lan.plist`) since `brew services` drops env vars. Prints actual listening sockets from `lsof`. | **Detects what is active now** (LAN LaunchAgent present, or server answering on the LAN IP) and defaults the question to keep it — Enter = no change. An explicit LAN→localhost switch tears the LAN agent down. |
| `installOllamaUv` | uv (prerequisite of mlx-lm); proposes upgrade if brew reports one | Idempotent |
| `installOllamaMlx` | mlx-lm via uv | When installed, **checks PyPI automatically** and asks to update only if a newer version actually exists — no question on an up-to-date rerun |
| `installOllamaClaudeCli` | Claude Code CLI — the frontend aiModelLauncher.sh connects to local models | First run (missing) → proposes installation (default Y). Rerun (present) → **automatic** version check against the npm registry (works for npm *and* native installs); only when a newer version exists does it ask "Update now? [Y/n]" — updating via the matching mechanism (`npm install -g` or `claude update`). |
| `installOllamaModels` | **Merged model step — see below** | Loops until "N" |
| `installOllamaVerification` | Full status summary (versions, server, models) + optional `--verbose` throughput test | Pure read/report |
| `installOllama` | **Wrapper** — runs all of the above in order; hard-fails on sanity/disk/brew/engine, degrades gracefully on the rest | — |

## The model menu (`installOllamaModels`)

Replaces the old fixed "step 7 + step 8" model pulls with a universal,
hardware-aware chooser:

1. **Scans Ollama** for what is already downloaded (`ollama list`).
2. Builds a numbered menu from a curated catalog (~29 entries, biggest →
   smallest), showing only models that:
   - **fit this host** — estimated need (`size × 1.3 + 2 GB` for KV-cache and
     runtime) must be within the GPU allocation; and
   - are **not yet downloaded**.

   The GPU allocation is read from the **currently set**
   `iogpu.wired_limit_mb` (falling back to the macOS ~75 % default) — raising
   the limit via the launcher's GPU tuning widens the menu, and the step
   prints the exact `sysctl` command that unlocks the next tier.

   **Quantization variants** are separate catalog entries for the main coder
   models: default `q4_K_M` plus `q8_0` (+~85 % size, effectively lossless)
   where the registry offers them. Which quants appear is pure fit math
   against the current GPU limit and free disk.

   **Ollama-registry tags only** — `hf.co/*` GGUF entries (which would have
   added Q5_K_M/Q6_K from HuggingFace) were removed after direct HF pulls
   reproducibly failed on Ollama 0.32 with `context deadline exceeded` at the
   final commit, despite complete blob downloads and working resume. Registry
   pulls work reliably; the retry logic (3 attempts on transient errors) and
   resume-aware cleanup remain in place for them.
3. **Verifies every candidate tag against the live registry** before offering
   it (parallel manifest probes to `registry.ollama.ai`, cached 24 h — first
   run ~2 s, reruns instant; unreachable network = benefit of the doubt).
   Non-existent tags are hidden with a note, so the menu can never offer a
   pull that would 404. (The registry has no single list-everything endpoint,
   so one tiny probe per candidate is the practical equivalent of the "one
   remote query".)
4. Menu is capped at **25 options**, ordered **biggest to smallest**, each line
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

Companions: [uninstall.sh.md](uninstall.sh.md) (reversal),
[aiModelLauncher.sh.md](aiModelLauncher.sh.md) (day-to-day launching),
[aiModelTest.sh.md](aiModelTest.sh.md) (benchmarking after pulls).
