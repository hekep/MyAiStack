# noDockerRole.sh — full Docker purge ("reg cleaner" style)

## What it does

Removes every trace of Docker Desktop from the Mac — as if it was never
installed — while **explicitly protecting your own files** (`~/MyDocker*`:
`MyDockers`, `MyDockersScripts`). Asks before **every** removal, ordered from
the most *raw* cuts (running processes, the 33 GB VM disk, the app) down to
the most *surgical* traces (symlinks, plists, keychain entries), and reports
**how much disk space each confirmed step actually freed**.

## How it works

| Step | What | Typical size |
|---|---|---|
| 1 | Stop everything: quit the app, boot out root LaunchDaemons (`vmnetd`, `socket`), `pkill` survivors | — |
| 2 | VM data disk `~/Library/Containers/com.docker.docker` — ALL images, containers, volumes | **~33 GB** |
| 3 | `/Applications/Docker.app` | ~2 GB |
| 4 | Root-level components (sudo): LaunchDaemon plists, PrivilegedHelperTools, `/var/run/docker.sock` | small |
| 5 | CLI symlinks in `/usr/local/bin` — only links that resolve *into Docker.app* (docker, compose, credential helpers, hub-tool, kubectl…). Warns that `kubectl` is Docker's copy (`brew install kubernetes-cli` to replace). | 0 bytes |
| 6 | `~/.docker` — CLI config, contexts, cli-plugins | ~23 MB |
| 7 | Remaining user-library traces: Group Containers, App Support, caches, prefs, logs, cookies, saved state | ~360 MB |
| 8 | Docker-related brew packages (found: `lazydocker`), asked per package | small |
| 9 | Keychain entries — **recommended KEEP**: they free no space and keeping them avoids re-entering registry logins on a future reinstall. Question is phrased "delete anyway (frees no space)?" | 0 bytes |
| 10 | **Final trace scan** — sweeps all known locations plus `find ~/Library -iname "*docker*"`, excluding `~/MyDocker*`, and declares the machine clean or lists what remains | — |

Space reporting: free disk is snapshotted (`df`) at start and before each
step; after each "yes" the script prints *actual* gained space ("Space gained:
33.2 GB (free now: 36G)") and a run total at the end — measured reality, not
`du` estimates.

## Why it is necessary

- Docker Desktop scatters itself across **five ownership domains**: the app,
  root-owned daemons/helpers, root-owned symlinks, per-user Library data, and
  the keychain. Dragging Docker.app to the Trash removes exactly one of them —
  the other four (including the 33 GB VM disk) stay behind forever.
- On this machine Docker was the single biggest disk consumer and the main
  blocker for install.sh's 25 GB gate; running this script took free space
  from 3 GB to ~50 GB.
- The protected-files rule (`~/MyDocker*`) and the keep-recommendation on
  keychain entries encode the difference between *Docker's* data and *your*
  data — the part a generic "cleaner" app gets wrong.

## Usage

```bash
./noDockerRole.sh
```

Steps 1, 4, 5 prompt for the sudo password (root-owned daemons and symlinks).
