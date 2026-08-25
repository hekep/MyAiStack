# noDockerRole.sh — full Docker purge for Debian/Ubuntu

## What it does

Removes every trace of Docker from a Debian or Ubuntu machine — as if it was
never installed — while **explicitly protecting your own files** (`~/MyDocker*`:
`MyDockers`, `MyDockersScripts`). Asks before **every** removal, ordered from
the most *raw* cuts (running services, the image store, the VM disk) down to
the most *surgical* traces (systemd drop-ins, the `docker` group, keyring
entries), and reports **how much disk space each confirmed step actually
freed**.

Run it through the dispatcher:

```bash
./noRole.sh Docker      # case-insensitive
```

## How it works

| Step | What | Typical size |
|---|---|---|
| 1 | Stop everything: `docker-desktop.service` (user), `docker.socket`, `docker.service`, `containerd.service`, rootless units, then `pkill` survivors | — |
| 2 | `/var/lib/docker` + `/var/lib/containerd` — ALL images, containers, volumes (sudo) | **tens of GB** |
| 3 | Docker Desktop VM data `~/.docker/desktop` — **mount-aware**, see below | **tens of GB** |
| 4 | Docker Desktop application `/opt/docker-desktop` — reported, then left to the package removal, since deleting a package's files by hand confuses apt | ~1.3 GB |
| 5 | Packages: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, `docker-ce-rootless-extras`, `docker-desktop`, `docker.io`, … purged together; then the `docker` snap if present | varies |
| 6 | **The apt repository and its signing key** — `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.{gpg,asc}` | 0 bytes |
| 7 | systemd units and drop-ins, `/etc/docker`, `/var/run/docker.sock`, stray `/usr/local/bin` binaries | small |
| 8 | User data: `~/.docker`, rootless `~/.local/share/docker`, `~/.config/docker`, `~/.cache/docker` | varies |
| 9 | The **`docker` group** — membership is effectively root on the machine, so on a Docker-free system it is a privilege with nothing behind it | 0 bytes |
| 10 | Stored registry credentials via `secret-tool` — **recommended KEEP**: they free no space and keeping them avoids re-entering registry logins on a future reinstall | 0 bytes |
| 11 | **Final trace scan** — sweeps all known locations plus the XDG directories, excluding `~/MyDocker*`, and declares the machine clean or lists what remains | — |

## The three things that differ from the macOS purge

macOS Docker Desktop hides in five ownership domains: the app bundle, root
LaunchDaemons, root symlinks, per-user Library data, and the keychain. Debian
Docker is **packages**, and that changes the shape of the job.

### 1. The repository has to go, or Docker comes back

Removing the packages is not enough: `/etc/apt/sources.list.d/docker.list`
keeps Docker one `apt install` away, and `apt upgrade` will keep offering it.
Step 6 removes the list file and the keyring, then refreshes the package lists.
macOS has no analogue — a deleted `.app` does not reinstall itself.

Declining is respected and stated plainly: *"Keeping the repository — Docker
stays one 'apt install' away."*

### 2. The VM disk is usually a bind mount

This is a real hazard, not a hypothetical. On the machine this port was
developed against, `~/.docker/desktop/vms/0/data` is **89 GB bind-mounted from
another NVMe partition**, with an `/etc/fstab` entry — and `~/MyDockers` is
bind-mounted the same way.

`rm -rf` through a live mount empties the *other* filesystem and leaves the
mount and its fstab line behind: the worst of both outcomes. So
`removeMaybeMounted()`:

1. asks `findmnt` for every mountpoint at or under the path (boundary-matched,
   so `/x/desktop` never claims `/x/desktop-backup`);
2. lists each one with the device or bind source it comes from;
3. refuses outright on anything `isProtected()` claims;
4. unmounts the rest, only with consent;
5. offers to **comment out the matching `/etc/fstab` lines**, backing the file
   up to `/etc/fstab.noDockerRole.bak` first, so the mount does not return on
   the next boot;
6. only then deletes.

`isProtected()` covers `~/MyDocker*` **and** anything bind-mounted from the same
source as a protected directory — because a protected directory that is a
mountpoint is precisely the easiest thing to destroy by accident.

### 3. Disk gain is per-filesystem

macOS reads one data volume and is done. Here `/`, `$HOME`, `/var/lib/docker`
and a bind-mounted VM disk can each live on a different filesystem, so
`free_kb`/`gain()` take a path and report against the filesystem the removed
thing actually lived on. The closing summary reports `/` and `$HOME`
separately, and says plainly that a bind-mounted VM disk on a third filesystem
was counted at its own step rather than in the total — a single "space gained"
number would be a fiction.

`sizeof()` also retries under `sudo` for root-owned trees like
`/var/lib/docker`, where an unprivileged `du` silently reports nothing.

## Why it is necessary

- Docker on Debian scatters itself across **package data, system state, user
  state and the apt configuration**. `apt remove docker-ce` removes exactly one
  of them — `/var/lib/docker`, `/etc/docker`, `~/.docker`, the repository, the
  group and any Desktop VM disk all stay behind.
- The protected-files rule (`~/MyDocker*`, mount-aware) and the keep
  recommendation on credentials encode the difference between *Docker's* data
  and *your* data — the part a generic cleaner gets wrong, and the part that on
  Linux is easiest to get catastrophically wrong because of bind mounts.

## Usage

```bash
./noRole.sh Docker
```

Most steps prompt for the sudo password (system directories, packages, systemd
units, the group).
