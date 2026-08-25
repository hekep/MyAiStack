# uninstall.sh — Local AI coding stack remover (function-based)

## What it does

Removes the stack that `install.sh` builds, one layer at a time, asking before
every action. Structurally it is the mirror image of the installer: same
function-per-step shape, same prefix convention (`aistackUninstall*`, with
`Ollama` in the name only for engine-specific layers), same `source`-and-call
usability — but the order is reversed, from the **most dependent** layer down
to the foundations.

## The gate

**While any Ollama model is installed, nothing below it may be removed.**
`aistackUninstallOllamaModels` returns non-zero if models remain, and the
wrapper stops right there, keeping Ollama, mlx-lm, the Claude CLI and uv —
everything the models depend on. Remove every model to reach the foundation
layers. `aistackUninstallOllamaEngine` enforces the same rule independently, so
it refuses even when called directly with models present.

## How it works — one function per layer

Layer order mirrors the installer in reverse: **sanity** → **disk report** →
**models, one step per engine** (the gate) → **monitoring** → **coding agents**
→ **engines** → **their data** → **foundations**.

Every `aistackInstall*` step has an `aistackUninstall*` counterpart of the same
name, so the two families are symmetrical. Two asymmetries are deliberate:

- `aistackUninstallDiskGate` **reports** rather than gates. The installer blocks
  below a disk minimum; removing things can only free space, so the inverse is a
  breakdown of what each layer is holding, to inform what is worth removing.
- `aistackUninstallOllamaData` has no install counterpart — nothing explicitly
  *installs* `~/.ollama`; it accumulates. It is the deep clean of the blob
  store, kept separate because it is the one unrecoverable step.

| Function | Layer | Behavior |
|---|---|---|
| `aistackUninstallOllamaModels` | the models — **gate** | Numbered menu mirroring the installer's download menu: models with sizes and current free disk, pick by number to remove (freed GB reported), menu re-renders, until none remain (→ descend) or **N** cancels the whole uninstall. Starts the Ollama server temporarily if needed, stops it again on every exit path. |
| `aistackUninstallMacmonMonitoring` | macmon | Default **No** — small, useful beside any workload, and unrelated to whether you keep the models |
| `aistackUninstallAnubisMonitoring` | Anubis OSS | Default **No**. Removes the cask, then offers brew's `--zap` separately — that clears your saved benchmark history, which is not something an uninstall should take by default |
| `aistackUninstallLitellmMonitoring` | LiteLLM proxy | Default **No**; offers `~/.litellm` separately, since it can hold provider keys |
| `aistackUninstallClaudeCodingAgent` | Claude Code CLI | Default **No** — it may be running this session. `~/.claude` (sessions, settings, memory) is never touched |
| `aistackUninstallOpenCodeCodingAgent` | OpenCode | Brew or npm, whichever installed it; offers `~/.config/opencode` separately |
| `aistackUninstallPiCodingAgent` | Pi | npm package; offers `~/.pi` separately |
| `aistackUninstallMlx` | mlx-lm / MLX-LM engine | Removes the uv tool, then offers the separate (often large) `~/.cache/huggingface` model cache — default No, since it is pure re-downloadable cache. |
| `aistackUninstallOllamaEngine` | Ollama runtime | Refuses while models exist. Otherwise stops every way it can be running (brew service, LAN LaunchAgent, app, bare `ollama serve`), then removes the brew formula, the standalone `.app` plus its five support paths, and the stray `/usr/local/bin/ollama` symlink. |
| `aistackUninstallOllamaData` | `~/.ollama` | The only unrecoverable step: every model blob plus this machine's registry keypair. Size shown, **double confirmation**, both defaulting to No. |
| `aistackUninstallUv` | uv | Warns which tools uv still manages before asking (default No). |
| `aistackUninstallHomebrew` | Homebrew | Reports only — never removed, since it manages software far beyond this stack. |
| `aistackUninstallStatus` | — | What is left standing, plus free disk. Also printed when the gate stops the run. |
| `aistackUninstall` | wrapper | Runs the layers in order, enforcing the gate. |

## Why it is necessary

- **Ordering prevents orphans.** Removing Ollama before its models leaves
  tens of GB of blobs that nothing can manage; removing uv before mlx-lm
  leaves an unmanageable tool. Reverse-dependency order plus the gate
  guarantee nothing is removed while something still stands on it.
- **Two install kinds.** Ollama may exist as a brew formula *and/or* the
  standalone app, and the Claude CLI as an npm package *or* a native install;
  a naive removal misses the other layout's files. Each function knows both.
- **The expensive step is isolated.** Uninstalling the program (minutes to
  reinstall) and deleting the model blobs (hours to re-download) are different
  decisions, so they are separate functions with different confirmation
  strength.

## Usage

```bash
./uninstall.sh                          # full pipeline, gate enforced
```

```bash
source uninstall.sh                     # à la carte, e.g.:
aistackUninstallMlx                     # just drop mlx-lm
```
