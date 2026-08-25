# launchInference.sh — engine, model, context, network, then serve (Debian)

## What it does

Everything about **running** a local model, which is deliberately not the
installer's job: pick the engine, pick a model installed for that engine,
choose the context size, choose which network interface to bind, free memory,
check the model actually fits, start the server, and hand the endpoint to a
coding agent.

Two engines here rather than three — MLX-LM is Apple Silicon only, and asking
for it by name gets that answer rather than "unknown engine".

## How it works — one function per decision

| Function | What | Notes |
|---|---|---|
| `aistackLaunchInferenceEngineSelector` | Lists engines that are installed **and have at least one model downloaded**, with their model counts | An engine with nothing downloaded cannot be launched, so it is never offered — just named once ("installed but no models downloaded"). Asked only when more than one qualifies. Previous choice is the default |
| `aistackLaunchInferenceModelSelector <engine>` | Numbered menu of the models installed **for that engine**, with on-disk sizes | **Not asked when the engine has only one model** — it is announced and used. Ollama reads `ollama list` (falling back to the manifests); llama.cpp scans `~/Models/llama.cpp` |
| `aistackLaunchInferenceContextSelector <engine> <model>` | **Numeric menu: 32K / 64K / 128K (default) / 256K / 512K / 1024K** | Larger sizes appear **only when they fit**: weights + estimated KV cache + 2 GB must stay inside the memory budget. For Ollama it also queries `/api/show` for the model's own ceiling. **Not asked when only one size fits.** Prints the budget line, so the number on screen is explained |
| `aistackLaunchInferenceNetworkSelector <engine>` | localhost (default) or LAN — for both engines | Refuses non-private addresses, warns that no engine authenticates, notes the DHCP caveat, and **names the `ufw` rule** when a firewall is active and would silently drop LAN connections |
| `aistackLaunchInferenceFreeResources` | Your own processes over 100 MB, **grouped by executable**, biggest first, `Close? [y/N]` | Enter means NO. Reinvented rather than translated — see below |
| `aistackLaunchInferenceKillPrevious` | Offers to stop whatever is already serving | Unloads Ollama models but keeps the cheap daemon; can stop the daemon (including the **systemd unit**, with sudo) when switching engines |
| `aistackLaunchInferencePrerequisites <engine> <model> <ctx>` | Hard gate: weights + KV + runtime vs. the memory budget | Fails with the exact `RAM_RESERVE_GB` line that widens it. A model larger than VRAM **warns** rather than fails — see below |
| `aistackLaunchInferenceStart <engine> <model> <ctx> <bind>` | Starts the engine's server and reports endpoint, memory and CPU | Offers to restart a server that is already running. Sets `LAUNCH_ENDPOINT` |
| `aistackLaunchInferenceAgentSelector <engine>` | Coding agent, filtered by engine compatibility | Names incompatible ones with the reason; self-answering when one option is valid |
| `aistackLaunchInferenceStartAgent <agent> <engine> <model>` | Dispatches to the per-agent launcher | `none` leaves the server up and prints the endpoint |
| `aistackLaunchInferenceAgentClaude` / `AgentPi` / `AgentOpenCode` | The three agent launchers | Identical to macOS; the config files and their backups are the same |
| `aistackLaunchInference` | Wrapper: runs all of the above in order | — |

Choices persist in `~/.aistackLaunchInference.conf`, so the next run defaults to
what you picked last — the same file and keys as on macOS.

**Self-answering questions are never asked.** Every selector — engine, model,
context, coding agent — announces and proceeds when exactly one option is
valid, and only presents a menu when there is a real choice to make.

## What each engine is started with

| Engine | Command | API | Port |
|---|---|---|---|
| Ollama | `ollama serve` with `OLLAMA_CONTEXT_LENGTH`, `OLLAMA_HOST`, `OLLAMA_MODELS`, flash attention + q8_0 KV cache, then loads the model with a 60 min keep-alive | **Anthropic** + OpenAI | 11434 |
| llama.cpp | `llama-server -m <gguf> -c <ctx> --alias <tag> --host <bind> --port <port>` **plus a backend-dependent argument** | OpenAI-compatible | 8080 |

### The extra llama-server arguments

macOS never needs any: Metal offloads everything by default. On Linux the right
flags depend on the hardware, so `llamacppServerArgs()` reads the backend from
the libraries beside the binary and the device class from `vulkaninfo`:

| Hardware | Arguments | Why |
|---|---|---|
| CUDA / ROCm | `-ngl 999` | a discrete card has its own memory; offload everything (llama.cpp clamps to the layers that exist) |
| Vulkan / SYCL, **discrete** | `-ngl 999` | same reasoning |
| Vulkan / SYCL, **integrated** | *(none)* | measured loss — see below |
| CPU / unknown | *(none)* | measured loss — see below |

