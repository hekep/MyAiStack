# install.sh — Local AI coding stack installer (multi-engine, function-based)

## What it does

Interactive, **re-runnable** installer that builds a local-AI coding
environment on any Apple Silicon Mac. It offers **three inference engines** —
llama.cpp, MLX-LM and Ollama — then, for each engine actually installed, a
RAM-aware menu of code-generation models drawn from that engine's own catalog.
One question at a time; nothing installs silently.

## How it works — one function per step

Run the file for the full pipeline, or `source install.sh` and call any
function alone. Every function checks its own prerequisites, detects work
already done, and proposes an update only when one genuinely exists — so both
the script and each individual function can be run any number of times.

Steps carrying an engine name are engine-specific; the rest apply to the whole
stack. There are two optional layers: the **engines** (which serve tokens) and
the **coding agents** (what you actually type into).

| Function | What | Default / re-run behavior |
|---|---|---|
| `installAiStackSanity` | Platform check + **host RAM detection**; sets `TOTAL_GB`/`GPU_GB` | Aborts under 16 GB RAM or non-Apple-Silicon |
| `installAiStackDiskGate` | **HARD BLOCK** below 25 GB free. Shows shortfall, measured disk hogs, and offers to delete local Time Machine snapshots (which pin freed space). Loops *Enter = re-check / q = quit* | No bypass |
| `installAiStackHomebrew` | Homebrew | Skips if present |
| **`installAiStackLlamacppEngine`** | **llama.cpp** — `brew install llama.cpp` | **Default YES.** The only engine that reaches `Q5_K_M`/`Q6_K`. Present → checks `brew outdated`, offers upgrade only if one exists |
| **`installAiStackMlxmlEngine`** | **MLX-LM** — `uv tool install mlx-lm` | **Default no.** Apple-native, fastest on this chip, publishes 6-bit builds. Pulls in `uv` automatically when accepted. Present → automatic PyPI check, asks only if a newer version exists |
| **`installAiStackOllamaEngine`** | **Ollama** — brew formula | **Default no.** Managed daemon + Anthropic-compatible API (what Claude CLI talks to), narrowest quant ladder. A standalone `Ollama.app` gets the migrate-to-brew offer; brew-managed gets an upgrade offer only if one exists |
| `installAiStackUv` | uv | Asked normally; `installAiStackUv required` installs without asking (used by MLX-LM) |
| **`installAiStackPiCodingAgent`** | **Pi** — `npm i -g @earendil-works/pi-coding-agent` (+ `pi install npm:pi-local-models`) | **Default YES.** Works with every engine — it drives any OpenAI-compatible endpoint |
| **`installAiStackOpenCodeCodingAgent`** | **OpenCode** — brew (npm fallback) | **Default no.** Also engine-agnostic |
| **`installAiStackClaudeCodingAgent`** | **Claude Code** — npm / native installer | **Default no.** Anthropic API only, so of the engines here it works with **Ollama alone** |
| **`installAiStackLlamacppModels`** | GGUF files → `~/Models/llama.cpp` | Skipped unless llama.cpp is installed |
| **`installAiStackMlxmlModels`** | HF repos → HuggingFace cache | Skipped unless MLX-LM is installed |
| **`installAiStackOllamaModels`** | registry tags → `~/.ollama` | Skipped unless Ollama is installed. Prunes failed-download leftovers first |
| `installAiStackVerification` | Status summary: every engine, the frontend, and the models installed per engine | Pure read/report |
| `installAiStack` | **Wrapper** — see order below | — |

## Order, and the engine gate

```
sanity → disk gate → Homebrew
      → llama.cpp engine → MLX-LM engine → Ollama engine      (at least one!)
      → Pi → OpenCode → Claude Code                     (coding agents)
      → llama.cpp models → MLX-LM models → Ollama models
      → verification
```

**Serving is not an install concern.** Starting an engine, choosing a context
size and binding a network interface all live in
[launchInference.sh](launchInference.sh.md); the installer only ensures the
Ollama daemon is briefly up so that model pulls work.

**If no engine is installed, the wizard cancels** — everything below the engine
layer is meaningless without one, so the wrapper reports which engines are
available or stops with `No inference engine installed`. The model steps then
run in the same order as the engines, each skipping itself if its engine is
absent.

## The model menu — one implementation, three engines

`aiStackModelMenu <EngineFolder> <list-installed-fn> <pull-fn>` does the work
for every engine; each engine supplies only two small adapters (what is
installed, how to download). The menu:

1. Loads the catalog as **data**: `ModelLists/<Engine>/<RAM>_GB_Ram.json` for
   the largest tier ≤ host RAM. Curated top-20 per tier, biggest first, with
   sizes read from upstream manifests rather than estimated. Schema and rules:
   [ModelLists/README.md](../ModelLists/README.md).
2. Filters to models that **fit the current GPU limit** (`size × 1.3 + 2`,
   read from the live `iogpu.wired_limit_mb`), **fit free disk**, and are **not
   already installed**.
3. **Verifies every candidate upstream** before offering it — parallel
   existence probes, cached 24 h. A tag containing `/` is checked on
   HuggingFace, otherwise on the Ollama registry. Unavailable tags are hidden,
   so the menu can never offer a download that 404s.
4. Renders biggest-first (max 25), with **N** to finish, and **loops** until N.
   Disk is re-checked immediately before every download.

Per-engine download behavior:

- **llama.cpp** — resolves the real GGUF filename from the repo tree (uploaders
  name files differently), then `curl -L -C -`: **resumable**, which is exactly
  what the Ollama HF path could not do.
- **MLX-LM** — `huggingface_hub.snapshot_download` via
  `uv run --with huggingface-hub`; resumes from fetched shards.
- **Ollama** — `ollama pull` with 3 retries on transient errors, real error
  reporting, and resume-aware cleanup of orphaned blobs.

## Why it is necessary

- **One engine is not enough.** Ollama's registry carries only q4_K_M and q8_0
  for the models that matter here, and its direct HuggingFace pulls fail on
  0.32 (`context deadline exceeded`, reproduced repeatedly). On a 48 GB Mac the
  8-bit 35B does not fit and the 4-bit is a visible quality step down — so the
  useful middle (`Q6_K`, `6bit`) is reachable *only* through llama.cpp or MLX.
  Hence three engines, with llama.cpp recommended by default.
- **Hardware-aware menus prevent the classic local-LLM failure**: pulling a
  model that loads, swaps, and generates at 1 token/s.
- **Disk reality**: a single model is 20–30 GB; the hard gate and the
  per-download re-check keep a half-finished pull from filling the disk.
- **Agent and engine are separate choices.** Pi and OpenCode speak the
  OpenAI-compatible API every engine here serves; Claude Code speaks the
  Anthropic API, which only Ollama provides. The installer offers all three and
  launchInference.sh refuses to pair incompatible ones.
- **Brew must not ask twice**: our questions are the ones that matter, so the
  brew calls pass `-y` and never re-prompt for the same decision.

## Usage

```bash
./install.sh                         # full pipeline
```

```bash
source install.sh                    # à la carte, e.g.:
installAiStackLlamacppModels         # just the llama.cpp model menu
```

Companions: [uninstall.sh.md](uninstall.sh.md) (reversal),
[launchInference.sh.md](launchInference.sh.md) (day-to-day launching),
[aiModelTest.sh.md](aiModelTest.sh.md) (benchmarking after pulls).
