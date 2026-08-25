# DebianDocs — the Debian/Ubuntu implementations

Documentation for the scripts in [`Debian/`](../Debian/). Each doc covers **what
the script does, how it works, and why it is necessary** — the same shape as
[`Docs/`](../Docs/README.md), which documents the macOS side.

**If you only read two things:**

- [Docs/SPECIFICATION.md](../Docs/SPECIFICATION.md) — the contract both
  platforms implement: four layers, the naming rule, the nine invariants.
- [Docs/PlatformNotes.md](../Docs/PlatformNotes.md) — what differs between
  macOS and Debian, and why. Every deviation below is explained there.

## Repo layout — OS dispatch

The `*.sh` scripts in the repo root are thin **wrappers**: each one sources
[common.sh](../common.sh), detects the host OS, and `exec`s the real
implementation from the matching OS folder, forwarding all arguments.

```
./install.sh  →  common.sh: detectOsFolder → "Debian"  →  Debian/install.sh
```

Always invoke the root wrappers — `./install.sh`, not `Debian/install.sh` — so
the same commands work unchanged on either platform.

Detection: `Linux` with `debian` or `ubuntu` in `/etc/os-release`'s `ID` or
`ID_LIKE`. A Fedora/RHEL box is refused with a clear message rather than
half-run.

## The scripts

| Script | Doc | One-liner |
|---|---|---|
| [install.sh](../Debian/install.sh) | [install.sh.md](install.sh.md) | Re-runnable installer: disk gate → base apt tools → **two engines** (llama.cpp default-yes from upstream binaries, Ollama optional; wizard cancels if none) → **coding agents** (Pi default-yes, OpenCode/Claude optional) → a RAM-aware model menu **per installed engine** → verification. |
| [uninstall.sh](../Debian/uninstall.sh) | [uninstall.sh.md](uninstall.sh.md) | Function-per-layer remover, mirror of the installer in reverse-dependency order: models (numbered menu, **gate**) → monitoring → agents → engines → the Ollama model store (double-confirmed) → Node → uv. Nothing below the models is removed while any model remains. Base apt packages untouched. |
| [launchInference.sh](../Debian/launchInference.sh) | [launchInference.sh.md](launchInference.sh.md) | Runs a model: engine → model → **context size** → network exposure → free memory → fit check → start server → **coding agent** (compatibility-filtered). Chooses `-ngl` or `-t` from the llama.cpp backend actually installed, and resolves the Ollama system-service clash. |
| [aiModelTest.sh](../Debian/aiModelTest.sh) | [aiModelTest.sh.md](aiModelTest.sh.md) | Tests one engine+model: **engine menu → model menu → prompt question**, then server → generation (tokens/sec) → Anthropic endpoint (Ollama only, SKIP elsewhere) → tool-calling (PASS/FLAKY/FAIL) → served context. |
| [testAllAiModels.sh](../Debian/testAllAiModels.sh) | [testAllAiModels.sh.md](testAllAiModels.sh.md) | Sweeps **every engine × model**, one prompt for all, stopping each server between models so the next one gets clean memory. Ends with one comparison table. |
| [noDockerRole.sh](../Debian/noDockerRole.sh) | [noDockerRole.sh.md](noDockerRole.sh.md) | Eleven-step Docker purge: engine data, Desktop VM disk (**mount-aware**), apt packages, **the repository**, systemd units, user data, the `docker` group, credentials — protecting `~/MyDocker*`. Run via `./noRole.sh Docker`. |
| [noCodexRole.sh](../Debian/noCodexRole.sh) | [noCodexRole.sh.md](noCodexRole.sh.md) | Removes the OpenAI Codex CLI and its leftovers. Shorter than the macOS version because Linux has no official ChatGPT desktop app to disentangle it from. Run via `./noRole.sh Codex`. |

Two root scripts are shared rather than per-OS, and are documented once on the
macOS side:

- [noRole.sh](../Docs/noRole.sh.md) — the purge dispatcher. It **discovers**
  `no*Role.sh` in the OS folder, so both Debian roles appeared automatically.
- [installAliases.sh](../Docs/installAliases.sh.md) — the shell integration.
  Editing a shell rc is identical on every platform, and `shellFunctions.sh`
  reads the function names out of whichever OS folder is detected. It needed
  **no change** for this port; `aistackHelp` simply lists the 64 Debian step
  functions instead of the 66 macOS ones.

## Prerequisites, and what needs root

### Already on a stock Debian/Ubuntu

`bash`, `apt`, `dpkg`, `systemctl`, `df`, `du`, `ps`, `awk`, `sed`, `find`.
Nothing to do.

### Established by `aistackInstallBaseTools` (needs root)

```
curl ca-certificates tar gzip python3 jq lsof procps iproute2
```

