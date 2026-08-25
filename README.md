# MyAiStack

A local AI coding stack for Apple Silicon: pick an inference **engine**, pull
**models** that actually fit your machine, launch one with a sane context size,
and hand it to a **coding agent** — each step interactive, re-runnable, and
honest about what it measures.

```bash
git clone https://github.com/hekep/MyAiStack.git
cd MyAiStack
./install.sh
```

Everything is plain `bash` plus `curl` and `python3` (both already on macOS).
Nothing runs without asking, and nothing is installed silently.

## What it sets up

| Layer | Options | Notes |
|---|---|---|
| **Engines** | llama.cpp *(default)*, MLX-LM, Ollama | At least one required. llama.cpp and MLX reach the `Q5_K_M`/`Q6_K`/6-bit quants Ollama's registry does not carry |
| **Coding agents** | Pi *(default)*, OpenCode, Claude Code | Pi and OpenCode drive any engine; Claude Code needs Ollama, because it speaks the Anthropic API |
| **Models** | curated top-20 per RAM tier, per engine | [ModelLists/](ModelLists/) — data, not code, with sizes read from upstream manifests |
| **Monitoring** *(all optional)* | macmon, Anubis OSS, LiteLLM proxy | macOS-specific: live CPU/GPU/ANE usage, GUI benchmarking of local models, request logging with OpenTelemetry |

## The scripts

| Command | What it does |
|---|---|
| `./install.sh` | Disk gate → engines → coding agents → a RAM-aware model menu per engine → status |
| `./launchInference.sh` | Engine → model → **context size** → network exposure → free memory → start → coding agent |
| `./aiModelTest.sh` | Test one engine+model: reachability, tokens/sec, tool-calling, served context |
| `./testAllAiModels.sh` | Sweep every engine × model with one prompt, one comparison table |
| `./uninstall.sh` | Remove layers most-dependent-first; models gate everything below them |
| `./noRole.sh <Role>` | Purge a whole product and its leftovers (`Docker`, `Codex`) |
| `./installAliases.sh` | Make all 55 step functions available in every shell |

Full write-ups — what each does, how it works, and **why** — are in
[Docs/](Docs/README.md).

## Calling individual steps

The wizards are the front door, but every step is an independent function, and
most day-to-day work is a single one. After `./installAliases.sh` and a shell
restart:

```bash
aistackHelp                     # list everything available
aistackInstallOllamaModels      # just the download menu
aistackLaunchInferenceKillPrevious     # free the GPU without a full launch
aistackModelTest Ollama qwen3.6:35b-a3b
```

Each call runs in its own bash process, so the scripts' internal helpers never
land in your shell. `./installAliases.sh --remove` undoes it.

## Repo layout

```
install.sh, launchInference.sh, ...   thin wrappers: detect the OS, dispatch
common.sh                            OS detection + dispatch
MacOs/                               the implementations (complete)
Debian/                              awaiting a port
ModelLists/<Engine>/<RAM>_GB_Ram.json  model catalogs as data
Docs/                                one document per script
```

Always call the root wrappers, not `MacOs/...` directly — the same commands
then work unchanged once `Debian/` is populated. An unsupported OS (Fedora,
Windows) exits with a clear message rather than half-running.

## Requirements

- Apple Silicon macOS, **16 GB RAM minimum** (48 GB+ for 30B-class models)
- **25 GB free disk** minimum — the installer blocks below this and will not
  bargain; a single model is 20–30 GB
- Homebrew (offered if missing)

## Design rules

- **One question at a time**, and never a question with only one possible
  answer — those are announced and skipped.
- **Enter is safe**: destructive prompts default to No, expected ones to Yes.
- **Hard gates over warnings** — not enough disk or RAM stops the flow.
- **Measured, not estimated** — disk from `df` before/after, memory from
  `ps`/`vm_stat`, ports from `lsof`, tokens/sec from the engine's own counters.
- **Safe to re-run** — every step detects what is already done, so each script
  doubles as its own status check.
