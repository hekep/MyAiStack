#!/bin/bash
#
# launchInference.sh — pick an engine, a model and a context size, serve it,
#                      and (where supported) hand it to the Claude CLI.
#
# Installing is install.sh's job. This script owns everything about *running*:
# which engine, which model, how much context, which network interface, how
# much memory to free first, and how to keep the model resident.
#
#   launchInferenceEngineSelector    -> engine (asked only if several exist)
#   launchInferenceModelSelector     -> a model installed FOR that engine
#   launchInferenceContextSelector   -> 32K / 64K / 128K (default) / bigger
#   launchInferenceNetworkSelector   -> localhost or LAN, for ANY engine
#   launchInferenceFreeResources     -> close memory-hungry desktop apps
#   launchInferenceKillPrevious      -> stop engines/models already serving, so
#                                       the new model gets the whole machine
#   launchInferencePrerequisites     -> weights + KV cache must fit the GPU
#   launchInferenceStart             -> start the engine's server, report usage
#   launchInferenceAgentSelector     -> coding agent, filtered by engine
#                                       compatibility (self-answering when
#                                       only one option is valid)
#   launchInferenceStartAgent        -> Pi / OpenCode / Claude on the endpoint
#   launchInference                  -> wrapper: runs all of the above in order
#
# Usage:
#   ./launchInference.sh             # full flow
#   source launchInference.sh        # then call any function yourself
#
set -u

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

# Print a progress heading. Narration goes to stderr on purpose: several
# functions return their result on stdout, which must stay clean.
info()  { echo "${BLUE}==>${RESET} $*" >&2; }
# Print a success line to stderr — including "this was already true".
ok()    { echo "${GREEN} ✓ ${RESET} $*" >&2; }
# Print a caution line to stderr: a caveat, or a choice left unmade.
warn()  { echo "${YELLOW} ! ${RESET} $*" >&2; }
# Print an error line to stderr for something that did not work.
fail()  { echo "${RED} ✗ ${RESET} $*" >&2; }

# Yes/no question where Enter means YES.
# For the expected path of an action you already opted into (restart the server
# you asked to launch). Returns 0 for yes, 1 for no.
ask_yn() {   # Enter = yes
    local a; printf "%s%s%s [Y/n] " "${BOLD}" "$1" "${RESET}" >&2
    read -r a </dev/tty || return 1
    case "$a" in ""|[Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}
# Yes/no question where Enter means NO.
# For anything that could lose work — closing an app, stopping someone else's
# engine — so holding Enter never destroys anything. Returns 0 for yes.
ask_ny() {   # Enter = no
    local a; printf "%s%s%s [y/N] " "${BOLD}" "$1" "${RESET}" >&2
    read -r a </dev/tty || return 1
    case "$a" in [Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}
# Free-form question with a default; echoes the answer on stdout.
# Args: <question> <default>. Enter (or no terminal) yields the default, which
# is how every selector here becomes a single keystroke on a re-run.
ask_val() {  # free-form with default; echoes the answer
    local a; printf "%s%s%s [%s]: " "${BOLD}" "$1" "${RESET}" "$2" >&2
    read -r a </dev/tty || { echo "$2"; return; }
    echo "${a:-$2}"
}

# ---------- persisted choices (previous answer = next default) ---------------
SETTINGS_FILE="$HOME/.launchInference.conf"
# Read one persisted setting from ~/.launchInference.conf.
# Args: <key>. Prints the value, or nothing when unset.
# This is what makes the previous run's choice the next run's default.
tune_get() { [ -f "$SETTINGS_FILE" ] && sed -n "s/^$1=//p" "$SETTINGS_FILE" | tail -1; }
# Persist one setting to ~/.launchInference.conf, replacing any earlier value.
# Args: <key> <value>. Rewrites the file rather than appending, so the file
# does not grow one line per launch.
tune_set() {
    local tmp; tmp=$(grep -v "^$1=" "$SETTINGS_FILE" 2>/dev/null)
    { [ -n "$tmp" ] && printf '%s\n' "$tmp"; printf '%s=%s\n' "$1" "$2"; } > "$SETTINGS_FILE"
}

# ---------- engines -----------------------------------------------------------
LLAMACPP_MODEL_DIR="${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}"
MLX_HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}/hub"
OLLAMA_PORT=11434; LLAMACPP_PORT=8080; MLX_PORT=8081

# True when llama.cpp is available (llama-server or llama-cli on PATH).
# Engine presence, not model presence — enginesWithModels() checks the latter.
llamacpp_installed() { command -v llama-server >/dev/null 2>&1 || command -v llama-cli >/dev/null 2>&1; }

# PIDs of the llama-server WE run, identified by the port we serve on.
# Ollama spawns its own subprocess also called llama-server, so matching the
# bare name would kill Ollama's runner and break it. Never match by name.
llamacppOurPids()  { pgrep -f "llama-server .*--port ${LLAMACPP_PORT}" 2>/dev/null; }
# Stop only our llama-server, using the same port-scoped match.
# Safe to call when none is running; Ollama's internal runner is never touched.
llamacppKillOurs() { pkill  -f "llama-server .*--port ${LLAMACPP_PORT}" 2>/dev/null; }
# True when MLX-LM is installed as a uv tool.
mlxml_installed()    { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^mlx-lm'; }
# True when the ollama binary is on PATH.
ollama_installed()   { command -v ollama >/dev/null 2>&1; }

# This Mac's LAN address on en0, falling back to en1 (Wi-Fi vs Ethernet).
# Empty when offline, which the network selector treats as localhost-only.
lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null; }

# Print a usage message for a step called with missing arguments, return 2.
# Args: <signature> [detail lines...]. Every step is individually callable from
# the shell, so a bare call has to explain itself instead of emitting a raw
# bash "parameter null or not set".
aiStackUsage() {
    local sig="$1"; shift
    fail "usage: ${sig}"
    local l
    for l in "$@"; do echo "         ${l}" >&2; done
    return 2
}

# Help lines resolved live, so they name what THIS machine actually has rather
# than a generic placeholder.
_hintEngine() {
    local e; e=$(enginesWithModels | tr '\n' ' ' | sed 's/ $//')
    echo "engine  : ${e:-none installed — run ./install.sh}"
}
_hintModel() {
    echo "model   : one of that engine's models — list: engineListInstalled <engine>"
}

# ---------- coding agents + engine compatibility -----------------------------
# True when the Pi coding agent is on PATH.
pi_installed()       { command -v pi >/dev/null 2>&1; }
# True when OpenCode is on PATH.
opencode_installed() { command -v opencode >/dev/null 2>&1; }
# True when the Claude Code CLI is on PATH.
claude_installed()   { command -v claude >/dev/null 2>&1; }

# Can this coding agent actually drive this engine?
# Args: <agent> <engine>. Pi and OpenCode speak the OpenAI-compatible API every
# engine here serves; Claude Code needs the Anthropic Messages API, which only
# Ollama provides. This is the single rule that filters the agent menu.
agent_supports_engine() {   # $1 agent, $2 engine
    case "$1" in
        Pi|OpenCode) return 0 ;;
        Claude)      [ "$2" = "Ollama" ] ;;
        *)           return 1 ;;
    esac
}
# Explain, in one clause, why an agent cannot be used with an engine.
# Args: <agent>. Shown next to an installed-but-unusable agent so it is clear
# the option was withheld deliberately rather than forgotten.
agent_reason() {            # why an agent cannot be used with an engine
    case "$1" in
        Claude) echo "needs the Anthropic API — only Ollama serves it" ;;
        *)      echo "incompatible" ;;
    esac
}

