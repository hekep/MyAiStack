#!/bin/bash
#
# launchInference.sh — pick an engine, a model and a context size, serve it,
#                      and (where supported) hand it to a coding agent.
#                      Debian/Ubuntu implementation.
#
# Installing is install.sh's job. This script owns everything about *running*:
# which engine, which model, how much context, which network interface, how
# much memory to free first, and how to keep the model resident.
#
#   aistackLaunchInferenceEngineSelector    -> engine (asked only if several exist)
#   aistackLaunchInferenceModelSelector     -> a model installed FOR that engine
#   aistackLaunchInferenceContextSelector   -> 32K / 64K / 128K (default) / bigger
#   aistackLaunchInferenceNetworkSelector   -> localhost or LAN, for ANY engine
#   aistackLaunchInferenceFreeResources     -> close memory-hungry applications
#   aistackLaunchInferenceKillPrevious      -> stop engines/models already serving, so
#                                       the new model gets the whole machine
#   aistackLaunchInferencePrerequisites     -> weights + KV cache must fit RAM
#   aistackLaunchInferenceStart             -> start the engine's server, report usage
#   aistackLaunchInferenceAgentSelector     -> coding agent, filtered by engine
#                                       compatibility (self-answering when
#                                       only one option is valid)
#   aistackLaunchInferenceStartAgent        -> Pi / OpenCode / Claude on the endpoint
#   aistackLaunchInference                  -> wrapper: runs all of the above in order
#
# Two engines here, not three: MLX-LM is Apple Silicon only. Anything that
# names it says so rather than pretending it does not exist.
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

# ---------- Linux platform primitives ----------------------------------------
# The sysctl/vm_stat/df -g block from the macOS implementation, in /proc terms.
# Kept identical to Debian/install.sh so the two never disagree about how much
# memory this machine has.

# Memory the kernel can hand out, in whole GB. Not the size on the RAM stick:
# MemTotal excludes firmware-reserved and iGPU-carved memory.
memTotalGb() { awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo; }
# Nominal RAM size in whole GB (MemTotal rounded up to the nearest 4).
hostRamGb() { local t=$(memTotalGb); echo $(( ( (t + 3) / 4 ) * 4 )); }
# Memory available for a new allocation right now, in whole GB.
availMemGb() { awk '/^MemAvailable:/ {printf "%d", $2/1048576}' /proc/meminfo; }
# Memory available right now with one decimal — for the "freed this much" lines.
availMemGbF() { awk '/^MemAvailable:/ {printf "%.1f", $2/1048576}' /proc/meminfo; }
# RAM held back for the OS and everything that is not a model.
RAM_RESERVE_GB="${RAM_RESERVE_GB:-5}"
# The budget a model plus its KV cache has to fit inside, in whole GB.
inferenceBudgetGb() { local b=$(( $(memTotalGb) - RAM_RESERVE_GB )); [ "$b" -lt 1 ] && b=1; echo "$b"; }

# What kind of Vulkan device this machine has: discrete | integrated | none.
# llvmpipe reports PHYSICAL_DEVICE_TYPE_CPU — it is a software rasteriser, not
# an accelerator, and offloading to it means running the model on the CPU the
# slow way. It must never count as a GPU.
vulkanDeviceClass() {
    command -v vulkaninfo >/dev/null 2>&1 || { echo none; return 0; }
    local types
    types=$(vulkaninfo --summary 2>/dev/null | awk -F= '/deviceType/ {gsub(/[ \t]/,"",$2); print $2}')
    case "$types" in
        *DISCRETE_GPU*)   echo discrete ;;
        *INTEGRATED_GPU*) echo integrated ;;
        *)                echo none ;;
    esac
}

# Which accelerator stack is usable: nvidia | rocm | vulkan | cpu.
gpuVendor() {
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then echo nvidia; return 0; fi
    if command -v rocminfo >/dev/null 2>&1 || command -v rocm-smi >/dev/null 2>&1; then echo rocm; return 0; fi
    if [ -e /dev/dri/renderD128 ] && [ "$(vulkanDeviceClass)" != "none" ]; then echo vulkan; return 0; fi
    echo cpu
}
# Dedicated video memory in whole GB, 0 when there is none worth counting.
gpuVramGb() {
    local mib=0
    case "$(gpuVendor)" in
        nvidia) mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1) ;;
        rocm)   mib=$(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F, 'NR==2 {printf "%d", $2/1048576}') ;;
    esac
    case "${mib:-0}" in ""|*[!0-9]*) mib=0 ;; esac
    echo $(( mib / 1024 ))
}
# One line explaining where the memory budget comes from.
budgetSummary() {
    local vram; vram=$(gpuVramGb)
    case "$(gpuVendor)" in
        nvidia) echo "$(inferenceBudgetGb) GB usable RAM; NVIDIA GPU with ${vram} GB VRAM (layers beyond it run on CPU)" ;;
        rocm)   echo "$(inferenceBudgetGb) GB usable RAM; ROCm GPU with ${vram} GB VRAM (layers beyond it run on CPU)" ;;
        vulkan) if [ "$(vulkanDeviceClass)" = "discrete" ]; then
                    echo "$(inferenceBudgetGb) GB usable RAM; discrete Vulkan GPU, layers offloaded to it"
                else
                    echo "$(inferenceBudgetGb) GB usable RAM; integrated Vulkan GPU sharing that same memory (generation stays on CPU)"
                fi ;;
        *)      echo "$(inferenceBudgetGb) GB usable RAM; CPU inference (no usable GPU backend detected)" ;;
    esac
}

