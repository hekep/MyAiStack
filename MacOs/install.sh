#!/bin/bash
#
# install.sh — Local AI coding stack installer (universal, function-based)
#
# Every step is an independent function, prefixed installAiStack*. Each function
# checks its own prerequisites and whether the work is already done, and
# proposes an update when one is available — so the script (or any single
# function) can be run any number of times.
#
# Steps carrying "Ollama" in the name are engine-specific; the others apply to
# the stack as a whole (and stay put when other engines are added).
#
#   installAiStackSanity          platform + host RAM detection (sets globals)
#   installAiStackDiskGate        HARD BLOCK until enough free disk
#   installAiStackHomebrew        Homebrew present / updated
#   --- engines (at least one required; the wizard stops if none) ---
#   installAiStackLlamacppEngine  llama.cpp   — default YES; reaches Q5_K_M/Q6_K
#   installAiStackMlxmlEngine     MLX-LM      — default no; Apple-native, 6-bit
#   installAiStackOllamaEngine    Ollama      — default no; managed daemon + API
#   --- shared ---
#   installAiStackUv              uv (pulled in automatically by MLX-LM)
#   installAiStackClaudeCli       Claude Code CLI (the agent frontend)
#   --- models, one step per engine, same order, each skipped if absent ---
#   installAiStackLlamacppModels  GGUF files -> ~/Models/llama.cpp
#   installAiStackMlxmlModels     HF repos   -> HuggingFace cache
#   installAiStackOllamaModels    registry tags -> ~/.ollama
#   installAiStackVerification    status summary
#   installAiStack                wrapper — runs all of the above in order
#
# Serving models (engine choice, context size, network exposure, keeping a
# model resident) is NOT an install concern — that is launchInference.sh.
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
# Neither the Ollama registry nor HuggingFace has a list-everything endpoint,
# so this does the next-best thing: one tiny existence probe per candidate tag,
# all in parallel, cached for a day — first run ~2 s, reruns instant. A tag
# containing "/" is a HuggingFace repo (llama.cpp GGUF, MLX); otherwise it is
# an Ollama registry tag.
TAG_CACHE_DIR="$HOME/.cache/ollama-tag-check"
tag_cache_file() { echo "$TAG_CACHE_DIR/$(echo "$1" | tr ':/' '__')"; }
tag_check_prefetch() {   # probe one tag and cache the HTTP status
    local f code name="${1%%:*}" t="${1#*:}" url
    f=$(tag_cache_file "$1")
    mkdir -p "$TAG_CACHE_DIR"
    [ -f "$f" ] && [ -n "$(find "$f" -mmin -1440 2>/dev/null)" ] && return 0
    case "$name" in
        */*) url="https://huggingface.co/api/models/${name#hf.co/}" ;;   # HF repo: llama.cpp GGUF or MLX
        *)   url="https://registry.ollama.ai/v2/library/${name}/manifests/${t}" ;;
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

# Where to reach the Ollama API (launchInference.sh may bind it to a LAN IP).
OLLAMA_API="${OLLAMA_API:-127.0.0.1}"
ollama_server_up() { curl -sf "http://${OLLAMA_API}:11434/api/version" >/dev/null 2>&1; }
lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null; }

model_installed() { ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$1"; }

# ---------- engine detection --------------------------------------------------
llamacpp_installed() { command -v llama-cli >/dev/null 2>&1 || command -v llama-server >/dev/null 2>&1; }
mlxml_installed()    { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^mlx-lm'; }
ollama_installed()   { command -v ollama >/dev/null 2>&1; }

# space-separated list of engines present, empty when none
installed_engines() {
    local e=""
    llamacpp_installed && e="${e} llama.cpp"
    mlxml_installed    && e="${e} MLX-LM"
    ollama_installed   && e="${e} Ollama"
    echo "${e# }"
}

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
installAiStackSanity() {
    info "installAiStackSanity — platform and memory detection"
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
installAiStackDiskGate() {
    info "installAiStackDiskGate — disk space (need >= ${MIN_DISK_GB} GB, ${RECOMMENDED_DISK_GB}+ recommended)"
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
installAiStackHomebrew() {
    info "installAiStackHomebrew — package manager"
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
installAiStackOllamaEngine() {
    info "installAiStackOllamaEngine — the Ollama runtime"
    command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew (run installAiStackHomebrew)."; return 1; }

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
            brew install -y ollama || { fail "brew install -y ollama failed."; return 1; }
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
            ask_def "Upgrade Ollama now?" "y" && brew upgrade -y ollama
        else
            ok "Already the latest version."
        fi
        return 0
    fi

    warn "Ollama not installed."
    echo "    Optional — llama.cpp or MLX-LM can serve models instead. Ollama's"
    echo "    advantages: a managed daemon, an Anthropic-compatible API for Claude"
    echo "    CLI, and one-command pulls; its quant ladder is the narrowest."
    ask_def "Install Ollama via Homebrew?" "n" || { warn "Skipping Ollama."; return 0; }
    brew install -y ollama || { fail "brew install -y ollama failed."; return 1; }
    ok "Installed: $(ollama --version 2>/dev/null)"
}

# ---------- Ollama daemon, only so that pulls work -------------------------
# NOTE: serving is NOT an install concern. Network exposure, context size and
# keeping a model resident all live in launchInference.sh. This helper only
# makes sure the daemon is up long enough to download models.
ollama_ensure_daemon() {
    ollama_server_up && return 0
    info "Starting the Ollama daemon (needed to download models)..."
    nohup ollama serve >/dev/null 2>&1 &
    sleep 3
    ollama_server_up || { fail "Could not start the Ollama daemon."; return 1; }
    ok "Daemon running on ${OLLAMA_API}:11434."
}

# ---------- step: uv ---------------------------------------------------------
# installAiStackUv [required]
# "required" installs without asking — used when another step depends on it.
installAiStackUv() {
    info "installAiStackUv — Python tool manager (needed by MLX-LM)"
    command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew."; return 1; }
    if command -v uv >/dev/null 2>&1; then
        ok "uv present: $(uv --version)"
        if brew list uv >/dev/null 2>&1 && [ -n "$(brew outdated uv 2>/dev/null)" ]; then
            warn "A newer uv is available."
            ask_def "Upgrade uv now?" "y" && brew upgrade -y uv
        fi
        return 0
    fi
    if [ "${1:-}" != "required" ]; then
        ask_def "Install uv via Homebrew?" "y" || { warn "Skipping — MLX-LM will be unavailable."; return 1; }
    else
        info "uv is required for MLX-LM — installing it."
    fi
    brew install -y uv && ok "uv installed." || { fail "uv install failed."; return 1; }
}

# ---------- step: mlx-lm -----------------------------------------------------
# ---------- engine step: llama.cpp (asked first, default YES) ----------------
installAiStackLlamacppEngine() {
    info "installAiStackLlamacppEngine — llama.cpp (GGUF engine)"
    command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew."; return 1; }
    if llamacpp_installed; then
        ok "llama.cpp present: $(llama-cli --version 2>&1 | head -1)"
        if brew list llama.cpp >/dev/null 2>&1 && [ -n "$(brew outdated llama.cpp 2>/dev/null)" ]; then
            warn "A newer llama.cpp is available."
            ask_def "Upgrade llama.cpp now?" "y" && brew upgrade -y llama.cpp
        else
            ok "Already the latest version."
        fi
        return 0
    fi
    echo "    The only engine here that reaches the Q5_K_M / Q6_K quants —"
    echo "    Ollama's registry stops at q4_K_M and q8_0."
    if ask_def "Install llama.cpp via Homebrew?" "y"; then
        brew install -y llama.cpp && ok "llama.cpp installed." || { fail "brew install -y llama.cpp failed."; return 1; }
    else
        warn "Skipping llama.cpp."
    fi
}

# ---------- engine step: MLX-LM (optional, default NO) -----------------------
installAiStackMlxmlEngine() {
    info "installAiStackMlxmlEngine — MLX-LM (Apple-native engine)"
    if mlxml_installed; then
        # installed: check PyPI automatically, ask only if an update exists
        local cur latest
        cur=$(uv tool list 2>/dev/null | awk '/^mlx-lm /{print $2}' | tr -d 'v')
        latest=$(curl -sf --max-time 10 https://pypi.org/pypi/mlx-lm/json 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "mlx-lm update available: ${cur} -> ${latest}"
            ask_def "Update MLX-LM now?" "y" && uv tool upgrade mlx-lm
        elif [ -z "$latest" ]; then
            ok "MLX-LM ${cur:-?} installed (update check skipped — PyPI unreachable)."
        else
            ok "MLX-LM ${cur} is up to date."
        fi
        return 0
    fi
    echo "    Apple's own array framework — usually the fastest inference on this chip,"
    echo "    and it reaches 6-bit builds. Needs uv (installed automatically if accepted)."
    if ! ask_def "Install MLX-LM?" "n"; then
        warn "Skipping MLX-LM."
        return 0
    fi
    installAiStackUv required || { fail "MLX-LM needs uv — not installed."; return 1; }
    uv tool install mlx-lm && ok "MLX-LM installed." || { fail "mlx-lm install failed."; return 1; }
}

# ---------- step: Claude Code CLI --------------------------------------------
installAiStackClaudeCli() {
    info "installAiStackClaudeCli — Claude Code CLI (frontend used by launchInference.sh)"
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
    warn "claude CLI not installed — launchInference.sh needs it for Claude sessions."
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
# The catalog is DATA, not code: ModelLists/<Engine>/<RAM>_GB_Ram.json holds a
# curated top-20 of code-generation models per RAM tier, biggest first, with
# real download sizes read from the registry manifests. loadModelCatalog picks
# the file matching this host and fills AI_MODEL_CATALOG with
# "tag|size_gb|description" lines.
#
# The menu then filters further: fits the CURRENT GPU limit (need = size*1.3+2),
# fits free disk, not already downloaded, tag verified on the registry.
#
# NOTE: hf.co/* GGUF entries are deliberately absent — direct HuggingFace pulls
# fail on this Ollama version with "context deadline exceeded" at the final
# commit (reproduced 3x with successful blob downloads; registry pulls work
# fine). That also means Q5_K_M / Q6_K quants are unavailable: the Ollama
# registry offers q4_K_M and q8_0.

MODEL_LIST_ENGINE="${MODEL_LIST_ENGINE:-Ollama}"     # Llama.cpp / MLX-LM later
AI_MODEL_CATALOG=()

# repo root = parent of the OS folder holding this script
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# modelListFile <host_ram_gb> — largest tier <= host RAM (smallest if below all)
modelListFile() {
    local ram="$1" dir f tier best="" smallest=""
    dir="${REPO_ROOT}/ModelLists/${MODEL_LIST_ENGINE}"
    [ -d "$dir" ] || return 1
    for f in "$dir"/*_GB_Ram.json; do
        [ -e "$f" ] || continue
        tier=$(basename "$f"); tier=${tier%_GB_Ram.json}
        case "$tier" in ""|*[!0-9]*) continue ;; esac
        if [ -z "$smallest" ] || [ "$tier" -lt "$smallest" ]; then smallest="$tier"; fi
        if [ "$tier" -le "$ram" ]; then
            if [ -z "$best" ] || [ "$tier" -gt "$best" ]; then best="$tier"; fi
        fi
    done
    [ -z "$best" ] && best="$smallest"          # host below every tier
    [ -z "$best" ] && return 1                  # no lists at all
    echo "${dir}/${best}_GB_Ram.json"
}

# parseModelJson <file> — emit "tag|size_gb|description" per model
parseModelJson() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$1" <<'PYEOF'
import json, sys
for m in json.load(open(sys.argv[1])).get("models", []):
    print("%s|%s|%s" % (m["tag"], m["size_gb"], m.get("description", "")))
PYEOF
    else
        # fallback: the generator writes exactly one model object per line
        sed -n 's/.*"tag": *"\([^"]*\)".*"size_gb": *\([0-9]*\).*"description": *"\([^"]*\)".*/\1|\2|\3/p' "$1"
    fi
}