**Both "obvious" flags turned out to be measured losses**, so on a CPU or
integrated-GPU host this function deliberately emits *nothing*. Benchmarked on
the reference box (Ryzen 5 7430U, 6 physical / 12 logical cores, Radeon Vega
RENOIR; Qwen2.5-Coder-7B Q4_K_M; `llama-bench -p 64 -n 32`):

```
              prompt (pp64)   generation (tg32)
-ngl 0          51.66 t/s        8.19 t/s
-ngl 999        59.24 t/s        7.61 t/s     <- offload LOSES 7% on generation

-t 4            50.84 t/s        7.99 t/s
-t 6 (default)  46.92 t/s        8.16 t/s     <- llama.cpp's own choice
-t 12 (nproc)   45.66 t/s        6.72 t/s     <- 18% SLOWER than no flag
```

Two lessons, both counter-intuitive:

- **`-ngl` on an integrated GPU costs generation speed.** An iGPU shares the
  CPU's memory bandwidth, and token generation is bandwidth-bound rather than
  compute-bound. Prompt processing *does* gain 15 %, so set `LLAMACPP_NGL=999`
  when your workload is prompt-heavy (long contexts re-read every turn);
  interactive coding is generation-dominated, so the default favours it.
- **In `llama-server` the flag turned out to be inert here entirely.** Measured
  on a real 1624-token turn: no flag 58.27 t/s prompt / 7.30 t/s generation;
  `-ngl 999` 58.54 / 7.30; `--device Vulkan0 -ngl 999` 59.22 / 7.29. The server
  never loads the Vulkan backend (its log never mentions it, llama-bench's
  does), although `llama-server --list-devices` reports `Vulkan0`. Serving is
  the only path this toolkit uses, so the default passes nothing rather than a
  flag that promises offload and delivers none.
- **`-t $(nproc)` is worse than passing nothing.** `nproc` counts logical CPUs,
  and two hyperthreads on one core share a single memory port. llama.cpp
  already defaults to the physical core count, which measured fastest — so the
  correct flag is no flag.

Override either with `LLAMACPP_NGL` / `LLAMACPP_THREADS`; they win in both
directions and compose. The chosen backend and arguments are printed at launch,
so a surprisingly slow run is one line away from being explained.

### The Ollama system service

The launcher refuses to serve at the wrong context rather than doing it
quietly. If the system-wide `ollama.service` holds port 11434, it explains that
the unit ignores the context size chosen here and offers to stop it. Declining
aborts the launch with the permanent fix named
(`sudo systemctl disable --now ollama`). Our daemon is always started with
`OLLAMA_MODELS` set explicitly, so the two layouts cannot disagree about where
models live.

## Agent / engine compatibility

| Agent | Ollama | llama.cpp | Why |
|---|---|---|---|
| **Pi** | ✓ | ✓ | drives any OpenAI-compatible endpoint; config written to `~/.pi/agent/local-models.json`, then pick with `/models` inside Pi |
| **OpenCode** | ✓ | ✓ | same; provider block written into `~/.config/opencode/opencode.json` with `baseURL` inside `options` |
| **Claude Code** | ✓ | ✗ | needs the **Anthropic** Messages API, which only Ollama serves |

The selector enforces this, so an impossible pairing is never offered. Existing
agent configs are backed up (`.bak`) before being written.

Each launcher refuses early rather than half-working:

1. **agent not installed** → names the install function, and lists the agents
   that *are* ready for that engine.
2. **unknown or uninstalled engine** → lists the valid names, and which of them
   have models here. **`MLX-LM` gets its own answer**: Apple Silicon only, use
   Llama.cpp for the same quality band.
3. **model not installed for that engine** → lists the models that engine
   actually has, so a typo is obvious, and names the download command.
4. **agent incompatible with the engine** → says which API is missing.
5. **nothing serving the engine** → gives the `aistackLaunchInferenceStart` line
   for a model you actually have. `LAUNCH_ENDPOINT` is only set by
   `aistackLaunchInferenceStart`, so a launcher called on its own derives the
   endpoint and verifies it instead of writing an empty URL into the agent's
   config.

## Fit: RAM decides, VRAM decides speed

This is the deepest divergence from the macOS implementation, and it is a
hardware fact rather than a design choice.

macOS has unified memory and one raisable GPU allocation, so "does it fit" has
one answer. On Linux:

- **Integrated GPU or CPU-only** — one pool, no separate GPU budget to raise.
  The limit is RAM.
