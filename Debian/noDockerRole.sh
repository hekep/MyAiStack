#!/bin/bash
#
# noDockerRole.sh — full Docker purge for Debian/Ubuntu ("reg cleaner" style)
#
# Goal: machine ends up Docker-free, as if Docker was never installed.
# PROTECTED: ~/MyDocker* (your own files) are NEVER touched by this script —
# including when they are bind mounts onto another disk, which is exactly how
# they are easiest to destroy by accident.
#
# Interactive: asks before EVERY removal step, one question at a time,
# ordered from most RAW (big, coarse cuts) to most SURGICAL (fine traces):
#
#   1. Stop everything Docker that is running    (prerequisite)
#   2. Engine data /var/lib/docker + containerd  (images, containers, volumes)
#   3. Docker Desktop VM data ~/.docker/desktop  (mount-aware)
#   4. Docker Desktop application /opt/docker-desktop
#   5. Packages: apt, then snap                  (asked per package)
#   6. The apt repository and its keyring
#   7. systemd units, /etc/docker, sockets, stray binaries
#   8. User config ~/.docker and rootless data
#   9. The 'docker' group
#  10. Stored registry credentials               (most surgical)
#  11. Final trace scan                          (verify nothing remains)
#
# Three things differ from the macOS purge, all of them Linux facts:
#   * Docker here is packages, not an app bundle — apt has to remove it, and
#     the repository that would reinstall it has to go too.
#   * The heavy directories live on system paths (/var/lib/docker) that may sit
#     on a different filesystem from $HOME, so disk gain is measured per path.
#   * Docker Desktop's VM disk is often a bind mount onto another disk. Deleting
#     through a live mount is the wrong operation; this unmounts first.
#
set -u

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

# Print a progress heading ("==> ...").
# All narration goes through these four helpers so colour handling and
# stream choice stay in one place.
info()  { echo "${BLUE}==>${RESET} $*"; }
# Print a success line (green check).
# Used for both "did it" and "already true", since a re-run should read the
# same whether the work happened now or earlier.
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
# Print a caution line (yellow !) — something worth reading, not a failure.
# Also used for "skipped by your choice", so the transcript records decisions.
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
# Print an error line (red x).
# Only for things that did not work; a declined question is a warn, not a fail.
fail()  { echo "${RED} ✗ ${RESET} $*"; }

# Print a usage message for a function called without its arguments, return 2.
# Args: <signature> [detail lines...]. Anything here can be called standalone
# from a shell, so a bare call must explain itself rather than misbehave.
aiStackUsage() {
    local sig="$1"; shift
    # fail() exists in the wizard scripts but not in every file that needs this
    if command -v fail >/dev/null 2>&1; then fail "usage: ${sig}"
    else echo "✗ usage: ${sig}" >&2; fi
    local l
    for l in "$@"; do echo "         ${l}" >&2; done
    return 2
}