# Yes/no question where Enter means YES.
# For the expected path of an action you already opted into (restart the server
# you asked to launch). Returns 0 for yes, 1 for no.
ask_yn() {   # Enter = yes
    if [ $# -lt 1 ]; then
        aiStackUsage "ask_yn <question>" "Enter means YES" "example : ask_yn \"Restart it?\""
        return 2
    fi
    local a; printf "%s%s%s [Y/n] " "${BOLD}" "$1" "${RESET}" >&2
    read -r a </dev/tty || return 1
    case "$a" in ""|[Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}
# Yes/no question where Enter means NO.
# For anything that could lose work — closing an app, stopping someone else's
# engine — so holding Enter never destroys anything. Returns 0 for yes.
ask_ny() {   # Enter = no
    if [ $# -lt 1 ]; then
        aiStackUsage "ask_ny <question>" "Enter means NO" "example : ask_ny \"Close it?\""
        return 2
    fi
    local a; printf "%s%s%s [y/N] " "${BOLD}" "$1" "${RESET}" >&2
    read -r a </dev/tty || return 1
    case "$a" in [Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}
# Free-form question with a default; echoes the answer on stdout.
# Args: <question> <default>. Enter (or no terminal) yields the default, which
# is how every selector here becomes a single keystroke on a re-run.
ask_val() {  # free-form with default; echoes the answer
    if [ $# -lt 2 ]; then
        aiStackUsage "ask_val <question> <default>" "example : ask_val \"Context tokens\" 32768"
        return 2
    fi
    local a; printf "%s%s%s [%s]: " "${BOLD}" "$1" "${RESET}" "$2" >&2
    read -r a </dev/tty || { echo "$2"; return; }
    echo "${a:-$2}"
}

# ---------- persisted choices (previous answer = next default) ---------------
SETTINGS_FILE="$HOME/.aistackLaunchInference.conf"
# Read one persisted setting from ~/.aistackLaunchInference.conf.
# Args: <key>. Prints the value, or nothing when unset.
# This is what makes the previous run's choice the next run's default.
tune_get() { [ $# -ge 1 ] || { aiStackUsage "tune_get <key>" "reads ~/.aistackLaunchInference.conf" "example : tune_get CTX_Ollama"; return 2; }; [ -f "$SETTINGS_FILE" ] && sed -n "s/^$1=//p" "$SETTINGS_FILE" | tail -1; }
# Persist one setting to ~/.aistackLaunchInference.conf, replacing any earlier value.
# Args: <key> <value>. Rewrites the file rather than appending, so the file
# does not grow one line per launch.
tune_set() {
    if [ $# -lt 2 ]; then
        aiStackUsage "tune_set <key> <value>" "example : tune_set CTX_Ollama 65536"
        return 2
    fi
    local tmp; tmp=$(grep -v "^$1=" "$SETTINGS_FILE" 2>/dev/null)
    { [ -n "$tmp" ] && printf '%s\n' "$tmp"; printf '%s=%s\n' "$1" "$2"; } > "$SETTINGS_FILE"
}

# ---------- engines -----------------------------------------------------------
LLAMACPP_MODEL_DIR="${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}"
OLLAMA_PORT=11434; LLAMACPP_PORT=8080

# True when llama.cpp is available (llama-server or llama-cli on PATH).
# Engine presence, not model presence — enginesWithModels() checks the latter.
llamacpp_installed() { command -v llama-server >/dev/null 2>&1 || command -v llama-cli >/dev/null 2>&1; }

# Which ggml backend the installed llama.cpp carries: cuda|hip|vulkan|sycl|cpu.
# Read from the libraries beside the resolved binary, so it stays true however
# the engine was installed. Decides whether the server gets -ngl or -t.
llamacppBackend() {
    local bin dir
    bin=$(command -v llama-server 2>/dev/null || command -v llama-cli 2>/dev/null) || { echo unknown; return 0; }
    dir=$(dirname "$(readlink -f "$bin")")
    if   ls "$dir"/libggml-cuda.so*   >/dev/null 2>&1; then echo cuda
    elif ls "$dir"/libggml-hip.so*    >/dev/null 2>&1; then echo hip
    elif ls "$dir"/libggml-vulkan.so* >/dev/null 2>&1; then echo vulkan
    elif ls "$dir"/libggml-sycl.so*   >/dev/null 2>&1; then echo sycl
    elif ls "$dir"/libggml-cpu*.so    >/dev/null 2>&1; then echo cpu
    else echo unknown
    fi
}

# PIDs of the llama-server WE run, identified by the port we serve on.
# Ollama spawns its own model runner; matching a bare name risks killing it.
# Never match by name.
llamacppOurPids()  { pgrep -f "llama-server .*--port ${LLAMACPP_PORT}" 2>/dev/null; }
# Stop only our llama-server, using the same port-scoped match.
# Safe to call when none is running; Ollama's internal runner is never touched.
llamacppKillOurs() { pkill  -f "llama-server .*--port ${LLAMACPP_PORT}" 2>/dev/null; }
# True when the ollama binary is on PATH.
ollama_installed()   { command -v ollama >/dev/null 2>&1; }

# --- tools layer: ToolUniverse ------------------------------------------------
# A local MCP tool server (biomedical tools, Tool_RAG, Finish) the launched
# model calls through the generated Pi plugin (mcp.sh). Port 8765: 8080 is
# llama.cpp and 8000 — ToolUniverse's own default — is what ATHENA-R1 gives to
# vLLM. Compact mode exposes four discovery/execute tools and loads the rest
# behind them; TOOLUNIVERSE_ARGS replaces that, e.g. "--categories tool_finder".
TOOLUNIVERSE_PORT="${TOOLUNIVERSE_PORT:-8765}"
TOOLUNIVERSE_ARGS="${TOOLUNIVERSE_ARGS:---compact-mode}"
TOOLUNIVERSE_LOG="${TOOLUNIVERSE_LOG:-$HOME/.aistack/tooluniverse.log}"
tooluniverse_installed() { command -v tooluniverse-smcp-server >/dev/null 2>&1 \
                           || { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^tooluniverse'; }; }
# Only OUR server: the one on our port.
tooluniverseOurPids()  { pgrep -f "tooluniverse-smcp-server .*--port ${TOOLUNIVERSE_PORT}" 2>/dev/null; }
tooluniverseKillOurs() { pkill  -f "tooluniverse-smcp-server .*--port ${TOOLUNIVERSE_PORT}" 2>/dev/null; }
# True when something answers on the port. MCP streamable-http rejects a bare
# GET with a 4xx, so any HTTP status at all means a server is there.
tooluniverse_up() { local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
                        "http://127.0.0.1:${TOOLUNIVERSE_PORT}/mcp" 2>/dev/null); [ -n "$c" ] && [ "$c" != "000" ]; }

# The directory Ollama stores manifests and blobs in.
# Linux has two possible locations — the system service's /usr/share/ollama and
# your own ~/.ollama — so every path goes through here.
ollamaModelsDir() {
    if [ -n "${OLLAMA_MODELS:-}" ]; then echo "$OLLAMA_MODELS"; return 0; fi
    if [ -d "$HOME/.ollama/models/manifests" ]; then echo "$HOME/.ollama/models"; return 0; fi
    if [ -d /usr/share/ollama/.ollama/models/manifests ]; then echo /usr/share/ollama/.ollama/models; return 0; fi
    echo "$HOME/.ollama/models"
}
# True when the system-wide ollama.service is currently running.
ollamaSystemServiceActive() { systemctl is-active --quiet ollama.service 2>/dev/null; }
# Run one privileged command; fails clearly rather than with "permission denied".
_asRoot() {
    if [ "$(id -u)" = "0" ]; then "$@"; return $?; fi
    command -v sudo >/dev/null 2>&1 || { fail "sudo is required for: $*"; return 1; }
    sudo "$@"
}

# This machine's LAN address, empty when offline.
lan_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

# Engines installed on this machine, regardless of whether they hold models.
# Args: none. Prints a space-separated list, empty when none are installed.
_enginesInstalled() {
    local e=""
    llamacpp_installed && e="${e} Llama.cpp"
    ollama_installed   && e="${e} Ollama"
    echo "${e# }"
}

# The install function that downloads models for one engine.
# Args: <engine>. Prints the function name, so the guidance can be pasted.
_modelInstallerFor() {
    case "$1" in
        Llama.cpp) echo "aistackInstallLlamacppModels" ;;
        Ollama)    echo "aistackInstallOllamaModels" ;;
    esac
}

# Build "example :" help lines from what is ACTUALLY installed — one per usable
# engine, so every example shown can be pasted and will run.
# Args: <function-name> <shape> [agent]
#   shape: engine | engine-host | engine-model | engine-model-ctx |
#          engine-model-ctx-bind | agent-engine-model
#   agent: restrict to engines that agent supports (Claude -> Ollama only)
# When nothing is possible it says why and gives the exact command that fixes
# it: install an engine, or download models for the engines you already have.
_hintExamples() {
    local fn="$1" shape="$2" agent="${3:-}" e m out="" any=0 pad="\n         "
    # an example is useless if the agent itself is missing — lead with that
    if [ -n "$agent" ] && ! _agentInstalled "$agent"; then
        printf '%b' "NOT INSTALLED: ${agent} — install it first:${pad}    $(_agentInstallerFor "$agent")${pad}then, once an engine is serving:"
        printf '%b' "${pad}"
    fi
    for e in $(enginesWithModels); do
        [ -n "$agent" ] && { agent_supports_engine "$agent" "$e" || continue; }
        m=$(engineListInstalled "$e" | head -1)
        [ -z "$m" ] && continue
        [ "$any" = "1" ] && out="${out}${pad}"
        any=1
        case "$shape" in
            engine)                out="${out}example : ${fn} ${e}" ;;
            engine-host)           out="${out}example : ${fn} ${e} 127.0.0.1" ;;
            engine-model)          out="${out}example : ${fn} ${e} ${m}" ;;
            engine-model-ctx)      out="${out}example : ${fn} ${e} ${m} 32768" ;;
            engine-model-ctx-bind) out="${out}example : ${fn} ${e} ${m} 32768 127.0.0.1" ;;
            agent-engine-model)    out="${out}example : ${fn} ${agent:-Pi} ${e} ${m}" ;;
        esac
    done
    if [ "$any" = "1" ]; then printf '%b' "$out"; return 0; fi

    local inst; inst=$(_enginesInstalled)
    if [ -z "$inst" ]; then
        printf '%b' "example : none possible yet — no engine is installed.${pad}install one:  aistackInstallLlamacppEngine   (llama.cpp, recommended)${pad}              aistackInstallOllamaEngine     (Ollama — required by Claude Code)"
        return 0
    fi
    if [ -n "$agent" ]; then
        local okeng="" x
        for x in $inst; do agent_supports_engine "$agent" "$x" && okeng="${okeng} ${x}"; done
        if [ -z "$okeng" ]; then
            printf '%b' "example : none possible — ${agent} works with none of your engines (${inst}).${pad}$(agent_reason "$agent")"
            return 0
        fi
        inst="${okeng# }"
    fi
    out="example : none possible yet — no models downloaded for: ${inst}"
    for e in $inst; do out="${out}${pad}download them:  $(_modelInstallerFor "$e")   (for ${e})"; done
    printf '%b' "$out"
}

# Print a usage message for a step called with missing arguments, return 2.
# Args: <signature> [detail lines...]. Every step is individually callable from
# the shell, so a bare call has to explain itself instead of emitting a raw
# bash "parameter null or not set".
aiStackUsage() {
    local sig="$1"; shift
    # fail() exists in the wizard scripts but not in every file that needs this
    if command -v fail >/dev/null 2>&1; then fail "usage: ${sig}"
    else echo "✗ usage: ${sig}" >&2; fi
    local l
    for l in "$@"; do echo "         ${l}" >&2; done
    return 2
}

# Help lines resolved live, so they name what THIS machine actually has rather
# than a generic placeholder.
_hintEngine() {
    local e i
    e=$(enginesWithModels | tr '\n' ' ' | sed 's/ $//')
    [ -n "$e" ] && { echo "engine  : ${e}"; return 0; }
    # distinguish "nothing installed" from "installed but empty" — different
    # problems with different fixes
    i=$(_enginesInstalled)
    if [ -n "$i" ]; then echo "engine  : ${i}  (installed, but no models downloaded yet)"
    else echo "engine  : none installed — run ./install.sh"; fi
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
# Args: <agent> <engine>. Pi and OpenCode speak the OpenAI-compatible API both
# engines here serve; Claude Code needs the Anthropic Messages API, which only
# Ollama provides. This is the single rule that filters the agent menu.
agent_supports_engine() {   # $1 agent, $2 engine
    if [ $# -lt 2 ]; then
        aiStackUsage "agent_supports_engine <agent> <engine>" "agent   : Pi | OpenCode | Claude" "engine  : Llama.cpp | Ollama" "example : agent_supports_engine Claude Ollama"
        return 2
    fi
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
    if [ $# -lt 1 ]; then
        aiStackUsage "agent_reason <agent>" \
            "agent   : Pi | OpenCode | Claude" \
            "example : agent_reason Claude"
        return 2
    fi
    case "$1" in
        Claude) echo "needs the Anthropic API — only Ollama serves it" ;;
        *)      echo "incompatible" ;;
    esac
}

# The port an engine serves on: Ollama 11434, llama.cpp 8080.
# Args: <engine>. Fixed per engine so several scripts agree without config.
engine_port() {
    if [ $# -lt 1 ]; then
        aiStackUsage "engine_port <engine>" \
            "engine  : Llama.cpp | Ollama" \
            "$(_hintExamples engine_port engine)"
        return 2
    fi
    case "$1" in
        Llama.cpp) echo "$LLAMACPP_PORT" ;;
        Ollama)    echo "$OLLAMA_PORT" ;;
    esac
}
# Is this engine serving AND ready to infer?
# Args: <engine> <host>. llama.cpp is probed on /health because it answers 503
# on both /health and /v1/models while a model is still loading — treating
# "port open" as "ready" makes the first request fail.
engine_up() {   # $1 engine, $2 host — is it up AND ready to infer?
    if [ $# -lt 2 ]; then
        aiStackUsage "engine_up <engine> <host>" \
            "engine  : Llama.cpp | Ollama" \
            "host    : 127.0.0.1 or a LAN IP" \
            "$(_hintExamples engine_up engine-host)"
        return 2
    fi
    local p; p=$(engine_port "$1")
    case "$1" in
        Ollama)    curl -sf --max-time 3 "http://${2}:${p}/api/version" >/dev/null 2>&1 ;;
        Llama.cpp) curl -sf --max-time 3 "http://${2}:${p}/health"      >/dev/null 2>&1 ;;
        *)         curl -sf --max-time 3 "http://${2}:${p}/v1/models"   >/dev/null 2>&1 ;;
    esac
}

