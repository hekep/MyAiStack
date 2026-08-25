# uninstall.sh — Local AI coding stack remover (Debian/Ubuntu)

## What it does

Removes the stack that `install.sh` builds, one layer at a time, asking before
every action. Structurally it is the mirror image of the installer: same
function-per-step shape, same prefix convention (`aistackUninstall*`), same
`source`-and-call usability — but the order is reversed, from the **most
dependent** layer down to the foundations.

## The gate

**While any model is installed, nothing below it may be removed.**
`aistackUninstallLlamacppModels` and `aistackUninstallOllamaModels` return
non-zero if models remain, and the wrapper stops right there, keeping the
engines, agents, monitoring and foundations — everything the models depend on.
Remove every model to reach the foundation layers.

`aistackUninstallOllamaEngine` and `aistackUninstallLlamacppEngine` each
enforce the same rule independently, so it holds even when called directly.

## How it works — one function per layer

Layer order mirrors the installer in reverse: **sanity** → **disk report** →
**models, one step per engine** (the gate) → **monitoring** → **coding agents**
→ **engines** → **engine data** → **foundations**.

Every `aistackInstall*` step has an `aistackUninstall*` counterpart of the same
name, so the two families are symmetrical. Two asymmetries are deliberate, and
they are the same two as on macOS:

- `aistackUninstallDiskGate` **reports** rather than gates. The installer blocks
  below a disk minimum; removing things can only free space, so the inverse is a
  breakdown of what each layer is holding, to inform what is worth removing.
- `aistackUninstallOllamaData` has no install counterpart — nothing explicitly
  *installs* the Ollama model store; it accumulates. It is the deep clean of the
  blob store, kept separate because it is the one unrecoverable step.

| Function | Layer | Behavior |
|---|---|---|
| `aistackUninstallSanity` | — | Confirms this is a Debian-family Linux before touching anything |
| `aistackUninstallDiskGate` | — | Reports what each layer holds: the Ollama store, the GGUFs, the llama.cpp prefix, the HuggingFace cache, uv's tool store |
| `aistackUninstallLlamacppModels` | GGUFs — **gate** | Numbered menu mirroring the installer's download menu: models with sizes and current free disk, pick by number to remove (freed GB reported), menu re-renders, until none remain (→ descend) or **N** stops |
| `aistackUninstallOllamaModels` | Ollama models — **gate** | Same menu, driven through `ollama rm`. Starts the daemon temporarily if needed and stops it again on every exit path |
| `aistackUninstallNvtopMonitoring` | nvtop | Default **No** — tiny, useful beside any GPU workload, unrelated to whether you keep the models |
| `aistackUninstallBtopMonitoring` | btop | Default **No** — a general system monitor that happens to have been installed here |
| `aistackUninstallLitellmMonitoring` | LiteLLM proxy | Default **No**; offers `~/.litellm` separately, since it can hold provider keys |
| `aistackUninstallClaudeCodingAgent` | Claude Code CLI | Default **No** — it may be running this session. `~/.claude` (sessions, settings, memory) is never touched |
| `aistackUninstallOpenCodeCodingAgent` | OpenCode | npm package; offers `~/.config/opencode` separately |
| `aistackUninstallPiCodingAgent` | Pi | npm package, either publisher scope; offers `~/.pi` separately |
| `aistackUninstallOllamaEngine` | Ollama runtime | Refuses while models exist. Otherwise undoes the **official installer's** layout, none of which apt knows about — see below |
| `aistackUninstallLlamacppEngine` | llama.cpp | Refuses while GGUFs exist. Removes **only what this stack installed** — see below |
| `aistackUninstallOllamaData` | the Ollama model store | The only unrecoverable step: every model blob plus this machine's registry keypair. Size shown, **double confirmation**, both defaulting to No |
| `aistackUninstallNode` | Node + npm | Warns which global npm packages would break, and that Node is a general-purpose runtime. Default **No**. Skipped entirely when Node was not installed by apt |
| `aistackUninstallUv` | uv | Lists the tools uv still manages before asking (default No). Uses `uv self uninstall`, falling back to removing the binaries; offers `~/.local/share/uv` separately |
| `aistackUninstallBaseTools` | curl, python3, jq, … | Reports only — never removed, since the rest of the system depends on them |
| `aistackUninstallVerification` | — | What is left standing, plus free disk. Also printed when the gate stops the run |
| `aistackUninstall` | wrapper | Runs the layers in order, enforcing the gate |

## What differs from the macOS remover

### Ollama is not a package

The official Linux installer is a shell script, not apt, so `apt remove ollama`
would find nothing. The engine step therefore undoes each piece it created:

1. `systemctl disable --now ollama.service`, then removes
   `/etc/systemd/system/ollama.service` and reloads the daemon;
2. `pkill -f "ollama serve"` for a user-run daemon;
3. the binary at `/usr/local/bin/ollama` (or `/usr/bin/ollama`) and the
   `/usr/local/lib/ollama` runtime directory;
4. the **system user and group `ollama`** the installer created — asked
   separately, because a leftover system account is a different decision from
   removing a program.

macOS's counterpart removes a brew formula and/or an `.app` bundle. Neither
concept exists here.

### llama.cpp removes only what this stack installed

The engine was installed into `~/.local/opt/llama.cpp` with symlinks in
`~/.local/bin`. The uninstall step removes that prefix and **only the symlinks
that actually resolve into it** — so a distro package, a hand-built copy or
another checkout elsewhere on `PATH` is reported and left alone rather than
deleted. On macOS there is one answer (`brew uninstall llama.cpp`); here there
are several possible installs and the script owns exactly one of them.

### The model store may not be yours

`aistackUninstallOllamaData` resolves the store through `ollamaModelsDir()`,
which can point at `/usr/share/ollama/.ollama` when the system service was left
enabled. The step names the actual directory in its prompts and escalates to
`sudo` only when the parent is not writable — it never assumes `~/.ollama`.

### Base tools replace Homebrew

macOS reports Homebrew and refuses to remove it, because it manages software far
beyond this stack. `aistackUninstallBaseTools` does exactly the same for curl,
python3, jq, lsof and the rest, for exactly the same reason — and prints the
apt line for anyone who really means it.

### Node is a new layer

macOS assumed npm was present. Debian installs it as a step, so it has a
removal counterpart — which checks whether apt actually owns the Node on `PATH`
(leaving a NodeSource or nvm install alone), lists the global packages that
would break, and defaults to No.

## Why it is necessary

- **Ordering prevents orphans.** Removing Ollama before its models leaves tens
  of GB of blobs that nothing can manage; removing Node before the agents
  leaves three unusable commands. Reverse-dependency order plus the gate
  guarantee nothing is removed while something still stands on it.
- **Several install kinds.** Ollama may be a script install with a systemd unit;
  llama.cpp may be this stack's prefix or somebody else's build; the Claude CLI
  may be npm or the native installer; Node may be apt or NodeSource. A naive
  removal misses one layout or destroys another's files. Each function knows
  which ones it owns.
- **The expensive step is isolated.** Uninstalling the program (minutes to
  reinstall) and deleting the model blobs (hours to re-download) are different
  decisions, so they are separate functions with different confirmation
  strength.

## Usage

```bash
./uninstall.sh                          # full pipeline, gate enforced
```

```bash
source Debian/uninstall.sh              # à la carte, e.g.:
aistackUninstallLitellmMonitoring       # just drop the proxy
aistackUninstallVerification            # what is still standing
```
