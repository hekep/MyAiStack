# MacOsDocs — the Apple Silicon macOS implementations

Documentation for the scripts in [`MacOs/`](../MacOs/). Each doc covers **what
the script does, how it works, and why it is necessary** — the same shape as
[`DebianDocs/`](../DebianDocs/README.md), which documents the Debian side.

**If you only read two things:**

- [Docs/SPECIFICATION.md](../Docs/SPECIFICATION.md) — the contract both
  platforms implement: five layers, the naming rule, the nine invariants.
- [Docs/PlatformNotes.md](../Docs/PlatformNotes.md) — what differs between
  macOS and Debian, and why. Every deviation below is explained there.

New to the project? [Docs/DecisionTree.md](../Docs/DecisionTree.md) shows every
choice the stack offers and what each one determines.

## Repo layout — OS dispatch

The `*.sh` scripts in the repo root are thin **wrappers**: each one sources
[common.sh](../common.sh), detects the host OS, and `exec`s the real
implementation from the matching OS folder, forwarding all arguments.

```
./install.sh  →  common.sh: detectOsFolder → "MacOs"  →  MacOs/install.sh
```

Always invoke the root wrappers — `./install.sh`, not `MacOs/install.sh` — so
the same commands work unchanged on either platform.

Detection: `Darwin`. A Fedora/RHEL box, or any other unsupported system, is
refused with a clear message rather than half-run.

## The scripts

| Script | Doc | One-liner |
|---|---|---|
| [install.sh](../install.sh) | [install.sh.md](install.sh.md) | Multi-engine, re-runnable installer (`aistackInstall*` + `aistackInstall` wrapper): disk gate → **three engines** (llama.cpp default-yes, MLX-LM and Ollama optional; wizard cancels if none) → **coding agents** (Pi default-yes, OpenCode/Claude optional) → a RAM-aware model menu **per installed engine**, each from its own catalog → monitoring → verification. |
| [uninstall.sh](../uninstall.sh) | [uninstall.sh.md](uninstall.sh.md) | Function-per-layer remover (`aistackUninstall*` + `aistackUninstall` wrapper), mirror of the installer in reverse-dependency order: models (numbered menu, **gate**) → monitoring → agents → engines → `~/.ollama` (double-confirmed) → uv. Nothing below the models is removed while any model remains. Homebrew untouched. |
| [launchInference.sh](../launchInference.sh) | [launchInference.sh.md](launchInference.sh.md) | Runs a model: engine selector (asked when several are installed) → model → **context size menu (32K/64K/128K default/larger when it fits)** → network exposure (every engine) → free memory → fit check → start server → **coding agent** (compatibility-filtered: Pi/OpenCode any engine, Claude Ollama-only). |
| [aiModelTest.sh](../aiModelTest.sh) | [aiModelTest.sh.md](aiModelTest.sh.md) | Tests one engine+model: **engine menu → model menu → prompt question**, then server → generation (tokens/sec) → Anthropic endpoint (Ollama only, SKIP elsewhere) → tool-calling (PASS/FLAKY/FAIL) → served context. Starts the right server for the chosen model. |
| [testAllAiModels.sh](../testAllAiModels.sh) | [testAllAiModels.sh.md](testAllAiModels.sh.md) | Sweeps **every engine × every model it has**, one prompt for all, stopping each server between models so the next one gets clean memory. Ends with one table: engine, model, tokens, time, tok/s, tools, ctx, total. |
| [noDockerRole.sh](../MacOs/noDockerRole.sh) | [noDockerRole.sh.md](noDockerRole.sh.md) | "Reg cleaner" purge of Docker Desktop — app, 33 GB VM disk, root daemons, symlinks, traces, keychain — protecting `~/MyDocker*`. Reports GB gained per step. Run via `./noRole.sh Docker`. |
| [noCodexRole.sh](../MacOs/noCodexRole.sh) | [noCodexRole.sh.md](noCodexRole.sh.md) | Removes OpenAI Codex and ~2.2 GB of leftovers while guaranteeing ChatGPT survives; handles the two Codex/ChatGPT grey zones explicitly. Run via `./noRole.sh Codex`. |

Two root scripts are shared rather than per-OS, and are documented once in the
generic folder:

- [noRole.sh](../Docs/noRole.sh.md) — the purge dispatcher. It **discovers**
  `no*Role.sh` in the OS folder, so each platform's roles appear automatically.
- [installAliases.sh](../Docs/installAliases.sh.md) — the shell integration.
  Editing a shell rc is identical on every platform, and `shellFunctions.sh`
  reads the function names out of whichever OS folder is detected.

## What this platform has

| Layer | Members |
|---|---|
| Prerequisites | Homebrew, uv |
| Engines | llama.cpp (:8080), **MLX-LM (:8081)**, Ollama (:11434) |
| Coding agents | Pi, OpenCode, Claude Code |
| Tools | ToolUniverse — biomedical MCP tool server, cache under `~/Library/Caches/ToolUniverse` |
| Monitoring | **macmon**, **Anubis OSS**, LiteLLM |

Bold entries exist only here. **MLX-LM is Apple Silicon only** — Apple's own
array framework, and the reason this platform reaches 6bit quants that Debian
cannot. macmon and Anubis OSS are macOS applications; Debian's equivalents are
nvtop and btop.

## The macOS-specific facts worth knowing

- **The GPU budget is a sysctl.** `iogpu.wired_limit_mb` caps what the GPU may
  wire; it defaults to ~75% of RAM and **resets to 0 on every reboot**. Raising
  it is what unlocks the larger quants in the model menu.
- **Ollama runs its own `llama-server` subprocess.** Ours is matched by port,
  never by name — killing by name breaks Ollama's runner and poisons its Metal
  state.
- **Local Time Machine snapshots pin freed disk**, so a cleanup can look
  ineffective until the snapshots are deleted. The installer's disk gate offers
  this.

The full list, and which of these apply to Debian too, is in
[Docs/PlatformNotes.md](../Docs/PlatformNotes.md#platform-traps).