# List what is actually HOLDING a model, as "engine|what|memory" rows.
# Ollama-resident models and our llama-server. An idle Ollama daemon is
# deliberately excluded: it holds nothing, costs nothing and gets reused, so
# flagging it would be a false alarm.
busyEngines() {
    local pid rss m sz
    for m in $(ollama ps 2>/dev/null | awk 'NR>1 {print $1}'); do
        sz=$(ollama ps 2>/dev/null | awk -v M="$m" '$1==M {print $3" "$4}')
        echo "Ollama|model ${m} resident|${sz}"
    done
    for pid in $(llamacppOurPids); do
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f GB", $1/1048576}')
        echo "Llama.cpp|llama-server pid ${pid}|${rss}"
    done
}

# List what is serving, daemon included, as "engine|what|memory" rows.
# Broader than busyEngines(): used where stopping the daemon itself is on the
# table, not only where memory pressure matters. The systemd service is named
# separately, because stopping it needs root and a different command.
runningEngines() {
    local pid rss
    if curl -sf --max-time 2 "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
        rss=$(ps -eo rss=,args= | awk '/[o]llama/ {s+=$1} END {printf "%.1f", s/1048576}')
        if ollamaSystemServiceActive; then
            echo "Ollama|systemd ollama.service on :${OLLAMA_PORT}|${rss} GB"
        else
            echo "Ollama|daemon on :${OLLAMA_PORT}|${rss} GB"
        fi
    fi
    for pid in $(llamacppOurPids); do
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f", $1/1048576}')
        echo "Llama.cpp|llama-server pid ${pid}|${rss} GB"
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
# List Ollama model tags, one per line.
# Falls back to reading the manifests when the daemon is down: the models are on
# disk either way, and without this a stopped daemon makes Ollama look like it
# has none — hiding it from menus it belongs in.
ollamaListInstalled() {
    if ollama list >/dev/null 2>&1; then
        ollama list 2>/dev/null | awk 'NR>1 {print $1}'
        return 0
    fi
    local base f rel ns name tag
    base="$(ollamaModelsDir)/manifests"
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
    for e in Llama.cpp Ollama; do
        case "$e" in
            Llama.cpp) llamacpp_installed || continue ;;
            Ollama)    ollama_installed   || continue ;;
        esac
        [ "$(engineListInstalled "$e" | grep -c . || true)" -gt 0 ] && echo "$e"
    done
}

# List the models installed for one engine, one tag per line.
# Args: <engine>. Dispatches to the per-engine lister so callers stay generic.
engineListInstalled() {
    if [ $# -lt 1 ]; then
        aiStackUsage "engineListInstalled <engine>" \
            "engine  : Llama.cpp | Ollama" \
            "$(_hintExamples engineListInstalled engine)"
        return 2
    fi
    case "$1" in
        Llama.cpp) llamacppListInstalled ;;
        Ollama)    ollamaListInstalled ;;
    esac
}

