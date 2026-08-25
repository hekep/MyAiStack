# noCodexRole.sh — remove OpenAI Codex (Debian/Ubuntu)

## What it does

Removes the OpenAI Codex CLI and all of its data and traces. Same design as
[noDockerRole.sh](noDockerRole.sh.md): ask before every removal, raw → surgical
order, disk-space gain reported after each confirmed step.

```bash
./noRole.sh Codex       # case-insensitive
```

## How it works

| Step | What | Notes |
|---|---|---|
| 1 | Stop running Codex processes | graceful, then force. Matched on a path-boundary pattern so an unrelated process with "codex" in its arguments is not swept up |
| 2 | The Codex CLI itself | Detects npm (`@openai/codex`), a snap, or a loose binary — whichever exists. Already-gone is fine: the step says so and moves on to the leftovers |
| 3 | `~/.cache/codex-runtimes` | Usually the biggest chunk |
| 4 | `~/.codex` | `auth.json` (login tokens), config.toml, plugins, memories/log databases. Warns: deleting = permanently logged out of Codex on this machine |
| 5 | XDG traces: `~/.config`, `~/.local/share`, `~/.local/state`, `~/.cache` | Only paths whose **last component** names Codex. A bare `*openai*` match would be exactly the careless delete this script exists to avoid |
| 6 | **Grey zone — default KEEP**: the VS Code extension `openai.chatgpt-*` | It is branded ChatGPT but IS the Codex/ChatGPT IDE extension. Middle option offered: keep only the newest version and delete stale duplicates |
| 7 | Secret-service entries via `secret-tool` | Frees no space; keeping avoids re-login. "Delete anyway?" phrasing |
| 8 | Final trace scan | Lists whatever survived your choices |

## Why this is shorter than the macOS version — and that is the finding

The macOS script has nine steps, two of which exist purely to keep Codex from
taking ChatGPT with it: Codex task data lives *inside* ChatGPT's own container
(`com.openai.chat`), the two share the `com.openai.*` namespace, and a
pattern-match delete of `*codex*` or `*openai*` would either miss traces or
destroy the ChatGPT app you use.

**On Linux there is no official ChatGPT desktop application.** That entanglement
does not exist, so those two steps have nothing to protect and are absent
rather than stubbed.

What does survive the port:

- **The VS Code extension stays a grey zone.** It is still branded ChatGPT and
  still is the Codex IDE extension, so it keeps its own step and its default of
  keeping. Four locations are checked, not one: `~/.vscode/extensions`,
  `~/.vscode-server/extensions` (a Linux box is often the server end of
  somebody else's editor), `~/.vscode-oss/extensions`, and the Flatpak data
  directory.
- **Unofficial ChatGPT clients are detected, not assumed absent.** A ChatGPT
  snap, flatpak or `~/.config/ChatGPT` directory is found at startup and
  reported as protected. When nothing is found the script says why — *"there is
  no official one for Linux, so nothing to protect"* — rather than staying
  silent, so the absence is a stated finding rather than an oversight.
- **The keychain step becomes a secret-service step**, using `secret-tool` with
  the same keep-by-default recommendation. When libsecret is not installed the
  script says so and points at `~/.codex/auth.json`, which is where the token
  actually lives.

## Why it is necessary

The CLI uninstall alone leaves the runtime cache, the auth database and the
config behind — the typical "uninstalled but not gone" situation these scripts
exist to finish. Doing it by hand invites the `*openai*` glob that takes
something you wanted to keep; this encodes the boundary instead.

## Usage

```bash
./noRole.sh Codex
```

Only step 2 may need sudo, and only when the binary lives outside `$HOME`.
Everything else is user-owned.
