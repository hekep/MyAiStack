# uninstall.sh — Local AI coding stack remover (function-based)

## What it does

Removes the stack that `install.sh` builds, one layer at a time, asking before
every action. Structurally it is the mirror image of the installer: same
function-per-step shape, same prefix convention (`uninstallAiStack*`, with
`Ollama` in the name only for engine-specific layers), same `source`-and-call
usability — but the order is reversed, from the **most dependent** layer down
to the foundations.

## The gate

**While any Ollama model is installed, nothing below it may be removed.**
`uninstallAiStackOllamaModels` returns non-zero if models remain, and the
wrapper stops right there, keeping Ollama, mlx-lm, the Claude CLI and uv —
everything the models depend on. Remove every model to reach the foundation
layers. `uninstallAiStackOllamaEngine` enforces the same rule independently, so
it refuses even when called directly with models present.

## How it works — one function per layer

Layer order: **models** (the gate) → **coding agents** (they sit above the
engines) → **engines** → **their data** → **foundations**.

| Function | Layer | Behavior |
|---|---|---|
| `uninstallAiStackOllamaModels` | the models — **gate** | Numbered menu mirroring the installer's download menu: models with sizes and current free disk, pick by number to remove (freed GB reported), menu re-renders, until none remain (→ descend) or **N** cancels the whole uninstall. Starts the Ollama server temporarily if needed, stops it again on every exit path. |
| `uninstallAiStackClaudeCodingAgent` | Claude Code CLI | Default **No** — it may be running this session. `~/.claude` (sessions, settings, memory) is never touched |
| `uninstallAiStackOpenCodeCodingAgent` | OpenCode | Brew or npm, whichever installed it; offers `~/.config/opencode` separately |
| `uninstallAiStackPiCodingAgent` | Pi | npm package; offers `~/.pi` separately |
| `uninstallAiStackMlx` | mlx-lm / MLX-LM engine | Removes the uv tool, then offers the separate (often large) `~/.cache/huggingface` model cache — default No, since it is pure re-downloadable cache. |
| `uninstallAiStackOllamaEngine` | Ollama runtime | Refuses while models exist. Otherwise stops every way it can be running (brew service, LAN LaunchAgent, app, bare `ollama serve`), then removes the brew formula, the standalone `.app` plus its five support paths, and the stray `/usr/local/bin/ollama` symlink. |
| `uninstallAiStackOllamaData` | `~/.ollama` | The only unrecoverable step: every model blob plus this machine's registry keypair. Size shown, **double confirmation**, both defaulting to No. |
| `uninstallAiStackUv` | uv | Warns which tools uv still manages before asking (default No). |
| `uninstallAiStackHomebrew` | Homebrew | Reports only — never removed, since it manages software far beyond this stack. |
| `uninstallAiStackStatus` | — | What is left standing, plus free disk. Also printed when the gate stops the run. |
| `uninstallAiStack` | wrapper | Runs the layers in order, enforcing the gate. |

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
uninstallAiStackMlx                     # just drop mlx-lm
```