# On-disk size of one model in whole GB.
# Args: <engine> <model>. Reads the .gguf file or 'ollama list' as appropriate.
# Feeds the context and fit calculations.
engineModelSizeGb() {
    if [ $# -lt 2 ]; then
        aiStackUsage "engineModelSizeGb <engine> <model>" \
            "engine  : Llama.cpp | Ollama" \
            "model   : a tag for that engine — list: engineListInstalled <engine>" \
            "$(_hintExamples engineModelSizeGb engine-model)"
        return 2
    fi
    local engine="$1" tag="$2" f
    case "$engine" in
        Llama.cpp)
            f="${LLAMACPP_MODEL_DIR}/$(printf '%s' "$tag" | sed 's|/|__|g; s|:|@|').gguf"
            [ -e "$f" ] && du -m "$f" 2>/dev/null | awk '{printf "%d", $1/1024}' || echo 0 ;;
        Ollama)
            # prefer the daemon, but fall back to summing the manifest's layer
            # sizes: a model's size is a fact about the disk, not about whether
            # ollama happens to be running
            local via_daemon
            via_daemon=$(ollama list 2>/dev/null | awk -v t="$tag" '$1==t {print ($4=="GB")? $3 : 1; exit}' \
                         | awk '{printf "%d", $1}')
            if [ -n "$via_daemon" ] && [ "$via_daemon" != "0" ]; then
                echo "$via_daemon"; return 0
            fi
            local name="${tag%%:*}" ver="${tag##*:}" mf root
            root="$(ollamaModelsDir)/manifests"
            mf="${root}/registry.ollama.ai/library/${name}/${ver}"
            [ -f "$mf" ] || mf=$(find "$root" -type f -path "*${name}/${ver}" 2>/dev/null | head -1)
            if [ -f "$mf" ]; then
                python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    t=sum(l.get("size",0) for l in d.get("layers",[]))
    print(int(t/1073741824))
except Exception: print(0)' "$mf"
            else
                echo 0
            fi ;;
    esac
}

# ---------- 1. engine selector -----------------------------------------------
# Choose which engine to launch; prints it on stdout.
# Offers only engines that have models, naming any installed-but-empty ones once.
# Asks nothing when exactly one qualifies. Previous choice is the default.
aistackLaunchInferenceEngineSelector() {
    local engines=() e empty=""
    while IFS= read -r e; do [ -n "$e" ] && engines+=("$e"); done < <(enginesWithModels)

    # engines that are installed but have nothing to run — named, not offered
    for e in Llama.cpp Ollama; do
        case "$e" in
            Llama.cpp) llamacpp_installed || continue ;;
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
aistackLaunchInferenceModelSelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackLaunchInferenceModelSelector <engine>" \
            "$(_hintEngine)" \
            "$(_hintExamples aistackLaunchInferenceModelSelector engine)"
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
# sizes whose weights + estimated KV cache + runtime fit the memory budget; for
# Ollama it also hides anything above the model's own ceiling from /api/show.
aistackLaunchInferenceContextSelector() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aistackLaunchInferenceContextSelector <engine> <model>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "$(_hintExamples aistackLaunchInferenceContextSelector engine-model)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" size_gb budget_gb
    size_gb=$(engineModelSizeGb "$engine" "$model"); [ "${size_gb:-0}" -lt 1 ] && size_gb=1
    budget_gb=$(inferenceBudgetGb)

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
    echo "${BOLD}Context size${RESET} — model ~${size_gb} GB, memory budget ~${budget_gb} GB" >&2
    echo "    $(budgetSummary)" >&2
    [ "$model_max" -gt 0 ] && echo "    model supports up to $(( model_max / 1024 ))K tokens" >&2
    echo "    KV-cache estimate: ctxK x ${size_gb} / 200 GB (halved by q8_0 cache)" >&2

    local opts=() labels=() k kv need
    for k in 32 64 128 256 512 1024; do
        kv=$(( k * size_gb / 200 )); [ "$kv" -lt 1 ] && kv=1
        need=$(( size_gb + kv + 2 ))
        [ "$need" -gt "$budget_gb" ] && continue
        [ "$model_max" -gt 0 ] && [ $(( k * 1024 )) -gt "$model_max" ] && continue
        opts+=("$(( k * 1024 ))")
        labels+=("$(printf '%4sK tokens   (~%d GB KV cache, ~%d GB total)' "$k" "$kv" "$need")")
    done
    if [ "${#opts[@]}" -eq 0 ]; then
        warn "Even 32K does not fit the memory budget — using 32768 anyway; expect swapping."
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

# ---------- 4. network selector (every engine) -------------------------------
# Choose the bind address; prints it on stdout.
# Args: <engine>. Asked for every engine, because both serve over a socket and
# neither authenticates. Refuses to bind a non-private address, and warns that
# LAN mode is open to the whole network.
aistackLaunchInferenceNetworkSelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackLaunchInferenceNetworkSelector <engine>" \
            "$(_hintEngine)" \
            "prints  : the bind address (127.0.0.1 or your LAN IP)" \
            "$(_hintExamples aistackLaunchInferenceNetworkSelector engine)"
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
               warn "DHCP caveat: give this host a reservation, the bind is to ${ip}."
               command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active" \
                   && warn "ufw is active — allow the port:  sudo ufw allow $(engine_port "$engine")/tcp"
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
aistackLaunchInferenceAgentSelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackLaunchInferenceAgentSelector <engine>" \
            "$(_hintEngine)" \
            "prints  : Pi | OpenCode | Claude | none, filtered by compatibility" \
            "$(_hintExamples aistackLaunchInferenceAgentSelector engine)"
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
aistackLaunchInferenceKillPrevious() {
    local target="${1:-}" rows eng what mem killed=0
    # The tool server holds no weights, and it is asked about again once the
    # engine is up — so a running one is torn down here quietly, ours only.
    if [ -n "$(tooluniverseOurPids)" ]; then
        tooluniverseKillOurs && ok "Stopped our ToolUniverse server — it is offered again after the launch."
    fi
    rows=$(runningEngines)
    if [ -z "$rows" ]; then
        ok "No inference engine is running — all memory is free for this launch."
        return 0
    fi

    echo >&2
    echo "${BOLD}Already running:${RESET}" >&2
    while IFS='|' read -r eng what mem; do
        [ -z "$eng" ] && continue
        printf "  %-10s %-34s %s\n" "$eng" "$what" "$mem" >&2
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
                    if ollamaSystemServiceActive; then
                        _asRoot systemctl stop ollama.service >/dev/null 2>&1 && ok "systemd ollama.service stopped."
                    fi
                    pkill -f "ollama serve" 2>/dev/null && ok "Ollama daemon stopped."
                    killed=1
                fi ;;
            Llama.cpp)
                # only OUR llama-server, matched by the port we serve on
                llamacppKillOurs && { ok "Stopped llama-server."; killed=1; } ;;
        esac
    done <<< "$rows"

    [ "$killed" -eq 1 ] && sleep 2
    ok "Memory available now: $(availMemGbF) GB"
}

# ---------- 4d. tools layer: ToolUniverse -------------------------------------
# Asked once the engine is up, with a two-way answer: yes (re)starts our server,
# no removes one that is already there. Default no — it is a second Python
# process most coding sessions have no use for. Prints yes|no, and prints no
# without asking when ToolUniverse is not installed.
aistackLaunchInferenceToolsSelector() {
    tooluniverse_installed || { echo "no"; return 0; }
    echo >&2
    echo "${BOLD}Tool server${RESET}" >&2
    echo "    ToolUniverse serves biomedical tools over MCP on port ${TOOLUNIVERSE_PORT}:" >&2
    echo "    Tool_RAG, Finish and the FDA / ChEMBL / Open Targets tools ATHENA-R1 was" >&2
    echo "    trained on. The model reaches them through the generated Pi plugin." >&2
    [ -n "$(tooluniverseOurPids)" ] && echo "    (ours is running now — no stops it, yes restarts it)" >&2
    if ask_ny "Launch ToolUniverse?"; then echo "yes"; else echo "no"; fi
}

