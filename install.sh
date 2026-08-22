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

free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }

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
    local LANIP
    LANIP=$(lan_ip)
    if [ -n "$LANIP" ] && ask "Expose Ollama to the local network (${LANIP}, instead of localhost-only)?"; then
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
        if ollama_server_up; then
            ok "Ollama server already running (localhost-only)."
        elif brew list ollama >/dev/null 2>&1; then
            if ask "Start Ollama as a background service (brew services, auto-starts on login)?"; then
                brew services start ollama; sleep 3
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
        ok "mlx-lm already installed."
        ask "Check for and install mlx-lm updates?" && uv tool upgrade mlx-lm
        return 0
    fi
    ask "Install mlx-lm?" || { warn "Skipping mlx-lm."; return 0; }
    uv tool install mlx-lm && ok "mlx-lm installed." || fail "mlx-lm install failed."
}

# ---------- step: models — RAM-aware menu, loop until N ----------------------
# Catalog: "tag|size_gb|short description". Kept biggest -> smallest.
# Universal: the menu only shows entries that FIT this host's GPU allocation
# and are NOT yet downloaded. Refresh the catalog as the ecosystem moves.
OLLAMA_MODEL_CATALOG=(
    "gpt-oss:120b|65|OpenAI open-weight MoE, strongest general"
    "qwen3-coder-next:80b-a3b|43|80B MoE coder, 3B active — strongest open coder"
    "llama3.3:70b|40|Meta 70B dense, general purpose"
    "deepseek-r1:70b|40|Reasoning-tuned 70B"
    "qwen3:32b|20|Qwen3 dense general 32B"
    "qwen3.6:35b-a3b|20|MoE coder/agent, 3B active, 256K ctx — daily driver"
    "qwen2.5-coder:32b|20|Dense coder 32B"
    "deepseek-r1:32b|20|Reasoning 32B"
    "qwen3-coder:30b|19|Qwen3-Coder 30B MoE"
    "gemma3:27b|17|Google Gemma 3 27B"
    "devstral:24b|14|Mistral agentic coder — tool-call reliability"
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
    [ -z "${GPU_GB:-}" ] && { TOTAL_GB=$(( $(sysctl -n hw.memsize) / 1073741824 )); GPU_GB=$(( TOTAL_GB * 3 / 4 )); }

    while true; do
        # a) what is already downloaded
        local downloaded
        downloaded=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')
        echo
        echo "    Already downloaded:"
        [ -n "$downloaded" ] && echo "$downloaded" | sed 's/^/      /' || echo "      (none)"

        # b) build menu: fits GPU allocation, not downloaded, biggest first, max 25
        local menu_tags=() menu_lines=() entry tag size desc need
        for entry in "${OLLAMA_MODEL_CATALOG[@]}"; do
            IFS='|' read -r tag size desc <<< "$entry"
            need=$(( size * 13 / 10 + 2 ))                      # weights*1.3 + 2 GB overhead
            [ "$need" -gt "$GPU_GB" ] && continue               # doesn't fit this host
            echo "$downloaded" | grep -qx "$tag" && continue    # already present
            menu_tags+=("$tag")
            menu_lines+=("$(printf '%-28s %3d GB  (needs ~%d GB RAM)  %s' "$tag" "$size" "$need" "$desc")")
            [ "${#menu_tags[@]}" -ge 25 ] && break
        done

        [ "${#menu_tags[@]}" -eq 0 ] && { ok "No further catalog models fit this host — done."; return 0; }

        echo
        echo "${BOLD}Models that fit this machine (~${GPU_GB} GB usable), biggest first:${RESET}"
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
            ollama pull "$tag" && ok "${tag} downloaded." \
                || fail "Pull failed — tag may have changed; check https://ollama.com/library"
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

    command -v ollama >/dev/null 2>&1 && ollama_server_up || { warn "No server — skipping throughput test."; return 0; }
    echo
    info "Installed models:"
    ollama list

    local first
    first=$(ollama list 2>/dev/null | awk 'NR==2 {print $1}')
    [ -z "$first" ] && { warn "No models installed — nothing to benchmark."; return 0; }
    if ask "Run a quick throughput test on ${first}?"; then
        info "Watch the 'eval rate' line — expect tens of tokens/sec on MoE models."
        ollama run "$first" --verbose "Write a Python function that merges two sorted lists." || true
    fi
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
    installOllamaModels
    installOllamaVerification
    echo
    echo "Done. See AI_CompatibilityReport.md for tuning (GPU wired limit, quantization picks)."
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    installOllama
fi
