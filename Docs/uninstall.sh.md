# uninstall.sh — Local AI coding stack remover

## What it does

Interactively removes the stack that `install.sh` builds — models, mlx-lm,
Ollama, its data directory, uv — asking per item, in **reverse dependency
order**: most-dependent things first, foundations last. Homebrew itself is
deliberately never touched.

## How it works

| Step | What | Notes |
|---|---|---|
| 1 | **Models — the gate for everything below** | **Numbered menu, mirror of install.sh's download menu**: installed models listed with sizes and current free disk, pick one by number to remove (freed GB reported), menu re-renders. The uninstall proceeds to steps 2–6 **only when zero models remain** — while models exist, the foundations they depend on must stay, so **N = cancel the whole uninstallation** (everything kept), not a skip. Starts the Ollama server temporarily if needed, and stops it again on both paths. |
| 2 | **mlx-lm** | Depends on uv, so removed before uv. Offers to also delete the HuggingFace model cache (`~/.cache/huggingface`) with its measured size. |
| 3 | **Ollama itself** | Sub-order: stop brew service → quit app → remove LAN LaunchAgent (`local.ollama.lan.plist`, if install.sh created one) → `brew uninstall` → remove standalone `.app` + support files → remove stray `/usr/local/bin/ollama` symlink. Handles both install kinds. |
| 4 | **`~/.ollama` data dir** | Separate from step 3 on purpose. Holds ALL model blobs (+ the machine's Ed25519 registry keypair). **Double confirmation** — this is the only unrecoverable step; everything else can be reinstalled. |
| 5 | **uv** | Warns if uv still manages other tools before asking. |
| 6 | **Homebrew** | Never removed — it manages software beyond this stack. Link provided for manual removal. |

Ends with a summary of what is still installed vs. removed. Safe to re-run;
already-removed items are detected and skipped.

## Why it is necessary

- **Ordering prevents orphans.** Removing Ollama before its models leaves 20 GB
  blobs nothing can manage; removing uv before mlx-lm leaves an unmanageable
  tool. Reverse-dependency order guarantees nothing is removed while something
  still depends on it.
- **Two install kinds.** Ollama may exist as a brew formula *and/or* the
  standalone app; a naive `brew uninstall` misses the app's five scattered
  support paths. The script knows both layouts.
- **The data-dir split protects the expensive part.** Uninstalling the program
  (recoverable in minutes) and deleting the models (hours of re-downloading)
  are different decisions, so they are separate questions with different
  levels of confirmation.

## Usage

```bash
./uninstall.sh
```