# Start our ToolUniverse MCP server in the background on TOOLUNIVERSE_PORT,
# logging to TOOLUNIVERSE_LOG, and wait until the port answers — the first
# start loads every tool config, which takes tens of seconds. A server on the
# port that is not ours is left alone. Builds the connector's tool list when it
# has never been built, because that list is what the Pi plugin registers.
aistackLaunchInferenceStartTools() {
    tooluniverse_installed || { fail "ToolUniverse is not installed — run: aistackInstallTooluniverseTools"; return 1; }
    if [ -z "$(tooluniverseOurPids)" ] && tooluniverse_up; then
        warn "Something else is serving port ${TOOLUNIVERSE_PORT} — left running, it is not ours."
        return 1
    fi
    [ -n "$(tooluniverseOurPids)" ] && aistackLaunchInferenceStopTools
    mkdir -p "$(dirname "$TOOLUNIVERSE_LOG")"
    info "Starting ToolUniverse on 127.0.0.1:${TOOLUNIVERSE_PORT} (${TOOLUNIVERSE_ARGS}) — log: ${TOOLUNIVERSE_LOG}"
    # shellcheck disable=SC2086  # TOOLUNIVERSE_ARGS is a flag list by design
    nohup tooluniverse-smcp-server --host 127.0.0.1 --port "${TOOLUNIVERSE_PORT}" ${TOOLUNIVERSE_ARGS} \
        >"$TOOLUNIVERSE_LOG" 2>&1 </dev/null &
    local t=0
    while [ "$t" -lt 180 ]; do
        tooluniverse_up && break
        if [ -z "$(tooluniverseOurPids)" ]; then
            fail "ToolUniverse exited — last lines of ${TOOLUNIVERSE_LOG}:"; tail -5 "$TOOLUNIVERSE_LOG" >&2; return 1
        fi
        sleep 1; t=$((t+1))
    done
    tooluniverse_up || { fail "ToolUniverse did not answer within ${t} s — see ${TOOLUNIVERSE_LOG}"; return 1; }
    ok "ToolUniverse up after ${t} s (pid $(tooluniverseOurPids | head -1))."
    local mcpdir="${MCP_HOME:-$HOME/.aistack/mcp}/tooluniverse" root
    if [ ! -f "$mcpdir/server.json" ]; then
        warn "No 'tooluniverse' MCP connector — the model cannot see the server. Register it:"
        warn "  aistackMcpAdd tooluniverse --url http://127.0.0.1:${TOOLUNIVERSE_PORT}/mcp --no-auth"
    elif [ ! -f "$mcpdir/tools.json" ]; then
        info "No tool list yet — building the connector plugins..."
        root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        ( set +u; . "$root/mcp.sh" && aistackMcpBuild tooluniverse ) || warn "Build failed — run: aistackMcpBuild tooluniverse"
    fi
}

# The mirror of StartTools: declining has to actively remove a server that is
# already there, or "no" would leave a stale one running. Not ours: left alone.
aistackLaunchInferenceStopTools() {
    local pids; pids=$(tooluniverseOurPids | tr '\n' ' ')
    if [ -z "$pids" ]; then
        tooluniverse_up && warn "Something else is serving port ${TOOLUNIVERSE_PORT} — left running, it is not ours."
        return 0
    fi
    info "Stopping our ToolUniverse server (pid ${pids%% })..."
    tooluniverseKillOurs
    local t=0
    while [ "$t" -lt 20 ] && [ -n "$(tooluniverseOurPids)" ]; do sleep 1; t=$((t+1)); done
    [ -n "$(tooluniverseOurPids)" ] && tooluniverseOurPids | xargs -r kill -9 2>/dev/null
    ok "ToolUniverse stopped."
}

# ---------- 5. free resources -------------------------------------------------
# Walk the memory-hungry applications you are running, biggest first, offering
# to close each. Enter means NO.
#
# macOS can ask the window server for "applications with a UI"; Linux has no
# such list that is present on every desktop (and none at all on a headless
# box), so this works from the process table instead: your own processes,
# grouped by executable, summed by RSS. Skipped: everything in this shell's
# ancestry (closing the terminal that runs this would be self-defeating),
# session infrastructure that a desktop cannot survive losing, the stack's own
# engines and monitors, and anything under FREE_MIN_MB.
aistackLaunchInferenceFreeResources() {
    local FREE_MIN_MB="${FREE_MIN_MB:-100}"
    info "Scanning your processes (groups over ${FREE_MIN_MB} MB)..."

    # this shell's ancestry: pids AND their executable names, so a group is
    # never offered just because a sibling process shares the name
    local ancestors="" anc_names="" anc=$$ nm
    while [ -n "$anc" ] && [ "$anc" -gt 1 ] 2>/dev/null; do
        ancestors="${ancestors} ${anc}"
        nm=$(ps -o comm= -p "$anc" 2>/dev/null | tr -d ' ')
        [ -n "$nm" ] && anc_names="${anc_names} ${nm}"
        anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
    done

    # Session infrastructure: killing any of these logs you out, or kills audio,
    # graphics, credential access or your remote connection. Not a judgement
    # call worth offering, so it is never asked about.
    #
    # Deliberately covers several desktops rather than the one in front of us:
    # a KDE box and a GNOME box name the same services completely differently,
    # and a list that only knew GNOME would cheerfully offer to close KDE's
    # wallet, its polkit agent and its RDP server.
    local protected="
        systemd systemd-* dbus-daemon dbus-broker dbus-broker-lau snapd
        Xorg Xwayland xdg-* portal* pipewire pipewire-pulse wireplumber pulseaudio
        gnome-shell gnome-session-* gnome-keyring-d* gsd-* gvfs* mutter*
        plasmashell startplasma* kwin_* ksmserver kded* kwalletd* ksecretd
        kglobalacceld kactivitymanagerd kaccess kscreenlocker* xembedsniproxy
        xfce4-session xfwm4 xfsettingsd xfce4-power-* cinnamon* mate-session
        marco muffin lxqt-session openbox i3 sway Hyprland
        polkitd polkit-* pkexec at-spi-bus-laun at-spi2-registr ibus-* fcitx*
        krdpserver xrdp xrdp-sesman x11vnc vncserver* gnome-remote-desk*
        sshd ssh-agent gpg-agent scdaemon
        bash zsh sh dash su sudo tmux screen login agetty"

    local rows="" hidden_small=0 hidden_stack=0 hidden_prot=0
    # group by executable basename, summing RSS: a browser is dozens of
    # processes and closing "one tab's renderer" frees nothing worth having
    rows=$(ps -u "$(id -u)" -o pid=,rss=,args= 2>/dev/null | awk '
        {
            pid=$1; rss=$2; exe=$3;
            n=split(exe, parts, "/"); name=parts[n];
            if (name == "") next;
            if (name ~ /^\[/) next;                      # kernel threads
            mem[name] += rss;
            pids[name] = pids[name] " " pid;
        }
        END { for (n in mem) printf "%d|%s|%s\n", mem[n]/1024, n, pids[n]; }')

    local out="" mem name pids p skip lower
    while IFS='|' read -r mem name pids; do
        [ -z "$name" ] && continue
        skip=0
        # never touch this session's own ancestry
        for p in $ancestors; do case " $pids " in *" $p "*) skip=1 ;; esac; done
        case " $anc_names " in *" $name "*) skip=1 ;; esac
        [ "$skip" = "1" ] && continue
        # session infrastructure
        for p in $protected; do
            # shellcheck disable=SC2254
            case "$name" in $p) skip=1; break ;; esac
        done
        [ "$skip" = "1" ] && { hidden_prot=$((hidden_prot+1)); continue; }
        # the stack itself: engines, and the monitors that exist to watch it
        lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
        case "$lower" in
            ollama|llama-server|llama-cli|litellm|nvtop|btop|htop|radeontop|nvidia-smi)
                hidden_stack=$((hidden_stack+1)); continue ;;
        esac
        if [ "$mem" -lt "$FREE_MIN_MB" ]; then
            hidden_small=$((hidden_small+1)); continue
        fi
        out="${out}${mem}|${name}|${pids}
