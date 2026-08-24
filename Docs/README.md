# Docs — AI_Code_generator scripts

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
| [install.sh](../install.sh) | [install.sh.md](install.sh.md) | Function-per-step, re-runnable installer (`installOllama*` + `installOllama` wrapper): Homebrew → Ollama (.app→brew migration, upgrade proposals) → server with localhost/LAN choice → uv → mlx-lm → RAM-aware model menu (biggest→smallest, loops until N) → verification. Hard disk gate. |
| [uninstall.sh](../uninstall.sh) | [uninstall.sh.md](uninstall.sh.md) | Reverses install.sh in reverse-dependency order: models → mlx-lm → Ollama → `~/.ollama` (double-confirmed) → uv. Homebrew untouched. |
| [noRole.sh](../noRole.sh) | — | Unified purge dispatcher: discovers the `no<Role>Role.sh` scripts in the OS folder. `./noRole.sh Docker` (case-insensitive) launches one directly; with no argument it offers each available role as a y/N question (default No). |
| [MacOs/noDockerRole.sh](../MacOs/noDockerRole.sh) | [noDockerRole.sh.md](noDockerRole.sh.md) | "Reg cleaner" purge of Docker Desktop — app, 33 GB VM disk, root daemons, symlinks, traces, keychain — protecting `~/MyDocker*`. Reports GB gained per step. Run via `./noRole.sh Docker`. |
| [MacOs/noCodexRole.sh](../MacOs/noCodexRole.sh) | [noCodexRole.sh.md](noCodexRole.sh.md) | Removes OpenAI Codex and ~2.2 GB of leftovers while guaranteeing ChatGPT survives; handles the two Codex/ChatGPT grey zones explicitly. Run via `./noRole.sh Codex`. |
| [aiModelLauncher.sh](../aiModelLauncher.sh) | [aiModelLauncher.sh.md](aiModelLauncher.sh.md) | Six functions: pick model → free memory → RAM prerequisite gate → launch server+model (32k context enforced) with usage report → Claude CLI wired to the local model. |
| [aiModelTest.sh](../aiModelTest.sh) | [aiModelTest.sh.md](aiModelTest.sh.md) | Layered stack verification: server → raw generation (tokens/sec) → Anthropic endpoint → tool-calling (with retry, PASS/FLAKY/FAIL) → context window. Reusable functions (`aiModelTestReset`/`aiModelTestRun`) with metrics exported for wrappers. |
| [testAllAiModels.sh](../testAllAiModels.sh) | [testAllAiModels.sh.md](testAllAiModels.sh.md) | Runs the aiModelTest suite over every downloaded model (custom prompt, clean load per model) and prints one comparison table: model, tokens, time, tok/s, tool call, total time. |

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