# The port an engine serves on: Ollama 11434, llama.cpp 8080, MLX-LM 8081.
# Args: <engine>. Fixed per engine so several scripts agree without config.
engine_port() {
    case "$1" in
        Llama.cpp) echo "$LLAMACPP_PORT" ;;
        MLX-LM)    echo "$MLX_PORT" ;;
        Ollama)    echo "$OLLAMA_PORT" ;;
    esac
}
# Is this engine serving AND ready to infer?
# Args: <engine> <host>. llama.cpp is probed on /health because it answers 503
# on both /health and /v1/models while a model is still loading — treating
# "port open" as "ready" makes the first request fail.
engine_up() {   # $1 engine, $2 host — is it up AND ready to infer?
    local p; p=$(engine_port "$1")
    case "$1" in
        Ollama)    curl -sf --max-time 3 "http://${2}:${p}/api/version" >/dev/null 2>&1 ;;
        Llama.cpp) curl -sf --max-time 3 "http://${2}:${p}/health"      >/dev/null 2>&1 ;;
        *)         curl -sf --max-time 3 "http://${2}:${p}/v1/models"   >/dev/null 2>&1 ;;
    esac
}

# List what is actually HOLDING a model, as "engine|what|memory" rows.
# Ollama-resident models, our llama-server, mlx_lm.server. An idle Ollama daemon
# is deliberately excluded: it holds nothing, costs nothing and gets reused, so
# flagging it would be a false alarm.
busyEngines() {
    local pid rss m sz
    for m in $(ollama ps 2>/dev/null | awk 'NR>1 {print $1}'); do
        sz=$(ollama ps 2>/dev/null | awk -v M="$m" '$1==M {print $3" "$4}')
        echo "Ollama|model ${m} resident|${sz}"
    done
    for pid in $(llamacppOurPids); do
        rss=$(ps -o rss= -p "$pid" | awk '{printf "%.1f GB", $1/1048576}')
        echo "Llama.cpp|llama-server pid ${pid}|${rss}"
    done
    for pid in $(pgrep -f "mlx_lm.server" 2>/dev/null); do
        rss=$(ps -o rss= -p "$pid" | awk '{printf "%.1f GB", $1/1048576}')
        echo "MLX-LM|mlx_lm.server pid ${pid}|${rss}"
    done
}

# List what is serving, daemon included, as "engine|what|memory" rows.
# Broader than busyEngines(): used where stopping the daemon itself is on the
# table, not only where memory pressure matters.
runningEngines() {
    local pid rss
    if curl -sf --max-time 2 "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
        rss=$(ps -axo rss,command | awk '/[o]llama/ {s+=$1} END {printf "%.1f", s/1048576}')
        echo "Ollama|daemon on :${OLLAMA_PORT}|${rss} GB"
    fi
    for pid in $(llamacppOurPids); do
        rss=$(ps -o rss= -p "$pid" | awk '{printf "%.1f", $1/1048576}')
        echo "Llama.cpp|llama-server pid ${pid}|${rss} GB"
    done
    for pid in $(pgrep -f "mlx_lm.server" 2>/dev/null); do
        rss=$(ps -o rss= -p "$pid" | awk '{printf "%.1f", $1/1048576}')
        echo "MLX-LM|mlx_lm.server pid ${pid}|${rss} GB"
    done
}