"
    done <<< "$rows"

    [ "$hidden_stack" -gt 0 ] && ok "Skipped ${hidden_stack} of this stack's own processes (engines, monitoring)."
    [ "$hidden_prot"  -gt 0 ] && ok "Skipped ${hidden_prot} session process group(s) the desktop needs."
    [ "$hidden_small" -gt 0 ] && ok "Skipped ${hidden_small} group(s) under ${FREE_MIN_MB} MB — too small to matter."
    [ -z "$out" ] && { ok "No closable applications found."; return 0; }
    warn "RSS is summed per executable and counts shared pages more than once — treat it as a ranking, not a total."

    local n2 pids2
    while IFS='|' read -r mem n2 pids2; do
        [ -z "$n2" ] && continue
        local count; count=$(printf '%s' "$pids2" | wc -w)
        if [ "$mem" -ge 1024 ]; then
            printf "  %-24s %s%s GB%s across %s process(es). " "$n2" "$BOLD" \
                   "$(awk -v m="$mem" 'BEGIN{printf "%.1f", m/1024}')" "$RESET" "$count" >&2
        else
            printf "  %-24s %s%d MB%s across %s process(es). " "$n2" "$BOLD" "$mem" "$RESET" "$count" >&2
        fi
        if ask_ny "Close?"; then
            # shellcheck disable=SC2086
            kill -TERM $pids2 2>/dev/null
            sleep 3
            local alive=""
            for p in $pids2; do kill -0 "$p" 2>/dev/null && alive="${alive} ${p}"; done
            if [ -n "$alive" ]; then
                warn "Forcing ${n2} closed."
                # shellcheck disable=SC2086
                kill -9 $alive 2>/dev/null
            fi
            ok "\"${n2}\" closed."
        else
            ok "Keeping \"${n2}\"."
        fi
    done <<< "$(printf '%s' "$out" | sort -t'|' -k1 -rn)"

    ok "Roughly $(availMemGbF) GB of memory available."
}

# ---------- 6. prerequisites --------------------------------------------------
# Hard gate: will this model at this context actually fit?
# Args: <engine> <model> <context>. Compares weights + KV estimate + runtime
# against the memory budget and says exactly what to change when it does not
# fit. Runs before anything is loaded, because discovering it afterwards means
# the OOM killer or a swap storm.
aistackLaunchInferencePrerequisites() {
    if [ $# -lt 3 ]; then
        aiStackUsage "aistackLaunchInferencePrerequisites <engine> <model> <context-tokens>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "context : tokens, e.g. 32768 / 65536 / 131072" \
            "$(_hintExamples aistackLaunchInferencePrerequisites engine-model-ctx)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" ctx="${3:-}" size_gb kv need budget total vram avail
    size_gb=$(engineModelSizeGb "$engine" "$model"); [ "${size_gb:-0}" -lt 1 ] && size_gb=1
    total=$(memTotalGb)
    budget=$(inferenceBudgetGb)
    vram=$(gpuVramGb)
    kv=$(( (ctx / 1024) * size_gb / 200 )); [ "$kv" -lt 1 ] && kv=1
    need=$(( size_gb + kv + 2 ))

    info "Prerequisites for ${model} @ $(( ctx / 1024 ))K on ${engine}"
    echo "    weights ~${size_gb} GB + KV ~${kv} GB + runtime 2 GB = ~${need} GB" >&2
    echo "    budget: ${budget} GB of ${total} GB allocatable RAM (reserve ${RAM_RESERVE_GB} GB)" >&2
    if [ "$need" -gt "$budget" ]; then
        fail "Does not fit: needs ~${need} GB, budget is ${budget} GB."
        fail "Lower the reserve:  RAM_RESERVE_GB=3 aistackLaunchInference"
        fail "...or choose a smaller context / model / quant."
        return 1
    fi
    # a discrete GPU changes speed, not fit: llama.cpp offloads what fits and
    # runs the rest on CPU, so say which case this is instead of failing
    if [ "${vram:-0}" -gt 0 ] && [ "$need" -gt "$vram" ]; then
        warn "Larger than the ${vram} GB of VRAM — llama.cpp will keep the overflow layers on CPU."
        warn "Expect a fraction of full-GPU speed. A smaller quant would fit entirely."
    fi
    avail=$(availMemGb)
    [ "$avail" -lt "$need" ] && warn "Only ~${avail} GB available right now — the kernel will reclaim caches, or swap."
    ok "Fits: ~${need} GB of ${budget} GB."
}

# The context the engine is ACTUALLY serving, which can be lower than asked for.
# Args: <engine> <host>. Prints a number, or 0 when the engine cannot report it.
# Engines clamp silently to the model's trained maximum, so "what I requested"
# and "what I got" are different questions.
_servedContext() {
    local engine="${1:?}" host="${2:?}" port
    port=$(engine_port "$engine")
    case "$engine" in
        Ollama)
            curl -sf --max-time 8 "http://${host}:${port}/api/ps" 2>/dev/null | python3 -c '
import json,sys
try:
    m=json.load(sys.stdin).get("models",[])
    print(m[0].get("context_length",0) if m else 0)
except Exception: print(0)' 2>/dev/null ;;
        Llama.cpp)
            curl -sf --max-time 8 "http://${host}:${port}/props" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("default_generation_settings",{}).get("n_ctx", d.get("n_ctx",0)) or 0)
except Exception: print(0)' 2>/dev/null ;;
        *) echo 0 ;;
    esac
}

# The extra llama-server arguments this machine needs, one per line.
# Emits NOTHING for a CPU or integrated-GPU host — both of the flags that
# seemed obviously right there turned out to be measured losses.
#
# Reference box: AMD Ryzen 5 7430U (6 physical / 12 logical cores) with Radeon
# Vega RENOIR, Qwen2.5-Coder-7B Q4_K_M, llama-bench -p 64 -n 32.
#
# 1. NO -ngl ON AN INTEGRATED GPU. Two independent reasons, both measured.
#
#    (a) In llama-bench it is a net loss for interactive use:
#            -ngl 0     prompt 51.66 t/s     generation 8.19 t/s
#            -ngl 999   prompt 59.24 t/s     generation 7.61 t/s
#        Offload buys 15 % on prompt processing and LOSES 7 % on generation —
#        an iGPU shares the CPU's memory bandwidth, and token generation is
#        bandwidth-bound rather than compute-bound.
#
#    (b) IN LLAMA-SERVER IT DOES NOTHING AT ALL on this hardware. Same 1624-token
#        prompt, same 20-token reply, cold server each time:
#            (no flag)                 prompt 58.27 t/s   generation 7.30 t/s
#            -ngl 999                  prompt 58.54 t/s   generation 7.30 t/s
#            --device Vulkan0 -ngl 999 prompt 59.22 t/s   generation 7.29 t/s
#        Identical within noise, and llama-server's log never mentions Vulkan
#        while llama-bench's does — the server process does not load the Vulkan
#        backend, even though `llama-server --list-devices` reports Vulkan0.
#        Serving is the only path this toolkit uses, so passing -ngl here would
#        be a flag that promises offload and delivers none.
#
#    A DISCRETE card has its own memory and does not have problem (a); whether it
#    escapes (b) could not be tested here, so it still gets -ngl 999.
#    LLAMACPP_NGL opts in either way.
#
# 2. NO -t AT ALL.
#        -t 4     prompt 50.84 t/s     generation 7.99 t/s
#        -t 6     prompt 46.92 t/s     generation 8.16 t/s   <- llama.cpp's own default
#        -t 12    prompt 45.66 t/s     generation 6.72 t/s   <- $(nproc)
#    Passing $(nproc) is 18 % SLOWER than passing nothing, because nproc counts
#    logical CPUs and the two hyperthreads on a core share one memory port.
#    llama.cpp already defaults to the physical core count, which measured
#    fastest — so the correct flag here is no flag. LLAMACPP_THREADS overrides.
llamacppServerArgs() {
    local args=()
    # explicit overrides win, in either direction
    [ -n "${LLAMACPP_NGL:-}" ]     && args+=("-ngl" "${LLAMACPP_NGL}")
    [ -n "${LLAMACPP_THREADS:-}" ] && args+=("-t" "${LLAMACPP_THREADS}")
    if [ -z "${LLAMACPP_NGL:-}" ]; then
        case "$(llamacppBackend)" in
            cuda|hip)    args+=("-ngl" "999") ;;
            vulkan|sycl) [ "$(vulkanDeviceClass)" = "discrete" ] && args+=("-ngl" "999") ;;
        esac
    fi
    [ "${#args[@]}" -gt 0 ] && printf '%s\n' "${args[@]}"
    return 0
}

