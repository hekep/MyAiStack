# noCodexRole.sh — remove OpenAI Codex, keep ChatGPT

## What it does

Removes the OpenAI Codex CLI/app and all of its data and traces (~2.2 GB on
this machine) while **guaranteeing the ChatGPT application and its data
survive**. Same design as noDockerRole.sh: ask before every removal, raw →
surgical order, disk-space gain reported after each confirmed step.

## How it works

| Step | What | Notes |
|---|---|---|
| 1 | Stop running Codex processes | graceful, then force |
| 2 | The Codex CLI/app itself | Detects npm (`@openai/codex`), brew, a loose binary, or `/Applications/Codex.app` — whichever exists. On this machine the CLI was already gone; the step just confirms and moves on. |
| 3 | `~/.cache/codex-runtimes` | **~1.6 GB** — the biggest chunk |
| 4 | `~/.codex` | ~550 MB: `auth.json` (login tokens), config.toml, plugins, memories/log databases. Warns: deleting = permanently logged out of Codex on this machine; **ChatGPT login is separate and unaffected.** |
| 5 | Codex-specific `~/Library` traces | Only `com.openai.codex` / `Codex` namespaces: caches, App Support, preferences, HTTPStorages, logs |
| 6 | **Grey zone — default KEEP**: `codex-*` task data *inside* ChatGPT's own container (`com.openai.chat`) | Powers ChatGPT's Codex-tasks view; deleting could confuse the app you want to keep. Only removed on an explicit "yes anyway". |
| 7 | **Grey zone — default KEEP**: the VS Code extension `openai.chatgpt-*` | It is branded ChatGPT but IS the Codex/ChatGPT IDE extension. Middle option offered: keep only the newest of the 11 accumulated versions and delete the stale duplicates. |
| 8 | Keychain entries | Frees no space; keeping avoids re-login. "Delete anyway?" phrasing. |
| 9 | Final trace scan | Excludes everything under `com.openai.chat`; closing summary proves ChatGPT.app and its data are intact, plus total GB gained. |

## Why it is necessary

- **Codex and ChatGPT are entangled on disk.** They share the `com.openai.*`
  namespace, Codex task data lives inside ChatGPT's container, and the VS Code
  extension carries the ChatGPT name. A pattern-match delete of "*codex*" or
  "*openai*" would either miss traces or destroy the ChatGPT app you use. The
  script encodes the exact boundary, verified against this machine's real
  layout.
- The CLI uninstall alone (already done here) left **~2.2 GB** of runtimes,
  auth databases and caches behind — the typical "uninstalled but not gone"
  situation this script exists to finish.

## Usage

```bash
./noCodexRole.sh
```
