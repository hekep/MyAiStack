#!/bin/bash
#
# noDockerRole.sh — full Docker purge for macOS ("reg cleaner" style)
#
# Goal: machine ends up Docker-free, as if Docker was never installed.
# PROTECTED: ~/MyDocker* (your own files) are NEVER touched by this script.
#
# Interactive: asks before EVERY removal step, one question at a time,
# ordered from most RAW (big, coarse cuts) to most SURGICAL (fine traces):
#
#   1. Stop everything Docker that is running        (prerequisite)
#   2. VM data disk  ~/Library/Containers/...        (~33 GB — the big one)
#   3. /Applications/Docker.app                      (the application)
#   4. System-level daemons & privileged helpers     (sudo)
#   5. CLI symlinks in /usr/local/bin                (sudo)
#   6. User config ~/.docker                         (contexts, cli-plugins)
#   7. Remaining user-library traces                 (prefs, caches, logs...)
#   8. Related brew tools (lazydocker)
#   9. Keychain entries                              (most surgical)
#  10. Final trace scan                              (verify nothing remains)
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

# Ask a yes/no question on the terminal and loop until the answer is clear.
# Reads from /dev/tty, so it still works when stdout is piped to a file.
# Returns 0 for yes, 1 for no. There is no default: every removal in this
# script is deliberate, so Enter alone is not accepted as consent.
ask() {
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

# Human-readable size of a file or directory ('du -sh'), e.g. "33G".
# Args: <path>. Prints an empty string when the path does not exist, so it is
# safe to interpolate straight into a prompt.
sizeof() { du -sh "$1" 2>/dev/null | cut -f1; }

# ---------- disk-gain reporting ----------------------------------------------
# Free space on the data volume in KB, as an integer.
# Used as the before/after probe for gain(): 'df' is the only source that
# reflects what macOS actually released, unlike a 'du' estimate.
free_kb() { df -k /System/Volumes/Data | awk 'NR==2 {print $4}'; }
# Free space on the data volume, human-readable (e.g. "114Gi").
# Display only — free_kb() is what the arithmetic uses.
free_h()  { df -h /System/Volumes/Data | awk 'NR==2 {print $4}'; }
START_KB=$(free_kb)

# Report how much disk a step actually freed.
# Args: <free_kb before the step>. Compares against free space now and prints
# GB, MB, or "negligible", plus the current free total.
# Measured from df on purpose: du estimates lie when files are still open.
gain() {
    local d=$(( $(free_kb) - $1 ))
    [ "$d" -lt 0 ] && d=0
    if [ "$d" -ge 1048576 ]; then
        ok "Space gained: $(awk -v k="$d" 'BEGIN{printf "%.1f GB", k/1048576}')  (free now: $(free_h))"
    elif [ "$d" -ge 1024 ]; then
        ok "Space gained: $(( d / 1024 )) MB  (free now: $(free_h))"
    else
        ok "Space gained: negligible (<1 MB)  (free now: $(free_h))"
    fi
}

echo "${BOLD}=============================================================${RESET}"
echo "${BOLD} noDockerRole — remove every trace of Docker from this Mac${RESET}"
echo "${BOLD} Protected and never touched: ${HOME}/MyDocker*${RESET}"
echo "${BOLD}=============================================================${RESET}"
for p in "$HOME"/MyDocker*; do
    [ -e "$p" ] && ok "Protected: $p"
done

# ---------- Step 1: stop everything Docker (prerequisite for all removals) ---
info "Step 1/10 — Stop all running Docker components"
if pgrep -if "docker" >/dev/null 2>&1; then
    warn "Docker processes are running:"
    pgrep -lif "com.docker|Docker.app" 2>/dev/null | sed 's/^/    /' | head -8
    if ask "Quit Docker Desktop and stop all Docker processes/daemons?"; then
        osascript -e 'quit app "Docker"' 2>/dev/null || true
        osascript -e 'quit app "Docker Desktop"' 2>/dev/null || true
        sleep 3
        # unload root LaunchDaemons (vmnetd, socket helper)
        for plist in /Library/LaunchDaemons/com.docker.*.plist; do
            [ -e "$plist" ] && sudo launchctl bootout system "$plist" 2>/dev/null
        done
        pkill -f "com.docker" 2>/dev/null || true
        sleep 2
        if pgrep -if "com.docker" >/dev/null 2>&1; then
            warn "Some processes survived — forcing."
            pkill -9 -f "com.docker" 2>/dev/null || true
            sleep 1
        fi
        pgrep -if "com.docker" >/dev/null 2>&1 && fail "Docker processes still running — later steps may fail." \
                                                || ok "All Docker processes stopped."
    else
        warn "Skipping. Removing files under a running Docker may fail or leave stale state."
    fi
else
    ok "No Docker processes running."
fi

# ---------- Step 2: the VM data disk (rawest, biggest cut) -------------------
info "Step 2/10 — Docker VM data (containers, images, volumes)"
DDATA="$HOME/Library/Containers/com.docker.docker"
if [ -d "$DDATA" ]; then
    warn "This holds ALL images, containers, and volumes: $(sizeof "$DDATA")"
    warn "Unrecoverable once deleted. (Your ~/MyDocker* files are separate and safe.)"
    if ask "Delete the Docker VM data ($(sizeof "$DDATA"))?"; then
        B=$(free_kb)
        rm -rf "$DDATA" && { ok "VM data deleted."; gain "$B"; } || fail "Deletion failed."
    else
        ok "Keeping VM data."
    fi
else
    ok "No VM data found."
fi

# ---------- Step 3: the application ------------------------------------------
info "Step 3/10 — Docker Desktop application"
if [ -d /Applications/Docker.app ]; then
    if ask "Delete /Applications/Docker.app ($(sizeof /Applications/Docker.app))?"; then
        B=$(free_kb)
        rm -rf /Applications/Docker.app 2>/dev/null || sudo rm -rf /Applications/Docker.app
        [ -d /Applications/Docker.app ] && fail "Could not remove Docker.app." || { ok "Docker.app deleted."; gain "$B"; }
    else
        ok "Keeping Docker.app."
    fi
else
    ok "Docker.app not present."
fi

# ---------- Step 4: system-level daemons & privileged helpers (sudo) ---------
info "Step 4/10 — System daemons and privileged helpers (requires sudo)"
SYS_ITEMS=()
for f in /Library/LaunchDaemons/com.docker.socket.plist \
         /Library/LaunchDaemons/com.docker.vmnetd.plist \
         /Library/PrivilegedHelperTools/com.docker.socket \
         /Library/PrivilegedHelperTools/com.docker.vmnetd \
         /var/run/docker.sock; do
    [ -e "$f" ] || [ -L "$f" ] && SYS_ITEMS+=("$f")
done
if [ ${#SYS_ITEMS[@]} -gt 0 ]; then
    echo "    Found root-level Docker components:"
    printf '      %s\n' "${SYS_ITEMS[@]}"
    if ask "Remove these system-level Docker components (sudo)?"; then
        B=$(free_kb)
        for f in "${SYS_ITEMS[@]}"; do
            sudo rm -f "$f" && ok "Removed $f" || fail "Could not remove $f"
        done
        gain "$B"
    else
        ok "Keeping system components."
    fi
else
    ok "No system-level Docker components found."
fi

# ---------- Step 5: CLI symlinks in /usr/local/bin (sudo) --------------------
info "Step 5/10 — Docker CLI symlinks in /usr/local/bin"
LINKS=()
for name in docker docker-compose docker-credential-desktop docker-credential-osxkeychain \
            docker-credential-ecr-login docker-index hub-tool cagent kubectl kubectl.docker \
            com.docker.cli; do
    p="/usr/local/bin/$name"
    if [ -L "$p" ]; then
        target=$(readlink "$p")
        case "$target" in
            *Docker.app*|*Docker/Docker.app*) LINKS+=("$p") ;;
        esac
    fi
done
if [ ${#LINKS[@]} -gt 0 ]; then
    echo "    Symlinks pointing into Docker.app:"
    printf '      %s\n' "${LINKS[@]}"
    for l in "${LINKS[@]}"; do
        case "$l" in *kubectl*) warn "Note: kubectl here is Docker's copy. If you use Kubernetes, reinstall later: brew install kubernetes-cli" ;; esac
    done
    if ask "Remove these ${#LINKS[@]} symlinks (sudo)?"; then
        B=$(free_kb)
        for l in "${LINKS[@]}"; do
            sudo rm -f "$l" && ok "Removed $l" || fail "Could not remove $l"
        done
        gain "$B"
    else
        ok "Keeping symlinks."
    fi
else
    ok "No Docker symlinks found in /usr/local/bin."
fi

# ---------- Step 6: user config ~/.docker ------------------------------------
info "Step 6/10 — User Docker config (~/.docker)"
if [ -d "$HOME/.docker" ]; then
    warn "Contains CLI config, contexts, cli-plugins, and possibly registry login references ($(sizeof "$HOME/.docker"))."
    if ask "Delete ~/.docker ($(sizeof "$HOME/.docker"))?"; then
        B=$(free_kb)
        rm -rf "$HOME/.docker" && { ok "~/.docker deleted."; gain "$B"; } || fail "Deletion failed."
    else
        ok "Keeping ~/.docker."
    fi
else
    ok "~/.docker not present."
fi

# ---------- Step 7: remaining user-library traces ----------------------------
info "Step 7/10 — Remaining user-library traces"
TRACES=()
for d in "$HOME/Library/Group Containers/group.com.docker" \
         "$HOME/Library/Application Support/Docker Desktop" \
         "$HOME/Library/Caches/com.docker.docker" \
         "$HOME/Library/Caches/com.docker.desktop" \
         "$HOME/Library/Logs/Docker Desktop" \
         "$HOME/Library/HTTPStorages/com.docker.docker" \
         "$HOME/Library/Preferences/com.docker.docker.plist" \
         "$HOME/Library/Preferences/com.electron.docker-frontend.plist" \
         "$HOME/Library/Saved Application State/com.electron.docker-frontend.savedState" \
         "$HOME/Library/Saved Application State/com.electron.dockerdesktop.savedState" \
         "$HOME/Library/Cookies/com.docker.docker.binarycookies"; do
    [ -e "$d" ] && TRACES+=("$d")
done
if [ ${#TRACES[@]} -gt 0 ]; then
    echo "    Found leftover traces:"
    for t in "${TRACES[@]}"; do echo "      $(sizeof "$t")	$t"; done
    if ask "Remove all ${#TRACES[@]} leftover trace items?"; then
        B=$(free_kb)
        for t in "${TRACES[@]}"; do
            rm -rf "$t" && ok "Removed ${t#$HOME/}" || fail "Could not remove $t"
        done
        gain "$B"
    else
        ok "Keeping traces."
    fi
else
    ok "No user-library traces found."
fi

# ---------- Step 8: related brew tools ---------------------------------------
info "Step 8/10 — Docker-related Homebrew packages"
BREW_PKGS=$(brew list --formula 2>/dev/null | grep -iE '^(docker|docker-compose|docker-credential|lazydocker|ctop|dive)' ; brew list --cask 2>/dev/null | grep -iE '^docker')
if [ -n "$BREW_PKGS" ]; then
    echo "    Installed docker-related brew packages:"
    echo "$BREW_PKGS" | sed 's/^/      /'
    for pkg in $BREW_PKGS; do
        if ask "brew uninstall ${pkg}?"; then
            B=$(free_kb)
            brew uninstall "$pkg" && { ok "Removed $pkg."; gain "$B"; } || fail "Could not remove $pkg."
        else
            ok "Keeping $pkg."
        fi
    done
else
    ok "No docker-related brew packages."
fi

# ---------- Step 9: keychain entries (most surgical) -------------------------
info "Step 9/10 — Keychain entries (registry credentials)"
KC_HITS=$(security dump-keychain 2>/dev/null | grep -i 'docker' | grep '"svce"' | sed 's/.*"\([^"]*\)"$/\1/' | sort -u)
if [ -n "$KC_HITS" ]; then
    echo "    Keychain items referencing Docker:"
    echo "$KC_HITS" | sed 's/^/      /'
    warn "Keychain entries take no disk space. KEEPING them is reasonable:"
    warn "you avoid re-entering Docker Hub / registry logins if you ever reinstall."
    warn "Delete only if you want a true zero-trace machine."
    if ask "Delete these keychain entries anyway (frees no space)?"; then
        echo "$KC_HITS" | while read -r svc; do
            security delete-generic-password -s "$svc" >/dev/null 2>&1 \
                && ok "Deleted keychain item: $svc" \
                || warn "Could not delete: $svc (remove manually in Keychain Access)"
        done
    else
        ok "Keeping keychain entries."
    fi
else
    ok "No Docker keychain entries found."
fi

# ---------- Step 10: final trace scan ("reg cleaner" verification) -----------
info "Step 10/10 — Final trace scan"
echo "    Scanning known locations for anything docker-named (excluding ~/MyDocker*)..."
LEFT=$( { ls -d /Applications/Docker.app \
               /Library/LaunchDaemons/com.docker.* \
               /Library/PrivilegedHelperTools/com.docker.* \
               /var/run/docker.sock \
               "$HOME/.docker" 2>/dev/null;
          find "$HOME/Library" -maxdepth 3 -iname "*docker*" 2>/dev/null;
          ls /usr/local/bin 2>/dev/null | grep -i docker | sed 's|^|/usr/local/bin/|';
        } | grep -v "$HOME/MyDocker" | sort -u )
if [ -z "$LEFT" ]; then
    ok "CLEAN — no Docker traces found. Machine is Docker-free."
else
    warn "Remaining items (kept by your choices above, or need manual review):"
    echo "$LEFT" | sed 's/^/      /'
fi

echo
echo "${BOLD}================= Space summary =================${RESET}"
TOTAL_D=$(( $(free_kb) - START_KB ))
[ "$TOTAL_D" -lt 0 ] && TOTAL_D=0
if [ "$TOTAL_D" -ge 1048576 ]; then
    ok "Total space gained this run: $(awk -v k="$TOTAL_D" 'BEGIN{printf "%.1f GB", k/1048576}')"
else
    ok "Total space gained this run: $(( TOTAL_D / 1024 )) MB"
fi
ok "Free space now: $(free_h)  (was $(awk -v k="$START_KB" 'BEGIN{printf "%.1f GB", k/1048576}') at start)"

echo
echo "${BOLD}Done.${RESET} Protected user files:"
for p in "$HOME"/MyDocker*; do [ -e "$p" ] && echo "    $p ($(sizeof "$p"))"; done
command -v docker >/dev/null 2>&1 && warn "'docker' still resolves: $(command -v docker)" || ok "'docker' command no longer exists."