# List the GGUF models on disk as engine tags, one per line.
# Reverses the on-disk encoding (org__repo@QUANT.gguf) back into org/repo:QUANT,
# so what is listed here can be fed straight back to the launcher.
llamacppListInstalled() {
    [ -d "$LLAMACPP_MODEL_DIR" ] || return 0
    local f b
    for f in "$LLAMACPP_MODEL_DIR"/*.gguf; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .gguf)
        printf '%s\n' "$(printf '%s' "$b" | sed 's|@|:|; s|__|/|g')"
    done
}
# List MLX models in the HuggingFace cache as repo ids, one per line.
# Reverses the cache layout (models--org--repo) into org/repo.
mlxmlListInstalled() {
    [ -d "$MLX_HF_CACHE" ] || return 0
    local d b
    for d in "$MLX_HF_CACHE"/models--*; do
        [ -d "$d" ] || continue
        b=$(basename "$d")
        printf '%s\n' "$(printf '%s' "${b#models--}" | sed 's|--|/|')"
    done
}
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

# List engines that are installed AND have at least one model, one per line.
# The shared filter behind every engine menu: an engine with nothing downloaded
# cannot be launched, so it is never offered as a choice.
enginesWithModels() {
    local e
    for e in Llama.cpp MLX-LM Ollama; do
        case "$e" in
            Llama.cpp) llamacpp_installed || continue ;;
            MLX-LM)    mlxml_installed    || continue ;;
            Ollama)    ollama_installed   || continue ;;
        esac
        [ "$(engineListInstalled "$e" | grep -c . || true)" -gt 0 ] && echo "$e"
    done
}

# List the models installed for one engine, one tag per line.
# Args: <engine>. Dispatches to the per-engine lister so callers stay generic.
engineListInstalled() {
    case "$1" in
        Llama.cpp) llamacppListInstalled ;;
        MLX-LM)    mlxmlListInstalled ;;
        Ollama)    ollamaListInstalled ;;
    esac
}

# On-disk size of one model in whole GB.
# Args: <engine> <model>. Reads the .gguf file, the HF cache directory, or
# 'ollama list' as appropriate. Feeds the context and fit calculations.
engineModelSizeGb() {
    local engine="$1" tag="$2" f d
    case "$engine" in
        Llama.cpp)
            f="${LLAMACPP_MODEL_DIR}/$(printf '%s' "$tag" | sed 's|/|__|g; s|:|@|').gguf"
            [ -e "$f" ] && du -m "$f" 2>/dev/null | awk '{printf "%d", $1/1024}' || echo 0 ;;
        MLX-LM)
            d="${MLX_HF_CACHE}/models--$(printf '%s' "$tag" | sed 's|/|--|')"
            [ -d "$d" ] && du -sm "$d" 2>/dev/null | awk '{printf "%d", $1/1024}' || echo 0 ;;
        Ollama)
            ollama list 2>/dev/null | awk -v t="$tag" '$1==t {print ($4=="GB")? $3 : 1; exit}' \
                | awk '{printf "%d", $1}' ;;
    esac
}

# ---------- 1. engine selector -----------------------------------------------
# Choose which engine to launch; prints it on stdout.
# Offers only engines that have models, naming any installed-but-empty ones once.
# Asks nothing when exactly one qualifies. Previous choice is the default.
launchInferenceEngineSelector() {
    local engines=() e empty=""
    while IFS= read -r e; do [ -n "$e" ] && engines+=("$e"); done < <(enginesWithModels)

    # engines that are installed but have nothing to run — named, not offered
    for e in Llama.cpp MLX-LM Ollama; do
        case "$e" in
            Llama.cpp) llamacpp_installed || continue ;;
            MLX-LM)    mlxml_installed    || continue ;;
            Ollama)    ollama_installed   || continue ;;
        esac
        [ "$(engineListInstalled "$e" | grep -c . || true)" -eq 0 ] && empty="${empty} ${e}"
    done
    [ -n "$empty" ] && warn "Installed but no models downloaded, so not offered:${empty}"

    if [ "${#engines[@]}" -eq 0 ]; then
        if [ -n "$empty" ]; then
            fail "No engine has any models — run ./install.sh to download one."
        else
            fail "No inference engine installed — run ./install.sh first."
        fi
        return 1
    fi
    if [ "${#engines[@]}" -eq 1 ]; then
        ok "Only one engine has models: ${engines[0]}"
        echo "${engines[0]}"
        return 0
    fi

    echo >&2
    echo "${BOLD}Engines with downloaded models:${RESET}" >&2
    local i=1 n
    for e in "${engines[@]}"; do
        n=$(engineListInstalled "$e" | grep -c . || true)
        printf "  %d) %-12s %s model(s)\n" "$i" "$e" "${n:-0}" >&2
        i=$((i+1))
    done
    local def sel
    def=$(tune_get ENGINE); def="${def:-${engines[0]}}"
    local defnum=1 j=1
    for e in "${engines[@]}"; do [ "$e" = "$def" ] && defnum=$j; j=$((j+1)); done
    while true; do
        sel=$(ask_val "Select engine [1-${#engines[@]}]" "$defnum")
        case "$sel" in *[!0-9]*|"") echo "Enter a number." >&2; continue ;; esac
        [ "$sel" -ge 1 ] && [ "$sel" -le "${#engines[@]}" ] && break
        echo "Out of range." >&2
    done
    tune_set ENGINE "${engines[$((sel-1))]}"
    echo "${engines[$((sel-1))]}"
}

# ---------- 2. model selector -------------------------------------------------
# Choose which of that engine's models to run; prints the tag on stdout.
# Args: <engine>. Lists sizes alongside names. When the engine has exactly one
# model it is announced and used — a question with one answer is not a choice.
launchInferenceModelSelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "launchInferenceModelSelector <engine>" "$(_hintEngine)" "example : launchInferenceModelSelector Ollama"
        return 2
    fi
    local engine="${1:-}" models=() m
    while IFS= read -r m; do [ -n "$m" ] && models+=("$m"); done < <(engineListInstalled "$engine")
    if [ "${#models[@]}" -eq 0 ]; then
        fail "No models installed for ${engine} — run ./install.sh to download one."
        return 1
    fi
    if [ "${#models[@]}" -eq 1 ]; then
        ok "Only one ${engine} model installed: ${models[0]} ($(engineModelSizeGb "$engine" "${models[0]}") GB)"
        echo "${models[0]}"
        return 0
    fi

    echo >&2
    echo "${BOLD}${engine} models:${RESET}" >&2
    local i=1 sz
    for m in "${models[@]}"; do
        sz=$(engineModelSizeGb "$engine" "$m")
        printf "  %2d) %-52s %s GB\n" "$i" "$m" "${sz:-?}" >&2
        i=$((i+1))
    done
    local def sel defnum=1 j=1
    def=$(tune_get "MODEL_${engine}")
    for m in "${models[@]}"; do [ "$m" = "$def" ] && defnum=$j; j=$((j+1)); done
    while true; do
        sel=$(ask_val "Select model [1-${#models[@]}]" "$defnum")
        case "$sel" in *[!0-9]*|"") echo "Enter a number." >&2; continue ;; esac
        [ "$sel" -ge 1 ] && [ "$sel" -le "${#models[@]}" ] && break
        echo "Out of range." >&2
    done
    tune_set "MODEL_${engine}" "${models[$((sel-1))]}"
    echo "${models[$((sel-1))]}"
}

# ---------- 3. context selector ----------------------------------------------
# Choose the context window; prints it in tokens on stdout.
# Args: <engine> <model>. Offers 32K/64K/128K (default) and larger, but only
# sizes whose weights + estimated KV cache + runtime fit the GPU budget; for
# Ollama it also hides anything above the model's own ceiling from /api/show.
launchInferenceContextSelector() {
    if [ $# -lt 2 ]; then
        aiStackUsage "launchInferenceContextSelector <engine> <model>" "$(_hintEngine)" "$(_hintModel)" "example : launchInferenceContextSelector Ollama qwen3.6:35b-a3b"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" size_gb gpu_gb total_gb limit_mb
    size_gb=$(engineModelSizeGb "$engine" "$model"); [ "${size_gb:-0}" -lt 1 ] && size_gb=1
    total_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    limit_mb=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    if [ "$limit_mb" -gt 0 ]; then gpu_gb=$(( limit_mb / 1024 )); else gpu_gb=$(( total_gb * 3 / 4 )); fi

    # model's own ceiling, when the engine can tell us (Ollama can)
    local model_max=0
    if [ "$engine" = "Ollama" ] && curl -sf --max-time 3 "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
        model_max=$(curl -sf --max-time 8 "http://127.0.0.1:${OLLAMA_PORT}/api/show" \
                    -d "{\"model\":\"${model}\"}" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin).get("model_info",{})
    print(next((v for k,v in d.items() if k.endswith(".context_length")), 0))
except Exception: print(0)' 2>/dev/null)
    fi
    [ -z "$model_max" ] && model_max=0

    echo >&2
    echo "${BOLD}Context size${RESET} — model ~${size_gb} GB, GPU budget ~${gpu_gb} GB" >&2
    [ "$model_max" -gt 0 ] && echo "    model supports up to $(( model_max / 1024 ))K tokens" >&2
    echo "    KV-cache estimate: ctxK x ${size_gb} / 200 GB (halved by q8_0 cache)" >&2

    local opts=() labels=() k kv need
    for k in 32 64 128 256 512 1024; do
        kv=$(( k * size_gb / 200 )); [ "$kv" -lt 1 ] && kv=1
        need=$(( size_gb + kv + 2 ))
        [ "$need" -gt "$gpu_gb" ] && continue
        [ "$model_max" -gt 0 ] && [ $(( k * 1024 )) -gt "$model_max" ] && continue
        opts+=("$(( k * 1024 ))")
        labels+=("$(printf '%4sK tokens   (~%d GB KV cache, ~%d GB total)' "$k" "$kv" "$need")")
    done
    if [ "${#opts[@]}" -eq 0 ]; then
        warn "Even 32K does not fit the GPU budget — using 32768 anyway; expect swapping."
        echo 32768; return 0
    fi

    if [ "${#opts[@]}" -eq 1 ]; then
        ok "Only one context size fits: $(( ${opts[0]} / 1024 ))K tokens — using it."
        tune_set "CTX_${engine}" "${opts[0]}"
        echo "${opts[0]}"; return 0
    fi

    local i=1 defnum=1 j=1 prev
    prev=$(tune_get "CTX_${engine}"); prev="${prev:-131072}"
    for i in "${!opts[@]}"; do
        [ "${opts[$i]}" = "$prev" ] && defnum=$(( i + 1 ))
    done
    # default to 128K when available and nothing was chosen before
    if [ -z "$(tune_get "CTX_${engine}")" ]; then
        j=1; for i in "${!opts[@]}"; do [ "${opts[$i]}" = "131072" ] && defnum=$(( i + 1 )); done
    fi
    for i in "${!opts[@]}"; do
        printf "  %d) %s\n" "$(( i + 1 ))" "${labels[$i]}" >&2
    done
    local sel
    while true; do
        sel=$(ask_val "Select context [1-${#opts[@]}]" "$defnum")
        case "$sel" in *[!0-9]*|"") echo "Enter a number." >&2; continue ;; esac
        [ "$sel" -ge 1 ] && [ "$sel" -le "${#opts[@]}" ] && break
        echo "Out of range." >&2
    done
    tune_set "CTX_${engine}" "${opts[$((sel-1))]}"
    echo "${opts[$((sel-1))]}"
}

# ---------- 4. network selector (every engine, not just Ollama) --------------
# Choose the bind address; prints it on stdout.
# Args: <engine>. Asked for every engine, not just Ollama, because all three
# serve over a socket and none of them authenticate. Refuses to bind a
# non-private address, and warns that LAN mode is open to the whole network.
launchInferenceNetworkSelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "launchInferenceNetworkSelector <engine>" "$(_hintEngine)" "prints  : the bind address (127.0.0.1 or your LAN IP)"
        return 2
    fi
    local engine="${1:-}" ip def sel
    ip=$(lan_ip)
    echo >&2
    echo "${BOLD}Network exposure for ${engine}${RESET}" >&2
    echo "  1) localhost only — 127.0.0.1, nothing else can connect (safest)" >&2
    if [ -n "$ip" ]; then
        echo "  2) LAN           — ${ip}, reachable from your local network" >&2
        warn "LAN mode has NO authentication: anyone on the network can use this model."
    fi
    def=$(tune_get "BIND_${engine}"); def="${def:-1}"
    [ -z "$ip" ] && def=1
    while true; do
        sel=$(ask_val "Select exposure [1-2]" "$def")
        case "$sel" in
            1) tune_set "BIND_${engine}" 1; echo "127.0.0.1"; return 0 ;;
            2) if [ -z "$ip" ]; then echo "No LAN address detected." >&2; continue; fi
               case "$ip" in
                   192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) : ;;
                   *) fail "${ip} is not a private-range address — refusing to expose."; continue ;;
               esac
               tune_set "BIND_${engine}" 2
               warn "DHCP caveat: give this Mac a reservation, the bind is to ${ip}."
               echo "$ip"; return 0 ;;
            *) echo "Enter 1 or 2." >&2 ;;
        esac
    done
}

# ---------- 4b. coding agent selector ----------------------------------------
# Choose the coding agent; prints its name, or "none", on stdout.
# Args: <engine>. Offers only agents that are installed AND compatible with this
# engine, naming incompatible ones with the reason. One valid option answers
# itself; none leaves the server running and says what would have worked.
launchInferenceAgentSelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "launchInferenceAgentSelector <engine>" "$(_hintEngine)" "prints  : Pi | OpenCode | Claude | none, filtered by compatibility"
        return 2
    fi
    local engine="${1:-}" all=() usable=() blocked=() a
    pi_installed       && all+=("Pi")
    opencode_installed && all+=("OpenCode")
    claude_installed   && all+=("Claude")

    for a in ${all[@]+"${all[@]}"}; do
        if agent_supports_engine "$a" "$engine"; then usable+=("$a"); else blocked+=("$a"); fi
    done

    for a in ${blocked[@]+"${blocked[@]}"}; do
        warn "${a} is installed but not usable with ${engine} — $(agent_reason "$a"). Not offered."
    done

    if [ "${#usable[@]}" -eq 0 ]; then
        if [ "${#all[@]}" -eq 0 ]; then
            warn "No coding agent installed — run ./install.sh to add Pi, OpenCode or Claude."
        else
            warn "No installed coding agent works with ${engine}."
            warn "Pi or OpenCode would (they drive any OpenAI-compatible endpoint)."
        fi
        echo "none"; return 0
    fi

    if [ "${#usable[@]}" -eq 1 ]; then
        ok "Only one coding agent works here: ${usable[0]} — using it."
        echo "${usable[0]}"; return 0
    fi

    echo >&2
    echo "${BOLD}Coding agents available for ${engine}:${RESET}" >&2
    local i=1
    for a in "${usable[@]}"; do printf "  %d) %s\n" "$i" "$a" >&2; i=$((i+1)); done
    local def defnum=1 j=1 sel
    def=$(tune_get "AGENT_${engine}")
    for a in "${usable[@]}"; do [ "$a" = "$def" ] && defnum=$j; j=$((j+1)); done
    while true; do
        sel=$(ask_val "Select coding agent [1-${#usable[@]}]" "$defnum")
        case "$sel" in *[!0-9]*|"") echo "Enter a number." >&2; continue ;; esac
        [ "$sel" -ge 1 ] && [ "$sel" -le "${#usable[@]}" ] && break
        echo "Out of range." >&2
    done
    tune_set "AGENT_${engine}" "${usable[$((sel-1))]}"
    echo "${usable[$((sel-1))]}"
}

# ---------- 4c. free the hardware from previous runs --------------------------
# Offer to stop whatever is already serving, so the new model gets the machine.
# Args: <engine about to launch>. Lists what is running with its memory first.
# Unloads Ollama models but keeps the cheap daemon; can stop the daemon too when
# switching engines. Declining is fine — the new model just gets less memory.
launchInferenceKillPrevious() {
    local target="${1:-}" rows line eng what mem killed=0
    rows=$(runningEngines)
    if [ -z "$rows" ]; then
        ok "No inference engine is running — all memory is free for this launch."
        return 0
    fi

    echo >&2
    echo "${BOLD}Already running:${RESET}" >&2
    while IFS='|' read -r eng what mem; do
        [ -z "$eng" ] && continue
        printf "  %-10s %-28s %s\n" "$eng" "$what" "$mem" >&2
    done <<< "$rows"
    warn "Their models stay resident and take memory away from the new one."

    if ! ask_yn "Kill previous inference runs to free the hardware?"; then
        ok "Leaving them running — the new model gets whatever memory is left."
        return 0
    fi

    while IFS='|' read -r eng what mem; do
        [ -z "$eng" ] && continue
        case "$eng" in
            Ollama)
                # unload every resident model but keep the daemon: it is cheap,
                # and Ollama is the only engine serving the Anthropic API
                local m
                for m in $(ollama ps 2>/dev/null | awk 'NR>1 {print $1}'); do
                    ollama stop "$m" >/dev/null 2>&1 && { ok "Unloaded Ollama model ${m}."; killed=1; }
                done
                if [ "$target" != "Ollama" ] && ask_ny "Also stop the Ollama daemon itself?"; then
                    brew services stop ollama >/dev/null 2>&1
                    pkill -f "ollama serve" 2>/dev/null && ok "Ollama daemon stopped."
                    killed=1
                fi ;;
            Llama.cpp)
                # only OUR llama-server: Ollama runs an internal one by the same
                # name, and killing that breaks Ollama
                llamacppKillOurs && { ok "Stopped llama-server."; killed=1; } ;;
            MLX-LM)
                pkill -f "mlx_lm.server" 2>/dev/null && { ok "Stopped mlx_lm.server."; killed=1; } ;;
        esac
    done <<< "$rows"

    [ "$killed" -eq 1 ] && sleep 2
    ok "Memory free/reclaimable now: $(vm_stat | awk '/Pages free/ {f=$3} /Pages inactive/ {i=$3} END {gsub(/\./,"",f); gsub(/\./,"",i); printf "%.1f", (f+i)*16384/1073741824}') GB"
}

# ---------- 5. free resources -------------------------------------------------
# Walk every open desktop app over FREE_MIN_MB (default 100), biggest first,
# offering to close each. Enter means NO, and the app hosting this session is
# skipped by walking the parent-process chain — otherwise the script could close
# the terminal it runs in. Also skipped: Finder, the engines, and the monitoring
# tools, which exist to watch this very run.
launchInferenceFreeResources() {
    local FREE_MIN_MB="${FREE_MIN_MB:-100}"
    info "Scanning open desktop applications (over ${FREE_MIN_MB} MB)..."
    local ancestors="" anc=$$
    while [ -n "$anc" ] && [ "$anc" -gt 1 ] 2>/dev/null; do
        ancestors="$ancestors $anc"
        anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
    done

    local apps
    apps=$(osascript -e 'tell application "System Events"
        set out to ""
        repeat with p in (every application process whose background only is false)
            set out to out & (unix id of p) & tab & (name of p) & linefeed
        end repeat
        return out
    end tell' 2>/dev/null)
    [ -z "$apps" ] && { warn "Could not enumerate desktop apps — skipping."; return 0; }

    local rows="" pid name mem_mb lower hidden_small=0 hidden_stack=0
    while IFS=$'\t' read -r pid name; do
        [ -z "$pid" ] && continue
        case " $ancestors " in *" $pid "*)
            warn "\"$name\" hosts this session — skipping."; continue ;;
        esac
        lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
        case "$lower" in
            finder) continue ;;
            # the stack itself: engines, and the monitoring tools that exist to
            # watch this very run — closing them would defeat the purpose
            ollama*|*llama-server*|*mlx*|anubis*|macmon*|litellm*)
                hidden_stack=$((hidden_stack+1)); continue ;;
        esac
        mem_mb=$(ps -axo rss=,command= | awk -v app="$(echo "$name" | tr '[:upper:]' '[:lower:]').app/" '
            index(tolower($0), app) {s+=$1} END {printf "%d", s/1024}')
        [ "$mem_mb" -eq 0 ] && mem_mb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%d", $1/1024}')
        [ -z "$mem_mb" ] && mem_mb=0
        # closing a 50 MB app frees nothing a model would notice; asking about
        # it is pure keystroke tax
        if [ "$mem_mb" -lt "$FREE_MIN_MB" ]; then
            hidden_small=$((hidden_small+1)); continue
        fi
        rows="${rows}${mem_mb}|${pid}|${name}
"
    done <<< "$apps"

    [ "$hidden_stack" -gt 0 ] && ok "Skipped ${hidden_stack} of this stack's own processes (engines, monitoring)."
    [ "$hidden_small" -gt 0 ] && ok "Skipped ${hidden_small} app(s) under ${FREE_MIN_MB} MB — too small to matter."
    [ -z "$rows" ] && { ok "No closable desktop apps found."; return 0; }

    local mem pid2 name2
    while IFS='|' read -r mem pid2 name2; do
        [ -z "$name2" ] && continue
        if [ "$mem" -ge 1024 ]; then
            printf "  %-28s using %s%s GB%s of memory. " "$name2" "$BOLD" \
                   "$(awk -v m="$mem" 'BEGIN{printf "%.1f", m/1024}')" "$RESET" >&2
        else
            printf "  %-28s using %s%d MB%s of memory. " "$name2" "$BOLD" "$mem" "$RESET" >&2
        fi
        if ask_ny "Close?"; then
            osascript -e "quit app \"$name2\"" 2>/dev/null
            sleep 2
            kill -0 "$pid2" 2>/dev/null && { warn "Forcing ${name2} closed."; kill -9 "$pid2" 2>/dev/null; }
            ok "\"$name2\" closed."
        else
            ok "Keeping \"$name2\"."
        fi
    done <<< "$(printf '%s' "$rows" | sort -t'|' -k1 -rn)"

    ok "Roughly $(vm_stat | awk '/Pages free/ {f=$3} /Pages inactive/ {i=$3} END {gsub(/\./,"",f); gsub(/\./,"",i); printf "%.1f", (f+i)*16384/1073741824}') GB of memory free/reclaimable."
}

# ---------- 6. prerequisites --------------------------------------------------
# Hard gate: will this model at this context actually fit?
# Args: <engine> <model> <context>. Compares weights + KV estimate + runtime
# against the GPU budget and fails with the exact sysctl to raise the limit.
# Runs before anything is loaded, because discovering it afterwards means swap.
launchInferencePrerequisites() {
    if [ $# -lt 3 ]; then
        aiStackUsage "launchInferencePrerequisites <engine> <model> <context-tokens>" "$(_hintEngine)" "$(_hintModel)" "context : tokens, e.g. 32768 / 65536 / 131072" "example : launchInferencePrerequisites Ollama qwen3.6:35b-a3b 32768"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" ctx="${3:-}" size_gb kv need gpu_gb total_gb limit_mb avail
    size_gb=$(engineModelSizeGb "$engine" "$model"); [ "${size_gb:-0}" -lt 1 ] && size_gb=1
    total_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    limit_mb=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    if [ "$limit_mb" -gt 0 ]; then gpu_gb=$(( limit_mb / 1024 )); else gpu_gb=$(( total_gb * 3 / 4 )); fi
    kv=$(( (ctx / 1024) * size_gb / 200 )); [ "$kv" -lt 1 ] && kv=1
    need=$(( size_gb + kv + 2 ))

    info "Prerequisites for ${model} @ $(( ctx / 1024 ))K on ${engine}"
    echo "    weights ~${size_gb} GB + KV ~${kv} GB + runtime 2 GB = ~${need} GB" >&2
    echo "    GPU budget: ${gpu_gb} GB of ${total_gb} GB RAM" >&2
    if [ "$need" -gt "$gpu_gb" ]; then
        fail "Does not fit: needs ~${need} GB, budget is ${gpu_gb} GB."
        fail "Raise it:  sudo sysctl iogpu.wired_limit_mb=$(( (total_gb - 5) * 1024 ))"
        fail "...or choose a smaller context / model."
        return 1
    fi
    avail=$(vm_stat | awk '/Pages free/ {f=$3} /Pages inactive/ {i=$3} /Pages speculative/ {s=$3} END {gsub(/\./,"",f); gsub(/\./,"",i); gsub(/\./,"",s); printf "%d", (f+i+s)*16384/1073741824}')
    [ "$avail" -lt "$need" ] && warn "Only ~${avail} GB free right now — macOS will evict caches."
    ok "Fits: ~${need} GB of ${gpu_gb} GB."
}

# ---------- 7. start the engine ----------------------------------------------
# Start the engine on the chosen model, context and address.
# Args: <engine> <model> <context> <bind>. Offers to restart a server already
# running, waits for real readiness, then reports endpoint, memory and CPU.
# Sets LAUNCH_ENDPOINT, which the agent step consumes.
launchInferenceStart() {
    if [ $# -lt 4 ]; then
        aiStackUsage "launchInferenceStart <engine> <model> <context-tokens> <bind-address>" "$(_hintEngine)" "$(_hintModel)" "context : tokens, e.g. 32768" "bind    : 127.0.0.1 (local) or this Mac's LAN IP" "example : launchInferenceStart Ollama qwen3.6:35b-a3b 32768 127.0.0.1"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" ctx="${3:-}" bind="${4:-}" port
    port=$(engine_port "$engine")

    if engine_up "$engine" "$bind"; then
        warn "${engine} is already serving on ${bind}:${port}."
        if ask_yn "Restart it with the settings chosen here?"; then
            case "$engine" in
                Ollama)    brew services stop ollama >/dev/null 2>&1; pkill -f "ollama serve" 2>/dev/null ;;
                Llama.cpp) llamacppKillOurs ;;
                MLX-LM)    pkill -f "mlx_lm.server" 2>/dev/null ;;
            esac
            sleep 2
        else
            ok "Leaving the running server as it is."
            LAUNCH_ENDPOINT="http://${bind}:${port}"
            return 0
        fi
    fi

    info "Starting ${engine} — ${model} @ $(( ctx / 1024 ))K on ${bind}:${port}"
    case "$engine" in
        Ollama)
            OLLAMA_HOST="${bind}:${port}" OLLAMA_CONTEXT_LENGTH="$ctx" \
                OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}" \
                nohup ollama serve >/dev/null 2>&1 &
            sleep 3
            engine_up "$engine" "$bind" || { fail "Ollama did not come up."; return 1; }
            info "Loading ${model} (first token may take a while)..."
            curl -sf "http://${bind}:${port}/api/generate" \
                 -d "{\"model\":\"${model}\",\"keep_alive\":\"60m\"}" >/dev/null \
                || { fail "Failed to load ${model}."; return 1; }
            ;;
        Llama.cpp)
            local f
            f="${LLAMACPP_MODEL_DIR}/$(printf '%s' "$model" | sed 's|/|__|g; s|:|@|').gguf"
            [ -e "$f" ] || { fail "GGUF not found: ${f}"; return 1; }
            # --alias: without it the API advertises the full .gguf path, and
            # agents infer a runtime from the uploader org in the filename
            # (e.g. "lmstudio-community" -> "I'm running through LM Studio").
            nohup llama-server -m "$f" -c "$ctx" --alias "$model" \
                  --host "$bind" --port "$port" \
                  >"${TMPDIR:-/tmp}/llama-server.log" 2>&1 &
            local t=0
            info "Waiting for llama-server to finish loading the model (503 until ready)..."
            while [ "$t" -lt 600 ] && ! engine_up "$engine" "$bind"; do sleep 3; t=$((t+3)); done
            engine_up "$engine" "$bind" || { fail "llama-server did not become ready — see ${TMPDIR:-/tmp}/llama-server.log"; return 1; }
            ;;
        MLX-LM)
            nohup mlx_lm.server --model "$model" --host "$bind" --port "$port" \
                  >"${TMPDIR:-/tmp}/mlx-server.log" 2>&1 &
            local t2=0
            info "Waiting for mlx_lm.server to load the model..."
            while [ "$t2" -lt 600 ] && ! engine_up "$engine" "$bind"; do sleep 3; t2=$((t2+3)); done
            engine_up "$engine" "$bind" || { fail "mlx_lm.server did not come up — see ${TMPDIR:-/tmp}/mlx-server.log"; return 1; }
            ;;
    esac

    LAUNCH_ENDPOINT="http://${bind}:${port}"
    local mem cpu pat
    case "$engine" in
        Ollama) pat="[o]llama" ;; Llama.cpp) pat="[l]lama-server" ;; MLX-LM) pat="[m]lx_lm.server" ;;
    esac
    mem=$(ps -axo rss,command | awk -v p="$pat" '$0 ~ p {s+=$1} END {printf "%.1f", s/1048576}')
    cpu=$(ps -axo %cpu,command | awk -v p="$pat" '$0 ~ p {s+=$1} END {printf "%.1f", s}')
    echo >&2
    echo "${BOLD}=================== Running ===================${RESET}" >&2
    ok "Engine:   ${engine}"
    ok "Model:    ${model}"
    ok "Context:  $(( ctx / 1024 ))K tokens"
    ok "Endpoint: ${LAUNCH_ENDPOINT}"
    ok "Memory:   ${mem} GB    Processor: ${cpu} %"
}

# ---------- 8. start the coding agent ----------------------------------------
# $1 agent, $2 engine, $3 model. Uses LAUNCH_ENDPOINT set by the start step.

# Ask the running endpoint what model id it advertises.
# Needed because llama-server and mlx_lm.server name models their own way, and
# an agent config must use the id the server will actually accept.
endpointModelId() {
    curl -sf --max-time 8 "${LAUNCH_ENDPOINT}/v1/models" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    xs=d.get("data") or d.get("models") or []
    print((xs[0].get("id") or xs[0].get("name") or "") if xs else "")
except Exception: print("")' 2>/dev/null
}

# Hand the running endpoint to the chosen coding agent.
# Args: <agent> <engine> <model>. Dispatches to the per-agent launcher, or
# prints the endpoint and stops when the agent is "none".
launchInferenceStartAgent() {
    if [ $# -lt 3 ]; then
        aiStackUsage "launchInferenceStartAgent <agent> <engine> <model>" "agent   : Pi | OpenCode | Claude | none" "$(_hintEngine)" "$(_hintModel)" "note    : needs LAUNCH_ENDPOINT set by launchInferenceStart"
        return 2
    fi
    local agent="${1:-}" engine="${2:-}" model="${3:-}" endpoint="${LAUNCH_ENDPOINT:-}"
    [ "$agent" = "none" ] && {
        info "No coding agent launched. The endpoint stays up:"
        echo "    ${endpoint}" >&2
        return 0
    }
    case "$agent" in
        Claude)   launchInferenceAgentClaude   "$engine" "$model" ;;
        Pi)       launchInferenceAgentPi       "$engine" "$model" ;;
        OpenCode) launchInferenceAgentOpenCode "$engine" "$model" ;;
    esac
}

# --- Claude Code: Anthropic API, Ollama only ---------------------------------
# Launch Claude Code against a local Ollama endpoint.
# Ollama only: Claude Code speaks the Anthropic Messages API. Maps all three
# model tiers to the local model, puts a small model on the background tier when
# one exists, and offers continue/resume when this directory has sessions.
launchInferenceAgentClaude() {
    local engine="$1" model="$2" endpoint="${LAUNCH_ENDPOINT:-}"
    if [ "$engine" != "Ollama" ]; then
        fail "Claude Code needs the Anthropic API — ${engine} does not serve it."
        return 1
    fi
    local proj sflag="" answer n
    proj="$HOME/.claude/projects/$(pwd | sed 's|[/_.]|-|g')"
    if ls "$proj"/*.jsonl >/dev/null 2>&1; then
        n=$(ls "$proj"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
        info "${n} previous session(s) for this directory."
        answer=$(ask_val "Session: C = continue latest, r = resume picker, n = new" "C")
        case "$answer" in
            [Cc]) sflag="--continue" ;;
            [Rr]) sflag="--resume" ;;
            [Nn]) sflag="" ;;
            *) warn "Unknown answer — continuing latest."; sflag="--continue" ;;
        esac
    fi
    local haiku="$model" small
    small=$(ollamaListInstalled | grep -E '(:1\.5b|:3b|:7b)$' | head -1)
    [ -n "$small" ] && [ "$small" != "$model" ] && { haiku="$small"; ok "Background tier -> ${haiku}"; }

    info "Launching Claude Code in $(pwd) against ${model}..."
    warn "Local models are weaker than hosted Claude — expect simpler agentic behaviour."
    ANTHROPIC_BASE_URL="$endpoint" \
    ANTHROPIC_AUTH_TOKEN="ollama" \
    ANTHROPIC_API_KEY="" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku" \
    claude --model "$model" $sflag
}

# --- Pi: OpenAI-compatible, any engine ---------------------------------------
# Launch Pi against the running endpoint.
# Writes ~/.pi/agent/local-models.json ({url, apiKey}) — backing up any existing
# one — and makes sure the local-models plugin is present. Pi discovers models
# itself, so the model is picked inside Pi with /models.
launchInferenceAgentPi() {
    local engine="$1" model="$2" endpoint="${LAUNCH_ENDPOINT:-}" cfg="$HOME/.pi/agent/local-models.json"
    mkdir -p "$(dirname "$cfg")"
    if [ -f "$cfg" ] && ! grep -q "\"${endpoint}\"" "$cfg" 2>/dev/null; then
        cp "$cfg" "${cfg}.bak" && warn "Existing Pi config backed up to ${cfg}.bak"
    fi
    printf '{\n  "url": "%s",\n  "apiKey": "local"\n}\n' "$endpoint" > "$cfg"
    ok "Pi local-model config written: ${cfg} -> ${endpoint}"
    pi list 2>/dev/null | grep -q pi-local-models || {
        info "Adding local-model discovery to Pi..."
        pi install npm:pi-local-models >/dev/null 2>&1 || warn "Run 'pi install npm:pi-local-models' if /models is empty."
    }
    info "Launching Pi in $(pwd). Pick the model inside Pi with: /models"
    echo "    (serving ${model} via ${engine} at ${endpoint})" >&2
    pi
}

# --- OpenCode: OpenAI-compatible, any engine ---------------------------------
# Launch OpenCode against the running endpoint.
# Merges a "local" provider into ~/.config/opencode/opencode.json (backing up
# the old file) with baseURL inside "options" — OpenCode ignores it anywhere
# else — keyed by the id the endpoint really advertises.
launchInferenceAgentOpenCode() {
    local engine="$1" model="$2" endpoint="${LAUNCH_ENDPOINT:-}" cfg="$HOME/.config/opencode/opencode.json" mid
    mid=$(endpointModelId); [ -z "$mid" ] && mid="$model"
    mkdir -p "$(dirname "$cfg")"
    [ -f "$cfg" ] && { cp "$cfg" "${cfg}.bak"; warn "Existing OpenCode config backed up to ${cfg}.bak"; }
    python3 - "$cfg" "$endpoint" "$mid" "$engine" <<'PYEOF'
import json, os, sys
cfg, endpoint, mid, engine = sys.argv[1:5]
data = {}
if os.path.exists(cfg):
    try:
        data = json.load(open(cfg))
    except Exception:
        data = {}
data.setdefault("$schema", "https://opencode.ai/config.json")
prov = data.setdefault("provider", {})
prov["local"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": f"Local ({engine})",
    "options": {"baseURL": endpoint.rstrip("/") + "/v1", "apiKey": "local"},
    "models": {mid: {"name": mid}},
}
json.dump(data, open(cfg, "w"), indent=2)
print(cfg)
PYEOF
    ok "OpenCode config written: ${cfg} -> ${endpoint}/v1 (model ${mid})"
    info "Launching OpenCode in $(pwd)..."
    opencode --model "local/${mid}" 2>/dev/null || opencode
}

# ---------- wrapper -----------------------------------------------------------
# Wrapper: engine, model, context, network, free memory, fit check, start, agent.
# Every selector answers itself when only one option is valid, so a repeat launch
# of the same setup is mostly Enter. Any step returning non-zero stops the run
# before anything is loaded.
launchInference() {
    echo "${BOLD}=============================================================${RESET}" >&2
    echo "${BOLD} Local inference — engine, model, context, network${RESET}" >&2
    echo "${BOLD}=============================================================${RESET}" >&2
    local engine model ctx bind agent
    engine=$(launchInferenceEngineSelector) || return 1
    model=$(launchInferenceModelSelector "$engine") || return 1
    ctx=$(launchInferenceContextSelector "$engine" "$model") || return 1
    bind=$(launchInferenceNetworkSelector "$engine") || return 1
    launchInferenceFreeResources
    launchInferenceKillPrevious "$engine"
    launchInferencePrerequisites "$engine" "$model" "$ctx" || return 1
    launchInferenceStart "$engine" "$model" "$ctx" "$bind" || return 1
    agent=$(launchInferenceAgentSelector "$engine")
    launchInferenceStartAgent "$agent" "$engine" "$model"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    launchInference
fi
