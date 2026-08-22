#!/bin/bash
#
# install.sh — Local AI coding stack installer for Mac mini (M4 Pro, 48 GB)
# Companion to AI_CompatibilityReport.md
#
# Interactive: asks ONE question at a time, in dependency order.
# Every step first verifies the requirements established by earlier steps,
# so the script is safe to re-run — completed steps are detected and skipped.
#
# Order:
#   1. Hardware gate: disk space   (HARD BLOCK — refuses to continue until met)
#   2. Homebrew                    (required by everything below)
#   3. Ollama migration/upgrade    (.app -> brew formula, or plain upgrade)
#   4. Ollama server running       (required for pulls)
#   5. uv                          (required by mlx-lm)
#   6. mlx-lm                      (optional, fastest path on Apple Silicon)
#   7. Model: Qwen3.6-35B-A3B      (primary, ~20 GB)
#   8. Model: Devstral Small 24B   (optional, ~14 GB)
#   9. Verify throughput
#
set -u

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

info()  { echo "${BLUE}==>${RESET} $*"; }
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
fail()  { echo "${RED} ✗ ${RESET} $*"; }

# ask "question" -> returns 0 for yes, 1 for no. One question at a time.
ask() {
    local answer
    while true; do
        printf "\n%s%s%s [y/n] " "${BOLD}" "$1" "${RESET}"
        read -r answer </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
        case "$answer" in
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }

# Where to reach the Ollama API. Default: loopback. Step 4 may switch this
# to the LAN IP if the user chooses LAN exposure.
OLLAMA_API="127.0.0.1"
ollama_server_up() { curl -sf "http://${OLLAMA_API}:11434/api/version" >/dev/null 2>&1; }
lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null; }

