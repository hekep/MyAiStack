#!/bin/bash
#
# install.sh — Local AI coding stack installer (universal, function-based)
#
# Every step is an independent function, prefixed aistackInstall*. Each function
# checks its own prerequisites and whether the work is already done, and
# proposes an update when one is available — so the script (or any single
# function) can be run any number of times.
#
# Steps carrying "Ollama" in the name are engine-specific; the others apply to
# the stack as a whole (and stay put when other engines are added).
#
#   aistackInstallSanity          platform + host RAM detection (sets globals)
#   aistackInstallDiskGate        HARD BLOCK until enough free disk
#   aistackInstallHomebrew        Homebrew present / updated
#   --- engines (at least one required; the wizard stops if none) ---
#   aistackInstallLlamacppEngine  llama.cpp   — default YES; reaches Q5_K_M/Q6_K
#   aistackInstallMlxmlEngine     MLX-LM      — default no; Apple-native, 6-bit
#   aistackInstallOllamaEngine    Ollama      — default no; managed daemon + API
#   --- shared ---
#   aistackInstallUv              uv (pulled in automatically by MLX-LM)
#   --- coding agents (what you type into) ---
#   aistackInstallPiCodingAgent        Pi        — default YES; any engine
#   aistackInstallOpenCodeCodingAgent  OpenCode  — default no;  any engine
#   aistackInstallClaudeCodingAgent    Claude    — default no;  Ollama only
#   --- tools (optional): MCP tool servers a launched model can call ---
#   aistackInstallTooluniverseTools    ToolUniverse — default no; biomedical tools, Tool_RAG, Finish
#   --- models, one step per engine, same order, each skipped if absent ---
#   aistackInstallLlamacppModels  GGUF files -> ~/Models/llama.cpp
#   aistackInstallMlxmlModels     HF repos   -> HuggingFace cache
#   aistackInstallOllamaModels    registry tags -> ~/.ollama
#   --- monitoring (optional, macOS-specific) ---
#   aistackInstallMacmonMonitoring     macmon     — default no; CPU/GPU/ANE + memory
#   aistackInstallAnubisMonitoring     Anubis OSS — default no; LLM benchmarking app
#   aistackInstallLitellmMonitoring    LiteLLM  — default no;  proxy logging / OTel
#   aistackInstallVerification    status summary
#   aistackInstall                wrapper — runs all of the above in order
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

# Print a progress heading ("==> ...") naming the step about to run.
info()  { echo "${BLUE}==>${RESET} $*"; }
# Print a success line — also used for "already installed and current",
# so a re-run reads the same whether work happened or not.
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
# Print a caution line: a caveat, or something skipped by your choice.
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
# Print an error line for something that was attempted and failed.
fail()  { echo "${RED} ✗ ${RESET} $*"; }

# A real, pasteable tag for one engine — an installed model if there is one,
# otherwise the smallest entry from that engine's catalog.
# Args: <engine>. Prints nothing when neither is available.
_liveTagFor() {
    local engine="$1" t f
    case "$engine" in
        Ollama)    t=$(ollamaListInstalled 2>/dev/null | head -1) ;;
        Llama.cpp) t=$(llamacppListInstalled 2>/dev/null | head -1) ;;
        MLX-LM)    t=$(mlxmlListInstalled 2>/dev/null | head -1) ;;
    esac
    [ -n "$t" ] && { echo "$t"; return 0; }
    f=$(MODEL_LIST_ENGINE="$engine" modelListFile "$(( $(sysctl -n hw.memsize) / 1073741824 ))" 2>/dev/null)
    [ -f "$f" ] && python3 -c '
import json,sys
try:
    ms=json.load(open(sys.argv[1]))["models"]
    print(sorted(ms, key=lambda m: m["size_gb"])[0]["tag"])
except Exception: pass' "$f"
}

# Build an "example :" line for the install-side helpers from live data, and
# say what to install first when there is nothing to point at.
# Args: <function-name> <kind>  (kind: ollama-tag | gguf-tag | mlx-repo | any)
_hintTagExample() {
    local fn="$1" kind="$2" t pad="\n         "
    case "$kind" in
        ollama-tag) t=$(_liveTagFor Ollama) ;;
        gguf-tag)   t=$(_liveTagFor Llama.cpp) ;;
        mlx-repo)   t=$(_liveTagFor MLX-LM) ;;
        *)          t=$(_liveTagFor Ollama); [ -z "$t" ] && t=$(_liveTagFor Llama.cpp) ;;
    esac
    if [ -n "$t" ]; then printf '%s' "example : ${fn} ${t}"; return 0; fi
    printf '%b' "example : none possible yet — nothing installed and no catalog to read.${pad}install an engine:  aistackInstallLlamacppEngine   (or ...MlxmlEngine / ...OllamaEngine)${pad}then models:        aistackInstallLlamacppModels   (or ...MlxmlModels / ...OllamaModels)"
}

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

# Ask a yes/no question, looping until the answer is unambiguous.
# Reads /dev/tty so the prompt survives piped output, and aborts when there is
# no terminal. Returns 0 for yes, 1 for no; no Enter-default.
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

