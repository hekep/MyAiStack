# Docs — MyAiStack

The **generic** documentation: what the project is, what it guarantees, and how
its pieces fit together on every platform it supports. Anything specific to one
operating system lives in that platform's folder instead.

## Where to start

| Document | What it answers |
|---|---|
| [SPECIFICATION.md](SPECIFICATION.md) | **The contract.** What the project is, the four layers, the naming rule, and the nine invariants every change must keep. |
| [DecisionTree.md](DecisionTree.md) | **The shape.** Every choice the stack offers, and what each choice determines — catalog, model ID format, quant ladder, download location. |
| [PlatformNotes.md](PlatformNotes.md) | **The delta.** What macOS and Debian share, where they diverge, and why. Most apparent inconsistencies between the two implementations are platform facts recorded here; the rest are traps somebody already fell into. |

## The platform folders

Each implementation is documented one file per script, in its own folder:

- [MacOsDocs/](../MacOsDocs/README.md) — the Apple Silicon macOS implementations
  in [`MacOs/`](../MacOs/)
- [DebianDocs/](../DebianDocs/README.md) — the Debian/Ubuntu implementations in
  [`Debian/`](../Debian/)

Both folders have the same shape, and both implement the specification above.
What differs is never the contract — only the primitives.

## The shared scripts

Two root scripts are genuinely platform-independent, so they are documented once,
here, rather than twice:

| Script | Doc | One-liner |
|---|---|---|
| [noRole.sh](../noRole.sh) | [noRole.sh.md](noRole.sh.md) | Unified purge dispatcher: **discovers** the `no<Role>Role.sh` scripts in whichever OS folder was detected. `./noRole.sh Docker` (case-insensitive) launches one directly; with no argument it offers each available role as a y/N question (default No). |
| [installAliases.sh](../installAliases.sh) | [installAliases.sh.md](installAliases.sh.md) | Adds a marker-delimited block to your shell rc so every step function is callable from anywhere (`aistackHelp` lists them). Idempotent, backs up the rc, `--remove` undoes it. Runs each function in its own bash process, so helper names never leak into your shell. |

## Repo layout — OS dispatch

The `*.sh` scripts in the repo root are thin **wrappers**: each one sources
[common.sh](../common.sh), detects the host OS, and `exec`s the real
implementation from the matching OS folder, forwarding all arguments.

```
./install.sh  →  common.sh: detectOsFolder  →  MacOs/install.sh
                                            or  Debian/install.sh
                                            or  refuse, with a clear message
```

`common.sh` holds the shared code: `detectOsFolder` (Darwin → `MacOs`; Linux
with `debian` or `ubuntu` in `/etc/os-release`'s `ID`/`ID_LIKE` → `Debian`;
anything else → refuse) and `os_exec` (dispatch, with a friendly error when an
OS folder lacks that script).

Always invoke the root wrappers — `./install.sh`, not `MacOs/install.sh` — so
the same commands work unchanged on every platform. Unsupported systems exit
with a clear message instead of half-running.

## Shared design principles

- **One question at a time** — every destructive or installing action is an
  individual y/n prompt; nothing happens silently.
- **Never a question with one possible answer** — a single valid option is
  announced and used, not asked about.
- **Dependency order** — installers go foundation-first, removers go
  most-dependent-first; each step verifies what earlier steps established.
- **Hard gates over warnings** — not enough disk or RAM blocks the flow
  (re-check loop / non-zero exit), it doesn't just print a caveat.
- **Measured, not estimated** — disk gains come from `df` before/after, memory
  from live process and kernel counters, listening ports from `lsof`, tokens per
  second from the engine's own usage figures.
- **Protect the expensive and the personal** — model blobs, `~/MyDocker*`,
  agent configs and keychain logins are separated from the things being removed,
  with keep-recommendations where re-acquiring is costly.
- **Safe to re-run** — completed steps are detected and skipped, so every script
  doubles as its own status checker.

These are stated formally, with the reasoning, as the nine invariants in
[SPECIFICATION.md](SPECIFICATION.md#invariants).