- **Discrete GPU** — VRAM is a real second pool, but llama.cpp offloads the
  layers that fit and runs the rest on the CPU, and the weights pass through
  host memory either way.

So `aistackLaunchInferencePrerequisites` **fails** only when the model exceeds

```
budget = MemTotal − RAM_RESERVE_GB     (reserve defaults to 5 GB)
```

and **warns** when it exceeds VRAM:

> Larger than the 12 GB of VRAM — llama.cpp will keep the overflow layers on
> CPU. Expect a fraction of full-GPU speed. A smaller quant would fit entirely.

The macOS advice *"raise it: `sudo sysctl iogpu.wired_limit_mb=…`"* becomes
*"lower the reserve: `RAM_RESERVE_GB=3 aistackLaunchInference`"* — the same
lever at the other end.

`MemTotal` is deliberately used for the budget rather than the rounded nominal
RAM size: a budget must be made of memory that actually exists. The rounded
figure exists only to pick the right catalog tier. Full reasoning in
[PlatformNotes](../Docs/PlatformNotes.md#the-memory-model--the-deepest-difference).

## Freeing memory without a window server

`aistackLaunchInferenceFreeResources` is the one function whose *mechanism* had
to be reinvented. macOS asks the window server for processes with a UI; Linux
has no equivalent present on every desktop, and none at all on a headless box.

The Debian version works from the process table: your own processes, grouped by
executable basename, RSS summed per group — so a browser is one question, not
forty. It skips, and says how many it skipped:

- **this shell's process ancestry**, matched by both pid and name, so it can
  never offer to close the terminal it is running in;
- **session infrastructure** a desktop cannot survive losing — `systemd`,
  `gnome-shell`, `Xorg`/`Xwayland`, `pipewire`, `wireplumber`, `dbus-*`,
  `gnome-keyring-daemon`, `polkitd`, `at-spi*`, `sshd`, shells, `tmux`;
- **the stack's own** engines and monitors, which exist to watch this very run;
- anything **under `FREE_MIN_MB`** (default 100) — closing a 50 MB process
  frees nothing a model would notice.

Accepted groups get `SIGTERM`, three seconds, then `SIGKILL` for survivors —
the honest equivalent of macOS's "quit, then force". The function states that
summed RSS counts shared pages more than once, so the figure is a ranking
rather than a total.

## Requested vs served context

Engines clamp silently: a model trained for 32K accepts `-c 524288`, allocates
KV cache for the request, and serves 32K. The launch summary therefore reports
what is **actually** served and says so when it is less than you asked for,
including that relaunching lower frees the wasted memory. Only Ollama exposes
its ceiling in advance (`/api/show`), which the context menu already uses.

## The context estimate

KV cache is estimated as `ctxK × model_GB / 200` — the same formula as the
macOS side, so the two platforms offer the same sizes for the same model. It is
an estimate, stated as such in the menu; the point is to keep you from choosing
a context that quietly pushes the machine into swap.

## Calling a step directly

Every step is individually callable (see
[installAliases.sh.md](../Docs/installAliases.sh.md)). A step invoked without
its arguments prints usage rather than a bash error, and the hints are resolved
live — the engine line names what this machine actually has:

```
$ aistackLaunchInferencePrerequisites
 ✗  usage: aistackLaunchInferencePrerequisites <engine> <model> <context-tokens>
         engine  : none installed — run ./install.sh
         model   : one of that engine's models — list: engineListInstalled <engine>
         context : tokens, e.g. 32768 / 65536 / 131072
         example : none possible yet — no engine is installed.
         install one:  aistackInstallLlamacppEngine   (llama.cpp, recommended)
                       aistackInstallOllamaEngine     (Ollama — required by Claude Code)
```

Return code is 2 for a usage error, distinct from a step that ran and failed.

## Why it is necessary

- **Installing and serving are different jobs.** install.sh does not start
  servers or ask about exposure; it only puts software and weights on disk.
  Everything runtime-shaped lives here, so re-running the installer never
  disturbs a running server.
- **Context is the setting people get wrong.** Ollama's small default silently
  truncates a coding agent's system prompt, which produces confused, mixed
  answers that look like model weakness. Making it an explicit, memory-checked
  choice removes that whole class of failure.
- **The memory maths belongs before the launch**, not after a model has already
  started swapping — and on Linux, not after the OOM killer has picked your
  desktop session as the victim.

## Usage

```bash
./launchInference.sh                       # full flow
```

```bash
source Debian/launchInference.sh           # à la carte, e.g.:
aistackLaunchInferenceStart Llama.cpp bartowski/Qwen_Qwen3.6-35B-A3B-GGUF:Q6_K 32768 127.0.0.1
aistackLaunchInferenceKillPrevious         # free memory without a full launch
```
