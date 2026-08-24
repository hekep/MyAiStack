# Docs — MyAiStack scripts

Documentation for the shell scripts in this repo. Each doc covers **what the
script does, how it works, and why it is necessary**.

## Repo layout — OS dispatch

The `*.sh` scripts in the repo root are thin **wrappers**: each one sources
[common.sh](../common.sh), detects the host OS, and `exec`s the real
implementation from the matching OS folder, forwarding all arguments:

- `MacOs/` — the Apple Silicon macOS implementations (complete; everything
  documented below lives here)
- `Debian/` — Debian/Ubuntu implementations (to be generated later on that box)
- Unsupported systems (e.g. Fedora/RHEL-based Linux) exit with a clear
  message instead of half-running.

`common.sh` holds the shared code: `detectOsFolder` (Darwin → MacOs;
Linux with debian/ubuntu in `/etc/os-release` ID/ID_LIKE → Debian; anything
else → refuse) and `os_exec` (dispatch, with a friendly error when an OS
folder lacks that script). Always invoke the root wrappers — `./install.sh`,
not `MacOs/install.sh` — so the same commands will work unchanged on the
Debian box.

| Script | Doc | One-liner |
|---|---|---|
| [install.sh](../install.sh) | [install.sh.md](install.sh.md) | Multi-engine, re-runnable installer (`installAiStack*` + `installAiStack` wrapper): disk gate → **three engines** (llama.cpp default-yes, MLX-LM and Ollama optional; wizard cancels if none) → **coding agents** (Pi default-yes, OpenCode/Claude optional) → a RAM-aware model menu **per installed engine**, each from its own catalog → verification. |
| [uninstall.sh](../uninstall.sh) | [uninstall.sh.md](uninstall.sh.md) | Function-per-layer remover (`uninstallAiStack*` + `uninstallAiStack` wrapper), mirror of the installer in reverse-dependency order: models (numbered menu, **gate**) → mlx-lm → Claude CLI → Ollama → `~/.ollama` (double-confirmed) → uv. Nothing below the models is removed while any model remains. Homebrew untouched. |
| [noRole.sh](../noRole.sh) | [noRole.sh.md](noRole.sh.md) | Unified purge dispatcher: discovers the `no<Role>Role.sh` scripts in the OS folder. `./noRole.sh Docker` (case-insensitive) launches one directly; with no argument it offers each available role as a y/N question (default No). |
| [MacOs/noDockerRole.sh](../MacOs/noDockerRole.sh) | [noDockerRole.sh.md](noDockerRole.sh.md) | "Reg cleaner" purge of Docker Desktop — app, 33 GB VM disk, root daemons, symlinks, traces, keychain — protecting `~/MyDocker*`. Reports GB gained per step. Run via `./noRole.sh Docker`. |
| [MacOs/noCodexRole.sh](../MacOs/noCodexRole.sh) | [noCodexRole.sh.md](noCodexRole.sh.md) | Removes OpenAI Codex and ~2.2 GB of leftovers while guaranteeing ChatGPT survives; handles the two Codex/ChatGPT grey zones explicitly. Run via `./noRole.sh Codex`. |
| [launchInference.sh](../launchInference.sh) | [launchInference.sh.md](launchInference.sh.md) | Runs a model: engine selector (asked when several are installed) → model → **context size menu (32K/64K/128K default/larger when it fits)** → network exposure (every engine) → free memory → fit check → start server → **coding agent** (compatibility-filtered: Pi/OpenCode any engine, Claude Ollama-only). |
| [aiModelTest.sh](../aiModelTest.sh) | [aiModelTest.sh.md](aiModelTest.sh.md) | Tests one engine+model: **engine menu → model menu → prompt question**, then server → generation (tokens/sec) → Anthropic endpoint (Ollama only, SKIP elsewhere) → tool-calling (PASS/FLAKY/FAIL) → served context. Starts the right server for the chosen model. |
| [installAliases.sh](../installAliases.sh) | [installAliases.sh.md](installAliases.sh.md) | Adds a marker-delimited block to your shell rc so all 55 step functions are callable from anywhere (`aiStackHelp` lists them). Idempotent, backs up the rc, `--remove` undoes it. Runs each function in its own bash process, so helper names never leak into your shell. |
| [testAllAiModels.sh](../testAllAiModels.sh) | [testAllAiModels.sh.md](testAllAiModels.sh.md) | Sweeps **every engine × every model it has**, one prompt for all, stopping each server between models so the next one gets clean memory. Ends with one table: engine, model, tokens, time, tok/s, tools, ctx, total. |

## Shared design principles

- **One question at a time** — every destructive or installing action is an
  individual y/n prompt; nothing happens silently.
- **Dependency order** — installers go foundation-first, removers go
  most-dependent-first; each step verifies what earlier steps established.
- **Hard gates over warnings** — not enough disk or RAM blocks the flow
  (re-check loop / non-zero exit), it doesn't just print a caveat.
- **Measured, not estimated** — disk gains come from `df` before/after, memory
  from live `ps`/`vm_stat`, listening ports from `lsof`.
- **Protect the expensive and the personal** — model blobs, `~/MyDocker*`,
  ChatGPT data and keychain logins are separated from the things being
  removed, with keep-recommendations where re-acquiring is costly.
- **Safe to re-run** — completed steps are detected and skipped, so every
  script doubles as its own status checker.