model_installed() { ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$1"; }

# require_disk <GB needed> <what for>  -> 0 if enough space
require_disk() {
    local need=$1 what=$2 have
    have=$(free_gb)
    if [ "$have" -lt "$need" ]; then
        fail "Not enough disk for ${what}: need ~${need} GB free, have ${have} GB."
        warn "Free space first (Xcode DerivedData, old simulators, Docker images, caches)."
        return 1
    fi
    ok "Disk OK for ${what} (${have} GB free, need ~${need} GB)."
    return 0
}

echo "${BOLD}=============================================================${RESET}"
echo "${BOLD} Local AI coding stack — installer (M4 Pro / 48 GB Mac mini)${RESET}"
echo "${BOLD}=============================================================${RESET}"

# ---------- Step 0: sanity — Apple Silicon mac + RAM -------------------------
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    fail "This script targets Apple Silicon macOS. Aborting."
    exit 1
fi
ok "Apple Silicon macOS detected."

RAM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
if [ "$RAM_GB" -lt 32 ]; then
    fail "Only ${RAM_GB} GB unified memory — the recommended models need 32 GB+. Aborting."
    exit 1
fi
ok "${RAM_GB} GB unified memory — sufficient for the recommended models."

# ---------- Step 1: HARD GATE — disk space -----------------------------------
# The script REFUSES to proceed until this requirement is met. Free space in
# another terminal, then re-check from the prompt below. No bypass.
MIN_DISK_GB=25       # bare minimum: primary model (~20 GB) + headroom
RECOMMENDED_DISK_GB=60

info "Step 1/9 — Hardware gate: disk space (need >= ${MIN_DISK_GB} GB, ${RECOMMENDED_DISK_GB}+ GB recommended)"
while true; do
    HAVE_GB=$(free_gb)
    if [ "$HAVE_GB" -ge "$MIN_DISK_GB" ]; then
        if [ "$HAVE_GB" -lt "$RECOMMENDED_DISK_GB" ]; then
            ok "${HAVE_GB} GB free — meets the ${MIN_DISK_GB} GB minimum."
            warn "Below the recommended ${RECOMMENDED_DISK_GB} GB: fine for the primary model, but no room for Devstral or the 80B stretch model."
        else
            ok "${HAVE_GB} GB free — requirement met."
        fi
        break
    fi

    fail "REQUIREMENT NOT MET: ${HAVE_GB} GB free, need at least ${MIN_DISK_GB} GB (short by $((MIN_DISK_GB - HAVE_GB)) GB)."
    echo
    echo "    ${BOLD}Reminder — nothing can be installed until disk space is freed.${RESET}"
    echo "    Usual suspects on a dev machine (checking actual sizes...):"
    for d in "$HOME/Library/Developer/Xcode/DerivedData" \
             "$HOME/Library/Developer/CoreSimulator" \
             "$HOME/Library/Caches" \
             "$HOME/Library/Containers/com.docker.docker"; do
        [ -d "$d" ] && echo "      $(du -sh "$d" 2>/dev/null | awk '{print $1}')	$d"
    done
    echo
    echo "    Free space in another terminal, then re-check here."
    printf "    %sPress Enter to re-check, or type q to quit:%s " "${BOLD}" "${RESET}"
    REPLY=""
    read -r REPLY </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
    if [ "$REPLY" = "q" ] || [ "$REPLY" = "Q" ]; then
        echo "Aborted — re-run ./install.sh once ${MIN_DISK_GB}+ GB is free."
        exit 1
    fi
done

# ---------- Step 2: Homebrew -------------------------------------------------
info "Step 2/9 — Homebrew (required for every later step)"
if command -v brew >/dev/null 2>&1; then
    ok "Homebrew present: $(brew --version | head -1)"
else
    warn "Homebrew not found."
    if ask "Install Homebrew now?"; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
        command -v brew >/dev/null 2>&1 || { fail "Homebrew install failed. Aborting."; exit 1; }
        ok "Homebrew installed."
    else
        fail "Everything below requires Homebrew. Aborting."
        exit 1
    fi
fi

# ---------- Step 3: Ollama (migrate .app -> brew, or install/upgrade) --------
info "Step 3/9 — Ollama"
# prerequisite: brew (verified above)
command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew."; exit 1; }

if [ -d "/Applications/Ollama.app" ]; then
    warn "Standalone Ollama.app detected — not managed by Homebrew (this is why 'brew upgrade ollama' fails)."
    echo "    Migrating replaces the app with the brew formula. Models in ~/.ollama are NOT touched."
    if ask "Remove Ollama.app and reinstall Ollama via Homebrew?"; then
        osascript -e 'quit app "Ollama"' 2>/dev/null || true
        sleep 2
        rm -rf /Applications/Ollama.app
        [ -L /usr/local/bin/ollama ] && sudo rm -f /usr/local/bin/ollama
        rm -rf ~/Library/Application\ Support/Ollama \
               ~/Library/Caches/com.electron.ollama \
               ~/Library/Preferences/com.electron.ollama.plist \
               ~/Library/Saved\ Application\ State/com.electron.ollama.savedState
        ok "Ollama.app removed (models in ~/.ollama preserved)."
        brew install ollama || { fail "brew install ollama failed."; exit 1; }
        ok "Ollama installed via Homebrew: $(ollama --version 2>/dev/null)"
    else
        warn "Keeping the .app. Later steps assume a recent Ollama — update it via the app's own updater."
    fi
elif brew list ollama >/dev/null 2>&1; then
    ok "Ollama already brew-managed: $(ollama --version 2>/dev/null)"
    if ask "Upgrade Ollama to the latest version?"; then
        brew upgrade ollama 2>/dev/null || ok "Already up to date."
    fi
else
    warn "Ollama not installed."
    if ask "Install Ollama via Homebrew?"; then
        brew install ollama || { fail "brew install ollama failed."; exit 1; }
        ok "Installed: $(ollama --version 2>/dev/null)"
    else
        warn "Skipping. Model steps (7-9) will be unavailable."
    fi
fi

# ---------- Step 4: Ollama server --------------------------------------------
info "Step 4/9 — Ollama server"
# prerequisite: ollama binary
if ! command -v ollama >/dev/null 2>&1; then
    warn "Prerequisite missing: ollama binary — skipping server, model pulls, and verification."
    SKIP_OLLAMA=1
else
    SKIP_OLLAMA=0

    # --- network exposure: loopback-only (default) or LAN-only ---------------
    echo "    Network exposure options:"
    echo "      localhost — API on 127.0.0.1 only; nothing else can connect (default, safest)"
    echo "      LAN       — API bound to this Mac's 192.168.x address; reachable from your"
    echo "                  local network only. NOTE: Ollama has NO authentication — anyone"
    echo "                  on the LAN could prompt, pull, or delete models."
    LANIP=$(lan_ip)
    if [ -n "$LANIP" ] && ask "Expose Ollama to the local network (${LANIP}, instead of localhost-only)?"; then
        case "$LANIP" in
            192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) : ;;
            *) fail "This Mac's IP ${LANIP} is not a private-range address — refusing to expose. Falling back to localhost."; LANIP="" ;;
        esac
    else
        LANIP=""
    fi

    if [ -n "$LANIP" ]; then
        OLLAMA_API="$LANIP"
        export OLLAMA_HOST="${LANIP}:11434"      # CLI in this script talks to the same bind
        warn "DHCP caveat: the server binds ${LANIP}. If the router hands out a different IP later,"
        warn "the service breaks — give this Mac a DHCP reservation in the router."
        if ollama_server_up; then
            ok "Ollama already serving on ${LANIP}:11434."
        elif ask "Install a login service bound to ${LANIP}:11434 (LaunchAgent)?"; then
            # brew services regenerates its plist and drops env vars, so LAN mode
            # gets its own LaunchAgent instead.
            brew services stop ollama >/dev/null 2>&1
            PLIST="$HOME/Library/LaunchAgents/local.ollama.lan.plist"
            cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>local.ollama.lan</string>
    <key>ProgramArguments</key><array>
        <string>$(command -v ollama)</string>
        <string>serve</string>
    </array>
    <key>EnvironmentVariables</key><dict>
        <key>OLLAMA_HOST</key><string>${LANIP}:11434</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict></plist>
