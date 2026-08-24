# noRole.sh — one dispatcher for the purge scripts

## What it does

Removes a whole piece of software and everything it left behind — Docker,
Codex, or whatever `no<Role>Role.sh` scripts the OS folder grows next. One
entry point instead of one command per role:

```bash
./noRole.sh Docker      # run a specific role (case-insensitive)
./noRole.sh codex       # same thing
./noRole.sh             # offer every available role, y/N each
```

## How it works

1. Detects the OS folder through [common.sh](../common.sh), so the same command
   works on macOS today and Debian once that folder is populated.
2. **Discovers** the roles rather than hardcoding them: it globs
   `<OsFolder>/no*Role.sh` and takes the middle of each filename. Drop a
   `noSlackRole.sh` into `MacOs/` and it appears automatically, here and in the
   no-argument menu, with no change to this script.
3. **With an argument** it matches case-insensitively and `exec`s that role's
   script, forwarding any further arguments. An unknown role is not guessed at
   — it lists what is actually available and exits 1:

   ```
   ✗ Unknown role 'kubernetes'. Available roles for MacOs:
       Codex
       Docker
   ```
4. **With no argument** it walks every discovered role asking
   `Run noDockerRole.sh — remove everything Docker-related? [y/N]`, running the
   ones you accept to completion before moving on. The default is **No**: these
   scripts delete things.

## Why it is necessary

- **The roles are data, not code.** Hardcoding a list means the dispatcher and
  the folder drift apart; discovery means they cannot.
- **One name to remember.** `./noRole.sh Docker` instead of remembering whether
  the file is `noDockerRole.sh`, `no-docker.sh` or `dockerPurge.sh`.
- **Refusing beats guessing.** An unrecognised role could plausibly be a typo
  for a destructive script, so it lists and stops rather than picking the
  closest match.

## The roles themselves

| Role | Doc | What it removes |
|---|---|---|
| `Docker` | [noDockerRole.sh.md](noDockerRole.sh.md) | Docker Desktop across all five places it hides: app, VM disk, root daemons, symlinks, library traces, keychain — protecting `~/MyDocker*` |
| `Codex` | [noCodexRole.sh.md](noCodexRole.sh.md) | OpenAI Codex and its leftovers, while guaranteeing ChatGPT survives |

Each asks before every step, in raw→surgical order, and reports the disk space
actually recovered.
