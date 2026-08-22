#!/bin/bash
#
# install.sh — Local AI coding stack installer (universal, function-based)
#
# Every step is an independent function, prefixed installOllama*. Each function
# checks its own prerequisites and whether the work is already done, and
# proposes an update when one is available — so the script (or any single
# function) can be run any number of times.
#
#   installOllamaSanity          platform + host RAM detection (sets globals)
#   installOllamaDiskGate        HARD BLOCK until enough free disk
#   installOllamaHomebrew        Homebrew present / updated
#   installOllamaEngine          Ollama itself (.app -> brew migration, upgrade)
#   installOllamaServer          server running; localhost-only or LAN binding
#   installOllamaUv              uv (needed by mlx-lm)
#   installOllamaMlx             mlx-lm (Apple-native inference)
#   installOllamaClaudeCli       Claude Code CLI (the agent frontend)
#   installOllamaModels          RAM-aware model menu: pick & pull until "N"
#   installOllamaVerification    throughput test + status summary
#   installOllama                wrapper — runs all of the above in order
#
# Usage:
#   ./install.sh                 # full pipeline
#   source install.sh            # then call any single function
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

# like ask(), but Enter picks a caller-supplied default: ask_def "Q?" y|n
ask_def() {
    local answer hint
    [ "$2" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf "\n%s%s%s %s " "${BOLD}" "$1" "${RESET}" "$hint"
        read -r answer </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
        case "$answer" in
            "") [ "$2" = "y" ] && return 0 || return 1 ;;
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }

