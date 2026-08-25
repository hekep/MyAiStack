# install.sh — Local AI coding stack installer (Debian/Ubuntu)

## What it does

Interactive, **re-runnable** installer that builds a local-AI coding
environment on a Debian or Ubuntu machine. It offers **two inference engines** —
llama.cpp and Ollama — then, for each engine actually installed, a RAM-aware
menu of code-generation models drawn from that engine's own catalog. One
question at a time; nothing installs silently.

There is no MLX-LM step: MLX is Apple's array framework and runs on Apple
Silicon only. See [PlatformNotes](../Docs/PlatformNotes.md#layer-membership).

**Before you start:** the only prerequisite a stock Debian/Ubuntu lacks is
**Node + npm**, which all three coding agents are delivered through —
`aistackInstallNode` installs it, or `sudo apt-get install -y nodejs npm` does.
Everything else is either already present or installed by
`aistackInstallBaseTools`. Which steps need root, and which of them you can
skip entirely on a machine where you cannot sudo, is tabulated in
[README.md](README.md#prerequisites-and-what-needs-root) — the whole inference
path (engine, models, serving, testing) needs no privileges at all.

## How it works — one function per step

Run the file for the full pipeline, or `source install.sh` and call any
function alone. Every function checks its own prerequisites, detects work
already done, and proposes an update only when one genuinely exists — so both
the script and each individual function can be run any number of times.

| Function | What | Default / re-run behavior |
|---|---|---|
| `aistackInstallSanity` | Platform check + **RAM and accelerator detection**; sets `TOTAL_GB`/`GPU_GB` | Aborts under 16 GB RAM or on a non-Debian-family distro. Names the accelerator (`nvidia` / `rocm` / `vulkan` / `cpu`) and warns plainly when inference will be CPU-only |
| `aistackInstallDiskGate` | **HARD BLOCK** below 25 GB free. Shows the shortfall and measured disk hogs, then offers the three reclaims that actually move a Debian box: apt cache + autoremove, journal vacuum, emptying the trash. Loops *Enter = re-check / q = quit* | No bypass |
| `aistackInstallBaseTools` | `curl ca-certificates tar gzip python3 jq lsof procps iproute2` | The counterpart of macOS's Homebrew step: apt is always present, so what needs establishing is the set of tools the rest of the scripts shell out to. Declining ends the wizard |
| **`aistackInstallLlamacppEngine`** | **llama.cpp** — upstream release tarball into `~/.local/opt/llama.cpp`, or a source build | **Default YES.** The only engine that reaches `Q5_K_M`/`Q6_K`. See "How llama.cpp is installed" below |
| **`aistackInstallOllamaEngine`** | **Ollama** — the official Linux installer | **Default no.** Managed daemon + Anthropic-compatible API (what Claude CLI talks to), narrowest quant ladder. Also resolves the system-service clash — see below |
| `aistackInstallUv` | uv — Astral's installer (no Debian package) | Asked normally; `aistackInstallUv required` installs without asking (used by LiteLLM) |
| `aistackInstallNode` | Node + npm via apt, **and moves npm's global prefix to `~/.local`** | Asked normally; `aistackInstallNode required` installs without asking (used by every agent). Warns when apt's Node is older than 20 and gives the NodeSource line |
| **`aistackInstallPiCodingAgent`** | **Pi** — `npm i -g @earendil-works/pi-coding-agent` (+ `pi install npm:pi-local-models`) | **Default YES.** Works with both engines — it drives any OpenAI-compatible endpoint |
| **`aistackInstallOpenCodeCodingAgent`** | **OpenCode** — npm | **Default no.** Also engine-agnostic. npm is the only channel here: no Debian package, no brew |
| **`aistackInstallClaudeCodingAgent`** | **Claude Code** — npm, falling back to the native installer | **Default no.** Anthropic API only, so of the engines here it works with **Ollama alone** |
| **`aistackInstallLlamacppModels`** | GGUF files → `~/Models/llama.cpp` | Skipped unless llama.cpp is installed |
| **`aistackInstallOllamaModels`** | registry tags → the resolved Ollama model store | Skipped unless Ollama is installed. Prunes failed-download leftovers first |
| **`aistackInstallNvtopMonitoring`** | **nvtop** — apt | **Default no.** GPU/APU utilisation and memory for AMD, Intel and NVIDIA. **Skipped entirely with a notice when no GPU backend is detected** — it would have nothing to show |
| **`aistackInstallBtopMonitoring`** | **btop** — apt | **Default no.** CPU, memory and process view. On a CPU-inference box this is the meter that matters, because the model's cost shows up as cores and resident memory rather than GPU wattage |
| **`aistackInstallLitellmMonitoring`** | **LiteLLM proxy** — uv | **Default no.** OpenAI-compatible proxy in front of the engines: logs every request and exports OpenTelemetry traces. Identical to the macOS step |
| `aistackInstallVerification` | Status summary: host, budget, every engine, agents, monitoring, tooling, models per engine | Pure read/report |
| `aistackInstall` | **Wrapper** — see order below | — |

## Order, and the engine gate

```
sanity → disk gate → base tools
      → llama.cpp engine → Ollama engine                 (at least one!)
      → Pi → OpenCode → Claude Code                      (coding agents)
      → llama.cpp models → Ollama models
      → nvtop → btop → LiteLLM                     (monitoring, all optional)
      → verification
```

**Serving is not an install concern.** Starting an engine, choosing a context
size and binding a network interface all live in
[launchInference.sh](launchInference.sh.md); the installer only ensures the
Ollama daemon is briefly up so that model pulls work.

**If no engine is installed, the wizard cancels** — everything below the engine
layer is meaningless without one. The model steps then run in the same order as
the engines, each skipping itself if its engine is absent.

## How llama.cpp is installed

Debian has no llama.cpp package, so the engine comes from the project's own
releases. Two routes are offered, and the question is asked because both are
genuinely on the table:

1. **Upstream release binary** *(default)* — seconds, no compiler.
2. **Build from source** — minutes; needed on older Debian, or for CUDA.

Three details make this reliable rather than hopeful:

- **The right release is found by walking the list.** GitHub's
  `releases/latest` for this repo points at a different tag series carrying one
  file. The build tarballs live on `bNNNNN` tags, so `llamacppResolveAsset`
  scans the ten most recent releases for the newest that actually carries the
  asset wanted — a single release can omit a flavour.
- **The backend is chosen from the hardware.** ROCm → `ubuntu-rocm-*-x64`;
  Vulkan-capable GPU → `ubuntu-vulkan-x64`; otherwise plain `ubuntu-x64`
  (`arm64` variants on aarch64). **NVIDIA is given the Vulkan build**, because
  upstream publishes no Linux CUDA tarball — and is told that the source build
  is the route to CUDA proper.
- **The binary is proved to run before it replaces anything.**
  `llamacppInstallTarball` extracts to `<prefix>.new`, executes
  `llama-cli --version`, and only then swaps it in. Upstream builds against a
  newer glibc than Debian stable ships, so a tarball can unpack perfectly and
  still not execute; on that failure it says so and offers the source build.

Binaries land in `~/.local/opt/llama.cpp` and are symlinked into
`~/.local/bin`, so nothing needs root. The script warns when that directory is
not on your `PATH`. `llamacppBackend()` afterwards reports which backend is
actually present by inspecting the libraries beside the resolved binary, not a
state file — so it stays correct however llama.cpp was installed.

## The Ollama system-service clash

The official Linux installer registers a **system service** running as the
`ollama` user, which stores models in `/usr/share/ollama/.ollama/models` — not
`~/.ollama`. This stack runs the daemon **as you**, because context length and
bind address are chosen per launch and a system unit cannot be given per-launch
settings. Both want port 11434.

`aistackInstallOllamaEngine` therefore asks once, immediately after installing,
whether to `systemctl disable --now ollama` — defaulting to yes, and saying how
many manifests already exist in the system location. This occupies exactly the
slot where the macOS installer offers to migrate a standalone `Ollama.app` to
the brew formula: same question, same place, different clash.

Declining is respected: the model steps then read the system location and the
launcher will not start a competing daemon. `ollamaModelsDir()` resolves
`$OLLAMA_MODELS` → a non-empty `~/.ollama` → the system location, and every
path in the port goes through it, so neither store is ever invisible.

## The memory budget

macOS has one number to report — the GPU's share of unified memory, raisable
with `sysctl`. Linux has no such lever, so the installer computes:

```
budget = MemTotal − RAM_RESERVE_GB          (reserve defaults to 5 GB)
```

and `budgetSummary()` prints one line naming which hardware case the machine is
in. On a discrete-GPU box VRAM is reported too, but as a **speed** annotation:
llama.cpp offloads the layers that fit and runs the rest on the CPU, so VRAM
decides how fast a model runs, not whether it fits. The model menu says so, and
names the lever that widens it: `RAM_RESERVE_GB=3`.

One trap worth knowing: `/proc/meminfo`'s `MemTotal` excludes firmware-reserved
memory, so a 48 GB machine reports 46. The catalogs are keyed by RAM tier, so
using that number directly would load the 32 GB list and hide half the models
the machine can run. `hostRamGb()` rounds up to the nearest 4 GB for tier
selection; `memTotalGb()` stays raw for the budget, which must be made of
memory that exists.

## The model menu — one implementation, both engines

`aiStackModelMenu <EngineFolder> <list-installed-fn> <pull-fn>` does the work
for every engine; each engine supplies only two small adapters (what is
installed, how to download). The menu:

1. Loads the catalog as **data**: `ModelLists/<Engine>/<RAM>_GB_Ram.json` for
   the largest tier ≤ host RAM. Curated top-20 per tier, biggest first, with
   sizes read from upstream manifests rather than estimated. Schema and rules:
   [ModelLists/README.md](../ModelLists/README.md). **These are the same files
   the macOS side reads** — a GGUF is a GGUF.
2. Filters to models that **fit the memory budget** (`size × 1.3 + 2`), **fit
   free disk**, and are **not already installed**.
3. **Verifies every candidate upstream** before offering it — parallel
   existence probes, cached 24 h. A tag containing `/` is checked on
   HuggingFace, otherwise on the Ollama registry. Unavailable tags are hidden,
   so the menu can never offer a download that 404s.
4. Renders biggest-first (max 25), with **N** to finish, and **loops** until N.
   Disk is re-checked immediately before every download.

Per-engine download behavior:

- **llama.cpp** — resolves the real GGUF filename **and its size** from the repo
  tree (uploaders name files differently), then `curl -L -C -`: **resumable**.
  The bytes arrive in `<name>.gguf.part` and are renamed to `<name>.gguf` only
  once the size matches what HuggingFace reported, so an interrupted download
  can never masquerade as an installed model. Identical to the macOS side —
  see [Docs/install.sh.md](../Docs/install.sh.md#completed-downloads-are-named-differently)
  for the full reasoning.
- **Ollama** — `ollama pull` with 3 retries on transient errors, real error
  reporting, and resume-aware cleanup of orphaned blobs. The orphan cleanup
  checks the blob directory is writable first, since the system-service layout
  is owned by another user.

## Why it is necessary

- **One engine is not enough.** Ollama's registry carries only q4_K_M and q8_0
  for the models that matter here, so the useful middle (`Q6_K`, `Q5_K_M`) is
  reachable only through llama.cpp. Hence two engines, with llama.cpp
  recommended by default.
- **Hardware-aware menus prevent the classic local-LLM failure**: pulling a
  model that loads, swaps, and generates at 1 token/s. On a CPU-only Linux box
  that failure mode is closer than on a Mac, so the sanity step says outright
  what to expect.
- **Disk reality**: a single model is 20–30 GB; the hard gate and the
  per-download re-check keep a half-finished pull from filling the disk.
- **Agent and engine are separate choices.** Pi and OpenCode speak the
  OpenAI-compatible API both engines serve; Claude Code speaks the Anthropic
  API, which only Ollama provides. The installer offers all three and
  launchInference.sh refuses to pair incompatible ones.
- **apt must not ask twice**: our questions are the ones that matter, so every
  apt call goes through one helper that passes `-y` and refreshes the package
  lists at most once per run.

## Usage

```bash
./install.sh                         # full pipeline
```

```bash
source Debian/install.sh             # à la carte, e.g.:
aistackInstallOllamaModels           # just the Ollama model menu
RAM_RESERVE_GB=3 aistackInstallLlamacppModels   # widen the menu
```

Companions: [uninstall.sh.md](uninstall.sh.md) (reversal),
[launchInference.sh.md](launchInference.sh.md) (day-to-day launching),
[aiModelTest.sh.md](aiModelTest.sh.md) (benchmarking after pulls).
