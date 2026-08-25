# launchInference.sh — engine, model, context, network, then serve

## What it does

Everything about **running** a local model, which is deliberately not the
installer's job: pick the engine, pick a model installed for that engine,
choose the context size, choose which network interface to bind, free memory,
check the model actually fits, start the server, and — where the engine
supports it — hand the endpoint to the Claude CLI.

(Renamed from `aiModelLauncher.sh`, and generalised from Ollama-only to all
three engines.)

## How it works — one function per decision

| Function | What | Notes |
|---|---|---|
| `aistackLaunchInferenceEngineSelector` | Lists engines that are installed **and have at least one model downloaded**, with their model counts | An engine with nothing downloaded cannot be launched, so it is never offered — just named once ("installed but no models downloaded"). Asked only when more than one engine qualifies; with exactly one it says so and proceeds. Previous choice is the default |
| `aistackLaunchInferenceModelSelector <engine>` | Numbered menu of the models installed **for that engine**, with on-disk sizes | **Not asked when the engine has only one model** — it is announced and used. Ollama reads `ollama list`; llama.cpp scans `~/Models/llama.cpp`; MLX-LM scans the HuggingFace cache |
| `aistackLaunchInferenceContextSelector <engine> <model>` | **Numeric menu: 32K / 64K / 128K (default) / 256K / 512K / 1024K** | Larger sizes appear **only when they fit**: weights + estimated KV cache + 2 GB must stay inside the GPU budget. For Ollama it also queries `/api/show` for the model's own ceiling. **Not asked when only one size fits.** |
| `aistackLaunchInferenceNetworkSelector <engine>` | localhost (default) or LAN — **for every engine**, not just Ollama | Refuses non-private addresses, warns that no engine authenticates, notes the DHCP caveat |
| `aistackLaunchInferenceFreeResources` | Every open desktop app **over 100 MB**, biggest memory first, `Close? [y/N]` | Enter means NO. Skipped: the app hosting this session (found by walking the parent-process chain), Finder, the engines, and the monitoring tools — closing macmon or Anubis would defeat their purpose. Apps under the threshold are counted, not asked about; override with `FREE_MIN_MB` |
| `aistackLaunchInferencePrerequisites <engine> <model> <ctx>` | Hard gate: weights + KV + runtime vs. GPU budget | Fails with the exact `sysctl` command to raise the limit |
| `aistackLaunchInferenceStart <engine> <model> <ctx> <bind>` | Starts the engine's server and reports endpoint, memory and CPU | Offers to restart a server that is already running. Sets `LAUNCH_ENDPOINT` |
| `aistackLaunchInferenceClaudeCli <engine> <model>` | Claude CLI wired to the endpoint, with the session question (C/r/n) and a small local model on the background tier | **Ollama only** — see below |
| `aistackLaunchInference` | Wrapper: runs all of the above in order | — |

Choices persist in `~/.aistackLaunchInference.conf`, so the next run defaults to what
you picked last.

**Self-answering questions are never asked.** Every selector — engine, model,
context, coding agent — announces and proceeds when exactly one option is
valid, and only presents a menu when there is a real choice to make.

## What each engine is started with

| Engine | Command | API | Port |
|---|---|---|---|
| Ollama | `ollama serve` with `OLLAMA_CONTEXT_LENGTH`, `OLLAMA_HOST`, flash attention + q8_0 KV cache, then loads the model with a 60 min keep-alive | **Anthropic** + OpenAI | 11434 |
| llama.cpp | `llama-server -m <gguf> -c <ctx> --alias <tag> --host <bind> --port` | OpenAI-compatible | 8080 |
| MLX-LM | `mlx_lm.server --model <repo> --host <bind> --port` | OpenAI-compatible | 8081 |

## Agent / engine compatibility

| Agent | Ollama | llama.cpp | MLX-LM | Why |
|---|---|---|---|---|
| **Pi** | ✓ | ✓ | ✓ | drives any OpenAI-compatible endpoint; config written to `~/.pi/agent/local-models.json`, then pick with `/models` inside Pi |
| **OpenCode** | ✓ | ✓ | ✓ | same; provider block written into `~/.config/opencode/opencode.json` with `baseURL` inside `options` |
| **Claude Code** | ✓ | ✗ | ✗ | needs the **Anthropic** Messages API, which only Ollama serves |