# ---------- registry tag availability (cached 24 h) --------------------------
# The Ollama registry has no single list-everything endpoint, so this does the
# next-best thing: one tiny manifest probe per candidate tag, all in parallel,
# cached for a day — first run ~2 s, reruns instant.
TAG_CACHE_DIR="$HOME/.cache/ollama-tag-check"
tag_cache_file() { echo "$TAG_CACHE_DIR/$(echo "$1" | tr ':/' '__')"; }
tag_check_prefetch() {   # probe one tag and cache the HTTP status
    local f code name="${1%%:*}" t="${1#*:}" url
    f=$(tag_cache_file "$1")
    mkdir -p "$TAG_CACHE_DIR"
    [ -f "$f" ] && [ -n "$(find "$f" -mmin -1440 2>/dev/null)" ] && return 0
    case "$name" in
        hf.co/*) url="https://huggingface.co/api/models/${name#hf.co/}" ;;  # GGUF repo on HuggingFace
        *)       url="https://registry.ollama.ai/v2/library/${name}/manifests/${t}" ;;
    esac
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null)
    echo "${code:-000}" > "$f"
}
tag_available() {        # 200 = exists; 000/empty (offline) = benefit of the doubt
    local c
    c=$(cat "$(tag_cache_file "$1")" 2>/dev/null)
    [ "$c" = "200" ] || [ "$c" = "000" ] || [ -z "$c" ]
}

# ---------- failed-download cleanup ------------------------------------------
# A failed pull can leave complete-but-unreferenced blobs (tens of GB) in
# ~/.ollama/models/blobs. This deletes every blob no manifest references.
# Safety: skipped entirely while any 'ollama pull' is running, and files
# currently open by a process are never touched.
ollama_prune_orphan_blobs() {
    local blobdir="$HOME/.ollama/models/blobs" mdir="$HOME/.ollama/models/manifests"
    [ -d "$blobdir" ] || return 0
    if pgrep -f "ollama pull" >/dev/null 2>&1; then
        warn "Another 'ollama pull' is running — skipping orphan-blob cleanup."
        return 0
    fi
    # collect the orphans first (referenced-by-no-manifest, not open anywhere)
    local refs f base before after orphans=() total_mb=0 sz
    refs=$(grep -rho 'sha256:[a-f0-9]\{64\}' "$mdir" 2>/dev/null | sort -u | tr ':' '-')
    for f in "$blobdir"/sha256-*; do
        [ -e "$f" ] || continue
        base=$(basename "$f"); base=${base%-partial*}
        echo "$refs" | grep -qx "$base" && continue     # referenced by a model
        lsof "$f" >/dev/null 2>&1 && continue           # open by a process
        orphans+=("$f")
        sz=$(du -m "$f" 2>/dev/null | cut -f1)
        total_mb=$(( total_mb + ${sz:-0} ))
    done
    [ "${#orphans[@]}" -eq 0 ] && { ok "No orphaned download data to clean."; return 0; }

    # mode "ask": leftover data can RESUME an interrupted pull of the same
    # model — let the user choose between disk space and resume
    if [ "${1:-}" = "ask" ]; then
        warn "$(( total_mb / 1024 )) GB of leftover data from failed/interrupted pulls found."
        if ! ask_def "Delete it now? (n = keep it so re-pulling the same model resumes)" "y"; then
            ok "Keeping — re-select the same model and the download resumes from this data."
            return 0
        fi
    fi

    before=$(free_gb)
    for f in "${orphans[@]}"; do rm -f "$f"; done
    after=$(free_gb)
    ok "Cleaned up failed-download leftovers: freed $((after - before)) GB (free now: ${after} GB)."
}

# Where to reach the Ollama API; installOllamaServer may switch it to a LAN IP.
OLLAMA_API="${OLLAMA_API:-127.0.0.1}"
ollama_server_up() { curl -sf "http://${OLLAMA_API}:11434/api/version" >/dev/null 2>&1; }
lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null; }

model_installed() { ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$1"; }

require_disk() {
    local need=$1 what=$2 have
    have=$(free_gb)
    if [ "$have" -lt "$need" ]; then
        fail "Not enough disk for ${what}: need ~${need} GB free, have ${have} GB."
        return 1
    fi
    ok "Disk OK for ${what} (${have} GB free, need ~${need} GB)."
}

# ---------- step: sanity — platform + host RAM (sets TOTAL_GB / GPU_GB) ------
installOllamaSanity() {
    info "installOllamaSanity — platform and memory detection"
    if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
        fail "This script targets Apple Silicon macOS. Aborting."
        return 1
    fi
    ok "Apple Silicon macOS detected."

    TOTAL_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    GPU_GB=$(( TOTAL_GB * 3 / 4 ))    # macOS default GPU wired limit ~75% of RAM
    if [ "$TOTAL_GB" -lt 16 ]; then
        fail "Only ${TOTAL_GB} GB unified memory — below the 16 GB minimum for local coding models."
        return 1
    fi
    ok "${TOTAL_GB} GB unified memory — GPU can address ~${GPU_GB} GB. Model menu will be sized to this."
}

# ---------- step: HARD GATE — disk space -------------------------------------
MIN_DISK_GB=25
RECOMMENDED_DISK_GB=60
installOllamaDiskGate() {
    info "installOllamaDiskGate — disk space (need >= ${MIN_DISK_GB} GB, ${RECOMMENDED_DISK_GB}+ recommended)"
    local have
    while true; do
        have=$(free_gb)
        if [ "$have" -ge "$MIN_DISK_GB" ]; then
            [ "$have" -lt "$RECOMMENDED_DISK_GB" ] \
                && warn "${have} GB free — meets the minimum, below the recommended ${RECOMMENDED_DISK_GB} GB." \
                || ok "${have} GB free — requirement met."
            return 0
        fi
        fail "REQUIREMENT NOT MET: ${have} GB free, need at least ${MIN_DISK_GB} GB (short by $((MIN_DISK_GB - have)) GB)."
        echo
        echo "    ${BOLD}Nothing can be installed until disk space is freed.${RESET}"
        echo "    Usual suspects (actual sizes):"
        local d
        for d in "$HOME/Library/Developer/Xcode/DerivedData" \
                 "$HOME/Library/Developer/CoreSimulator" \
                 "$HOME/Library/Caches" \
                 "$HOME/Library/Containers/com.docker.docker" \
                 "$HOME/.cache"; do
            [ -d "$d" ] && echo "      $(du -sh "$d" 2>/dev/null | awk '{print $1}')	$d"
        done
        # local Time Machine snapshots pin deleted files — freed space stays
        # invisible until they're removed
        local snaps
        snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple.TimeMachine") || snaps=0
        if [ "${snaps:-0}" -gt 0 ]; then
            warn "${snaps} local Time Machine snapshot(s) exist — they PIN deleted files,"
            warn "so space you free may not show up until they are removed."
            if ask "Delete the local snapshots now (safe — they are transient hourly caches)?"; then
                tmutil listlocalsnapshots / 2>/dev/null | sed -n 's/com.apple.TimeMachine.\(.*\).local/\1/p' \
                    | while read -r s; do tmutil deletelocalsnapshots "$s" >/dev/null 2>&1; done
                sleep 2
                ok "Snapshots removed — free space now: $(free_gb) GB."
                continue
            fi
        fi
        printf "    %sPress Enter to re-check, or type q to quit:%s " "${BOLD}" "${RESET}"
        local REPLY=""
        read -r REPLY </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
        [ "$REPLY" = "q" ] || [ "$REPLY" = "Q" ] && { echo "Aborted — re-run once ${MIN_DISK_GB}+ GB is free."; return 1; }
    done
}

# ---------- step: Homebrew ---------------------------------------------------
installOllamaHomebrew() {
    info "installOllamaHomebrew — package manager"
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew present: $(brew --version | head -1)"
        return 0
    fi
    warn "Homebrew not found."
    ask "Install Homebrew now?" || { fail "Everything below requires Homebrew."; return 1; }
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
    command -v brew >/dev/null 2>&1 || { fail "Homebrew install failed."; return 1; }
    ok "Homebrew installed."
}

# ---------- step: Ollama engine ----------------------------------------------
installOllamaEngine() {
    info "installOllamaEngine — the Ollama runtime"
    command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew (run installOllamaHomebrew)."; return 1; }

    if [ -d "/Applications/Ollama.app" ]; then
        warn "Standalone Ollama.app detected — not brew-managed ('brew upgrade ollama' cannot see it)."
        echo "    Migration replaces the app with the brew formula. Models in ~/.ollama are NOT touched."
        if ask "Remove Ollama.app and reinstall Ollama via Homebrew?"; then
            osascript -e 'quit app "Ollama"' 2>/dev/null || true
            sleep 2
            rm -rf /Applications/Ollama.app
            [ -L /usr/local/bin/ollama ] && sudo rm -f /usr/local/bin/ollama
            rm -rf ~/Library/Application\ Support/Ollama \
                   ~/Library/Caches/com.electron.ollama \
                   ~/Library/Preferences/com.electron.ollama.plist \
                   ~/Library/Saved\ Application\ State/com.electron.ollama.savedState
            ok "Ollama.app removed (models preserved)."
            brew install ollama || { fail "brew install ollama failed."; return 1; }
            ok "Ollama installed via Homebrew: $(ollama --version 2>/dev/null)"
        else
            warn "Keeping the .app. Later steps assume a recent Ollama — update via the app's own updater."
        fi
        return 0
    fi

    if brew list ollama >/dev/null 2>&1; then
        ok "Ollama brew-managed: $(ollama --version 2>/dev/null)"
        if brew outdated ollama >/dev/null 2>&1; then
            :   # up to date — brew outdated exits 0 with no output when current
        fi
        if [ -n "$(brew outdated ollama 2>/dev/null)" ]; then
            warn "A newer Ollama is available."
            ask "Upgrade Ollama now?" && brew upgrade ollama
        else
            ok "Already the latest version."
        fi
        return 0
    fi

    warn "Ollama not installed."
    ask "Install Ollama via Homebrew?" || { warn "Skipping — model steps will be unavailable."; return 0; }
    brew install ollama || { fail "brew install ollama failed."; return 1; }
    ok "Installed: $(ollama --version 2>/dev/null)"
}

# ---------- step: server + network exposure ----------------------------------
installOllamaServer() {
    info "installOllamaServer — server process and network binding"
    command -v ollama >/dev/null 2>&1 || { fail "Prerequisite missing: ollama binary (run installOllamaEngine)."; return 1; }

    echo "    Network exposure options:"
    echo "      localhost — API on 127.0.0.1 only; nothing else can connect (default, safest)"
    echo "      LAN       — API bound to this Mac's private LAN address; reachable from your"
    echo "                  local network only. NOTE: Ollama has NO authentication."
    # detect what is active NOW; the default answer keeps it (no change)
    local LANIP current_mode def_lan
    LANIP=$(lan_ip)
    current_mode="localhost"
    if [ -f "$HOME/Library/LaunchAgents/local.ollama.lan.plist" ] \
       || { [ -n "$LANIP" ] && curl -sf --max-time 2 "http://${LANIP}:11434/api/version" >/dev/null 2>&1; }; then
        current_mode="LAN"
    fi
    def_lan="n"; [ "$current_mode" = "LAN" ] && def_lan="y"
    ok "Currently active exposure: ${current_mode} — Enter keeps it unchanged."
    if [ -n "$LANIP" ] && ask_def "Expose Ollama to the local network (${LANIP}, instead of localhost-only)?" "$def_lan"; then
        case "$LANIP" in
            192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) : ;;
            *) fail "IP ${LANIP} is not a private-range address — refusing to expose. Using localhost."; LANIP="" ;;
        esac
    else
        LANIP=""
    fi

    if [ -n "$LANIP" ]; then
        OLLAMA_API="$LANIP"
        export OLLAMA_HOST="${LANIP}:11434"
        warn "DHCP caveat: binds ${LANIP} — give this Mac a DHCP reservation in the router."
        if ollama_server_up; then
            ok "Ollama already serving on ${LANIP}:11434."
        elif ask "Install a login service bound to ${LANIP}:11434 (LaunchAgent)?"; then
            brew services stop ollama >/dev/null 2>&1
            local PLIST="$HOME/Library/LaunchAgents/local.ollama.lan.plist"
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
        <key>OLLAMA_CONTEXT_LENGTH</key><string>32768</string>
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
        # explicit switch LAN -> localhost: tear the LAN service down first
        if [ "$current_mode" = "LAN" ]; then
            warn "Switching LAN -> localhost: removing the LAN LaunchAgent."
            launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.ollama.lan.plist" 2>/dev/null
            rm -f "$HOME/Library/LaunchAgents/local.ollama.lan.plist"
            pkill -f "ollama serve" 2>/dev/null; sleep 2
        fi
        if ollama_server_up; then
            ok "Ollama server already running (localhost-only)."
        elif brew list ollama >/dev/null 2>&1; then
            if ask "Start Ollama as a background service (brew services, auto-starts on login)?"; then
                warn "brew services cannot pass env vars — server runs with the 4k default context."
                warn "For Claude Code use, aiModelLauncher.sh will offer a restart with 32k context."
                brew services start ollama; sleep 3
            elif ask "Start Ollama just for this session (with 32k context for Claude Code)?"; then
                OLLAMA_CONTEXT_LENGTH=32768 nohup ollama serve >/dev/null 2>&1 &
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
        warn "Server not reachable — model steps will be unavailable."
        return 1
    fi
}

# ---------- step: uv ---------------------------------------------------------
installOllamaUv() {
    info "installOllamaUv — Python tool manager (needed by mlx-lm)"
    command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew."; return 1; }
    if command -v uv >/dev/null 2>&1; then
        ok "uv present: $(uv --version)"
        if brew list uv >/dev/null 2>&1 && [ -n "$(brew outdated uv 2>/dev/null)" ]; then
            warn "A newer uv is available."
            ask "Upgrade uv now?" && brew upgrade uv
        fi
        return 0
    fi
    ask "Install uv via Homebrew?" || { warn "Skipping — mlx-lm will be unavailable."; return 1; }
    brew install uv && ok "uv installed." || { fail "uv install failed."; return 1; }
}

# ---------- step: mlx-lm -----------------------------------------------------
installOllamaMlx() {
    info "installOllamaMlx — Apple-native inference (fastest path on this chip)"
    command -v uv >/dev/null 2>&1 || { fail "Prerequisite missing: uv (run installOllamaUv)."; return 1; }
    if uv tool list 2>/dev/null | grep -q '^mlx-lm'; then
        # installed: check for updates automatically, ask only if one exists
        local cur latest
        cur=$(uv tool list 2>/dev/null | awk '/^mlx-lm /{print $2}' | tr -d 'v')
        latest=$(curl -sf --max-time 10 https://pypi.org/pypi/mlx-lm/json 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "mlx-lm update available: ${cur} -> ${latest}"
            ask_def "Update mlx-lm now?" "y" && uv tool upgrade mlx-lm
        elif [ -z "$latest" ]; then
            ok "mlx-lm ${cur:-?} installed (update check skipped — PyPI unreachable)."
        else
            ok "mlx-lm ${cur} is up to date."
        fi
        return 0
    fi
    ask "Install mlx-lm?" || { warn "Skipping mlx-lm."; return 0; }
    uv tool install mlx-lm && ok "mlx-lm installed." || fail "mlx-lm install failed."
}

# ---------- step: Claude Code CLI --------------------------------------------
installOllamaClaudeCli() {
    info "installOllamaClaudeCli — Claude Code CLI (frontend for aiModelLauncher.sh)"
    if command -v claude >/dev/null 2>&1; then
        # rerun path: version check is AUTOMATIC (works for npm and native
        # installs alike); the update question appears only when needed,
        # defaulting to Y.
        local cur latest
        cur=$(claude --version 2>/dev/null | awk '{print $1}')
        ok "claude present: ${cur:-unknown}"
        latest=$(curl -sf --max-time 10 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "claude-code update available: ${cur} -> ${latest}"
            if ask_def "Update claude-code now?" "y"; then
                if command -v npm >/dev/null 2>&1 && npm ls -g @anthropic-ai/claude-code >/dev/null 2>&1; then
                    npm install -g @anthropic-ai/claude-code
                else
                    claude update
                fi
                ok "Now: $(claude --version 2>/dev/null | head -1)"
            fi
        elif [ -z "$latest" ]; then
            ok "Update check skipped (registry unreachable)."
        else
            ok "claude-code ${cur} is up to date."
        fi
        return 0
    fi

    # first-run path: not installed — propose installation
    warn "claude CLI not installed — aiModelLauncher's Claude step needs it."
    if command -v npm >/dev/null 2>&1; then
        if ask_def "Install Claude Code now (npm install -g @anthropic-ai/claude-code)?" "y"; then
            npm install -g @anthropic-ai/claude-code \
                && ok "Installed: $(claude --version 2>/dev/null | head -1)" \
                || fail "npm install failed — try the native installer: curl -fsSL https://claude.ai/install.sh | bash"
        else
            warn "Skipped."
        fi
    else
        warn "npm not found. Either install Node first (brew install node) and re-run,"
        warn "or use the native installer:  curl -fsSL https://claude.ai/install.sh | bash"
    fi
}

# ---------- step: models — RAM-aware menu, loop until N ----------------------
# Catalog: "tag|size_gb|short description". Kept biggest -> smallest.
# Universal: the menu only shows entries that FIT this host's GPU allocation
# and are NOT yet downloaded. Refresh the catalog as the ecosystem moves.
#
# Quantization variants: default tags are q4_K_M; q8_0 (+~85% size) is
# effectively lossless. Which appear depends on the CURRENT GPU limit — raise
# it (launcher GPU tuning / sysctl iogpu.wired_limit_mb) and bigger quants
# become selectable.
#
# NOTE: hf.co/* GGUF entries were removed — direct HuggingFace pulls fail on
# this Ollama version with "context deadline exceeded" at the final commit
# (reproduced 3x with successful blob downloads; registry pulls work fine).
# Ollama-registry tags are the only reliable source here, which also means
# Q5_K_M / Q6_K quants are unavailable (registry offers q4_K_M and q8_0).
OLLAMA_MODEL_CATALOG=(
    "gpt-oss:120b|65|OpenAI open-weight MoE, strongest general"
    "qwen3-coder-next:80b-a3b|43|80B MoE coder, 3B active — strongest open coder"
    "llama3.3:70b|40|Meta 70B dense, general purpose"
    "deepseek-r1:70b|40|Reasoning-tuned 70B"
    "qwen3.6:35b-a3b-q8_0|37|daily driver @ q8_0 — effectively lossless"
    "qwen3.6:35b-a3b-coding-mxfp8|37|coding-tuned 8-bit build of the daily driver"
    "qwen2.5-coder:32b-instruct-q8_0|35|Dense coder 32B @ q8_0"
    "qwen3-coder:30b-a3b-q8_0|32|Qwen3-Coder 30B MoE @ q8_0"
    "qwen3:32b|20|Qwen3 dense general 32B"
    "qwen3.6:35b-a3b|20|MoE coder/agent @ q4_K_M, 256K ctx — daily driver"
    "qwen2.5-coder:32b|20|Dense coder 32B"
    "deepseek-r1:32b|20|Reasoning 32B"
    "qwen3-coder:30b|19|Qwen3-Coder 30B MoE @ q4_K_M"
    "gemma3:27b|17|Google Gemma 3 27B"
    "qwen2.5-coder:14b-instruct-q8_0|16|Dense coder 14B @ q8_0"
    "devstral:24b|14|Mistral agentic coder @ q4_K_M — tool-call reliability"
    "mistral-small3.2:24b|14|Mistral general 24B"
    "gpt-oss:20b|13|OpenAI open-weight MoE 20B"
    "qwen3:14b|9|Qwen3 dense 14B"
    "qwen2.5-coder:14b|9|Dense coder 14B"
    "phi4:14b|9|Microsoft Phi-4 14B"
    "gemma3:12b|8|Gemma 3 12B"
    "qwen3:8b|5|Qwen3 8B"
    "llama3.1:8b|5|Meta 8B"
    "qwen2.5-coder:7b|5|Coder 7B — good FIM/autocomplete"
    "gemma3:4b|3|Gemma 3 4B"
    "qwen2.5-coder:3b|2|Coder 3B — low-latency autocomplete"
    "qwen2.5-coder:1.5b|1|Tiny autocomplete"
)

installOllamaModels() {
    info "installOllamaModels — download models suited to this host (${TOTAL_GB:-?} GB RAM)"
    command -v ollama >/dev/null 2>&1 || { fail "Prerequisite missing: ollama (run installOllamaEngine)."; return 1; }
    ollama_server_up || { fail "Prerequisite missing: running server (run installOllamaServer)."; return 1; }
    [ -z "${TOTAL_GB:-}" ] && TOTAL_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))

    # fit against the CURRENT GPU limit: a raised iogpu.wired_limit_mb widens
    # the menu (bigger models / higher quants become selectable)
    local cur_limit_mb
    cur_limit_mb=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    if [ "$cur_limit_mb" -gt 0 ]; then
        GPU_GB=$(( cur_limit_mb / 1024 ))
        ok "Using the currently set GPU limit: ${GPU_GB} GB (iogpu.wired_limit_mb=${cur_limit_mb})."
    else
        GPU_GB=$(( TOTAL_GB * 3 / 4 ))
        echo "    GPU limit is macOS default (~${GPU_GB} GB). Raising it unlocks bigger quants:"
        echo "      sudo sysctl iogpu.wired_limit_mb=$(( (TOTAL_GB - 5) * 1024 ))   # then re-run this step"
    fi

    # clean leftovers of interrupted/failed pulls FIRST, so the free-space
    # numbers below are honest (skipped automatically if a pull is running;
    # asks before deleting since leftovers can resume an interrupted pull)
    ollama_prune_orphan_blobs ask

    while true; do
        # a) what is already downloaded
        local downloaded have_disk
        downloaded=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')
        have_disk=$(free_gb)
        echo
        echo "    Already downloaded:"
        [ -n "$downloaded" ] && echo "$downloaded" | sed 's/^/      /' || echo "      (none)"

        # b) candidates: fits GPU allocation AND free disk, not downloaded
        local menu_tags=() menu_lines=() entry tag size desc need hidden_disk=0
        for entry in "${OLLAMA_MODEL_CATALOG[@]}"; do
            IFS='|' read -r tag size desc <<< "$entry"
            need=$(( size * 13 / 10 + 2 ))                      # weights*1.3 + 2 GB overhead
            [ "$need" -gt "$GPU_GB" ] && continue               # doesn't fit this host's RAM
            echo "$downloaded" | grep -qx "$tag" && continue    # already present
            if [ $(( size + 5 )) -gt "$have_disk" ]; then       # doesn't fit free disk
                hidden_disk=$((hidden_disk+1))
                continue
            fi
            menu_tags+=("$tag")
            menu_lines+=("$(printf '%-28s %3d GB  (needs ~%d GB RAM)  %s' "$tag" "$size" "$need" "$desc")")
        done
        [ "$hidden_disk" -gt 0 ] && warn "${hidden_disk} model(s) hidden — larger than the ${have_disk} GB of free disk allows."

        [ "${#menu_tags[@]}" -eq 0 ] && { ok "No further catalog models fit this host — done."; return 0; }

        # c) availability: probe each candidate tag on the registry in parallel
        #    (cached 24 h) so the menu never offers a tag that would 404 on pull
        info "Verifying ${#menu_tags[@]} candidate tags on registry.ollama.ai (parallel, cached 24 h)..."
        for tag in "${menu_tags[@]}"; do tag_check_prefetch "$tag" & done
        wait
        local avail_tags=() avail_lines=() j
        for j in "${!menu_tags[@]}"; do
            if tag_available "${menu_tags[$j]}"; then
                avail_tags+=("${menu_tags[$j]}")
                avail_lines+=("${menu_lines[$j]}")
            else
                warn "Not on the registry (hidden): ${menu_tags[$j]}"
            fi
        done
        [ "${#avail_tags[@]}" -eq 0 ] && { ok "No available catalog models remain — done."; return 0; }
        menu_tags=("${avail_tags[@]}")
        menu_lines=("${avail_lines[@]}")
        # cap at 25 options
        while [ "${#menu_tags[@]}" -gt 25 ]; do
            unset 'menu_tags[${#menu_tags[@]}-1]' 'menu_lines[${#menu_lines[@]}-1]'
        done

        echo
        echo "${BOLD}Models that fit this machine (~${GPU_GB} GB usable GPU, ${have_disk} GB free disk), biggest first:${RESET}"
        local i
        for i in "${!menu_tags[@]}"; do
            printf "  %2d) %s\n" $((i+1)) "${menu_lines[$i]}"
        done
        echo "   N) No download — finish this step"

        local sel
        printf "\n%sSelect a model to download [1-%d / N]:%s " "${BOLD}" "${#menu_tags[@]}" "${RESET}"
        read -r sel </dev/tty || { echo; fail "No interactive terminal — aborting."; return 1; }
        case "$sel" in
            [Nn]) ok "Model downloads finished."; return 0 ;;
            *[!0-9]*|"") echo "Enter a number or N."; continue ;;
        esac
        [ "$sel" -lt 1 ] || [ "$sel" -gt "${#menu_tags[@]}" ] && { echo "Out of range."; continue; }

        tag="${menu_tags[$((sel-1))]}"
        IFS='|' read -r _ size _ <<< "$(printf '%s\n' "${OLLAMA_MODEL_CATALOG[@]}" | grep "^${tag}|")"
        if require_disk $(( size + 5 )) "${tag} (~${size} GB + headroom)"; then
            info "Pulling ${tag}..."
            local pull_log attempt ok_pull=0 last_err=""
            pull_log=$(mktemp "${TMPDIR:-/tmp}/ollama-pull.XXXXXX")
            for attempt in 1 2 3; do
                ollama pull "$tag" 2>&1 | tee "$pull_log"
                if [ "${PIPESTATUS[0]}" -eq 0 ]; then ok_pull=1; break; fi
                last_err=$(grep -i "error" "$pull_log" | tail -1)
                # transient errors (timeouts, resets): retry — the download
                # RESUMES from the already-fetched data, often at 100%
                if [ "$attempt" -lt 3 ] && grep -qiE "deadline exceeded|timeout|connection reset|unexpected EOF|TLS handshake|502|503" "$pull_log"; then
                    warn "Transient error: ${last_err}"
                    warn "Retrying (attempt $((attempt+1))/3) — resumes from already-downloaded data..."
                    sleep 5
                else
                    break
                fi
            done
            if [ "$ok_pull" -eq 1 ]; then
                ok "${tag} downloaded."
            else
                fail "Pull failed after ${attempt} attempt(s). Actual error:"
                fail "  ${last_err:-unknown (see output above)}"
                if grep -qiE "deadline exceeded|timeout|connection reset|unexpected EOF" "$pull_log"; then
                    # transient failure: KEEP the partial data — re-selecting
                    # this model resumes instead of restarting from zero
                    warn "Keeping downloaded data so a re-try resumes. (Cleanup runs on next step entry if you abandon it.)"
                else
                    warn "Permanent-looking error (bad tag/manifest) — cleaning up its disk space."
                    ollama_prune_orphan_blobs
                fi
            fi
            rm -f "$pull_log"
        fi
        # loop: menu re-renders without the model just downloaded
    done
}

# ---------- step: verification -----------------------------------------------
installOllamaVerification() {
    info "installOllamaVerification — status and throughput"
    echo
    echo "${BOLD}================= Install summary =================${RESET}"
    command -v brew   >/dev/null 2>&1 && ok "Homebrew: $(brew --version | head -1)"     || fail "Homebrew: missing"
    command -v ollama >/dev/null 2>&1 && ok "Ollama:   $(ollama --version 2>/dev/null)" || fail "Ollama: missing"
    ollama_server_up                  && ok "Server:   running on ${OLLAMA_API}:11434"  || warn "Server: not running"
    command -v uv     >/dev/null 2>&1 && ok "uv:       $(uv --version)"                  || warn "uv: not installed"
    uv tool list 2>/dev/null | grep -q '^mlx-lm' \
                                      && ok "mlx-lm:   installed"                        || warn "mlx-lm: not installed"
    command -v claude >/dev/null 2>&1 && ok "claude:   $(claude --version 2>/dev/null | head -1)" || warn "claude: not installed"

    command -v ollama >/dev/null 2>&1 && ollama_server_up || return 0
    echo
    info "Installed models:"
    ollama list
    echo
    echo "    Benchmark models with ./aiModelTest.sh or ./testAllAiModels.sh"
}

# ---------- wrapper ----------------------------------------------------------
installOllama() {
    echo "${BOLD}=============================================================${RESET}"
    echo "${BOLD} Local AI coding stack — installer (universal, re-runnable)${RESET}"
    echo "${BOLD}=============================================================${RESET}"
    installOllamaSanity        || return 1
    installOllamaDiskGate      || return 1
    installOllamaHomebrew      || return 1
    installOllamaEngine        || return 1
    installOllamaServer        || warn "Continuing without a running server."
    installOllamaUv            && installOllamaMlx
    installOllamaClaudeCli
    installOllamaModels
    installOllamaVerification
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    installOllama
fi