# Ask a yes/no question on the terminal and loop until the answer is clear.
# Reads from /dev/tty, so it still works when stdout is piped to a file.
# Returns 0 for yes, 1 for no. There is no default: every removal in this
# script is deliberate, so Enter alone is not accepted as consent.
ask() {
    if [ $# -lt 1 ]; then
        aiStackUsage "ask <question>" "no default — every step here deletes something" "example : ask \"Delete the VM disk?\""
        return 2
    fi
    local answer
    while true; do
        printf "\n%s%s%s [y/n] " "${BOLD}" "$1" "${RESET}"
        read -r answer </dev/tty || { echo; fail "No interactive terminal — aborting."; exit 1; }
        case "$answer" in
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Run one privileged command; most of this script needs root.
# Fails with the command named rather than a bare "permission denied".
_asRoot() {
    if [ "$(id -u)" = "0" ]; then "$@"; return $?; fi
    command -v sudo >/dev/null 2>&1 || { fail "sudo is required for: $*"; return 1; }
    sudo "$@"
}

# Human-readable size of a file or directory ('du -sh'), e.g. "89G".
# Args: <path>. Prints an empty string when the path does not exist, so it is
# safe to interpolate straight into a prompt. Falls back to sudo for root-owned
# trees like /var/lib/docker, where an unprivileged du would report nothing.
sizeof() {
    [ $# -ge 1 ] || { aiStackUsage "sizeof <path>" "example : sizeof /var/lib/docker"; return 2; }
    [ -e "$1" ] || return 0
    local s
    s=$(du -sh "$1" 2>/dev/null | cut -f1)
    if [ -z "$s" ] || [ "$s" = "0" ]; then
        s=$(_asRoot du -sh "$1" 2>/dev/null | cut -f1)
    fi
    echo "$s"
}

# ---------- disk-gain reporting ----------------------------------------------
# Measured with df, per path. On macOS one data volume answers for everything;
# on Linux /var/lib/docker, ~/.docker and a bind-mounted VM disk can all be on
# different filesystems, so "space gained" is only meaningful against the
# filesystem the thing being removed actually lived on.

# Free space in KB on the filesystem holding a path. Args: [path] (default /).
free_kb() { df -k --output=avail "${1:-/}" 2>/dev/null | awk 'NR==2 {print $1}'; }
# Free space on that filesystem, human-readable. Display only.
free_h()  { df -h --output=avail "${1:-/}" 2>/dev/null | awk 'NR==2 {print $1}'; }
START_KB_ROOT=$(free_kb /)
START_KB_HOME=$(free_kb "$HOME")

# Report how much disk a step actually freed, on the right filesystem.
# Args: <free_kb before the step> [path the step touched]. Measured from df on
# purpose: du estimates lie when files are still open, and a deleted file held
# by a running daemon frees nothing until the daemon exits.
gain() {
    if [ $# -lt 1 ]; then
        aiStackUsage "gain <free-kb-before> [path]" 'example : b=$(free_kb /var); rm -rf x; gain "$b" /var'
        return 2
    fi
    local path="${2:-/}"
    local d=$(( $(free_kb "$path") - $1 ))
    [ "$d" -lt 0 ] && d=0
    if [ "$d" -ge 1048576 ]; then
        ok "Space gained: $(awk -v k="$d" 'BEGIN{printf "%.1f GB", k/1048576}')  (free now on $(df --output=target "$path" 2>/dev/null | tail -1): $(free_h "$path"))"
    elif [ "$d" -ge 1024 ]; then
        ok "Space gained: $(( d / 1024 )) MB  (free now: $(free_h "$path"))"
    else
        ok "Space gained: negligible (<1 MB)  (free now: $(free_h "$path"))"
    fi
}

# ---------- mount awareness ---------------------------------------------------
# Docker Desktop's VM disk is routinely a bind mount onto a second disk, and so
# are people's own container directories. Deleting *through* a live mount empties
# the backing filesystem while leaving the mount and its fstab entry behind —
# the worst of both outcomes. Everything below asks findmnt first.

# The device or bind source backing an exact mountpoint, empty when the path is
# not itself a mountpoint. Args: <path>.
mountSourceOf() { findmnt -n -o SOURCE --mountpoint "$1" 2>/dev/null; }
# True when a path is an exact mountpoint. Args: <path>.
isMountpoint()  { mountpoint -q "$1" 2>/dev/null; }

# True when a path is one of the protected user directories, or lives inside
# one. Args: <path>. Every deletion and every trace scan consults this, so the
# rule is stated once and cannot be forgotten in one branch.
isProtected() {
    local p="${1:-}" q
    case "$p" in
        "$HOME"/MyDocker*) return 0 ;;
    esac
    # also protect anything bind-mounted FROM the same source as a protected
    # directory — a second mountpoint onto /srv/mydockers is still your data
    for q in "$HOME"/MyDocker*; do
        [ -d "$q" ] || continue
        isMountpoint "$q" || continue
        [ "$(mountSourceOf "$q")" = "$(mountSourceOf "$p")" ] && [ -n "$(mountSourceOf "$p")" ] && return 0
    done
    return 1
}

# Remove a directory that may be a live mountpoint, correctly.
# Args: <path> <label>. Unmounts first when needed, deletes the real backing
# directory rather than writing through the mount, and offers to take the fstab
# line out so the mount does not come back on the next boot. Refuses outright on
# anything isProtected() claims.
removeMaybeMounted() {
    if [ $# -lt 2 ]; then
        aiStackUsage "removeMaybeMounted <path> <label>" "example : removeMaybeMounted ~/.docker/desktop \"Docker Desktop VM data\""
        return 2
    fi
    local path="$1" label="$2" src before target
    if isProtected "$path"; then
        warn "PROTECTED — refusing to touch ${path}."
        return 1
    fi
    [ -e "$path" ] || { ok "${label}: not present."; return 0; }

    # find any mountpoints at or under this path, deepest first
    local mounts=()
    # prefix match on a path BOUNDARY: "/x/desktop" must not also claim
    # "/x/desktop-backup", which a plain string prefix would
    while IFS= read -r m; do [ -n "$m" ] && mounts+=("$m"); done < <(
        findmnt -rn -o TARGET 2>/dev/null \
        | awk -v p="$path" '$0 == p || index($0, p "/") == 1' | sort -r)

    if [ "${#mounts[@]}" -gt 0 ]; then
        warn "${label} contains ${#mounts[@]} live mount(s):"
        for m in "${mounts[@]}"; do
            printf "      %-52s <- %s\n" "$m" "$(mountSourceOf "$m")"
        done
        warn "Deleting through a live mount empties the OTHER disk and leaves the mount behind."
        if ! ask "Unmount them first (required to remove ${label} properly)?"; then
            warn "Skipping ${label} — it cannot be removed safely while mounted."
            return 1
        fi
        for m in "${mounts[@]}"; do
            if isProtected "$m"; then warn "PROTECTED — leaving ${m} mounted."; continue; fi
            _asRoot umount "$m" 2>/dev/null && ok "Unmounted ${m}" || fail "Could not unmount ${m} (in use?)"
        done
        # the backing directories are now the thing that holds the data
        for m in "${mounts[@]}"; do
            src=$(printf '%s' "$(mountSourceOf "$m")")
            [ -z "$src" ] && continue
            # a bind mount reports "device[/sub/path]"; the sub-path is the dir
            case "$src" in
                *\[/*\])
                    target=$(printf '%s' "$src" | sed 's/.*\[\(.*\)\]/\1/')
                    warn "Its data lives in the bind source ${target} (relative to that filesystem's root)." ;;
            esac
        done
        if grep -q "$path" /etc/fstab 2>/dev/null; then
            warn "/etc/fstab still mounts it at boot:"
            grep -n "$path" /etc/fstab | sed 's/^/      /'
            if ask "Comment out those fstab line(s)?"; then
                _asRoot cp /etc/fstab /etc/fstab.noDockerRole.bak
                _asRoot sed -i "\|${path}|s|^|# removed by noDockerRole.sh: |" /etc/fstab
                _asRoot systemctl daemon-reload >/dev/null 2>&1
                ok "fstab updated (backup: /etc/fstab.noDockerRole.bak)."
            fi
        fi
    fi

    before=$(free_kb "$path")
    if ask "Delete ${label} — ${path} ($(sizeof "$path"))?"; then
        rm -rf "$path" 2>/dev/null || _asRoot rm -rf "$path"
        [ -e "$path" ] && { fail "Could not remove ${path}."; return 1; }
        ok "${label} deleted."
        gain "$before" "$(dirname "$path")"
    else
        ok "Keeping ${label}."
    fi
}

echo "${BOLD}=============================================================${RESET}"
echo "${BOLD} noDockerRole — remove every trace of Docker from this system${RESET}"
echo "${BOLD} Protected and never touched: ${HOME}/MyDocker*${RESET}"
echo "${BOLD}=============================================================${RESET}"
for p in "$HOME"/MyDocker*; do
    [ -e "$p" ] || continue
    if isMountpoint "$p"; then
        ok "Protected: $p  (bind mount from $(mountSourceOf "$p") — left mounted and untouched)"
    else
        ok "Protected: $p"
    fi
done

# ---------- Step 1: stop everything Docker (prerequisite for all removals) ---
info "Step 1/11 — Stop all running Docker components"
DOCKER_RUNNING=0
systemctl is-active --quiet docker.service 2>/dev/null && DOCKER_RUNNING=1
systemctl is-active --quiet containerd.service 2>/dev/null && DOCKER_RUNNING=1
systemctl --user is-active --quiet docker-desktop.service 2>/dev/null && DOCKER_RUNNING=1
pgrep -f "com.docker|dockerd|docker-desktop" >/dev/null 2>&1 && DOCKER_RUNNING=1
if [ "$DOCKER_RUNNING" -eq 1 ]; then
    warn "Docker is running:"
    systemctl is-active docker.service   >/dev/null 2>&1 && echo "      docker.service      active"
    systemctl is-active docker.socket    >/dev/null 2>&1 && echo "      docker.socket       active"
    systemctl is-active containerd.service >/dev/null 2>&1 && echo "      containerd.service  active"
    systemctl --user is-active docker-desktop.service >/dev/null 2>&1 && echo "      docker-desktop.service (user) active"
    pgrep -alf "dockerd|com.docker|docker-desktop" 2>/dev/null | sed 's/^/      /' | head -6
    if ask "Stop Docker Desktop, the daemon and containerd?"; then
        systemctl --user stop docker-desktop.service 2>/dev/null || true
        systemctl --user stop docker.service docker.socket 2>/dev/null || true   # rootless
        _asRoot systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
        sleep 3
        pkill -f "com.docker|docker-desktop" 2>/dev/null || true
        sleep 2
        if pgrep -f "dockerd|com.docker" >/dev/null 2>&1; then
            warn "Some processes survived — forcing."
            pkill -9 -f "dockerd|com.docker|docker-desktop" 2>/dev/null || true
            sleep 1
        fi
        pgrep -f "dockerd|com.docker" >/dev/null 2>&1 && fail "Docker processes still running — later steps may fail." \
                                                      || ok "All Docker processes stopped."
    else
        warn "Skipping. Removing files under a running Docker may fail or leave stale state."
    fi
else
    ok "No Docker processes running."
fi

# ---------- Step 2: engine data (rawest, biggest cut for docker-ce) ----------
info "Step 2/11 — Docker engine data (images, containers, volumes)"
for D in /var/lib/docker /var/lib/containerd; do
    if [ -d "$D" ]; then
        warn "${D} — $(sizeof "$D"). Unrecoverable once deleted."
        warn "(Your ~/MyDocker* files are separate and safe.)"
        if ask "Delete ${D}?"; then
            B=$(free_kb "$D")
            _asRoot rm -rf "$D" && { ok "${D} deleted."; gain "$B" /var; } || fail "Deletion failed."
        else
            ok "Keeping ${D}."
        fi
    else
        ok "${D} not present."
    fi
done

# ---------- Step 3: Docker Desktop VM data (mount-aware) ---------------------
info "Step 3/11 — Docker Desktop VM data (~/.docker/desktop)"
removeMaybeMounted "$HOME/.docker/desktop" "Docker Desktop VM data" || true

# ---------- Step 4: the Docker Desktop application ---------------------------
info "Step 4/11 — Docker Desktop application"
if [ -d /opt/docker-desktop ]; then
    warn "/opt/docker-desktop — $(sizeof /opt/docker-desktop)"
    warn "It is owned by the docker-desktop package; step 5 removes both together."
    ok "Left to the package removal below (deleting it by hand would confuse apt)."
else
    ok "/opt/docker-desktop not present."
fi
DESKTOP_ENTRIES=$(ls /usr/share/applications/docker-desktop*.desktop \
                     "$HOME/.local/share/applications"/docker*.desktop 2>/dev/null)
[ -n "$DESKTOP_ENTRIES" ] && { echo "    Desktop launcher entries (removed with the package):"; echo "$DESKTOP_ENTRIES" | sed 's/^/      /'; }

# ---------- Step 5: packages (apt, then snap) --------------------------------
info "Step 5/11 — Docker packages"
APT_PKGS=$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null \
           | awk '$1=="installed" {print $2}' \
           | grep -xE 'docker-ce|docker-ce-cli|docker-ce-rootless-extras|containerd\.io|docker-buildx-plugin|docker-compose-plugin|docker-desktop|docker\.io|docker-compose|docker-doc|podman-docker' || true)
if [ -n "$APT_PKGS" ]; then
    echo "    Installed Docker packages:"
    echo "$APT_PKGS" | sed 's/^/      /'
    warn "Removing docker-ce also removes /opt/docker-desktop if docker-desktop is in the list."
    if ask "Purge all $(echo "$APT_PKGS" | wc -l) package(s) with apt?"; then
        B=$(free_kb /usr)
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive _asRoot apt-get purge -y $(echo "$APT_PKGS" | tr '\n' ' ') \
            && ok "Packages purged." || fail "apt-get purge failed."
        DEBIAN_FRONTEND=noninteractive _asRoot apt-get autoremove -y >/dev/null 2>&1
        gain "$B" /usr
    else
        ok "Keeping the packages."
    fi
else
    ok "No Docker packages installed via apt."
fi
if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
    warn "Docker is ALSO installed as a snap."
    if ask "snap remove docker?"; then
        B=$(free_kb /var)
        _asRoot snap remove docker && { ok "Snap removed."; gain "$B" /var; } || fail "snap remove failed."
    else
        ok "Keeping the snap."
    fi
fi

# ---------- Step 6: the apt repository ---------------------------------------
info "Step 6/11 — Docker's apt repository and signing key"
REPO_FILES=()
for f in /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker*.sources \
         /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.asc \
         /etc/apt/trusted.gpg.d/docker.gpg; do
    [ -e "$f" ] && REPO_FILES+=("$f")
done
if [ "${#REPO_FILES[@]}" -gt 0 ]; then
    echo "    Docker would be reinstallable (and re-offered by 'apt upgrade') from:"
    printf '      %s\n' "${REPO_FILES[@]}"
    if ask "Remove the repository definition and its key (${#REPO_FILES[@]} file(s))?"; then
        for f in "${REPO_FILES[@]}"; do
            _asRoot rm -f "$f" && ok "Removed $f" || fail "Could not remove $f"
        done
        _asRoot apt-get update -qq >/dev/null 2>&1 || true
        ok "Package lists refreshed."
    else
        ok "Keeping the repository — Docker stays one 'apt install' away."
    fi
else
    ok "No Docker apt repository configured."
fi

# ---------- Step 7: system-level leftovers -----------------------------------
info "Step 7/11 — systemd units, /etc/docker, sockets, stray binaries"
SYS_ITEMS=()
for f in /etc/systemd/system/docker.service /etc/systemd/system/docker.socket \
         /etc/systemd/system/docker.service.d /etc/systemd/system/containerd.service.d \
         /lib/systemd/system/docker.service /lib/systemd/system/docker.socket \
         /etc/docker /var/run/docker.sock /run/docker.sock \
         /usr/local/bin/docker /usr/local/bin/docker-compose /usr/local/bin/docker-credential-secretservice \
         /usr/local/lib/docker /etc/default/docker; do
    { [ -e "$f" ] || [ -L "$f" ]; } && SYS_ITEMS+=("$f")
done
if [ "${#SYS_ITEMS[@]}" -gt 0 ]; then
    echo "    Found system-level Docker leftovers:"
    for t in "${SYS_ITEMS[@]}"; do printf "      %-8s %s\n" "$(sizeof "$t")" "$t"; done
    if ask "Remove these ${#SYS_ITEMS[@]} item(s) (sudo)?"; then
        B=$(free_kb /)
        for f in "${SYS_ITEMS[@]}"; do
            _asRoot rm -rf "$f" && ok "Removed $f" || fail "Could not remove $f"
        done
        _asRoot systemctl daemon-reload >/dev/null 2>&1
        gain "$B" /
    else
        ok "Keeping system-level items."
    fi
else
    ok "No system-level Docker leftovers found."
fi

# ---------- Step 8: user config and rootless data ----------------------------
info "Step 8/11 — User Docker data (~/.docker, rootless store)"
if [ -d "$HOME/.docker" ]; then
    warn "~/.docker holds CLI config, contexts, cli-plugins and registry login references ($(sizeof "$HOME/.docker"))."
    if ask "Delete ~/.docker ($(sizeof "$HOME/.docker"))?"; then
        B=$(free_kb "$HOME")
        rm -rf "$HOME/.docker" && { ok "~/.docker deleted."; gain "$B" "$HOME"; } || fail "Deletion failed."
    else
        ok "Keeping ~/.docker."
    fi
else
    ok "~/.docker not present."
fi
for d in "$HOME/.local/share/docker" "$HOME/.config/docker" "$HOME/.cache/docker" \
         "$HOME/.local/share/containers"; do
    [ -d "$d" ] || continue
    if ask "Delete ${d} ($(sizeof "$d"))?"; then
        B=$(free_kb "$HOME")
        rm -rf "$d" && { ok "${d} deleted."; gain "$B" "$HOME"; } || fail "Deletion failed."
    else
        ok "Keeping ${d}."
    fi
done

# ---------- Step 9: the docker group -----------------------------------------
info "Step 9/11 — The 'docker' group"
if getent group docker >/dev/null 2>&1; then
    warn "Group 'docker' exists, members: $(getent group docker | cut -d: -f4)"
    warn "Membership in it is effectively root access to the machine, so on a"
    warn "Docker-free system it is a privilege with nothing behind it."
    if ask "Remove the 'docker' group?"; then
        _asRoot groupdel docker && ok "Group removed." || fail "groupdel failed (a process may still hold it)."
    else
        ok "Keeping the group."
    fi
else
    ok "No 'docker' group."
fi

# ---------- Step 10: stored registry credentials (most surgical) -------------
info "Step 10/11 — Stored registry credentials"
KC_HITS=""
if command -v secret-tool >/dev/null 2>&1; then
    KC_HITS=$(secret-tool search --all server https://index.docker.io/v1/ 2>/dev/null | head -20)
fi
if [ -n "$KC_HITS" ]; then
    echo "    Secret-service entries referencing Docker Hub:"
    echo "$KC_HITS" | sed 's/^/      /'
    warn "These take no disk space. KEEPING them is reasonable: you avoid re-entering"
    warn "registry logins if you ever reinstall. Delete only for a zero-trace machine."
    if ask "Delete these credential entries anyway (frees no space)?"; then
        secret-tool clear server https://index.docker.io/v1/ 2>/dev/null \
            && ok "Credential entries cleared." \
            || warn "Could not clear them — remove them in Seahorse / your keyring app."
    else
        ok "Keeping the credential entries."
    fi
elif command -v secret-tool >/dev/null 2>&1; then
    ok "No Docker credentials in the secret service."
else
    ok "secret-tool not installed — nothing to check (credentials, if any, were in ~/.docker/config.json)."
fi

# ---------- Step 11: final trace scan ----------------------------------------
info "Step 11/11 — Final trace scan"
echo "    Scanning known locations for anything docker-named (excluding ~/MyDocker*)..."
LEFT=$( { ls -d /var/lib/docker /var/lib/containerd /etc/docker /opt/docker-desktop \
               /var/run/docker.sock "$HOME/.docker" 2>/dev/null;
          ls -d /etc/apt/sources.list.d/docker* /etc/apt/keyrings/docker* 2>/dev/null;
          ls -d /etc/systemd/system/docker* /lib/systemd/system/docker* 2>/dev/null;
          find "$HOME/.config" "$HOME/.local/share" "$HOME/.cache" -maxdepth 2 -iname "*docker*" 2>/dev/null;
          command -v docker 2>/dev/null;
          command -v dockerd 2>/dev/null;
        } | grep -v "^${HOME}/MyDocker" | sort -u )
if [ -z "$LEFT" ]; then
    ok "CLEAN — no Docker traces found. Machine is Docker-free."
else
    warn "Remaining items (kept by your choices above, or need manual review):"
    echo "$LEFT" | sed 's/^/      /'
fi

echo
echo "${BOLD}================= Space summary =================${RESET}"
for fs_label in "/:${START_KB_ROOT}" "${HOME}:${START_KB_HOME}"; do
    fs_path=${fs_label%%:*}; fs_start=${fs_label##*:}
    d=$(( $(free_kb "$fs_path") - fs_start ))
    [ "$d" -lt 0 ] && d=0
    if [ "$d" -ge 1048576 ]; then
        ok "$(df --output=target "$fs_path" 2>/dev/null | tail -1): gained $(awk -v k="$d" 'BEGIN{printf "%.1f GB", k/1048576}')  (free now: $(free_h "$fs_path"))"
    else
        ok "$(df --output=target "$fs_path" 2>/dev/null | tail -1): gained $(( d / 1024 )) MB  (free now: $(free_h "$fs_path"))"
    fi
done
warn "A bind-mounted VM disk on another filesystem is not counted above — its"
warn "space came back on whatever disk it lived on, reported at the step itself."

echo
echo "${BOLD}Done.${RESET} Protected user files:"
for p in "$HOME"/MyDocker*; do [ -e "$p" ] && echo "    $p ($(sizeof "$p"))"; done
command -v docker >/dev/null 2>&1 && warn "'docker' still resolves: $(command -v docker)" || ok "'docker' command no longer exists."
