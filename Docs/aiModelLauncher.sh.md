# aiModelLauncher.sh — model picker, resource freer, launcher, Claude bridge

## What it does

One command that takes you from "which model?" to a working AI coding session:
pick a downloaded Ollama model from a menu → free memory by closing heavy apps
→ verify the model fits this machine's RAM → launch server + model → open
Claude CLI in the current directory wired to that local model.

## How it works — six functions

Run the file for the full pipeline, or `source` it and call any function alone.

### 1. `launchOllamaModelSelector`
Numbered menu of downloaded models (name + size from `ollama list`); validates
the choice and prints the model name on stdout so callers can capture it
(`model=$(launchOllamaModelSelector)`). Menu and prompts go to the terminal
(stderr/tty), keeping stdout clean for the return value.

### 2. `launchOllamaFreeResources`
Enumerates **every open desktop application** live via System Events — no
hardcoded app list; whatever is open on the desktop and closable is a
candidate (Slack, Chrome, NetBeans… were only examples). For each app it sums
real memory use across the app's *entire* process tree (helpers and renderers
included, matched case-insensitively by `.app` bundle path — so "Code" finds
"Visual Studio Code.app" helpers), sorts **biggest memory user first**, and
asks **"Close? [Y/n]"** per app (Enter = yes). Quits gracefully via
AppleScript, force-kills only if the graceful quit fails or hangs on a save
dialog.

Generic safeguards, none name-based:
- **Self-protection:** walks this shell's parent-process chain and skips any
  app that is an ancestor of the script — that is whatever terminal or app
  hosts the current session (Terminal, iTerm, Warp, VS Code's terminal, the
  Claude desktop app…), so the script can never close its own host.
- Skips **Finder** (macOS relaunches it) and **Ollama** (the thing being
  launched).

Ends with a measured estimate of memory now free/reclaimable.

### 3. `launchOllamaModelPrerequisites <model>`
The hardware gate. Reads the model's size, estimates true need
(weights × 1.3 for KV-cache + 2 GB runtime), compares against the GPU's
~75 %-of-RAM allocation (~36 GB here) and **exits non-zero if the model cannot
fit** — printing the exact `sysctl iogpu.wired_limit_mb` command that would
raise the limit. Soft-warns if *currently free* memory is short (step 2 helps).

### 4. `launchOllamaModel <model>`
- Server already running → leaves it alone.
- A **different** model loaded → asks "bring it down? Y/n" and replaces it via
  `ollama stop`; the **same** model loaded → does nothing.
- Loads the model through the API with a 60-minute keep-alive, then reports:
  the port (`http://127.0.0.1:11434`, or the LAN bind if `OLLAMA_HOST` is set),
  **memory usage in GB and processor usage in %** measured from the live
  ollama processes, plus the `ollama ps` table.

### 5. `launchClaudeCliToOllama <model>`
Launches `claude` in the current working directory against the local model.
Works because Ollama natively speaks the Anthropic Messages API — the function
sets, for the claude process only:

```
ANTHROPIC_BASE_URL=http://<host>:11434
ANTHROPIC_AUTH_TOKEN=ollama          ANTHROPIC_API_KEY=""
ANTHROPIC_DEFAULT_SONNET_MODEL / _OPUS_ / _HAIKU_ = <model>
```

The three tier variables all map to the chosen model because Claude Code
requests different tiers for different subtasks. Your normal shell is
untouched — real Claude keeps working elsewhere.

### 6. `launchOllama`
The wrapper: selector → free resources → prerequisites (aborts on failure) →
launch → Claude CLI. This is what runs when you execute the script directly.

## Why it is necessary

- **The manual sequence is seven commands and three failure modes.** Loading a
  20 GB model while Slack + Chrome + NetBeans hold 10 GB pushes macOS into
  swap and throughput collapses; loading a model that exceeds the GPU
  allocation fails confusingly late. The pipeline enforces the right order:
  free memory *first*, check fit *before* loading.
- **The replace-model question prevents silent double-loading.** Two large
  models resident at once share GPU memory and both slow down; the script
  makes that an explicit choice.
- **The Claude bridge needs five env variables with exact names** — nobody
  remembers them; the function encodes them once, correctly scoped.

## Usage

```bash
./aiModelLauncher.sh                 # full pipeline
```

```bash
source aiModelLauncher.sh            # à la carte, e.g.:
launchOllamaModel "qwen3.6:35b-a3b"
```