# ---------- 7. start the engine ----------------------------------------------
# Start the engine on the chosen model, context and address.
# Args: <engine> <model> <context> <bind>. Offers to restart a server already
# running, waits for real readiness, then reports endpoint, memory and CPU.
# Sets LAUNCH_ENDPOINT, which the agent step consumes.
aistackLaunchInferenceStart() {
    if [ $# -lt 4 ]; then
        aiStackUsage "aistackLaunchInferenceStart <engine> <model> <context-tokens> <bind-address>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "context : tokens, e.g. 32768" \
            "bind    : 127.0.0.1 (local) or this host's LAN IP" \
            "$(_hintExamples aistackLaunchInferenceStart engine-model-ctx-bind)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" ctx="${3:-}" bind="${4:-}" port
    _requireEngine "$engine" || return 1
    _requireModel "$engine" "$model" || return 1
    port=$(engine_port "$engine")

    if engine_up "$engine" "$bind"; then
        warn "${engine} is already serving on ${bind}:${port}."
        if ask_yn "Restart it with the settings chosen here?"; then
            case "$engine" in
                Ollama)
                    ollamaSystemServiceActive && _asRoot systemctl stop ollama.service >/dev/null 2>&1
                    pkill -f "ollama serve" 2>/dev/null ;;
                Llama.cpp) llamacppKillOurs ;;
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
            # the system service cannot be given per-launch context and bind
            # settings, so it must be out of the way before ours starts
            if ollamaSystemServiceActive; then
                warn "The system-wide ollama.service holds port ${port} and ignores these settings."
                if ask_yn "Stop it and run Ollama as you instead?"; then
                    _asRoot systemctl stop ollama.service >/dev/null 2>&1
                    sleep 2
                else
                    fail "Cannot apply a context size to the system service — aborting."
                    warn "Disable it permanently:  sudo systemctl disable --now ollama"
                    return 1
                fi
            fi
            OLLAMA_HOST="${bind}:${port}" OLLAMA_CONTEXT_LENGTH="$ctx" \
                OLLAMA_MODELS="$(ollamaModelsDir)" \
                OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}" \
                nohup ollama serve >"${TMPDIR:-/tmp}/ollama-serve.log" 2>&1 &
            sleep 3
            engine_up "$engine" "$bind" || { fail "Ollama did not come up — see ${TMPDIR:-/tmp}/ollama-serve.log"; return 1; }
            info "Loading ${model} (first token may take a while)..."
            curl -sf "http://${bind}:${port}/api/generate" \
                 -d "{\"model\":\"${model}\",\"keep_alive\":\"60m\"}" >/dev/null \
                || { fail "Failed to load ${model}."; return 1; }
            ;;
        Llama.cpp)
            local f extra=()
            f="${LLAMACPP_MODEL_DIR}/$(printf '%s' "$model" | sed 's|/|__|g; s|:|@|').gguf"
            [ -e "$f" ] || { fail "GGUF not found: ${f}"; return 1; }
            while IFS= read -r a; do extra+=("$a"); done < <(llamacppServerArgs)
            if [ "${#extra[@]}" -gt 0 ]; then
                ok "llama.cpp backend: $(llamacppBackend) — extra args: ${extra[*]}"
            else
                ok "llama.cpp backend: $(llamacppBackend) — no extra args; llama.cpp's own defaults measured fastest on this host"
            fi
            # --alias: without it the API advertises the full .gguf path, and
            # agents infer a runtime from the uploader org in the filename
            # (e.g. "lmstudio-community" -> "I'm running through LM Studio").
            nohup llama-server -m "$f" -c "$ctx" --alias "$model" \
                  --host "$bind" --port "$port" ${extra[@]+"${extra[@]}"} \
                  >"${TMPDIR:-/tmp}/llama-server.log" 2>&1 &
            local t=0
            info "Waiting for llama-server to finish loading the model (503 until ready)..."
            while [ "$t" -lt 600 ] && ! engine_up "$engine" "$bind"; do sleep 3; t=$((t+3)); done
            engine_up "$engine" "$bind" || { fail "llama-server did not become ready — see ${TMPDIR:-/tmp}/llama-server.log"; return 1; }
            ;;
    esac

    LAUNCH_ENDPOINT="http://${bind}:${port}"
    local mem cpu pat
    case "$engine" in
        Ollama) pat="[o]llama" ;; Llama.cpp) pat="[l]lama-server" ;;
    esac
    mem=$(ps -eo rss=,args= | awk -v p="$pat" '$0 ~ p {s+=$1} END {printf "%.1f", s/1048576}')
    cpu=$(ps -eo %cpu=,args= | awk -v p="$pat" '$0 ~ p {s+=$1} END {printf "%.1f", s}')
    echo >&2
    echo "${BOLD}=================== Running ===================${RESET}" >&2
    ok "Engine:   ${engine}"
    ok "Model:    ${model}"
    local served
    served=$(_servedContext "$engine" "$bind")
    if [ "${served:-0}" -gt 0 ] && [ "$served" -lt "$ctx" ]; then
        warn "Context:  $(( served / 1024 ))K tokens — you asked for $(( ctx / 1024 ))K, but"
        warn "          ${engine} clamped it to what this model was trained for."
        warn "          The extra KV cache was allocated for nothing; relaunching at"
        warn "          $(( served / 1024 ))K frees that memory."
    else
        ok "Context:  $(( ctx / 1024 ))K tokens"
    fi
    ok "Endpoint: ${LAUNCH_ENDPOINT}"
    ok "Memory:   ${mem} GB    Processor: ${cpu} %"
}

# ---------- 8. start the coding agent ----------------------------------------
# $1 agent, $2 engine, $3 model. Uses LAUNCH_ENDPOINT set by the start step.

# Ask the running endpoint what model id it advertises.
# Needed because llama-server names models its own way, and an agent config
# must use the id the server will actually accept.
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
aistackLaunchInferenceStartAgent() {
    if [ $# -lt 3 ]; then
        aiStackUsage "aistackLaunchInferenceStartAgent <agent> <engine> <model>" \
            "agent   : Pi | OpenCode | Claude | none" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "note    : needs LAUNCH_ENDPOINT set by aistackLaunchInferenceStart" \
            "$(_hintExamples aistackLaunchInferenceStartAgent agent-engine-model)"
        return 2
    fi
    local agent="${1:-}" engine="${2:-}" model="${3:-}" endpoint="${LAUNCH_ENDPOINT:-}"
    [ "$agent" = "none" ] && {
        info "No coding agent launched. The endpoint stays up:"
        echo "    ${endpoint:-$(_resolveEndpointFor "$engine" 2>/dev/null || echo "(nothing serving ${engine})")}" >&2
        return 0
    }
    case "$agent" in
        Claude)   aistackLaunchInferenceAgentClaude   "$engine" "$model" ;;
        Pi)       aistackLaunchInferenceAgentPi       "$engine" "$model" ;;
        OpenCode) aistackLaunchInferenceAgentOpenCode "$engine" "$model" ;;
    esac
}

# Refuse an engine name that is unknown or not installed, and say what to do.
# Args: <engine>. Catches typos before they turn into confusing later failures,
# and names MLX-LM explicitly: it is a valid engine on the macOS side of this
# repo, so "unknown engine" would be the wrong answer.
_requireEngine() {
    local engine="${1:?}"
    case "$engine" in
        Llama.cpp|Ollama) : ;;
        MLX-LM)
            fail "MLX-LM is Apple Silicon only — there is no Linux implementation."
            warn "Use Llama.cpp for the same quality band (Q5_K_M / Q6_K quants)."
            return 1 ;;
        *)  fail "Unknown engine '${engine}'."
            warn "Valid engines here:  Llama.cpp | Ollama"
            local w; w=$(enginesWithModels | tr '\n' ' ')
            [ -n "$w" ] && warn "With models here: ${w% }"
            return 1 ;;
    esac
    case "$engine" in
        Llama.cpp) llamacpp_installed && return 0 ;;
        Ollama)    ollama_installed   && return 0 ;;
    esac
    fail "${engine} is not installed."
    case "$engine" in
        Llama.cpp) warn "Install it:  aistackInstallLlamacppEngine" ;;
        Ollama)    warn "Install it:  aistackInstallOllamaEngine" ;;
    esac
    return 1
}