The selector enforces this, so an impossible pairing is never offered: with
llama.cpp running and only Claude installed you get an explanation rather than
a session that would fail; with llama.cpp and only Pi installed there is no
question at all.

Existing agent configs are backed up (`.bak`) before being written.

Each launcher refuses early rather than half-working:

1. **agent not installed** → names the install function, and lists the agents
   that *are* ready for that engine, so there is a working alternative:
   ```
   ✗ OpenCode is not installed — nothing to launch.
   ! Install it:  aistackInstallOpenCodeCodingAgent
   ! Ready to use with Llama.cpp right now: Pi
   ```
2. **unknown or uninstalled engine** → lists the valid names, and which of
   them have models here.
3. **model not installed for that engine** → lists the models that engine
   actually has, so a typo is obvious, and names the download command:
   ```
   ✗ 'FubarModelNotAvailable' is not installed for Llama.cpp.
   ! Llama.cpp models you do have:
        bartowski/Qwen2.5-Coder-7B-Instruct-GGUF:Q8_0
        lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q8_0
   ! Download more with:  aistackInstallLlamacppModels
   ```
4. **agent incompatible with the engine** → says which API is missing.
5. **nothing serving the engine** → gives the `aistackLaunchInferenceStart` line for a
   model you actually have. `LAUNCH_ENDPOINT` is only set by
   `aistackLaunchInferenceStart`, so a launcher called on its own derives the endpoint
   and verifies it instead of writing an empty URL into the agent's config.

## Requested vs served context

Engines clamp silently: a model trained for 32K accepts `-c 524288`, allocates
KV cache for the request, and serves 32K. The launch summary therefore reports
what is **actually** served and says so when it is less than you asked for,
including that relaunching lower frees the wasted memory. Only Ollama exposes
its ceiling in advance (`/api/show`), which the context menu already uses.

## The context estimate

KV cache is estimated as `ctxK × model_GB / 200` — calibrated against a 30B-class
model at f16 (~12.8 GB at 128K) and scaled by model size. It is an estimate,
stated as such in the menu; the point is to keep you from choosing a context
that quietly pushes the machine into swap.

Measured example on this 48 GB Mac (43 GB GPU limit, qwen3.6 at 23 GB): 32K,
64K and 128K are offered; 256K+ are filtered out, and Ollama reports the model
would allow 256K if there were memory for it.


## Calling a step directly

Every step is individually callable (see [installAliases.sh.md](installAliases.sh.md)). A step invoked without its
arguments prints usage rather than a bash error, and the hints are resolved
live — the engine line names what this machine actually has:

```
$ aistackLaunchInferencePrerequisites
 ✗  usage: aistackLaunchInferencePrerequisites <engine> <model> <context-tokens>
         engine  : Llama.cpp Ollama
         model   : one of that engine's models — list: engineListInstalled <engine>
         context : tokens, e.g. 32768 / 65536 / 131072
         example : aistackLaunchInferencePrerequisites Ollama qwen3.6:35b-a3b 32768
```

Return code is 2 for a usage error, distinct from a step that ran and failed.

## Why it is necessary

- **Installing and serving are different jobs.** install.sh no longer starts
  servers or asks about exposure; it only puts software and weights on disk.
  Everything runtime-shaped lives here, so re-running the installer never
  disturbs a running server.
- **Context is the setting people get wrong.** Ollama's 4k default silently
  truncates Claude Code's system prompt, which is what produced the confused,
  mixed answers early in this project. Making it an explicit, memory-checked
  choice removes that whole class of failure.
- **The memory maths belongs before the launch**, not after a model has already
  started swapping.

## Usage

```bash
./launchInference.sh                       # full flow
```

```bash
source launchInference.sh                  # à la carte, e.g.:
aistackLaunchInferenceStart Ollama qwen3.6:35b-a3b 131072 127.0.0.1
```
