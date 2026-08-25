# MyAiStack

A local AI coding stack for **Apple Silicon macOS and Debian/Ubuntu**: pick an
inference **engine**, pull **models** that actually fit your machine, launch one
with a sane context size, and hand it to a **coding agent** — each step
interactive, re-runnable, and honest about what it measures.

```bash
git clone https://github.com/hekep/MyAiStack.git
cd MyAiStack
./install.sh
```

Everything is plain `bash` plus `curl` and `python3`. Nothing runs without
asking, and nothing is installed silently. The root scripts detect the OS and
dispatch to the matching implementation, so the commands are identical on both
platforms.

## What it sets up

| Layer | Options | Notes |
|---|---|---|
| **Engines** | llama.cpp *(default)*, Ollama, **+ MLX-LM on macOS** | At least one required. llama.cpp reaches the `Q5_K_M`/`Q6_K` quants Ollama's registry does not carry |
| **Coding agents** | Pi *(default)*, OpenCode, Claude Code | Pi and OpenCode drive any engine; Claude Code needs Ollama, because it speaks the Anthropic API |
| **Models** | curated top-20 per RAM tier, per engine | [ModelLists/](ModelLists/) — data, not code, with sizes read from upstream manifests. The same catalogs feed both platforms |
| **Monitoring** *(all optional)* | macOS: macmon, Anubis OSS, LiteLLM · Debian: nvtop, btop, LiteLLM | Live hardware usage, benchmarking, and request logging with OpenTelemetry |

MLX-LM is Apple's array framework and runs on Apple Silicon only; on Debian it
is absent rather than stubbed, and anything that could ask for it says so.

## The scripts

| Command | What it does |
|---|---|
| `./install.sh` | Disk gate → engines → coding agents → a RAM-aware model menu per engine → status |
| `./launchInference.sh` | Engine → model → **context size** → network exposure → free memory → start → coding agent |
| `./aiModelTest.sh` | Test one engine+model: reachability, tokens/sec, tool-calling, served context |
| `./testAllAiModels.sh` | Sweep every engine × model with one prompt, one comparison table |
| `./uninstall.sh` | Remove layers most-dependent-first; models gate everything below them |
| `./noRole.sh <Role>` | Purge a whole product and its leftovers (`Docker`, `Codex`) |
| `./installAliases.sh` | Make every step function available in every shell |

The contract behind all of it — layers, naming, invariants — is in
[Docs/SPECIFICATION.md](Docs/SPECIFICATION.md). Full write-ups of each script,
what it does, how it works and **why**, are in [Docs/](Docs/README.md) (macOS)
and [DebianDocs/](DebianDocs/README.md) (Debian). What differs between the two
platforms, and why, is in [Docs/PlatformNotes.md](Docs/PlatformNotes.md).

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
MacOs/                               the Apple Silicon implementations
Debian/                              the Debian/Ubuntu implementations
ModelLists/<Engine>/<RAM>_GB_Ram.json  model catalogs as data (shared)
Docs/                                one document per macOS script, + the spec
DebianDocs/                          one document per Debian script
```

Always call the root wrappers, not `MacOs/...` or `Debian/...` directly — the
same commands then work on either machine. An unsupported OS (Fedora, Windows)
exits with a clear message rather than half-running.

## Requirements

Both platforms:

- **16 GB RAM minimum** (48 GB+ for 30B-class models)
- **25 GB free disk** minimum — the installer blocks below this and will not
  bargain; a single model is 20–30 GB

| | macOS | Debian/Ubuntu |
|---|---|---|
| Hardware | Apple Silicon | x86_64 or arm64 |
| Package manager | Homebrew (offered if missing) | apt (always present) |
| For the coding agents | Node via Homebrew | **Node + npm** — `sudo apt-get install -y nodejs npm`, or let `aistackInstallNode` do it |
| Acceleration | Metal, always | CUDA / ROCm / Vulkan when present, **otherwise CPU** — detected and reported, never assumed |
| Root needed for | Homebrew installs | apt steps, the Ollama installer, and the purge scripts — **not** for llama.cpp, models, launching or testing |

On a CPU-only Linux box a 30B-class model runs at single-digit tokens/second.
The installer says so before you download 30 GB, rather than after.

On Debian the whole inference path — install llama.cpp, download a model, serve
it, measure it — runs **without root**; see
[DebianDocs](DebianDocs/README.md#what-needs-root-and-what-does-not) for the
split. Every wizard needs an interactive terminal, because it reads `/dev/tty`;
individual step functions take arguments instead and need none.

## Design rules

- **One question at a time**, and never a question with only one possible
  answer — those are announced and skipped.
- **Enter is safe**: destructive prompts default to No, expected ones to Yes.
- **Hard gates over warnings** — not enough disk or RAM stops the flow.
- **Measured, not estimated** — disk from `df` before/after, memory from
  `vm_stat` or `/proc/meminfo`, ports from `lsof`/`ss`, tokens/sec from the
  engine's own counters. The test suite measures both platforms identically, so
  a tok/s figure from a Mac and from a Debian box are directly comparable.
- **Safe to re-run** — every step detects what is already done, so each script
  doubles as its own status check.

## License

[MIT](LICENSE) — do what you like, keep the copyright notice, no warranty.

The models, engines and agents this installs carry **their own licences**,
which are not MIT: check each one before commercial use. Anubis OSS is
GPL-3.0, and model weights range from Apache-2.0 to bespoke community terms.