# Ask a yes/no question where Enter picks a caller-supplied default.
# Args: <question> <y|n>; the [Y/n] or [y/N] hint reflects it. Optional installs
# pass "n", expected ones pass "y", so a re-run is mostly Enter.
ask_def() {
    if [ $# -lt 2 ]; then
        aiStackUsage "ask_def <question> <y|n>" "example : ask_def "Install it?" y"
        return 2
    fi
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

# Free space on the data volume in whole GB.
# Every disk decision here reads this rather than trusting an earlier value:
# a 30 GB download changes the answer mid-run.
free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }

# ---------- registry tag availability (cached 24 h) --------------------------
# Neither the Ollama registry nor HuggingFace has a list-everything endpoint,
# so this does the next-best thing: one tiny existence probe per candidate tag,
# all in parallel, cached for a day — first run ~2 s, reruns instant. A tag
# containing "/" is a HuggingFace repo (llama.cpp GGUF, MLX); otherwise it is
# an Ollama registry tag.
TAG_CHECK_DEADLINE="${TAG_CHECK_DEADLINE:-20}"
TAG_CACHE_DIR="$HOME/.cache/ollama-tag-check"
# Path of the cache entry for one model tag's availability probe.
# Args: <tag>. Slashes and colons become underscores so any tag is a filename.
tag_cache_file() { [ $# -ge 1 ] || { aiStackUsage "tag_cache_file <tag>" "$(_hintTagExample tag_cache_file any)"; return 2; }; echo "$TAG_CACHE_DIR/$(echo "$1" | tr ':/' '__')"; }
# Probe whether one model tag exists upstream, caching the result for 24 h.
# Args: <tag>. A tag containing "/" is a HuggingFace repo, otherwise an Ollama
# registry tag. Meant to be run in parallel for a whole menu; the cache makes
# the first render ~2 s and every later one instant.
tag_check_prefetch() {   # probe one tag and cache the HTTP status
    if [ $# -lt 1 ]; then
        aiStackUsage "tag_check_prefetch <tag>" \
            "tag     : ollama tag, or org/repo[:quant] for HuggingFace" \
            "$(_hintTagExample tag_check_prefetch any)"
        return 2
    fi
    local f code name="${1%%:*}" t="${1#*:}" url
    f=$(tag_cache_file "$1")
    mkdir -p "$TAG_CACHE_DIR"
    [ -f "$f" ] && [ -n "$(find "$f" -mmin -1440 2>/dev/null)" ] && return 0
    case "$name" in
        */*) url="https://huggingface.co/api/models/${name#hf.co/}" ;;   # HF repo: llama.cpp GGUF or MLX
        *)   url="https://registry.ollama.ai/v2/library/${name}/manifests/${t}" ;;
    esac
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "$url" 2>/dev/null)
    echo "${code:-000}" > "$f"
}
# Probe a whole menu's tags in parallel, under a hard deadline. Args: <tag>...
# curl's own --max-time bounds a transfer, but not a name lookup that never
# returns: on a flaky or captive network the resolver can outlive it, and a bare
# "wait" then blocks the installer with no way out but Ctrl-C. Stragglers are
# killed when the deadline passes and their tags are simply left unverified,
# which tag_available already treats as available — the model is offered and, at
# worst, fails at download. Interrupting only abandons the check, not the wizard.
_tagVerifyAll() {
    [ $# -ge 1 ] || return 0
    local pids=() pid tag waited=0 alive skipped=0
    trap 'skipped=1' INT
    for tag in "$@"; do
        tag_check_prefetch "$tag" &
        pids+=($!)
    done
    while [ "$waited" -lt "$TAG_CHECK_DEADLINE" ] && [ "$skipped" = "0" ]; do
        alive=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && { alive=1; break; }; done
        [ "$alive" = "0" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    trap - INT
    local stuck=0
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            stuck=$((stuck + 1))
            { pkill -P "$pid"; kill -9 "$pid"; } 2>/dev/null
        fi
        # Reap OUR pid, one at a time, never a bare "wait". A bare wait blocks
        # on every background job this shell owns — and by this point that
        # includes the Ollama daemon started with "nohup ollama serve &", which
        # never exits. That is what hung the installer here in the first place.
        # stderr is closed because bash announces "Terminated"/"Killed" for a
        # job it reaps, and that noise reads as a failure mid-install.
        { wait "$pid"; } 2>/dev/null
    done
    if [ "$skipped" = "1" ]; then
        warn "Upstream check skipped — every candidate is offered unverified."
    elif [ "$stuck" -gt 0 ]; then
        warn "${stuck} probe(s) did not answer within ${TAG_CHECK_DEADLINE}s — offered unverified."
        warn "The registry may be slow or unreachable; a download would still tell you."
    fi
    return 0
}

# True when a probed tag exists (HTTP 200).
# Args: <tag>. An unreachable network (000/empty) counts as available: better to
# offer a model and fail at download than to hide everything while offline.
tag_available() {        # 200 = exists; 000/empty (offline) = benefit of the doubt
    if [ $# -lt 1 ]; then
        aiStackUsage "tag_available <tag>" \
            "run tag_check_prefetch <tag> first" \
            "$(_hintTagExample tag_available any)"
        return 2
    fi
    local c
    c=$(cat "$(tag_cache_file "$1")" 2>/dev/null)
    [ "$c" = "200" ] || [ "$c" = "000" ] || [ -z "$c" ]
}

# ---------- failed-download cleanup ------------------------------------------
# Delete Ollama blobs that no manifest references — the debris of failed pulls.
# Args: [ask] to confirm first, since leftovers can also resume an interrupted
# download. Skips entirely while a pull is running and never touches a file that
# is open, so an in-flight 30 GB download cannot be destroyed by cleanup.
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
# True when the Ollama API answers on OLLAMA_API:11434.
ollama_server_up() { curl -sf "http://${OLLAMA_API}:11434/api/version" >/dev/null 2>&1; }
# This Mac's LAN address on en0, falling back to en1. Empty when offline.
lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null; }

# True when Ollama already has this exact tag. Args: <tag>.
model_installed() { [ $# -ge 1 ] || { aiStackUsage "model_installed <ollama-tag>" "$(_hintTagExample model_installed ollama-tag)"; return 2; }; ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$1"; }

# ---------- engine detection --------------------------------------------------
# True when llama.cpp is installed (llama-cli or llama-server on PATH).
llamacpp_installed() { command -v llama-cli >/dev/null 2>&1 || command -v llama-server >/dev/null 2>&1; }
# True when MLX-LM is installed as a uv tool.
mlxml_installed()    { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^mlx-lm'; }
# True when the ollama binary is on PATH.
ollama_installed()   { command -v ollama >/dev/null 2>&1; }

# Space-separated list of engines present, empty when none.
# The wrapper uses this as a gate: with no engine, every step below it — models
# included — would be meaningless, so the wizard stops there.
installed_engines() {
    local e=""
    llamacpp_installed && e="${e} llama.cpp"
    mlxml_installed    && e="${e} MLX-LM"
    ollama_installed   && e="${e} Ollama"
    echo "${e# }"
}

# Check there is room for a download, and say so either way.
# Args: <GB needed> <what for>. Returns 1 when short, printing both numbers.
# Called immediately before each pull, not once at the start.
require_disk() {
    if [ $# -lt 2 ]; then
        aiStackUsage "require_disk <GB-needed> <what-for>" "example : require_disk 25 qwen3.6-plus-headroom"
        return 2
    fi
    local need=$1 what=$2 have
    have=$(free_gb)
    if [ "$have" -lt "$need" ]; then
        fail "Not enough disk for ${what}: need ~${need} GB free, have ${have} GB."
        return 1
    fi
    ok "Disk OK for ${what} (${have} GB free, need ~${need} GB)."
}

# ---------- step: sanity — platform + host RAM (sets TOTAL_GB / GPU_GB) ------
# Step 1: confirm the machine can run this at all, and measure it.
# Requires Apple Silicon macOS and at least 16 GB RAM. Sets TOTAL_GB and GPU_GB
# (~75 % of RAM, the default Metal allocation), which size every later menu.
aistackInstallSanity() {
    info "aistackInstallSanity — platform and memory detection"
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
# Step 2: HARD BLOCK until there is enough free disk. No bypass.
# Below 25 GB it shows the shortfall and the measured disk hogs, offers to delete
# local Time Machine snapshots (they pin freed space, making cleanup look
# useless), and loops on Enter to re-check until the requirement is met.
aistackInstallDiskGate() {
    info "aistackInstallDiskGate — disk space (need >= ${MIN_DISK_GB} GB, ${RECOMMENDED_DISK_GB}+ recommended)"
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
# Step 3: make sure Homebrew is present, offering to install it.
# Everything below depends on it, so declining ends the wizard rather than
# producing a half-built stack.
aistackInstallHomebrew() {
    info "aistackInstallHomebrew — package manager"
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
# Engine step, default no: install or migrate Ollama.
# Its advantages are a managed daemon and the Anthropic API that Claude Code
# needs; its quant ladder is the narrowest. A standalone Ollama.app is offered
# the migration to the brew formula, keeping the models in ~/.ollama.
aistackInstallOllamaEngine() {
    info "aistackInstallOllamaEngine — the Ollama runtime"
    command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew (run aistackInstallHomebrew)."; return 1; }

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
# Start the Ollama daemon if it is not already up, quietly.
# Downloads need the daemon, but serving is launchInference.sh's job — so this
# deliberately does not ask about context size or network exposure.
ollama_ensure_daemon() {
    ollama_server_up && return 0
    info "Starting the Ollama daemon (needed to download models)..."
    nohup ollama serve >/dev/null 2>&1 &
    sleep 3
    ollama_server_up || { fail "Could not start the Ollama daemon."; return 1; }
    OLLAMA_STARTED_BY_INSTALLER=1
    ok "Daemon running on ${OLLAMA_API}:11434 — will be stopped again when the downloads are done."
}

# Stop the daemon again, but only if this run started it. A daemon that was
# already up belongs to the user and is left alone. Ollama is not the dominant
# engine here: leaving it running would make the next launch of llama.cpp or
# MLX-LM ask "Also stop the Ollama daemon itself?" about a process nobody
# consciously started.
ollama_release_daemon() {
    [ "${OLLAMA_STARTED_BY_INSTALLER:-0}" = "1" ] || return 0
    pkill -f "ollama serve" 2>/dev/null
    OLLAMA_STARTED_BY_INSTALLER=0
    ok "Ollama daemon stopped — it was started only for the downloads."
}

# ---------- step: uv ---------------------------------------------------------
# Install uv, the Python tool manager MLX-LM is delivered through.
# Args: [required] to install without asking, used when another step depends on
# it — you already agreed to MLX-LM, so being asked again is noise.
aistackInstallUv() {
    info "aistackInstallUv — Python tool manager (needed by MLX-LM)"
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
# Engine step, default YES: install llama.cpp via Homebrew.
# Recommended first because it is the only engine here that reaches the Q5_K_M
# and Q6_K quants — Ollama's registry carries q4_K_M and q8_0 and nothing
# between. Already installed: offers an upgrade only when one actually exists.
aistackInstallLlamacppEngine() {
    info "aistackInstallLlamacppEngine — llama.cpp (GGUF engine)"
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
# Engine step, default no: install MLX-LM (Apple's own framework) via uv.
# Usually the fastest inference on this chip and it publishes 6-bit builds.
# Pulls uv in automatically when accepted; when already installed it checks PyPI
# and asks about an update only if there is one.
aistackInstallMlxmlEngine() {
    info "aistackInstallMlxmlEngine — MLX-LM (Apple-native engine)"
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
    aistackInstallUv required || { fail "MLX-LM needs uv — not installed."; return 1; }
    uv tool install mlx-lm && ok "MLX-LM installed." || { fail "mlx-lm install failed."; return 1; }
}

# ---------- Coding agents ------------------------------------------------------
# The agent is the thing you actually type into; the engine only serves tokens.
# Compatibility matters and is enforced in launchInference.sh:
#   Pi, OpenCode  -> any OpenAI-compatible endpoint (all three engines)
#   Claude Code   -> Anthropic Messages API only (Ollama)

# True when the Pi coding agent is on PATH.
pi_installed()       { command -v pi >/dev/null 2>&1; }
# True when OpenCode is on PATH.
opencode_installed() { command -v opencode >/dev/null 2>&1; }
# True when the Claude Code CLI is on PATH.
claude_installed()   { command -v claude >/dev/null 2>&1; }

# Space-separated list of coding agents present, empty when none.
installed_agents() {
    local a=""
    pi_installed       && a="${a} Pi"
    opencode_installed && a="${a} OpenCode"
    claude_installed   && a="${a} Claude"
    echo "${a# }"
}

# --- Pi (default YES) ---------------------------------------------------------
PI_NPM_PKG="@earendil-works/pi-coding-agent"
# Coding-agent step, default YES: install Pi and its local-model plugin.
# Recommended because it works with every engine here — it drives any
# OpenAI-compatible endpoint. Already installed: checks npm and offers an update
# only when a newer version exists.
aistackInstallPiCodingAgent() {
    info "aistackInstallPiCodingAgent — Pi (minimal terminal coding harness)"
    if pi_installed; then
        local cur latest
        cur=$(pi --version 2>/dev/null | head -1 | tr -d 'v')
        ok "Pi present: ${cur:-unknown}"
        latest=$(npm view "$PI_NPM_PKG" version 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "Pi update available: ${cur} -> ${latest}"
            ask_def "Update Pi now?" "y" && npm install -g --ignore-scripts "$PI_NPM_PKG"
        elif [ -z "$latest" ]; then
            ok "Update check skipped (npm registry unreachable)."
        else
            ok "Pi ${cur} is up to date."
        fi
        return 0
    fi
    command -v npm >/dev/null 2>&1 || { warn "npm not found — install Node first (brew install node)."; return 0; }
    echo "    Works with every engine here: it talks to any OpenAI-compatible server."
    if ! ask_def "Install the Pi coding agent?" "y"; then
        warn "Skipping Pi."
        return 0
    fi
    npm install -g --ignore-scripts "$PI_NPM_PKG" || { fail "npm install failed."; return 1; }
    ok "Pi installed: $(pi --version 2>/dev/null | head -1)"
    # local model discovery, so /models lists what our engines serve
    info "Adding local-model discovery (pi install npm:pi-local-models)..."
    pi install npm:pi-local-models >/dev/null 2>&1 \
        && ok "pi-local-models added." \
        || warn "Could not add pi-local-models — run 'pi install npm:pi-local-models' by hand."
}

# --- OpenCode (default NO) ----------------------------------------------------
# Coding-agent step, default no: install OpenCode via brew, npm as fallback.
# Also engine-agnostic. Already installed: offers an upgrade only when brew
# reports one.
aistackInstallOpenCodeCodingAgent() {
    info "aistackInstallOpenCodeCodingAgent — OpenCode (terminal agentic coder)"
    if opencode_installed; then
        ok "OpenCode present: $(opencode --version 2>/dev/null | head -1)"
        if brew list opencode >/dev/null 2>&1 && [ -n "$(brew outdated opencode 2>/dev/null)" ]; then
            warn "An OpenCode update is available."
            ask_def "Upgrade OpenCode now?" "y" && brew upgrade -y opencode
        else
            ok "Already up to date."
        fi
        return 0
    fi
    echo "    Also engine-agnostic: it drives any OpenAI-compatible endpoint."
    if ! ask_def "Install the OpenCode coding agent?" "n"; then
        warn "Skipping OpenCode."
        return 0
    fi
    if command -v brew >/dev/null 2>&1; then
        brew install -y opencode && ok "OpenCode installed." && return 0
        warn "brew install failed — trying npm."
    fi
    command -v npm >/dev/null 2>&1 || { fail "Neither brew nor npm could install OpenCode."; return 1; }
    npm install -g opencode-ai && ok "OpenCode installed." || { fail "npm install failed."; return 1; }
}

# --- Claude Code (default NO; Ollama-only) ------------------------------------
# Coding-agent step, default no: install the Claude Code CLI.
# Default no because it speaks the Anthropic API, so of the engines here it works
# with Ollama alone. Already installed: compares against the npm registry (which
# works for the native build too) and asks only when an update exists.
aistackInstallClaudeCodingAgent() {
    info "aistackInstallClaudeCodingAgent — Claude Code CLI"
    if claude_installed; then
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
    warn "claude CLI not installed."
    echo "    Note: Claude Code speaks the Anthropic API, so of the engines here it"
    echo "    only works with Ollama. Pi and OpenCode work with all three."
    if command -v npm >/dev/null 2>&1; then
        if ask_def "Install Claude Code now (npm install -g @anthropic-ai/claude-code)?" "n"; then
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

# ---------- per-engine adapters ----------------------------------------------
# Each engine supplies two functions: one that lists what is already installed
# (one tag per line) and one that downloads a tag. aiStackModelMenu does the
# rest, identically for every engine.

# List Ollama model tags, one per line.
# Falls back to reading ~/.ollama manifests when the daemon is down: the models
# are on disk either way, and without this a stopped daemon makes Ollama look
# like it has none — hiding it from menus it belongs in.
ollamaListInstalled() {
    if ollama list >/dev/null 2>&1; then
        ollama list 2>/dev/null | awk 'NR>1 {print $1}'
        return 0
    fi
    local base="$HOME/.ollama/models/manifests" f rel ns name tag
    [ -d "$base" ] || return 0
    find "$base" -type f 2>/dev/null | while read -r f; do
        rel=${f#"$base"/}                 # <registry>/<namespace>/<name>/<tag>
        rel=${rel#*/}                     # drop the registry host
        ns=${rel%%/*}; rel=${rel#*/}
        name=${rel%%/*}; tag=${rel#*/}
        [ "$ns" = "library" ] && echo "${name}:${tag}" || echo "${ns}/${name}:${tag}"
    done | sort
}

# Download one Ollama model, surviving the failures that actually happen.
# Args: <tag>. Retries transient errors up to three times (the download resumes
# each time), reports the real error rather than a guess, and keeps resumable
# data while cleaning up after a permanent failure.
ollamaPullModel() {
    if [ $# -lt 1 ]; then
        aiStackUsage "ollamaPullModel <ollama-tag>" \
            "$(_hintTagExample ollamaPullModel ollama-tag)"
        return 2
    fi
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

# Local path for one llama.cpp tag: org__repo@QUANT.gguf under the model dir.
# Args: <tag>. The encoding is reversible, which is how the launcher turns files
# on disk back into tags without keeping a separate index.
llamacppLocalFile() {
    if [ $# -lt 1 ]; then
        aiStackUsage "llamacppLocalFile <tag>" \
            "tag     : hf-repo:QUANT" \
            "$(_hintTagExample llamacppLocalFile gguf-tag)"
        return 2
    fi
    echo "${LLAMACPP_MODEL_DIR}/$(printf '%s' "$1" | sed 's|/|__|g; s|:|@|').gguf"
}
# List downloaded GGUFs as tags by reversing that filename encoding.
llamacppListInstalled() {
    [ -d "$LLAMACPP_MODEL_DIR" ] || return 0
    local f b
    for f in "$LLAMACPP_MODEL_DIR"/*.gguf; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .gguf)
        printf '%s\n' "$(printf '%s' "$b" | sed 's|@|:|; s|__|/|g')"
    done
}
# List GGUF downloads that were interrupted, as "tag<TAB>bytes-so-far".
# A .part file holds real disk and is invisible to every menu, so the model
# step reports them rather than letting them accumulate unseen.
llamacppListPartial() {
    [ -d "$LLAMACPP_MODEL_DIR" ] || return 0
    local f b
    for f in "$LLAMACPP_MODEL_DIR"/*.gguf.part; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .gguf.part)
        printf '%s\t%s\n' "$(printf '%s' "$b" | sed 's|@|:|; s|__|/|g')" "$(fileSizeBytes "$f")"
    done
}

# Size of a file in bytes, 0 when it does not exist.
# macOS uses stat -f%z; the Debian copy of this function uses stat -c%s. That
# one flag is the whole platform difference in the download path.
fileSizeBytes() { [ -e "${1:-}" ] && stat -f%z "$1" 2>/dev/null || echo 0; }

# Download one GGUF for llama.cpp.
# Args: <tag>. Resolves the real filename AND its size from the repo tree first
# — uploaders name files differently, and the size is what makes "finished" a
# fact instead of an assumption — then fetches with curl -C - so an interrupted
# download resumes instead of restarting — the thing Ollama's HF path cannot do.
#
# The bytes land in <name>.gguf.part and are renamed to <name>.gguf only once
# the file is complete. Without that, an in-progress download already satisfies
# the *.gguf glob every lister here uses, so a half-downloaded model shows up as
# installed, reports 0 GB, is hidden from the download menu, and fails to load.
llamacppPullModel() {
    if [ $# -lt 1 ]; then
        aiStackUsage "llamacppPullModel <tag>" \
            "tag     : hf-repo:QUANT — downloads the GGUF into ~/Models/llama.cpp" \
            "$(_hintTagExample llamacppPullModel gguf-tag)"
        return 2
    fi
    # NB: separate statements on purpose. bash expands every argument to
    # "local" before assigning any of them, so "local a=$1 b=${a%:*}" leaves b
    # empty — or worse, silently picks up a same-named variable from the
    # caller's scope (local is dynamically scoped), which is why this worked
    # from aiStackModelMenu but not when called directly.
    local tag="$1" out part meta meta_rc file expected have url repo quant
    repo="${tag%:*}"
    quant="${tag##*:}"
    out=$(llamacppLocalFile "$tag")
    part="${out}.part"
    mkdir -p "$LLAMACPP_MODEL_DIR"

    # resolve the real filename and its size — uploaders name files differently,
    # and LFS entries carry the true byte count in .lfs.size
    info "Resolving the ${quant} GGUF in ${repo}..."
    meta=$(curl -sf --max-time 25 "https://huggingface.co/api/models/${repo}/tree/main" 2>/dev/null \
        | python3 -c "
import json, re, sys
q = sys.argv[1]
try:
    t = json.load(sys.stdin)
except Exception:
    sys.exit(1)
# Uploaders disagree on the delimiter before the quant: bartowski writes
# repo-Q8_0.gguf, mradermacher writes repo.Q8_0.gguf. Matching only "-" silently
# found nothing in half the repos this catalogue lists.
pat = re.compile(r'(?:^|[-_.])%s(?:-\d+-of-\d+)?\.gguf$' % re.escape(q), re.I)
hits = []
for e in t:
    p = e.get('path', '')
    if e.get('type') == 'directory' or not pat.search(p):
        continue
    # mmproj is the vision projector that ships beside a multimodal model. It
    # carries the quant in its name and is a fraction of the size, so a loose
    # match downloads it instead of the weights and reports success.
    if 'mmproj' in p.lower():
        continue
    lfs = e.get('lfs') or {}
    hits.append((p, lfs.get('size') or e.get('size') or 0))
if not hits:
    sys.exit(1)
if len(hits) > 1:
    # a sharded model: every part is needed, and this downloader fetches one
    # file. Say so rather than pulling a fragment that cannot load.
    sys.stderr.write('SHARDED:%d\n' % len(hits))
    sys.exit(2)
print('%s\t%s' % hits[0])
" "$quant" 2>/dev/null)
    file=${meta%%$'\t'*}
    expected=${meta##*$'\t'}
    case "${expected:-}" in ''|*[!0-9]*) expected=0 ;; esac
    if [ -z "$file" ]; then
        if [ "$meta_rc" = "2" ]; then
            fail "${quant} in ${repo} is split across several files."
            warn "This downloader fetches one file; a sharded model needs every part."
            warn "Pick a smaller quant that fits in one file, or fetch it by hand."
        else
            fail "No ${quant} GGUF found in ${repo} — skipping."
        fi
        return 1
    fi

    # a .part that is already complete only needs its rename — the previous run
    # may have been interrupted between the last byte and the mv
    if [ -e "$part" ] && [ "$expected" -gt 0 ] && [ "$(fileSizeBytes "$part")" -eq "$expected" ]; then
        mv -f "$part" "$out"
        ok "${tag} was already fully downloaded — completed it ($(du -h "$out" 2>/dev/null | cut -f1))."
        return 0
    fi

    if [ -e "$out" ]; then
        have=$(fileSizeBytes "$out")
        if [ "$expected" -eq 0 ] || [ "$have" -eq "$expected" ]; then
            ok "${tag} is already downloaded ($(du -h "$out" 2>/dev/null | cut -f1))."
            return 0
        fi
        # a short .gguf is debris from an interrupted download taken before
        # completed files were distinguished by name — reopen it as .part so
        # this run resumes it rather than ignoring it or starting over
        warn "${out} is incomplete ($(( have / 1048576 )) MB of $(( expected / 1048576 )) MB) — resuming it."
        mv -f "$out" "$part"
    fi

    url="https://huggingface.co/${repo}/resolve/main/${file}"
    info "Downloading ${file}"
    echo "    -> ${out}"
    echo "    (arrives as $(basename "$part") and is renamed only when complete, so an"
    echo "     interrupted pull resumes and never looks like an installed model)"
    if curl -L --fail --progress-bar -C - -o "$part" "$url"; then
        have=$(fileSizeBytes "$part")
        if [ "$expected" -gt 0 ] && [ "$have" -ne "$expected" ]; then
            fail "Got ${have} bytes, expected ${expected} — keeping the partial file for a retry:"
            fail "  ${part}"
            return 1
        fi
        mv -f "$part" "$out"
        ok "${tag} downloaded ($(du -h "$out" 2>/dev/null | cut -f1))."
        return 0
    fi
    fail "Download failed — the partial file is kept so a retry resumes:"
    fail "  ${part}"
    return 1
}

# --- MLX-LM: HuggingFace repos in the standard HF cache ----------------------
MLX_HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# List MLX models in the HuggingFace cache as repo ids (models--org--repo).
mlxmlListInstalled() {
    [ -d "$MLX_HF_CACHE" ] || return 0
    local d b
    for d in "$MLX_HF_CACHE"/models--*; do
        [ -d "$d" ] || continue
        b=$(basename "$d")
        printf '%s\n' "$(printf '%s' "${b#models--}" | sed 's|--|/|')"
    done
}
# Download one MLX model into the HuggingFace cache.
# Args: <repo>. Uses huggingface_hub via 'uv run --with', so nothing extra is
# installed permanently, and already-fetched shards resume.
mlxmlPullModel() {
    if [ $# -lt 1 ]; then
        aiStackUsage "mlxmlPullModel <hf-repo>" \
            "$(_hintTagExample mlxmlPullModel mlx-repo)"
        return 2
    fi
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

MODEL_LIST_ENGINE="${MODEL_LIST_ENGINE:-Ollama}"     # Llama.cpp / MLX-LM later
AI_MODEL_CATALOG=()

# repo root = parent of the OS folder holding this script
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# modelListFile <host_ram_gb> — largest tier <= host RAM (smallest if below all)
modelListFile() {
    if [ $# -lt 1 ]; then
        aiStackUsage "modelListFile <host-ram-gb>" "example : modelListFile $(( $(sysctl -n hw.memsize) / 1073741824 ))"
        return 2
    fi
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
    if [ $# -lt 1 ]; then
        aiStackUsage "parseModelJson <catalog.json>" "example : parseModelJson ModelLists/Ollama/48_GB_Ram.json"
        return 2
    fi
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

# ---------- generic model menu, shared by every engine -----------------------
# The model menu, shared by all three engines.
# Args: <EngineFolder> <list-installed-fn> <pull-fn>. Loads that engine's
# catalog, hides models that do not fit the GPU limit or free disk, are already
# installed, or do not exist upstream — then loops until you answer N.
aiStackModelMenu() {
    if [ $# -lt 3 ]; then
        aiStackUsage "aiStackModelMenu <EngineFolder> <list-fn> <pull-fn>" "EngineFolder : Ollama | Llama.cpp | MLX-LM" "example : aiStackModelMenu Ollama ollamaListInstalled ollamaPullModel"
        return 2
    fi
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

        info "Verifying ${#menu_tags[@]} candidate tags upstream (parallel, cached 24 h, ${TAG_CHECK_DEADLINE}s limit)..."
        _tagVerifyAll "${menu_tags[@]}"
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
        echo "   N) No download — finish this step (Enter)"

        # Enter is the safe answer, N; anything else that is not a valid number
        # re-asks right here — `continue` on the outer loop would re-verify
        # every tag and reprint the menu.
        local sel
        while :; do
            printf "\n%sSelect a %s model to download [1-%d / N, Enter = N]:%s " "${BOLD}" "$engine" "${#menu_tags[@]}" "${RESET}"
            read -r sel </dev/tty || { echo; fail "No interactive terminal — aborting."; return 1; }
            case "$sel" in
                ""|[Nn]) ok "${engine} model downloads finished."; return 0 ;;
                *[!0-9]*) echo "Enter a number or N."; continue ;;
            esac
            if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#menu_tags[@]}" ]; then echo "Out of range (1-${#menu_tags[@]})."; continue; fi
            break
        done

        tag="${menu_tags[$((sel-1))]}"
        size=$(printf '%s\n' "${AI_MODEL_CATALOG[@]}" | awk -F'|' -v t="$tag" '$1==t {print $2; exit}')
        if require_disk $(( size + 5 )) "${tag} (~${size} GB + headroom)"; then
            "$pull_fn" "$tag" "$size"
        fi
        # loop: menu re-renders without the model just downloaded
    done
}

# ---------- model steps, one per engine (same order as the engine steps) ------
# Model step for llama.cpp: GGUF files into ~/Models/llama.cpp.
# Skipped with a notice when llama.cpp is not installed, since another engine
# may well be the one in use.
aistackInstallLlamacppModels() {
    info "aistackInstallLlamacppModels — GGUF models for llama.cpp"
    if ! llamacpp_installed; then
        warn "llama.cpp is not installed — skipping its model list."
        return 0
    fi
    echo "    Download directory: ${LLAMACPP_MODEL_DIR}"
    # interrupted downloads hold real disk and appear in no menu, so name them
    # here — where re-selecting the same model is what resumes them
    local t b
    if [ -n "$(llamacppListPartial)" ]; then
        warn "Interrupted downloads found (re-select the same model to resume):"
        while IFS=$'\t' read -r t b; do
            [ -n "$t" ] && printf "      %-52s %s MB so far\n" "$t" "$(( b / 1048576 ))"
        done < <(llamacppListPartial)
    fi
    aiStackModelMenu "Llama.cpp" llamacppListInstalled llamacppPullModel
}

# Model step for MLX-LM: HuggingFace repos into the HF cache.
# Skipped with a notice when MLX-LM is not installed.
aistackInstallMlxmlModels() {
    info "aistackInstallMlxmlModels — MLX models for MLX-LM"
    if ! mlxml_installed; then
        warn "MLX-LM is not installed — skipping its model list."
        return 0
    fi
    echo "    Download cache: ${MLX_HF_CACHE}"
    aiStackModelMenu "MLX-LM" mlxmlListInstalled mlxmlPullModel
}

# Model step for Ollama: registry tags into ~/.ollama.
# Skipped when Ollama is absent. Prunes the debris of earlier failed pulls first,
# so the free-space numbers the menu shows are honest.
aistackInstallOllamaModels() {
    info "aistackInstallOllamaModels — models for Ollama"
    if ! ollama_installed; then
        warn "Ollama is not installed — skipping its model list."
        return 0
    fi
    ollama_ensure_daemon || return 1
    # clean leftovers of interrupted/failed pulls first, so free-space is honest
    ollama_prune_orphan_blobs ask
    local rc=0
    aiStackModelMenu "Ollama" ollamaListInstalled ollamaPullModel || rc=$?
    ollama_release_daemon
    return $rc
}

# ---------- Tools ------------------------------------------------------------
# MCP tool servers a launched model calls through the generated agent plugins
# (mcp.sh). They sit above the coding agents — a plugin needs an agent to be
# wired into — and below the models, which are what call them. Optional.

# True when ToolUniverse is installed (uv tool, or on PATH some other way).
tooluniverse_installed() { command -v tooluniverse-smcp-server >/dev/null 2>&1 \
                           || { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^tooluniverse'; }; }

# Space-separated list of tool servers present, empty when none.
installed_tools() {
    local t=""
    tooluniverse_installed && t="${t} tooluniverse"
    echo "${t# }"
}

# Same knobs the launcher uses (launchInference.sh) — a different port here
# would register a connector the launcher never serves.
TOOLUNIVERSE_PORT="${TOOLUNIVERSE_PORT:-8765}"
TOOLUNIVERSE_ARGS="${TOOLUNIVERSE_ARGS:---compact-mode}"

# Register ToolUniverse as the MCP connector 'tooluniverse' and build the agent
# plugins. The build has to list the tools, so the server is started for the
# duration and stopped again — from then on the launcher owns it. mcp.sh is
# sourced in a subshell without -u: it is written for interactive shells.
_aiStackToolsConnect() {
    local root log pid code t=0 rc=0 url="http://127.0.0.1:${TOOLUNIVERSE_PORT}/mcp"
    local mcpdir="${MCP_HOME:-$HOME/.aistack/mcp}/tooluniverse"
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    log="$HOME/.aistack/tooluniverse-install.log"; mkdir -p "$HOME/.aistack"
    if [ -f "$mcpdir/server.json" ]; then
        ok "MCP connector 'tooluniverse' is registered ($(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["tools"]))' "$mcpdir/tools.json" 2>/dev/null || echo 0) tools listed)."
        ask_def "Rebuild its tool list and agent plugins now?" "n" || return 0
    else
        echo "    The model reaches ToolUniverse through an MCP connector: a generated Pi"
        echo "    extension (and OpenCode tools) calling the server on port ${TOOLUNIVERSE_PORT}."
        if ! ask_def "Register ToolUniverse as MCP connector 'tooluniverse' and build the plugins?" "y"; then
            warn "Skipped. Later:  aistackMcpAdd tooluniverse --url ${url} --no-auth"
            return 0
        fi
    fi
    if lsof -nP -iTCP:"${TOOLUNIVERSE_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
        fail "Port ${TOOLUNIVERSE_PORT} is busy — set TOOLUNIVERSE_PORT to a free one and re-run this step:"
        lsof -nP -iTCP:"${TOOLUNIVERSE_PORT}" -sTCP:LISTEN >&2
        return 1
    fi
    info "Starting ToolUniverse on ${url} for the build (${TOOLUNIVERSE_ARGS}) — log: ${log}"
    # shellcheck disable=SC2086  # TOOLUNIVERSE_ARGS is a flag list by design
    # tooluniverseServer.py = the same server with the Tool_RAG embedder on Metal
    local py="$HOME/.local/share/uv/tools/tooluniverse/bin/python" wrapper
    wrapper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tooluniverseServer.py"
    if [ -x "$py" ] && [ -f "$wrapper" ]; then
        nohup "$py" "$wrapper" --host 127.0.0.1 --port "${TOOLUNIVERSE_PORT}" ${TOOLUNIVERSE_ARGS} >"$log" 2>&1 </dev/null &
    else
        nohup tooluniverse-smcp-server --host 127.0.0.1 --port "${TOOLUNIVERSE_PORT}" ${TOOLUNIVERSE_ARGS} >"$log" 2>&1 </dev/null &
    fi
    pid=$!
    while [ "$t" -lt 180 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && break
        kill -0 "$pid" 2>/dev/null || { fail "ToolUniverse exited — last lines of ${log}:"; tail -5 "$log" >&2; return 1; }
        sleep 1; t=$((t+1))
    done
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        fail "ToolUniverse did not answer within ${t} s — see ${log}"; kill "$pid" 2>/dev/null; return 1
    fi
    ok "ToolUniverse answered after ${t} s."
    if [ -f "$mcpdir/server.json" ]; then
        ( set +u; . "$root/mcp.sh" && aistackMcpBuild tooluniverse ) || rc=1
    else
        ( set +u; . "$root/mcp.sh" && aistackMcpAdd tooluniverse --url "$url" --no-auth ) || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        echo "    Tool_RAG needs its embedding model (a 5.75 GiB download) and an embedding of"
        echo "    every tool description (minutes, once). Without them the first Tool_RAG call"
        echo "    in a session stalls. Later:  aistackLaunchInferenceWarmupTools"
        if ask_def "Download the Tool_RAG embedder and build its cache now?" "n"; then
            ( set +u; . "$(dirname "${BASH_SOURCE[0]}")/launchInference.sh"; aistackLaunchInferenceWarmupTools ) \
                || warn "Warm-up did not finish — run it later: aistackLaunchInferenceWarmupTools"
        fi
    fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    ok "ToolUniverse stopped — the launcher starts it when you say yes to it."
    [ "$rc" -eq 0 ] || warn "Connector step failed — retry with the server running: aistackMcpBuild tooluniverse"
    return $rc
}

# Tools step, default no: ToolUniverse — Harvard's biomedical tool server (FDA,
# ChEMBL, Open Targets, EuropePMC, ...) with Tool_RAG and Finish, the meta-tools
# ATHENA-R1 was trained on. Served locally over MCP; the launcher starts it on
# request. The [embedding] extra brings sentence-transformers and faiss for
# Tool_RAG; the 1.5B embedder itself (5.75 GiB) downloads on first use, not here.
aistackInstallTooluniverseTools() {
    info "aistackInstallTooluniverseTools — ToolUniverse (biomedical MCP tool server)"
    if tooluniverse_installed; then
        local cur latest
        cur=$(uv tool list 2>/dev/null | awk '/^tooluniverse /{print $2}' | tr -d 'v')
        ok "ToolUniverse present: ${cur:-unknown}"
        latest=$(curl -sf --max-time 10 https://pypi.org/pypi/tooluniverse/json 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "ToolUniverse update available: ${cur} -> ${latest}"
            ask_def "Update ToolUniverse now?" "y" && uv tool upgrade tooluniverse
        elif [ -z "$latest" ]; then
            ok "Update check skipped (PyPI unreachable)."
        else
            ok "ToolUniverse ${cur} is up to date."
        fi
        _aiStackToolsConnect
        return 0
    fi
    echo "    A local MCP server with hundreds of biomedical tools (FDA labels, ChEMBL,"
    echo "    Open Targets, EuropePMC, ...) plus Tool_RAG and Finish — what ATHENA-R1"
    echo "    was trained to call. Python package via uv, a few hundred MB with its"
    echo "    embedding libraries. The 5.75 GiB Tool_RAG embedder downloads on first use."
    if ! ask_def "Install ToolUniverse?" "n"; then
        warn "Skipping ToolUniverse."
        return 0
    fi
    aistackInstallUv required || { fail "ToolUniverse needs uv — not installed."; return 1; }
    if ! uv tool install "tooluniverse[embedding]"; then
        warn "Install failed on the default Python — retrying on 3.12, where every wheel exists..."
        uv tool install --python 3.12 "tooluniverse[embedding]" || { fail "tooluniverse install failed."; return 1; }
    fi
    ok "ToolUniverse installed: $(uv tool list 2>/dev/null | awk '/^tooluniverse /{print $2}')"
    _aiStackToolsConnect
}

# ---------- Monitoring -------------------------------------------------------
# Optional observability around the stack. macOS-specific by nature: a Debian
# port will want entirely different tools, which is why this layer lives here
# rather than in a shared file.

# True when macmon is on PATH.
macmon_installed()  { command -v macmon >/dev/null 2>&1; }
# True when Anubis OSS is installed. It is a macOS app, not a CLI, so the check
# is the bundle (or the cask record) — "command -v anubis" would never find it.
ANUBIS_APP="/Applications/Anubis OSS.app"
anubis_installed()  { [ -d "$ANUBIS_APP" ] || brew list --cask anubis-oss >/dev/null 2>&1; }
# True when the litellm CLI is available (installed as a uv tool).
litellm_installed() { command -v litellm >/dev/null 2>&1 || { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^litellm'; }; }

# Space-separated list of monitoring tools present, empty when none.
# Used by the verification step, and by anything that wants to report the
# stack's observability without re-probing each tool.
installed_monitoring() {
    local m=""
    macmon_installed  && m="${m} macmon"
    anubis_installed  && m="${m} anubis"
    litellm_installed && m="${m} litellm"
    echo "${m# }"
}

# Install or update one brew-delivered monitoring tool.
# Args: <formula> <label> <y|n default> <one-line reason>. Present -> checks
# brew outdated and asks only when an update actually exists; missing -> offers
# the install at the caller's default.
_aiStackMonitorBrew() {
    if [ $# -lt 4 ]; then
        aiStackUsage "_aiStackMonitorBrew <formula> <label> <y|n> <reason>" "example : _aiStackMonitorBrew macmon macmon n reason-text"
        return 2
    fi
    local formula="$1" label="$2" def="$3" why="$4"
    command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew."; return 1; }
    if command -v "$formula" >/dev/null 2>&1; then
        ok "${label} present: $("$formula" --version 2>/dev/null | head -1)"
        if brew list "$formula" >/dev/null 2>&1 && [ -n "$(brew outdated "$formula" 2>/dev/null)" ]; then
            warn "A newer ${label} is available."
            ask_def "Upgrade ${label} now?" "y" && brew upgrade -y "$formula"
        else
            ok "Already the latest version."
        fi
        return 0
    fi
    echo "    ${why}"
    if ask_def "Install ${label}?" "$def"; then
        brew install -y "$formula" && ok "${label} installed." || { fail "brew install ${formula} failed."; return 1; }
    else
        warn "Skipping ${label}."
    fi
}

# Monitoring step, default no: macmon — sudoless CPU/GPU/ANE and memory
# monitoring for Apple Silicon. Useful beside a running model, but nothing in
# the stack needs it, so it is offered rather than recommended.
aistackInstallMacmonMonitoring() {
    info "aistackInstallMacmonMonitoring — macmon (Apple Silicon performance monitor)"
    _aiStackMonitorBrew macmon "macmon" "n" \
        "Live CPU/GPU/ANE power and memory — run it beside a model to see what inference costs."
}

# Monitoring step, default no: Anubis OSS — a native macOS app that benchmarks
# and compares local models over any OpenAI-compatible endpoint, with hardware
# telemetry recorded alongside each run. The GUI counterpart to aiModelTest.sh,
# so it works against every engine this stack installs.
aistackInstallAnubisMonitoring() {
    info "aistackInstallAnubisMonitoring — Anubis OSS (local LLM benchmarking)"
    command -v brew >/dev/null 2>&1 || { fail "Prerequisite missing: Homebrew."; return 1; }
    if anubis_installed; then
        ok "Anubis OSS present: ${ANUBIS_APP}"
        # the cask sets auto_updates, so the app updates itself and plain
        # "brew outdated" stays silent by design — --greedy is what sees it
        if [ -n "$(brew outdated --cask --greedy anubis-oss 2>/dev/null)" ]; then
            warn "A newer Anubis OSS is available (the app can also update itself)."
            ask_def "Upgrade Anubis OSS via brew now?" "y" && brew upgrade --cask --greedy anubis-oss
        else
            ok "Already the latest version."
        fi
        return 0
    fi
    echo "    Benchmarks and compares local models over any OpenAI-compatible endpoint"
    echo "    (Ollama, llama.cpp, MLX...), with hardware telemetry per run. Needs macOS 15+."
    if ask_def "Install Anubis OSS?" "n"; then
        brew install -y --cask uncsoft/anubis/anubis-oss \
            && ok "Anubis OSS installed -> ${ANUBIS_APP}" \
            || { fail "brew install --cask uncsoft/anubis/anubis-oss failed."; return 1; }
    else
        warn "Skipping Anubis OSS."
    fi
}

# Monitoring step, default no: LiteLLM — an OpenAI-compatible proxy that logs
# every request and can export OpenTelemetry traces. Sits in front of the
# engines, so you can see what an agent actually sent and what it cost.
# Delivered through uv, like MLX-LM, rather than brew.
aistackInstallLitellmMonitoring() {
    info "aistackInstallLitellmMonitoring — LiteLLM proxy (request logging / OpenTelemetry)"
    if litellm_installed; then
        local cur latest
        cur=$(uv tool list 2>/dev/null | awk '/^litellm /{print $2}' | tr -d 'v')
        ok "LiteLLM present: ${cur:-unknown}"
        latest=$(curl -sf --max-time 10 https://pypi.org/pypi/litellm/json 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "LiteLLM update available: ${cur} -> ${latest}"
            ask_def "Update LiteLLM now?" "y" && uv tool upgrade litellm
        elif [ -z "$latest" ]; then
            ok "Update check skipped (PyPI unreachable)."
        else
            ok "LiteLLM ${cur} is up to date."
        fi
        return 0
    fi
    echo "    An OpenAI-compatible proxy in front of your engines: logs every request,"
    echo "    exports OpenTelemetry traces, and gives one endpoint for several models."
    if ! ask_def "Install the LiteLLM proxy?" "n"; then
        warn "Skipping LiteLLM."
        return 0
    fi
    aistackInstallUv required || { fail "LiteLLM needs uv — not installed."; return 1; }
    uv tool install "litellm[proxy]" && ok "LiteLLM installed." || { fail "litellm install failed."; return 1; }
}

# ---------- step: verification -----------------------------------------------
# Final step: report what is installed — engines, agents, tooling, models.
# Read-only. Benchmarking lives in aiModelTest.sh, and serving in
# launchInference.sh; installing should not start or measure anything.
aistackInstallVerification() {
    info "aistackInstallVerification — status summary"
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
    echo "${BOLD}  Coding agents${RESET}"
    pi_installed       && ok "Pi:        $(pi --version 2>/dev/null | head -1)"       || warn "Pi:        not installed"
    opencode_installed && ok "OpenCode:  $(opencode --version 2>/dev/null | head -1)" || warn "OpenCode:  not installed"
    claude_installed   && ok "Claude:    $(claude --version 2>/dev/null | head -1)"   || warn "Claude:    not installed (Ollama-only agent)"
    echo "${BOLD}  Tools${RESET}"
    tooluniverse_installed && ok "ToolUniverse: $(uv tool list 2>/dev/null | awk '/^tooluniverse /{print $2}') — MCP on port ${TOOLUNIVERSE_PORT}" \
                           || warn "ToolUniverse: not installed"
    echo "${BOLD}  Monitoring${RESET}"
    macmon_installed  && ok "macmon:    $(macmon --version 2>/dev/null | head -1)" || warn "macmon:    not installed"
    anubis_installed  && ok "Anubis OSS: installed"                                 || warn "Anubis OSS: not installed"
    litellm_installed && ok "LiteLLM:   installed"                                 || warn "LiteLLM:   not installed"
    echo "${BOLD}  Tooling${RESET}"
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
    if ollama_installed; then
        # read from the manifests when the daemon is down — it usually is, now
        # that the installer stops what it started
        local o
        o=$(ollamaListInstalled | grep -c . || true)
        echo "    Ollama (~/.ollama): ${o:-0}"
        ollamaListInstalled | sed 's/^/      /'
    fi
    echo
    echo "    Benchmark Ollama models with ./aiModelTest.sh or ./testAllAiModels.sh"
}

# ---------- wrapper ----------------------------------------------------------
# Wrapper: sanity, disk gate, Homebrew, engines, agents, models, verification.
# Hard-fails on the foundations and stops entirely when no engine was installed.
# Every step is independently callable, so this is only the convenient order.
aistackInstall() {
    echo "${BOLD}=============================================================${RESET}"
    echo "${BOLD} Local AI coding stack — installer (universal, re-runnable)${RESET}"
    echo "${BOLD}=============================================================${RESET}"
    aistackInstallSanity        || return 1
    aistackInstallDiskGate      || return 1
    aistackInstallHomebrew      || return 1

    # --- engine layer: most-recommended first, each independently optional ---
    aistackInstallLlamacppEngine
    aistackInstallMlxmlEngine
    aistackInstallOllamaEngine

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

    # --- coding agents: what you type into (engine-compatibility enforced
    #     later by launchInference.sh) ---
    aistackInstallPiCodingAgent
    aistackInstallOpenCodeCodingAgent
    aistackInstallClaudeCodingAgent
    # --- tools: MCP servers the model calls; plugged into the agents above ----
    aistackInstallTooluniverseTools

    # --- model layer: same order as the engines, each skipped if absent ------
    aistackInstallLlamacppModels
    aistackInstallMlxmlModels
    aistackInstallOllamaModels

    # --- monitoring: optional observability, asked before the verdict ---
    aistackInstallMacmonMonitoring
    aistackInstallAnubisMonitoring
    aistackInstallLitellmMonitoring

    aistackInstallVerification
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    aistackInstall
fi