These are what the rest of the scripts shell out to — `curl` for every
download, `python3` for JSON, `jq`/`lsof`/`ss` for the measurements this
toolkit refuses to estimate. The step lists what is missing and installs only
that; declining ends the wizard rather than half-building a stack.

### Required for the coding agents: Node and npm (needs root)

**This is the one genuine prerequisite that is not on a stock system.** All
three coding agents — Pi, OpenCode and Claude Code — are npm packages, so
without Node none of them can be installed:

```bash
sudo apt-get install -y nodejs npm     # or let aistackInstallNode do it
```

`aistackInstallNode` runs exactly that, then **moves npm's global prefix to
`~/.local`** so every later `npm install -g` works without root. The agent
steps call it automatically (`aistackInstallNode required`), so you only need
the command above if you would rather install Node yourself.

Claude Code has a second route that needs no npm at all — its native installer
(`curl -fsSL https://claude.ai/install.sh | bash`), which
`aistackInstallClaudeCodingAgent` falls back to. Pi and OpenCode have no such
fallback: for them, npm is required.

### What needs root, and what does not

Worth knowing before you start, because **the entire inference path works
without any privileges at all** — verified end to end on the reference box:

| Needs root | Never needs root |
|---|---|
| `aistackInstallBaseTools` (apt) | `aistackInstallLlamacppEngine` → `~/.local/opt` |
| `aistackInstallNode` (apt) | `aistackInstallUv` → `~/.local/bin` |
| `aistackInstallOllamaEngine` (official installer + systemd unit) | `aistackInstallLlamacppModels` → `~/Models` |
| `aistackInstallNvtopMonitoring`, `...BtopMonitoring` (apt) | every `aistackLaunchInference*` step |
| Stopping the system-wide `ollama.service` | every `aistackModelTest*` step |
| `noDockerRole.sh` (most steps) | `aistackInstallPiCodingAgent` and friends, **once the npm prefix is `~/.local`** |

So on a machine where you cannot sudo, this still works:

```bash
aistackInstallLlamacppEngine     # upstream binary into ~/.local/opt
aistackInstallLlamacppModels     # GGUFs into ~/Models
aistackLaunchInference           # serve it
./aiModelTest.sh                 # measure it
```

What you lose without root: Ollama (and therefore Claude Code), the apt-based
monitoring tools, and Node — so of the coding agents only Claude Code remains
reachable, via its native installer.

### An interactive terminal

Every wizard and menu reads `/dev/tty`, so the full scripts need a real
terminal and abort with *"No interactive terminal available"* without one.
That is deliberate — nothing destructive should be answerable by a stray pipe.

For scripting or CI, do not fake a terminal: **call the step functions with
their arguments instead**, which is what they are designed for and what makes
every one of them individually callable:

```bash
source Debian/launchInference.sh
aistackLaunchInferenceStart Llama.cpp <model> 32768 127.0.0.1
```

If you genuinely must drive a wizard non-interactively, `script -qec '<cmd>'
/dev/null` allocates a pty and feeds its stdin to `/dev/tty`.

No terminal multiplexer is required. `tmux` and `screen` are convenient for
leaving a server running after you log out, but nothing in this toolkit needs
them.

## What this platform has, and does not

| Layer | Members on Debian |
|---|---|
| **Engines** | llama.cpp *(default)*, Ollama — **no MLX-LM** (Apple Silicon only) |
| **Coding agents** | Pi *(default)*, OpenCode, Claude Code — all three, same as macOS |
| **Models** | the same [ModelLists/](../ModelLists/) catalogs; `Llama.cpp/` and `Ollama/` are consumed, `MLX-LM/` is not |
| **Monitoring** | nvtop, btop, LiteLLM — replacing macmon and Anubis OSS, which are macOS-only |
| **Foundations** | base apt packages, uv, **Node** (an explicit step here, unlike macOS) |

Nothing above is a stub. A layer member that cannot exist on Linux is absent,
and the place you would look for it says why — `_requireEngine MLX-LM` explains
it rather than reporting an unknown engine.

## Shared design principles

Identical to the macOS side, because they are the contract rather than the
implementation:

- **One question at a time** — every destructive or installing action is an
  individual y/n prompt; nothing happens silently.
- **Dependency order** — installers go foundation-first, removers go
  most-dependent-first; each step verifies what earlier steps established.
- **Hard gates over warnings** — not enough disk or RAM blocks the flow.
- **Measured, not estimated** — disk from `df` before/after (**per filesystem**
  on Linux), memory from `/proc/meminfo`, ports from `lsof`/`ss`, tokens/sec
  from the engine's own counters.
- **Protect the expensive and the personal** — model blobs, `~/MyDocker*`,
  `~/.claude`, agent configs and keyring entries are separate decisions from
  the software that uses them.
- **Safe to re-run** — completed steps are detected and skipped, so every
  script doubles as its own status checker.