# Refuse a model that is not installed for this engine, and show what is.
# Args: <engine> <model>. Lists the engine's actual models so a typo is obvious,
# and names the download command when it has none at all.
_requireModel() {
    local engine="${1:?}" model="${2:?}" have
    have=$(engineListInstalled "$engine" 2>/dev/null)
    if [ -n "$have" ] && printf '%s\n' "$have" | grep -qxF "$model"; then
        return 0
    fi
    fail "'${model}' is not installed for ${engine}."
    if [ -n "$have" ]; then
        warn "${engine} models you do have:"
        printf '%s\n' "$have" | sed 's/^/     /' >&2
        warn "Download more with:  $(_modelInstallerFor "$engine")"
    else
        warn "${engine} has no models at all yet — download one:"
        warn "    $(_modelInstallerFor "$engine")"
    fi
    return 1
}

# The install function that provides one coding agent.
# Args: <agent>. Prints the function name so guidance can be pasted.
_agentInstallerFor() {
    case "$1" in
        Pi)       echo "aistackInstallPiCodingAgent" ;;
        OpenCode) echo "aistackInstallOpenCodeCodingAgent" ;;
        Claude)   echo "aistackInstallClaudeCodingAgent" ;;
    esac
}

# True when the named coding agent is installed. Args: <agent>.
_agentInstalled() {
    case "$1" in
        Pi)       pi_installed ;;
        OpenCode) opencode_installed ;;
        Claude)   claude_installed ;;
        *)        return 1 ;;
    esac
}

# Refuse to launch an agent that is not installed, and say how to get it.
# Args: <agent> [engine]. Also names the agents that ARE ready for that engine,
# so there is a working alternative rather than just a dead end.
_requireAgent() {
    local agent="${1:?}" engine="${2:-}" a others=""
    _agentInstalled "$agent" && return 0
    fail "${agent} is not installed — nothing to launch."
    warn "Install it:  $(_agentInstallerFor "$agent")"
    for a in Pi OpenCode Claude; do
        [ "$a" = "$agent" ] && continue
        _agentInstalled "$a" || continue
        [ -n "$engine" ] && { agent_supports_engine "$a" "$engine" || continue; }
        others="${others} ${a}"
    done
    if [ -n "$others" ]; then
        warn "Ready to use${engine:+ with ${engine}} right now:${others}"
    fi
    return 1
}

# Resolve the endpoint to hand to a coding agent, and prove something is
# actually serving it. Args: <engine>. Prints the URL, or fails with the exact
# command that starts the engine.
# LAUNCH_ENDPOINT is only set by aistackLaunchInferenceStart, so an agent launcher
# called on its own would otherwise write an empty URL into the agent's config
# — which looks like it worked and then reports "no models discovered".
_resolveEndpointFor() {
    local engine="${1:?}" ep host m
    ep="${LAUNCH_ENDPOINT:-}"
    [ -z "$ep" ] && ep="http://127.0.0.1:$(engine_port "$engine")"
    host=$(printf '%s' "$ep" | sed 's|http://||; s|:.*||')
    if engine_up "$engine" "$host"; then
        printf '%s' "$ep"
        return 0
    fi
    fail "Nothing is serving ${engine} at ${ep} — the agent would have no model."
    m=$(engineListInstalled "$engine" 2>/dev/null | head -1)
    if [ -n "$m" ]; then
        warn "Start it first:"
        warn "    aistackLaunchInferenceStart ${engine} ${m} 32768 127.0.0.1"
        warn "or run the whole flow:  aistackLaunchInference"
    else
        warn "No ${engine} models installed either — download one first:"
        warn "    $(_modelInstallerFor "$engine")"
    fi
    return 1
}

# --- Claude Code: Anthropic API, Ollama only ---------------------------------
# Launch Claude Code against a local Ollama endpoint.
# Ollama only: Claude Code speaks the Anthropic Messages API. Maps all three
# model tiers to the local model, puts a small model on the background tier when
# one exists, and offers continue/resume when this directory has sessions.
aistackLaunchInferenceAgentClaude() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aistackLaunchInferenceAgentClaude <engine> <model>" \
            "engine  : Ollama only — Claude Code needs the Anthropic API" \
            "model   : a tag for that engine — list: engineListInstalled <engine>" \
            "$(_hintExamples aistackLaunchInferenceAgentClaude engine-model Claude)"
        return 2
    fi
    local engine="$1" model="$2" endpoint
    _requireAgent Claude "$engine" || return 1
    _requireEngine "$engine" || return 1
    _requireModel "$engine" "$model" || return 1
    if [ "$engine" != "Ollama" ]; then
        fail "Claude Code needs the Anthropic API — ${engine} does not serve it."
        return 1
    fi
    endpoint=$(_resolveEndpointFor "$engine") || return 1
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
aistackLaunchInferenceAgentPi() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aistackLaunchInferenceAgentPi <engine> <model>" \
            "engine  : Llama.cpp | Ollama" \
            "model   : a tag for that engine — list: engineListInstalled <engine>" \
            "$(_hintExamples aistackLaunchInferenceAgentPi engine-model Pi)"
        return 2
    fi
    local engine="$1" model="$2" endpoint cfg="$HOME/.pi/agent/local-models.json"
    _requireAgent Pi "$engine" || return 1
    _requireEngine "$engine" || return 1
    _requireModel "$engine" "$model" || return 1
    endpoint=$(_resolveEndpointFor "$engine") || return 1
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
aistackLaunchInferenceAgentOpenCode() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aistackLaunchInferenceAgentOpenCode <engine> <model>" \
            "engine  : Llama.cpp | Ollama" \
            "model   : a tag for that engine — list: engineListInstalled <engine>" \
            "$(_hintExamples aistackLaunchInferenceAgentOpenCode engine-model OpenCode)"
        return 2
    fi
    local engine="$1" model="$2" endpoint cfg="$HOME/.config/opencode/opencode.json" mid
    _requireAgent OpenCode "$engine" || return 1
    _requireEngine "$engine" || return 1
    _requireModel "$engine" "$model" || return 1
    endpoint=$(_resolveEndpointFor "$engine") || return 1
    LAUNCH_ENDPOINT="$endpoint" mid=$(endpointModelId); [ -z "$mid" ] && mid="$model"
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
aistackLaunchInference() {
    echo "${BOLD}=============================================================${RESET}" >&2
    echo "${BOLD} Local inference — engine, model, context, network${RESET}" >&2
    echo "${BOLD}=============================================================${RESET}" >&2
    local engine model ctx bind agent
    engine=$(aistackLaunchInferenceEngineSelector) || return 1
    model=$(aistackLaunchInferenceModelSelector "$engine") || return 1
    ctx=$(aistackLaunchInferenceContextSelector "$engine" "$model") || return 1
    bind=$(aistackLaunchInferenceNetworkSelector "$engine") || return 1
    aistackLaunchInferenceFreeResources
    aistackLaunchInferenceKillPrevious "$engine"
    aistackLaunchInferencePrerequisites "$engine" "$model" "$ctx" || return 1
    aistackLaunchInferenceStart "$engine" "$model" "$ctx" "$bind" || return 1
    # Two-way answer: yes (re)starts the tool server, no removes a stale one.
    if [ "$(aistackLaunchInferenceToolsSelector)" = "yes" ]; then
        aistackLaunchInferenceStartTools || true
    else
        aistackLaunchInferenceStopTools
    fi
    agent=$(aistackLaunchInferenceAgentSelector "$engine")
    aistackLaunchInferenceStartAgent "$agent" "$engine" "$model"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    aistackLaunchInference
fi