# loadModelCatalog [host_ram_gb] — fill AI_MODEL_CATALOG from the JSON list
loadModelCatalog() {
    local ram="${1:-${TOTAL_GB:-0}}" file line
    [ "$ram" -gt 0 ] 2>/dev/null || ram=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    file=$(modelListFile "$ram") || {
        fail "No model lists found in ModelLists/${MODEL_LIST_ENGINE}/ — cannot offer models."
        return 1
    }
    AI_MODEL_CATALOG=()
    while IFS= read -r line; do
        [ -n "$line" ] && AI_MODEL_CATALOG+=("$line")
    done < <(parseModelJson "$file")
    if [ "${#AI_MODEL_CATALOG[@]}" -eq 0 ]; then
        fail "Could not parse $(basename "$file") — no models loaded."
        return 1
    fi
    ok "Model list: ${MODEL_LIST_ENGINE}/$(basename "$file") — ${#AI_MODEL_CATALOG[@]} models (host RAM ${ram} GB)."
}

# ---------- per-engine adapters ----------------------------------------------
# Each engine supplies two functions: one that lists what is already installed
# (one tag per line) and one that downloads a tag. aiStackModelMenu does the
# rest, identically for every engine.

# --- Ollama: pulls into ~/.ollama via the daemon ------------------------------
ollamaListInstalled() { ollama list 2>/dev/null | awk 'NR>1 {print $1}'; }