EOF
            launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
            launchctl bootstrap "gui/$(id -u)" "$PLIST" && ok "LaunchAgent installed and started."
            sleep 3
        elif ask "Start Ollama on ${LANIP}:11434 just for this session instead?"; then
            nohup ollama serve >/dev/null 2>&1 &
            sleep 3
        fi
    else
        # localhost-only (default)
        if ollama_server_up; then
            ok "Ollama server already running (localhost-only)."
        elif brew list ollama >/dev/null 2>&1; then
            if ask "Start Ollama as a background service (brew services, auto-starts on login)?"; then
                brew services start ollama
                sleep 3
            elif ask "Start Ollama just for this session instead?"; then
                nohup ollama serve >/dev/null 2>&1 &
                sleep 3
            fi
        else
            if ask "Start Ollama for this session?"; then
                open -a Ollama 2>/dev/null || { nohup ollama serve >/dev/null 2>&1 & }
                sleep 3
            fi
        fi
    fi

    if ollama_server_up; then
        ok "Server is up on ${OLLAMA_API}:11434."
        lsof -iTCP:11434 -sTCP:LISTEN -n -P 2>/dev/null | tail -n +2 | awk '{print "    listening: "$9}' | sort -u
    else
        warn "Server still not reachable — model steps will be skipped."
    fi
fi

# ---------- Step 5: uv -------------------------------------------------------
info "Step 5/9 — uv (Python tool manager, required for mlx-lm)"
if command -v uv >/dev/null 2>&1; then
    ok "uv present: $(uv --version)"
    HAVE_UV=1
else
    if ask "Install uv via Homebrew?"; then
        brew install uv && HAVE_UV=1 || { fail "uv install failed."; HAVE_UV=0; }
    else
        warn "Skipping uv — mlx-lm step will be unavailable."
        HAVE_UV=0
    fi
fi