ollamaPullModel() {
    local tag="$1" pull_log attempt ok_pull=0 last_err=""
    info "Pulling ${tag}..."
    pull_log=$(mktemp "${TMPDIR:-/tmp}/ollama-pull.XXXXXX")
    for attempt in 1 2 3; do
        ollama pull "$tag" 2>&1 | tee "$pull_log"
        if [ "${PIPESTATUS[0]}" -eq 0 ]; then ok_pull=1; break; fi
        last_err=$(grep -i "error" "$pull_log" | tail -1)
        # transient errors (timeouts, resets): retry — the download RESUMES
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
            warn "Keeping downloaded data so a re-try resumes. (Cleanup runs on next step entry if you abandon it.)"
        else
            warn "Permanent-looking error (bad tag/manifest) — cleaning up its disk space."
            ollama_prune_orphan_blobs
        fi
    fi
    rm -f "$pull_log"
    [ "$ok_pull" -eq 1 ]
}

# --- llama.cpp: plain GGUF files, downloaded with resumable curl --------------
LLAMACPP_MODEL_DIR="${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}"

# tag "org/repo:QUANT" <-> local file "org__repo@QUANT.gguf"
llamacppLocalFile() {
    echo "${LLAMACPP_MODEL_DIR}/$(printf '%s' "$1" | sed 's|/|__|g; s|:|@|').gguf"
}
llamacppListInstalled() {
    [ -d "$LLAMACPP_MODEL_DIR" ] || return 0
    local f b
    for f in "$LLAMACPP_MODEL_DIR"/*.gguf; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .gguf)
        printf '%s\n' "$(printf '%s' "$b" | sed 's|@|:|; s|__|/|g')"
    done
}
llamacppPullModel() {
    local tag="$1" repo="${tag%:*}" quant="${tag##*:}" out file url
    out=$(llamacppLocalFile "$tag")
    mkdir -p "$LLAMACPP_MODEL_DIR"

    # resolve the real filename from the repo — uploaders name files differently
    info "Resolving the ${quant} GGUF in ${repo}..."
    file=$(curl -sf --max-time 25 "https://huggingface.co/api/models/${repo}/tree/main" 2>/dev/null \
        | python3 -c "
import json, sys
q = sys.argv[1]
try:
    t = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for e in t:
    p = e.get('path', '')
    if e.get('type') != 'directory' and p.endswith('-%s.gguf' % q):
        print(p); break
" "$quant" 2>/dev/null)
    if [ -z "$file" ]; then
        fail "No ${quant} GGUF found in ${repo} — skipping."
        return 1
    fi
    url="https://huggingface.co/${repo}/resolve/main/${file}"
    info "Downloading ${file}"
    echo "    -> ${out}"
    echo "    (resumable: if this is interrupted, re-select the model to continue)"
    if curl -L --fail --progress-bar -C - -o "$out" "$url"; then
        ok "${tag} downloaded ($(du -h "$out" 2>/dev/null | cut -f1))."
        return 0
    fi
    fail "Download failed — the partial file is kept so a retry resumes:"
    fail "  ${out}"
    return 1
}

# --- MLX-LM: HuggingFace repos in the standard HF cache ----------------------
MLX_HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}/hub"

mlxmlListInstalled() {
    [ -d "$MLX_HF_CACHE" ] || return 0
    local d b
    for d in "$MLX_HF_CACHE"/models--*; do
        [ -d "$d" ] || continue
        b=$(basename "$d")
        printf '%s\n' "$(printf '%s' "${b#models--}" | sed 's|--|/|')"
    done
}
mlxmlPullModel() {
    local tag="$1"
    command -v uv >/dev/null 2>&1 || { fail "uv is required to download MLX models."; return 1; }
    info "Downloading ${tag} into the HuggingFace cache (resumable)..."
    if uv run --quiet --with huggingface-hub python3 - "$tag" <<'PYEOF'
import sys
from huggingface_hub import snapshot_download
print(snapshot_download(sys.argv[1]))
PYEOF
    then
        ok "${tag} downloaded."
        return 0
    fi
    fail "Download failed for ${tag} (already-fetched shards are kept for resume)."
    return 1
}

# ---------- generic model menu, shared by every engine -----------------------
# aiStackModelMenu <EngineFolder> <list-installed-fn> <pull-fn>
# Filters: fits the current GPU limit, fits free disk, not already installed,
# tag verified to exist upstream. Biggest first, loops until "N".
aiStackModelMenu() {
    local engine="$1" list_fn="$2" pull_fn="$3"

    [ -z "${TOTAL_GB:-}" ] && TOTAL_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    MODEL_LIST_ENGINE="$engine"
    loadModelCatalog "$TOTAL_GB" || return 1

    # fit against the CURRENT GPU limit: raising iogpu.wired_limit_mb widens the menu
    local cur_limit_mb
    cur_limit_mb=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    if [ "$cur_limit_mb" -gt 0 ]; then
        ok "Using the currently set GPU limit: $(( cur_limit_mb / 1024 )) GB (iogpu.wired_limit_mb=${cur_limit_mb})."
        GPU_GB=$(( cur_limit_mb / 1024 ))
    else
        GPU_GB=$(( TOTAL_GB * 3 / 4 ))
        echo "    GPU limit is macOS default (~${GPU_GB} GB). Raising it unlocks bigger quants:"
        echo "      sudo sysctl iogpu.wired_limit_mb=$(( (TOTAL_GB - 5) * 1024 ))"
    fi

    while true; do
        local downloaded have_disk
        downloaded=$("$list_fn")
        have_disk=$(free_gb)
        echo
        echo "    Already installed for ${engine}:"
        [ -n "$downloaded" ] && echo "$downloaded" | sed 's/^/      /' || echo "      (none)"

        local menu_tags=() menu_lines=() entry tag size desc need hidden_disk=0
        for entry in "${AI_MODEL_CATALOG[@]}"; do
            IFS='|' read -r tag size desc <<< "$entry"
            need=$(( size * 13 / 10 + 2 ))                    # weights*1.3 + 2 GB overhead
            [ "$need" -gt "$GPU_GB" ] && continue             # doesn't fit this host's RAM
            echo "$downloaded" | grep -qxF "$tag" && continue # already present
            if [ $(( size + 5 )) -gt "$have_disk" ]; then     # doesn't fit free disk
                hidden_disk=$((hidden_disk+1)); continue
            fi
            menu_tags+=("$tag")
            menu_lines+=("$(printf '%-52s %3d GB  (needs ~%d GB RAM)  %s' "$tag" "$size" "$need" "$desc")")
        done
        [ "$hidden_disk" -gt 0 ] && warn "${hidden_disk} model(s) hidden — larger than the ${have_disk} GB of free disk allows."
        [ "${#menu_tags[@]}" -eq 0 ] && { ok "No further ${engine} models fit this host — done."; return 0; }

        info "Verifying ${#menu_tags[@]} candidate tags upstream (parallel, cached 24 h)..."
        for tag in "${menu_tags[@]}"; do tag_check_prefetch "$tag" & done
        wait
        local avail_tags=() avail_lines=() j
        for j in "${!menu_tags[@]}"; do
            if tag_available "${menu_tags[$j]}"; then
                avail_tags+=("${menu_tags[$j]}"); avail_lines+=("${menu_lines[$j]}")
            else
                warn "Not available upstream (hidden): ${menu_tags[$j]}"
            fi
        done
        [ "${#avail_tags[@]}" -eq 0 ] && { ok "No available ${engine} models remain — done."; return 0; }
        menu_tags=("${avail_tags[@]}"); menu_lines=("${avail_lines[@]}")
        while [ "${#menu_tags[@]}" -gt 25 ]; do
            unset 'menu_tags[${#menu_tags[@]}-1]' 'menu_lines[${#menu_lines[@]}-1]'
        done

        echo
        echo "${BOLD}${engine} models that fit this machine (~${GPU_GB} GB usable GPU, ${have_disk} GB free disk):${RESET}"
        local i
        for i in "${!menu_tags[@]}"; do printf "  %2d) %s\n" $((i+1)) "${menu_lines[$i]}"; done
        echo "   N) No download — finish this step"

        local sel
        printf "\n%sSelect a %s model to download [1-%d / N]:%s " "${BOLD}" "$engine" "${#menu_tags[@]}" "${RESET}"
        read -r sel </dev/tty || { echo; fail "No interactive terminal — aborting."; return 1; }
        case "$sel" in
            [Nn]) ok "${engine} model downloads finished."; return 0 ;;
            *[!0-9]*|"") echo "Enter a number or N."; continue ;;
        esac
        if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#menu_tags[@]}" ]; then echo "Out of range."; continue; fi

        tag="${menu_tags[$((sel-1))]}"
        size=$(printf '%s\n' "${AI_MODEL_CATALOG[@]}" | awk -F'|' -v t="$tag" '$1==t {print $2; exit}')
        if require_disk $(( size + 5 )) "${tag} (~${size} GB + headroom)"; then
            "$pull_fn" "$tag" "$size"
        fi
        # loop: menu re-renders without the model just downloaded
    done
}

# ---------- model steps, one per engine (same order as the engine steps) ------
installAiStackLlamacppModels() {
    info "installAiStackLlamacppModels — GGUF models for llama.cpp"
    if ! llamacpp_installed; then
        warn "llama.cpp is not installed — skipping its model list."
        return 0
    fi
    echo "    Download directory: ${LLAMACPP_MODEL_DIR}"
    aiStackModelMenu "Llama.cpp" llamacppListInstalled llamacppPullModel
}

installAiStackMlxmlModels() {
    info "installAiStackMlxmlModels — MLX models for MLX-LM"
    if ! mlxml_installed; then
        warn "MLX-LM is not installed — skipping its model list."
        return 0
    fi
    echo "    Download cache: ${MLX_HF_CACHE}"
    aiStackModelMenu "MLX-LM" mlxmlListInstalled mlxmlPullModel
}

installAiStackOllamaModels() {
    info "installAiStackOllamaModels — models for Ollama"
    if ! ollama_installed; then
        warn "Ollama is not installed — skipping its model list."
        return 0
    fi
    ollama_ensure_daemon || return 1
    # clean leftovers of interrupted/failed pulls first, so free-space is honest
    ollama_prune_orphan_blobs ask
    aiStackModelMenu "Ollama" ollamaListInstalled ollamaPullModel
}

# ---------- step: verification -----------------------------------------------
installAiStackVerification() {
    info "installAiStackVerification — status summary"
    echo
    echo "${BOLD}================= Install summary =================${RESET}"
    command -v brew >/dev/null 2>&1 && ok "Homebrew:  $(brew --version | head -1)" || fail "Homebrew:  missing"
    echo "${BOLD}  Engines${RESET}"
    llamacpp_installed && ok "llama.cpp: $(llama-cli --version 2>&1 | head -1)"    || warn "llama.cpp: not installed"
    mlxml_installed    && ok "MLX-LM:    $(uv tool list 2>/dev/null | awk '/^mlx-lm /{print $2}')" \
                       || warn "MLX-LM:    not installed"
    if ollama_installed; then
        ok "Ollama:    $(ollama --version 2>/dev/null)"
        ollama_server_up && ok "  server:  running on ${OLLAMA_API}:11434" || warn "  server:  not running"
    else
        warn "Ollama:    not installed"
    fi
    echo "${BOLD}  Frontend / tooling${RESET}"
    command -v claude >/dev/null 2>&1 && ok "claude:    $(claude --version 2>/dev/null | head -1)" || warn "claude:    not installed"
    command -v uv >/dev/null 2>&1     && ok "uv:        $(uv --version)"                           || warn "uv:        not installed"

    echo "${BOLD}  Models${RESET}"
    if llamacpp_installed; then
        local n
        n=$(llamacppListInstalled | grep -c . || true)
        echo "    llama.cpp (${LLAMACPP_MODEL_DIR}): ${n:-0}"
        llamacppListInstalled | sed 's/^/      /'
    fi
    if mlxml_installed; then
        local m
        m=$(mlxmlListInstalled | grep -c . || true)
        echo "    MLX-LM / HF cache: ${m:-0}"
        mlxmlListInstalled | sed 's/^/      /'
    fi
    if ollama_installed && ollama_server_up; then
        echo "    Ollama:"
        ollama list | sed 's/^/      /'
    fi
    echo
    echo "    Benchmark Ollama models with ./aiModelTest.sh or ./testAllAiModels.sh"
}

# ---------- wrapper ----------------------------------------------------------
installAiStack() {
    echo "${BOLD}=============================================================${RESET}"
    echo "${BOLD} Local AI coding stack — installer (universal, re-runnable)${RESET}"
    echo "${BOLD}=============================================================${RESET}"
    installAiStackSanity        || return 1
    installAiStackDiskGate      || return 1
    installAiStackHomebrew      || return 1

    # --- engine layer: most-recommended first, each independently optional ---
    installAiStackLlamacppEngine
    installAiStackMlxmlEngine
    installAiStackOllamaEngine

    # GATE: nothing below this line means anything without an engine
    local engines
    engines=$(installed_engines)
    if [ -z "$engines" ]; then
        echo
        fail "No inference engine installed — cancelling the rest of the wizard."
        warn "Re-run and accept at least one of llama.cpp / MLX-LM / Ollama."
        return 1
    fi
    ok "Engines available: ${engines}"

    installAiStackClaudeCli

    # --- model layer: same order as the engines, each skipped if absent ------
    installAiStackLlamacppModels
    installAiStackMlxmlModels
    installAiStackOllamaModels

    installAiStackVerification
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    installAiStack
fi