# ---------- Step 6: mlx-lm ---------------------------------------------------
info "Step 6/9 — mlx-lm (Apple-native inference, fastest path on this chip)"
# prerequisite: uv
if [ "${HAVE_UV}" -eq 1 ]; then
    if command -v mlx_lm.generate >/dev/null 2>&1 || uv tool list 2>/dev/null | grep -q mlx-lm; then
        ok "mlx-lm already installed."
    elif ask "Install mlx-lm (Apple's MLX inference toolkit)?"; then
        uv tool install mlx-lm && ok "mlx-lm installed." || fail "mlx-lm install failed."
    else
        warn "Skipping mlx-lm."
    fi
else
    warn "Prerequisite missing: uv — skipping mlx-lm."
fi

# ---------- Step 7: primary model — Qwen3.6-35B-A3B --------------------------
info "Step 7/9 — Primary model: Qwen3.6-35B-A3B (~20 GB, MoE, 256K ctx)"
# prerequisites: ollama binary + running server + disk
if [ "$SKIP_OLLAMA" -eq 1 ] || ! ollama_server_up; then
    warn "Prerequisite missing: running Ollama server — skipping model pulls."
else
    PRIMARY_TAG="qwen3.6:35b-a3b"
    if model_installed "$PRIMARY_TAG" || model_installed "${PRIMARY_TAG}-q4_K_M"; then
        ok "Primary model already present."
    elif require_disk 25 "Qwen3.6-35B-A3B (~20 GB + headroom)"; then
        if ask "Pull ${PRIMARY_TAG} now (~20 GB download)?"; then
            ollama pull "$PRIMARY_TAG" \
                || ollama pull "${PRIMARY_TAG}-q4_K_M" \
                || { fail "Pull failed — tag may differ. Check https://ollama.com/library for the current Qwen3.6 tag."; }
        fi
    fi

    # ---------- Step 8: optional model — Devstral Small 24B ------------------
    info "Step 8/9 — Optional model: Devstral Small 24B (~14 GB, tool-call reliability)"
    if model_installed "devstral:24b" || model_installed "devstral:latest"; then
        ok "Devstral already present."
    elif require_disk 18 "Devstral Small (~14 GB + headroom)"; then
        if ask "Also pull Devstral Small 24B (~14 GB)?"; then
            ollama pull devstral:24b || ollama pull devstral \
                || fail "Pull failed — check https://ollama.com/library/devstral for the current tag."
        fi
    fi

    # ---------- Step 9: verify ----------------------------------------------
    info "Step 9/9 — Verification"
    if model_installed "$PRIMARY_TAG" || model_installed "${PRIMARY_TAG}-q4_K_M"; then
        if ask "Run a quick throughput test on the primary model?"; then
            TAG=$(ollama list | awk 'NR>1 {print $1}' | grep '^qwen3.6' | head -1)
            info "Running: ollama run ${TAG} --verbose (watch the 'eval rate' line — expect tens of tok/s)"
            ollama run "$TAG" --verbose "Write a Python function that merges two sorted lists." || true
        fi
    else
        warn "Primary model not installed — nothing to verify."
    fi
fi

# ---------- summary ----------------------------------------------------------
echo
echo "${BOLD}================= Install summary =================${RESET}"
command -v brew   >/dev/null 2>&1 && ok "Homebrew: $(brew --version | head -1)"     || fail "Homebrew: missing"
command -v ollama >/dev/null 2>&1 && ok "Ollama:   $(ollama --version 2>/dev/null)" || fail "Ollama: missing"
ollama_server_up                  && ok "Server:   running"                          || warn "Server: not running"
command -v uv     >/dev/null 2>&1 && ok "uv:       $(uv --version)"                  || warn "uv: not installed"
{ command -v mlx_lm.generate >/dev/null 2>&1 || uv tool list 2>/dev/null | grep -q mlx-lm; } \
                                  && ok "mlx-lm:   installed"                        || warn "mlx-lm: not installed"
if command -v ollama >/dev/null 2>&1 && ollama_server_up; then
    echo; info "Installed models:"; ollama list
fi
echo
echo "Done. See AI_CompatibilityReport.md for tuning (GPU wired limit, 80B stretch model)."
