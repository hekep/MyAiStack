#!/bin/bash
#
# launchInference.sh — pick an engine, a model and a context size, serve it,
#                      and (where supported) hand it to the Claude CLI.
#
# Installing is install.sh's job. This script owns everything about *running*:
# which engine, which model, how much context, which network interface, how
# much memory to free first, and how to keep the model resident.
#
#   aistackLaunchInferenceEngineSelector    -> engine (asked only if several exist)
#   aistackLaunchInferenceModelSelector     -> a model installed FOR that engine
#   aistackLaunchInferenceContextSelector   -> 32K / 64K / 128K (default) / bigger
#   aistackLaunchInferenceNetworkSelector   -> localhost or LAN, for ANY engine
#   aistackLaunchInferenceFreeResources     -> close memory-hungry desktop apps
#   aistackLaunchInferenceKillPrevious      -> stop engines/models already serving, so
#                                       the new model gets the whole machine
#   aistackLaunchInferencePrerequisites     -> weights + KV cache must fit the GPU
#   aistackLaunchInferenceStart             -> start the engine's server, report usage
#   aistackLaunchInferenceAgentSelector     -> coding agent, filtered by engine
#                                       compatibility (self-answering when
#                                       only one option is valid)
#   aistackLaunchInferenceStartAgent        -> Pi / OpenCode / Claude on the endpoint
#   aistackLaunchInference                  -> wrapper: runs all of the above in order
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
    if [ $# -lt 1 ]; then
        aiStackUsage "ask_yn <question>" "Enter means YES" "example : ask_yn "Restart it?""
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
        aiStackUsage "ask_ny <question>" "Enter means NO" "example : ask_ny "Close it?""
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
        aiStackUsage "ask_val <question> <default>" "example : ask_val "Context tokens" 32768"
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
MLX_HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}/hub"
# where convert.sh writes locally converted MLX models
MLX_CONVERT_DIR="${MLX_CONVERT_DIR:-$HOME/Models/mlx}"
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

# ---------- monitoring proxy --------------------------------------------------
# LiteLLM sits in front of an engine and speaks the same OpenAI API, so an agent
# cannot tell the difference. What it adds is a record: every request logged,
# OpenTelemetry traces, and token counts per call.
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_CONFIG="${LITELLM_CONFIG:-$HOME/.aistack/litellm.yaml}"
PROXY_REQUEST_LOG="${AISTACK_PROXY_LOG:-$HOME/.aistack/litellm-requests.jsonl}"

# True when the LiteLLM proxy is installed (a uv tool, or already on PATH).
# Installed by aistackInstallLitellmMonitoring; absent means the proxy question
# is never asked.
litellm_installed() {
    command -v litellm >/dev/null 2>&1 || \
        { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^litellm'; }
}

# PIDs of the LiteLLM WE run, identified by the port we serve on — the same
# rule as llama-server: never match a bare process name, because the user may
# be running their own proxy for something else.
litellmOurPids()  { pgrep -f "litellm .*--port ${LITELLM_PORT}" 2>/dev/null; }
# Stop only our proxy, using the same port-scoped match.
litellmKillOurs() { pkill  -f "litellm .*--port ${LITELLM_PORT}" 2>/dev/null; }

# True when the proxy is answering on its port.
litellm_up() { curl -sf --max-time 3 "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" >/dev/null 2>&1 \
               || curl -sf --max-time 3 "http://127.0.0.1:${LITELLM_PORT}/v1/models" >/dev/null 2>&1; }

# --- tools layer: ToolUniverse ------------------------------------------------
# A local MCP tool server (biomedical tools, Tool_RAG, Finish) the launched
# model calls through the generated Pi plugin (mcp.sh). Port 8765 because 8080
# is llama.cpp, 8000 — ToolUniverse's own default — is what ATHENA-R1 gives to
# vLLM, and 5000/7000 belong to macOS AirPlay. Compact mode exposes four
# discovery/execute tools and loads the rest behind them; TOOLUNIVERSE_ARGS
# replaces that with e.g. "--categories tool_finder special_tools fda_drug_label".
TOOLUNIVERSE_PORT="${TOOLUNIVERSE_PORT:-8765}"
TOOLUNIVERSE_ARGS="${TOOLUNIVERSE_ARGS:---compact-mode}"
TOOLUNIVERSE_LOG="${TOOLUNIVERSE_LOG:-$HOME/.aistack/tooluniverse.log}"
# Where ToolUniverse keeps the Tool_RAG embedding cache (utils.get_user_cache_dir).
TOOLUNIVERSE_CACHE_DIR="${TOOLUNIVERSE_TMPDIR:-$HOME/Library/Caches/ToolUniverse}"
tooluniverse_installed() { command -v tooluniverse-smcp-server >/dev/null 2>&1 \
                           || { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^tooluniverse'; }; }
# Only OUR server: the one on our port. Same port-scoped match as the proxy.
# Two command lines are ours: the console script, and tooluniverseServer.py —
# the same server with the embedder on Metal, which is what this launcher starts.
tooluniverseOurPids()  { pgrep -f "tooluniverse(Server\.py|-smcp-server) .*--port ${TOOLUNIVERSE_PORT}" 2>/dev/null; }
tooluniverseKillOurs() { pkill  -f "tooluniverse(Server\.py|-smcp-server) .*--port ${TOOLUNIVERSE_PORT}" 2>/dev/null; }
# True when something answers on the port. MCP streamable-http rejects a bare
# GET with a 4xx, so any HTTP status at all means a server is there.
tooluniverse_up() { local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
                        "http://127.0.0.1:${TOOLUNIVERSE_PORT}/mcp" 2>/dev/null); [ -n "$c" ] && [ "$c" != "000" ]; }

# Longest context a llama.cpp model was trained for. Args: <tag>.
# Read straight out of the GGUF header, so it costs a few kilobytes and no model
# load. llama-server will happily accept -c far above this: it splits the request
# across slots, allocates a KV cache for what was asked, and then every decode
# fails with "Compute error ... ret = -3". Prints 0 when it cannot be determined.
llamacppTrainedContext() {
    [ $# -ge 1 ] || { echo 0; return 0; }
    # same filename encoding the rest of this script inlines; llamacppLocalFile
    # lives in install.sh and is not sourced here
    local f="${LLAMACPP_MODEL_DIR}/$(printf '%s' "$1" | sed 's|/|__|g; s|:|@|').gguf"
    [ -f "$f" ] || { echo 0; return 0; }
    python3 - "$f" <<'PYEOF' 2>/dev/null || echo 0
import struct, sys
fh = open(sys.argv[1], "rb")
magic, ver, n_tensors, n_kv = struct.unpack("<4sIQQ", fh.read(24))
if magic != b"GGUF":
    print(0); raise SystemExit
def rd_str():
    (n,) = struct.unpack("<Q", fh.read(8)); return fh.read(n).decode("utf-8", "replace")
FMT = {0:"<B",1:"<b",2:"<H",3:"<h",4:"<I",5:"<i",6:"<f",7:"<?",10:"<Q",11:"<q",12:"<d"}
def rd_val(t):
    if t == 8: return rd_str()
    if t == 9:                                   # array: read and discard
        (et,) = struct.unpack("<I", fh.read(4)); (n,) = struct.unpack("<Q", fh.read(8))
        for _ in range(n): rd_val(et)
        return None
    s = FMT[t]; return struct.unpack(s, fh.read(struct.calcsize(s)))[0]
out = 0
for _ in range(n_kv):
    k = rd_str(); (t,) = struct.unpack("<I", fh.read(4)); v = rd_val(t)
    if k.endswith(".context_length") and isinstance(v, int):
        out = v; break
print(out)
PYEOF
}

# This Mac's LAN address on en0, falling back to en1 (Wi-Fi vs Ethernet).
# Empty when offline, which the network selector treats as localhost-only.
lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null; }

# Engines installed on this machine, regardless of whether they hold models.
# Args: none. Prints a space-separated list, empty when none are installed.
_enginesInstalled() {
    local e=""
    llamacpp_installed && e="${e} Llama.cpp"
    mlxml_installed    && e="${e} MLX-LM"
    ollama_installed   && e="${e} Ollama"
    echo "${e# }"
}

# The install function that downloads models for one engine.
# Args: <engine>. Prints the function name, so the guidance can be pasted.
_modelInstallerFor() {
    case "$1" in
        Llama.cpp) echo "aistackInstallLlamacppModels" ;;
        MLX-LM)    echo "aistackInstallMlxmlModels" ;;
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
            engine-model-bind)     out="${out}example : ${fn} ${e} ${m} 127.0.0.1" ;;
            engine-model-ctx)      out="${out}example : ${fn} ${e} ${m} 32768" ;;
            engine-model-ctx-bind) out="${out}example : ${fn} ${e} ${m} 32768 127.0.0.1" ;;
            agent-engine-model)    out="${out}example : ${fn} ${agent:-Pi} ${e} ${m}" ;;
        esac
    done
    if [ "$any" = "1" ]; then printf '%b' "$out"; return 0; fi

    local inst; inst=$(_enginesInstalled)
    if [ -z "$inst" ]; then
        printf '%b' "example : none possible yet — no engine is installed.${pad}install one:  aistackInstallLlamacppEngine   (llama.cpp, recommended)${pad}              aistackInstallMlxmlEngine      (MLX-LM)${pad}              aistackInstallOllamaEngine     (Ollama — required by Claude Code)"
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
# Args: <agent> <engine>. Pi and OpenCode speak the OpenAI-compatible API every
# engine here serves; Claude Code needs the Anthropic Messages API, which only
# Ollama provides. This is the single rule that filters the agent menu.
agent_supports_engine() {   # $1 agent, $2 engine
    if [ $# -lt 2 ]; then
        aiStackUsage "agent_supports_engine <agent> <engine>" "agent   : Pi | OpenCode | Claude" "engine  : Llama.cpp | MLX-LM | Ollama" "example : agent_supports_engine Claude Ollama"
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
            "$(echo 'example : agent_reason Claude')"
        return 2
    fi
    case "$1" in
        Claude) echo "needs the Anthropic API — only Ollama serves it" ;;
        *)      echo "incompatible" ;;
    esac
}

# The port an engine serves on: Ollama 11434, llama.cpp 8080, MLX-LM 8081.
# Args: <engine>. Fixed per engine so several scripts agree without config.
engine_port() {
    if [ $# -lt 1 ]; then
        aiStackUsage "engine_port <engine>" \
            "engine  : Llama.cpp | MLX-LM | Ollama" \
            "$(_hintExamples engine_port engine)"
        return 2
    fi
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
    if [ $# -lt 2 ]; then
        aiStackUsage "engine_up <engine> <host>" \
            "engine  : Llama.cpp | MLX-LM | Ollama" \
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
    local d b
    # models pulled from HuggingFace, named models--org--repo in its cache
    if [ -d "$MLX_HF_CACHE" ]; then
        for d in "$MLX_HF_CACHE"/models--*; do
            [ -d "$d" ] || continue
            # HuggingFace creates the cache entry before the first byte arrives
            # and leaves blobs/<hash>.<etag>.incomplete behind until each file is
            # whole. Listing one of those offers a model that cannot load — the
            # same trap the llama.cpp side avoids with its .part naming.
            if find "$d" -name '*.incomplete' -print -quit 2>/dev/null | grep -q .; then
                continue
            fi
            # sentence-transformers models (ToolUniverse's Tool_RAG embedder lives
            # here too) carry modules.json; mlx_lm.server cannot serve one, so the
            # menu must not offer it
            if find "$d/snapshots" -maxdepth 2 -name modules.json -print -quit 2>/dev/null | grep -q .; then
                continue
            fi
            b=$(basename "$d")
            printf '%s\n' "$(printf '%s' "${b#models--}" | sed 's|--|/|')"
        done
    fi
    # models converted locally by convert.sh. mlx_lm.server takes a path just as
    # readily as a repo id, so a converted model needs no catalogue entry and no
    # install step — appearing in this list IS being installed.
    if [ -d "$MLX_CONVERT_DIR" ]; then
        for d in "$MLX_CONVERT_DIR"/*@*bit; do
            [ -d "$d" ] || continue
            printf '%s\n' "$d"
        done
    fi
}

# MLX models still downloading, as "repo<TAB>bytes-so-far". A partial download
# holds real disk and is deliberately invisible to the model list, so it is
# reported instead of silently accumulating.
mlxmlListPartial() {
    [ -d "$MLX_HF_CACHE" ] || return 0
    local d b
    for d in "$MLX_HF_CACHE"/models--*; do
        [ -d "$d" ] || continue
        find "$d" -name '*.incomplete' -print -quit 2>/dev/null | grep -q . || continue
        b=$(basename "$d")
        printf '%s\t%s\n' "$(printf '%s' "${b#models--}" | sed 's|--|/|')" \
                            "$(du -sk "$d" 2>/dev/null | cut -f1)"
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
    if [ $# -lt 1 ]; then
        aiStackUsage "engineListInstalled <engine>" \
            "engine  : Llama.cpp | MLX-LM | Ollama" \
            "$(_hintExamples engineListInstalled engine)"
        return 2
    fi
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
    if [ $# -lt 2 ]; then
        aiStackUsage "engineModelSizeGb <engine> <model>" \
            "engine  : Llama.cpp | MLX-LM | Ollama" \
            "model   : a tag for that engine — list: engineListInstalled <engine>" \
            "$(_hintExamples engineModelSizeGb engine-model)"
        return 2
    fi
    local engine="$1" tag="$2" f d
    case "$engine" in
        Llama.cpp)
            f="${LLAMACPP_MODEL_DIR}/$(printf '%s' "$tag" | sed 's|/|__|g; s|:|@|').gguf"
            [ -e "$f" ] && du -m "$f" 2>/dev/null | awk '{printf "%d", $1/1024}' || echo 0 ;;
        MLX-LM)
            # a locally converted model is a directory, not an HF cache entry
            case "$tag" in
                /*) du -sk "$tag" 2>/dev/null | awk '{printf "%d", ($1/1048576)+0.5}'; return 0 ;;
            esac
            d="${MLX_HF_CACHE}/models--$(printf '%s' "$tag" | sed 's|/|--|')"
            [ -d "$d" ] && du -sm "$d" 2>/dev/null | awk '{printf "%d", $1/1024}' || echo 0 ;;
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
            local name="${tag%%:*}" ver="${tag##*:}" mf
            mf="$HOME/.ollama/models/manifests/registry.ollama.ai/library/${name}/${ver}"
            [ -f "$mf" ] || mf=$(find "$HOME/.ollama/models/manifests" -type f -path "*${name}/${ver}" 2>/dev/null | head -1)
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
# sizes whose weights + estimated KV cache + runtime fit the GPU budget; for
# Ollama it also hides anything above the model's own ceiling from /api/show.
aistackLaunchInferenceContextSelector() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aistackLaunchInferenceContextSelector <engine> <model>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "$(_hintExamples aistackLaunchInferenceContextSelector engine-model)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" size_gb gpu_gb total_gb limit_mb
    size_gb=$(engineModelSizeGb "$engine" "$model"); [ "${size_gb:-0}" -lt 1 ] && size_gb=1
    total_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    limit_mb=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    if [ "$limit_mb" -gt 0 ]; then gpu_gb=$(( limit_mb / 1024 )); else gpu_gb=$(( total_gb * 3 / 4 )); fi

    # model's own ceiling. Asking for more than this is not merely wasteful:
    # llama-server allocates the KV cache for what was requested and then fails
    # every decode with "Compute error ... ret = -3".
    local model_max=0
    if [ "$engine" = "Llama.cpp" ]; then
        model_max=$(llamacppTrainedContext "$model")
    elif [ "$engine" = "Ollama" ] && curl -sf --max-time 3 "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
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
        local floor=32768
        # never hand back more than the model was trained for, even in the
        # fallback: that is the case that fails to decode rather than clamping
        [ "$model_max" -gt 0 ] && [ "$model_max" -lt "$floor" ] && floor="$model_max"
        warn "Even ${floor} tokens is tight for the GPU budget — using it anyway; expect swapping."
        tune_set "CTX_${engine}" "$floor"
        echo "$floor"; return 0
    fi

    if [ "${#opts[@]}" -eq 1 ]; then
        ok "Only one context size fits: $(( ${opts[0]} / 1024 ))K tokens — using it."
        tune_set "CTX_${engine}" "${opts[0]}"
        echo "${opts[0]}"; return 0
    fi

    local i=1 defnum=1 j=1 prev
    prev=$(tune_get "CTX_${engine}"); prev="${prev:-131072}"
    # A remembered context belongs to whichever model was running when it was
    # saved. Applied to a model with a smaller ceiling it is not merely a bad
    # default: llama-server allocates for it and then fails every decode.
    if [ "$model_max" -gt 0 ] && [ "$prev" -gt "$model_max" ]; then
        warn "Saved default $(( prev / 1024 ))K is above this model's $(( model_max / 1024 ))K ceiling — capping."
        prev="$model_max"
    fi
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
               warn "DHCP caveat: give this Mac a reservation, the bind is to ${ip}."
               echo "$ip"; return 0 ;;
            *) echo "Enter 1 or 2." >&2 ;;
        esac
    done
}

# Write the request logger LiteLLM loads as a callback. Args: none.
# LiteLLM resolves a "callbacks" entry relative to the config file's directory,
# so this lands beside litellm.yaml and is referenced as "aistackLogger.handler".
# Without it the proxy logs only access lines — method, path, status — which is
# not what "request logging" should mean.
_aiStackWriteProxyLogger() {
    local dir; dir=$(dirname "$LITELLM_CONFIG")
    mkdir -p "$dir"
    cat > "${dir}/aistackLogger.py" <<'PYEOF'
"""GENERATED by launchInference.sh — one JSON object per call, appended.

Records what was sent and what came back, so a session can be replayed or
audited after the fact. Written as JSON Lines: greppable, and readable one
record at a time without parsing the whole file.
"""
import json, os, time
from litellm.integrations.custom_logger import CustomLogger

LOG_FILE = os.path.expanduser(os.environ.get("AISTACK_PROXY_LOG",
                                             "~/.aistack/litellm-requests.jsonl"))


def _messages(kwargs):
    out = []
    for m in kwargs.get("messages") or []:
        c = m.get("content")
        if isinstance(c, list):                      # multimodal parts
            c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
        out.append({"role": m.get("role"), "content": c,
                    **({"tool_calls": m["tool_calls"]} if m.get("tool_calls") else {})})
    return out


def _reply(response_obj):
    try:
        d = response_obj.model_dump() if hasattr(response_obj, "model_dump") else dict(response_obj)
    except Exception:
        return {"raw": str(response_obj)[:2000]}
    ch = (d.get("choices") or [{}])[0]
    msg = ch.get("message") or {}
    return {"content": msg.get("content"),
            "tool_calls": msg.get("tool_calls"),
            "finish_reason": ch.get("finish_reason"),
            "usage": d.get("usage")}


class AiStackLogger(CustomLogger):
    def _write(self, record):
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(record, default=str) + "\n")

    def _record(self, kwargs, response_obj, start_time, end_time, ok):
        tools = [t.get("function", {}).get("name")
                 for t in (kwargs.get("optional_params") or {}).get("tools") or []]
        rec = {
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "ok": ok,
            "model": kwargs.get("model"),
            "seconds": round((end_time - start_time).total_seconds(), 3)
            if hasattr(end_time, "__sub__") else None,
            "tools_offered": [t for t in tools if t],
            "request": _messages(kwargs),
        }
        rec["response"] = _reply(response_obj) if ok else {"error": str(response_obj)[:2000]}
        self._write(rec)

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        self._record(kwargs, response_obj, start_time, end_time, True)

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        self._record(kwargs, response_obj, start_time, end_time, False)

    def log_success_event(self, kwargs, response_obj, start_time, end_time):
        self._record(kwargs, response_obj, start_time, end_time, True)


handler = AiStackLogger()
PYEOF
}

# Show what has gone through the proxy. Args: [count] (default 10), "full" to
# print whole records, or "remove" to delete the log. Reads the JSON Lines the
# proxy callback appends, so it works while the proxy runs and after it stopped.
# The log grows without limit — every prompt and reply is kept — so removing it
# is the way to reclaim that space.
aistackLaunchInferenceProxyLog() {
    local n="${1:-10}"

    if [ "$n" = "remove" ]; then
        if [ ! -f "$PROXY_REQUEST_LOG" ]; then
            ok "Nothing to remove — no request log at ${PROXY_REQUEST_LOG}"
            return 0
        fi
        local sz lines
        sz=$(du -h "$PROXY_REQUEST_LOG" 2>/dev/null | cut -f1 | tr -d ' ')
        lines=$(wc -l < "$PROXY_REQUEST_LOG" 2>/dev/null | tr -d ' ')
        warn "${PROXY_REQUEST_LOG} holds ${lines} calls and takes ${sz}."
        warn "It contains every prompt and reply that went through the proxy."
        ask_ny "Delete it?" || { ok "Kept."; return 0; }
        rm -f "$PROXY_REQUEST_LOG"
        ok "Deleted — ${sz} reclaimed."
        # The callback opens the file per write, so a running proxy simply
        # recreates it on the next call. Nothing needs restarting.
        [ -n "$(litellmOurPids)" ] && info "The running proxy will start a new log on its next request."
        return 0
    fi
    if [ ! -f "$PROXY_REQUEST_LOG" ]; then
        warn "No proxy traffic recorded yet: ${PROXY_REQUEST_LOG}"
        # Saying "answer yes" is useless advice to someone who did. Work out
        # which of the three actual reasons applies.
        local pids; pids=$(litellmOurPids | tr '\n' ' ')
        if [ -z "$pids" ]; then
            echo "         No proxy is running. Relaunch and answer yes to" >&2
            echo "         \"Route <engine> through the LiteLLM proxy?\"." >&2
        elif ! grep -q '^  callbacks:' "$LITELLM_CONFIG" 2>/dev/null; then
            echo "         A proxy IS running (pid ${pids%% }), but its config has no request" >&2
            echo "         logger — it was started before logging existed, or by an older" >&2
            echo "         version. Relaunch to regenerate the config:" >&2
            echo "             ${LITELLM_CONFIG}" >&2
            echo "         The model stays resident, so this costs seconds, not a reload." >&2
        else
            echo "         A proxy is running and configured to log, but nothing has been" >&2
            echo "         sent through it yet. Ask the agent something." >&2
        fi
        return 1
    fi
    if [ "$n" = "full" ]; then
        python3 -c '
import json,sys
for line in open(sys.argv[1]):
    print(json.dumps(json.loads(line), indent=2))
    print("-" * 70)' "$PROXY_REQUEST_LOG"
        return 0
    fi
    case "$n" in
        ''|*[!0-9]*)
            aiStackUsage "aistackLaunchInferenceProxyLog [count | full | remove]" \
                "count   : how many recent calls to summarise (default 10)" \
                "full    : print whole records, one JSON object per call" \
                "remove  : delete the log and reclaim its space" \
                "example : aistackLaunchInferenceProxyLog 20"
            return 2 ;;
    esac
    echo "${BOLD}Last ${n} calls through the proxy${RESET}  (${PROXY_REQUEST_LOG})" >&2
    tail -n "$n" "$PROXY_REQUEST_LOG" | python3 -c '
import json, sys
for line in sys.stdin:
    try: r = json.loads(line)
    except ValueError: continue
    u = (r.get("response") or {}).get("usage") or {}
    last = ""
    for m in reversed(r.get("request") or []):
        if m.get("role") == "user" and m.get("content"):
            last = " ".join(str(m["content"]).split())[:58]; break
    calls = (r.get("response") or {}).get("tool_calls") or []
    tag = f" -> {calls[0].get(chr(102)+chr(110)) or calls[0].get("function",{}).get("name","tool")}()" if calls else ""
    print(f"  {r["at"]}  {r.get("seconds",0):>6}s  "
          f"in {u.get("prompt_tokens",0):>6} out {u.get("completion_tokens",0):>5}  "
          f"{len(r.get("tools_offered") or []):>2} tools  {last}{tag}")'
}

# Stop the proxy this toolkit started, if any. Args: none.
# The mirror of StartProxy: declining the proxy has to actively remove one that
# is already there, or the agent would be pointed at the engine while a stale
# proxy kept running and logging nothing. A proxy on the port that is not ours
# is left alone — it belongs to whoever started it.
aistackLaunchInferenceStopProxy() {
    local pids; pids=$(litellmOurPids | tr '\n' ' ')
    if [ -z "$pids" ]; then
        if litellm_up; then
            warn "Something else is serving port ${LITELLM_PORT} — left running, it is not ours."
        fi
        return 0
    fi
    info "Stopping our LiteLLM proxy (pid ${pids%% })..."
    litellmKillOurs
    local t=0
    while [ "$t" -lt 20 ] && [ -n "$(litellmOurPids)" ]; do sleep 1; t=$((t+1)); done
    [ -n "$(litellmOurPids)" ] && litellmOurPids | xargs -r kill -9 2>/dev/null
    ok "Proxy stopped — the agent will talk to the engine directly."
}

# ---------- 5c. tools layer: ToolUniverse -------------------------------------
# Asked after the proxy, with the same two-way answer: yes (re)starts our
# server, no removes one that is already there. Default no — it is a second
# Python process most coding sessions have no use for. Prints yes|no, and prints
# no without asking when ToolUniverse is not installed.
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
    # ToolUniverse itself picks cuda or cpu for the Tool_RAG embedder and nothing
    # else; tooluniverseServer.py is the same server with that one method
    # replaced so the embedder runs on Metal. Falls back to the console script
    # when the wrapper or the tool's interpreter is missing.
    local py="$HOME/.local/share/uv/tools/tooluniverse/bin/python" wrapper
    wrapper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tooluniverseServer.py"
    info "Starting ToolUniverse on 127.0.0.1:${TOOLUNIVERSE_PORT} (${TOOLUNIVERSE_ARGS}) — log: ${TOOLUNIVERSE_LOG}"
    # shellcheck disable=SC2086  # TOOLUNIVERSE_ARGS is a flag list by design
    if [ -x "$py" ] && [ -f "$wrapper" ]; then
        nohup "$py" "$wrapper" --host 127.0.0.1 --port "${TOOLUNIVERSE_PORT}" ${TOOLUNIVERSE_ARGS} \
            >"$TOOLUNIVERSE_LOG" 2>&1 </dev/null &
    else
        warn "tooluniverseServer.py or the tool's Python not found — embedder will run on the CPU."
        nohup tooluniverse-smcp-server --host 127.0.0.1 --port "${TOOLUNIVERSE_PORT}" ${TOOLUNIVERSE_ARGS} \
            >"$TOOLUNIVERSE_LOG" 2>&1 </dev/null &
    fi
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
    [ -n "$(tooluniverseCacheFile)" ] \
        || warn "No Tool_RAG embedding cache yet — the first Tool_RAG call would stall for minutes. Once: aistackLaunchInferenceWarmupTools"
}

# The newest embedding cache file ToolUniverse wrote, or nothing.
tooluniverseCacheFile() { ls -t "${TOOLUNIVERSE_CACHE_DIR}/embeddings/"*.pt 2>/dev/null | head -1; }

# Warm up Tool_RAG: fetch the embedding model and have the RUNNING server encode
# every loaded tool description once, so the first Tool_RAG call in a session
# is not a multi-minute stall inside a 90 s RPC. Args: [connector] (default
# tooluniverse). The encode goes through the server on purpose — ToolUniverse
# keys the cache on the exact tool set that process loaded, and a Python
# one-liner would load a different set and pay for a second full encode.
aistackLaunchInferenceWarmupTools() {
    local name="${1:-tooluniverse}" py="$HOME/.local/share/uv/tools/tooluniverse/bin/python" root cache t0 ms
    local snap="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--mims-harvard--ToolRAG-T1-GTE-Qwen2-1.5B"
    tooluniverse_installed || { fail "ToolUniverse is not installed — run: aistackInstallTooluniverseTools"; return 1; }
    tooluniverse_up || { fail "Nothing answers on port ${TOOLUNIVERSE_PORT} — start it: aistackLaunchInferenceStartTools"; return 1; }
    [ -f "${MCP_HOME:-$HOME/.aistack/mcp}/${name}/server.json" ] \
        || { fail "No MCP connector '${name}' — register it: aistackMcpAdd ${name} --url http://127.0.0.1:${TOOLUNIVERSE_PORT}/mcp --no-auth"; return 1; }
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    info "aistackLaunchInferenceWarmupTools — ToolRAG-T1 embedder + embedding cache"

    # 1. the model: 5.75 GiB, resumable, once
    if [ -d "$snap/snapshots" ] && ! ls "$snap"/blobs/*.incomplete >/dev/null 2>&1; then
        ok "Embedder present: $(du -sh "$snap" 2>/dev/null | cut -f1) — ${snap}"
    else
        info "Downloading mims-harvard/ToolRAG-T1-GTE-Qwen2-1.5B (5.75 GiB)..."
        [ -x "$py" ] || py=python3
        "$py" -c 'from huggingface_hub import snapshot_download as s; print(s("mims-harvard/ToolRAG-T1-GTE-Qwen2-1.5B"))' \
            || { fail "Download failed."; return 1; }
        ok "Embedder downloaded: $(du -sh "$snap" 2>/dev/null | cut -f1)"
    fi

    # 2. the cache — always through the running server. A .pt on disk proves
    #    nothing about THIS server: the key is the exact tool set it loaded.
    #    If the cache matches, this returns in seconds; if not, the server
    #    encodes every loaded description now (minutes, once) and writes it.
    local total
    total=$( ( set +u; . "$root/mcp.sh"; aistackMcpCall "$name" list_tools '{"mode":"names","limit":1}' 2>/dev/null ) \
             | python3 -c 'import json,sys; d=json.load(sys.stdin); d=json.loads(d) if isinstance(d,str) else d; print(d.get("total_tools","?"))' 2>/dev/null)
    info "Warming Tool_RAG through the running server (${total:-?} tools loaded) — minutes on a first run, seconds after..."
    t0=$(date +%s)
    ( set +u; . "$root/mcp.sh"
      AISTACK_MCP_TIMEOUT=3600 aistackMcpCall "$name" find_tools '{"query":"warm-up","limit":1,"search_method":"embedding"}' >/dev/null ) \
        || { fail "Warm-up call failed — see ${TOOLUNIVERSE_LOG}"; return 1; }
    cache=$(tooluniverseCacheFile)
    ok "Warm-up call: $(( $(date +%s) - t0 )) s · cache: $(du -h "$cache" 2>/dev/null | cut -f1) ${cache:-"(no cache file found)"}"

    # 3. a warm call, timed — this is what a session will feel
    ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    ( set +u; . "$root/mcp.sh"
      AISTACK_MCP_TIMEOUT=600 aistackMcpCall "$name" find_tools '{"query":"drug contraindication evidence","limit":5,"search_method":"embedding"}' >/dev/null ) \
        || { fail "Warm call failed — see ${TOOLUNIVERSE_LOG}"; return 1; }
    ms=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - ms ))
    ok "Warm Tool_RAG call: ${ms} ms  ($(grep -o '\[MyAiStack\] Tool_RAG embedder will load on [a-z0-9]* as [a-z0-9]*' "$TOOLUNIVERSE_LOG" 2>/dev/null | tail -1 | sed 's/.*load on //' || echo 'device: see log'))"
    # memory, measured three ways — process RSS alone says little on unified memory
    local spid; spid=$(tooluniverseOurPids | head -1)
    [ -n "$spid" ] && ok "Server RSS: $(ps -o rss= -p "$spid" | awk '{printf "%.2f GiB", $1/1048576}')  $(grep -o '\[MyAiStack\] embedder memory.*' "$TOOLUNIVERSE_LOG" 2>/dev/null | tail -1 | sed 's/\[MyAiStack\] //')"
    ok "Host: $(vm_stat | awk '/Pages free/ {f=$3} /Pages inactive/ {i=$3} /Pages wired/ {w=$4} END {gsub(/\./,"",f); gsub(/\./,"",i); gsub(/\./,"",w); printf "free+inactive %.1f GiB · wired %.1f GiB", (f+i)*16384/2**30, w*16384/2**30}') · swap $(sysctl -n vm.swapusage | awk '{print $6}' ) used"
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

# ---------- 5b. reuse an identical running server ----------------------------
# True when what is already serving is exactly what this launch would start.
# Args: <engine> <model> <ctx> <bind>. Reloading a model that is already
# resident costs minutes and re-allocates tens of gigabytes for no change, so
# the match is checked before anything is killed. Any difference — different
# model, different context, not answering on the requested address — returns 1
# and the normal start path runs.
aistackLaunchInferenceReuse() {
    if [ $# -lt 4 ]; then
        aiStackUsage "aistackLaunchInferenceReuse <engine> <model> <ctx> <bind>" \
            "$(_hintEngine)" \
            "returns : 0 when that exact model is already serving on that address" \
            "$(_hintExamples aistackLaunchInferenceReuse engine-model-ctx-bind)"
        return 2
    fi
    local engine="$1" model="$2" ctx="$3" bind="$4" port cur served f

    # Must answer on the address we were asked for: a server bound to loopback
    # cannot satisfy a request for the LAN address.
    engine_up "$engine" "$bind" || return 1
    port=$(engine_port "$engine")

    case "$engine" in
        Ollama)
            ollama ps 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF "$model" || return 1 ;;
        Llama.cpp)
            cur=$(curl -sf --max-time 8 "http://${bind}:${port}/v1/models" 2>/dev/null | python3 -c '
import json,sys
try:
    xs=(json.load(sys.stdin).get("data") or [])
    print(xs[0].get("id","") if xs else "")
except Exception: print("")' 2>/dev/null)
            # --alias makes the server report the tag; one started by hand reports
            # the .gguf path. Accept either, or an identical model is reloaded.
            if [ "$cur" != "$model" ]; then
                f="${LLAMACPP_MODEL_DIR}/$(printf '%s' "$model" | sed 's|/|__|g; s|:|@|').gguf"
                case "$cur" in
                    *"$(basename "$f")"*) : ;;
                    *) return 1 ;;
                esac
            fi ;;
        MLX-LM)
            # the list holds every cached model; ask for ours by name or path
            cur=$(LAUNCH_ENDPOINT="http://${bind}:${port}" endpointModelId "$model")
            case "$cur" in
                "$model") ;;
                *) [ -e "$model" ] && [ "$cur" = "$(cd "$model" 2>/dev/null && pwd -P)" ] || return 1 ;;
            esac ;;
        *) return 1 ;;
    esac

    # Same model, but a different context would mean a different KV allocation.
    served=$(_servedContext "$engine" "$bind")
    if [ "${served:-0}" -gt 0 ] && [ "$served" -ne "$ctx" ]; then
        info "Already serving ${model}, but at $(( served / 1024 ))K context — you asked for $(( ctx / 1024 ))K."
        return 1
    fi

    echo >&2
    echo "${BOLD}=================== Already running ===================${RESET}" >&2
    ok "Engine:   ${engine}"
    ok "Model:    ${model}"
    if [ "${served:-0}" -gt 0 ]; then
        ok "Context:  $(( served / 1024 ))K tokens"
    else
        ok "Context:  as previously started (${engine} does not report it)"
    fi
    ok "Endpoint: http://${bind}:${port}"
    ok "Reusing it — nothing was restarted, the model stays resident."
    return 0
}

# ---------- 4c. monitoring proxy selector ------------------------------------
# Ask whether to route this session through the LiteLLM proxy; prints "yes" or
# "no" on stdout. Args: <engine>. Asked only when LiteLLM is installed, so a
# machine without it is never offered a choice it cannot make. Enter always
# means no, and the answer is not remembered: an extra component in the path
# should be chosen each time, not inherited from a previous session.
aistackLaunchInferenceProxySelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackLaunchInferenceProxySelector <engine>" \
            "$(_hintEngine)" \
            "prints  : yes | no — whether to put LiteLLM in front of the engine" \
            "$(_hintExamples aistackLaunchInferenceProxySelector engine)"
        return 2
    fi
    local engine="${1:-}"
    litellm_installed || { echo "no"; return 0; }        # nothing to ask about
    echo >&2
    echo "${BOLD}Request logging for ${engine}${RESET}" >&2
    echo "  LiteLLM can sit in front of the engine on port ${LITELLM_PORT}. It speaks the" >&2
    echo "  same OpenAI API, so the agent cannot tell the difference — what you gain is" >&2
    echo "  a log of every request, token counts per call, and OpenTelemetry traces." >&2
    echo "  It costs one extra hop on localhost and about 100 MB of memory." >&2
    # Always Enter = no, and deliberately NOT remembered. Every other choice in
    # this launcher describes the model you want; this one adds a component in
    # front of it. Turning that on by holding Enter, because it was on last
    # week, is how a proxy ends up in a stack nobody meant to have one in.
    if ask_ny "Route ${engine} through the LiteLLM proxy?"; then
        echo "yes"
    else
        echo "no"
    fi
}

# ---------- 7b. start the monitoring proxy -----------------------------------
# Put LiteLLM in front of a running engine and repoint LAUNCH_ENDPOINT at it.
# Args: <engine> <model> <bind>. Writes a config naming one model — the one just
# started — so the id an agent asks for is the id the engine answers to. Leaves
# LAUNCH_ENDPOINT untouched and returns 1 if the proxy will not come up, so a
# failed proxy degrades to talking to the engine directly rather than to nothing.
aistackLaunchInferenceStartProxy() {
    if [ $# -lt 3 ]; then
        aiStackUsage "aistackLaunchInferenceStartProxy <engine> <model> <bind>" \
            "$(_hintEngine)" \
            "bind    : 127.0.0.1 or your LAN IP — where the ENGINE listens" \
            "$(_hintExamples aistackLaunchInferenceStartProxy engine-model-bind)"
        return 2
    fi
    local engine="$1" model="$2" bind="$3" port upstream mid t=0
    litellm_installed || { fail "LiteLLM is not installed — aistackInstallLitellmMonitoring"; return 1; }
    port=$(engine_port "$engine")
    upstream="http://${bind}:${port}"

    # Ask the engine what it calls the model. llama-server and mlx_lm.server
    # each name models their own way, and the proxy has to forward an id the
    # engine will accept.
    LAUNCH_ENDPOINT="$upstream" mid=$(endpointModelId "$model"); [ -z "$mid" ] && mid="$model"

    # A proxy already on the port is only reusable if it is ours; anything else
    # is the user's and must not be touched.
    if litellm_up; then
        if [ -n "$(litellmOurPids)" ]; then
            info "Restarting our LiteLLM proxy for the new model..."
            litellmKillOurs; sleep 2
        else
            fail "Something else is already serving port ${LITELLM_PORT}."
            warn "Set LITELLM_PORT to a free port, or stop that process first:"
            lsof -nP -iTCP:"${LITELLM_PORT}" -sTCP:LISTEN >&2
            return 1
        fi
    fi

    mkdir -p "$(dirname "$LITELLM_CONFIG")"
    _aiStackWriteProxyLogger
    # openai/<id> tells LiteLLM to speak the OpenAI protocol to api_base rather
    # than to look the name up as a hosted model.
    cat > "$LITELLM_CONFIG" <<YAML
# GENERATED by aistackLaunchInferenceStartProxy — rewritten on every launch.
model_list:
  - model_name: ${mid}
    litellm_params:
      model: openai/${mid}
      api_base: ${upstream}/v1
      api_key: local
litellm_settings:
  drop_params: true
  callbacks: aistackLogger.handler
YAML

    info "Starting LiteLLM on port ${LITELLM_PORT} in front of ${upstream}..."
    nohup litellm --config "$LITELLM_CONFIG" --port "$LITELLM_PORT" \
          >"${TMPDIR:-/tmp}/litellm.log" 2>&1 &
    while [ "$t" -lt 60 ] && ! litellm_up; do sleep 2; t=$((t+2)); done
    if ! litellm_up; then
        fail "LiteLLM did not come up in ${t}s — see ${TMPDIR:-/tmp}/litellm.log"
        warn "Continuing without it: the agent will talk to ${engine} directly."
        litellmKillOurs
        return 1
    fi
    LAUNCH_ENDPOINT="http://127.0.0.1:${LITELLM_PORT}"
    ok "Proxy:    ${LAUNCH_ENDPOINT} -> ${upstream}"
    ok "Requests: ${PROXY_REQUEST_LOG}"
    info "Read it with:  aistackLaunchInferenceProxyLog"
    return 0
}

# ---------- 4d. system prompt selector ---------------------------------------
# Choose which system prompt the coding agent runs with; prints the file path on
# stdout, or "default" to leave the agent's own prompt alone. Args: <model>.
# A model's system prompt should follow from what the model is: told it was "an
# expert coding assistant operating inside pi", MedGemma reported that it was
# running on gpt-3.5-turbo. The default follows the model name, so a medical
# model starts with the health prompt without anyone having to remember.
aistackLaunchInferenceSystemPromptSelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackLaunchInferenceSystemPromptSelector <model>" \
            "prints  : path to a SystemPrompts/*.txt file, or 'default'" \
            "$(_hintExamples aistackLaunchInferenceSystemPromptSelector engine-model)"
        return 2
    fi
    local model="$1" dir="${AI_STACK_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/SystemPrompts"
    [ -d "$dir" ] || { echo "default"; return 0; }

    local files=() names=() f
    for f in "$dir"/*.txt; do
        [ -e "$f" ] || continue
        files+=("$f"); names+=("$(basename "$f" .txt)")
    done
    [ "${#files[@]}" -eq 0 ] && { echo "default"; return 0; }

    # what this model probably wants, before anything is remembered
    local guess="coding" i
    case "$(printf '%s' "$model" | tr 'A-Z' 'a-z')" in
        *medgemma*|*meditron*|*med42*|*medical*|*medreason*|*meissa*|*bio*|*psy*|*shrink*|*baichuan-m2*|*athena*)
            guess="health" ;;
    esac
    local def=""
    for i in "${!names[@]}"; do [ "${names[$i]}" = "$guess" ] && def=$(( i + 1 )); done
    [ -z "$def" ] && def=1

    echo >&2
    echo "${BOLD}System prompt${RESET} — what this model should think it is" >&2
    for i in "${!names[@]}"; do
        printf '  %d) %-10s %s\n' "$(( i + 1 ))" "${names[$i]}" \
            "$(head -1 "${files[$i]}" | cut -c1-58)" >&2
    done
    printf '  %d) %-10s %s\n' "$(( ${#names[@]} + 1 ))" "default" \
        "leave the agent's own prompt untouched" >&2

    local sel
    sel=$(ask_val "Select [1-$(( ${#names[@]} + 1 ))]" "$def")
    case "$sel" in
        ''|*[!0-9]*) sel="$def" ;;
    esac
    if [ "$sel" -ge 1 ] && [ "$sel" -le "${#names[@]}" ]; then
        tune_set "SYSPROMPT_$(printf '%s' "$model" | tr -c 'A-Za-z0-9' '_')" "${names[$(( sel - 1 ))]}"
        ok "System prompt: ${names[$(( sel - 1 ))]}  (${files[$(( sel - 1 ))]})"
        echo "${files[$(( sel - 1 ))]}"
    else
        ok "System prompt: the agent's own default."
        echo "default"
    fi
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
    local target="${1:-}" rows line eng what mem killed=0
    # Our proxy is configured for one model. Whatever happens below, that model
    # is about to change, so a proxy we started is always stale here. It is not
    # an "inference engine" and holds no weights, so it is stopped quietly and
    # without asking — a proxy the user started themselves is left alone.
    if [ -n "$(litellmOurPids)" ]; then
        litellmKillOurs && ok "Stopped our LiteLLM proxy — it pointed at the previous model."
    fi
    # The tool server holds no weights either, and it is asked about again once
    # the engine is up — so a running one is torn down here the same quiet way.
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
aistackLaunchInferenceFreeResources() {
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
            ollama*|*llama-server*|*mlx*|anubis*|macmon*|litellm*|tooluniverse*)
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
aistackLaunchInferencePrerequisites() {
    if [ $# -lt 3 ]; then
        aiStackUsage "aistackLaunchInferencePrerequisites <engine> <model> <context-tokens>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "context : tokens, e.g. 32768 / 65536 / 131072" \
            "$(_hintExamples aistackLaunchInferencePrerequisites engine-model-ctx)"
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
            "bind    : 127.0.0.1 (local) or this Mac's LAN IP" \
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
# Needed because llama-server and mlx_lm.server name models their own way, and
# an agent config must use the id the server will actually accept.
endpointModelId() {
    # Args: [preferred-model ...]. An engine can advertise more than the model
    # that was launched — mlx_lm.server lists every model in the HuggingFace
    # cache, Ollama every model installed — so the first id is not "the" model.
    # Prefer an id that names what we asked for (exactly, or as the resolved
    # path a converted model is launched by); fall back to the first id only
    # when nothing matches. The proxy once forwarded every request to a 4B
    # model that happened to sort first while an 8B was the one launched.
    curl -sf --max-time 8 "${LAUNCH_ENDPOINT}/v1/models" 2>/dev/null | python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
    xs = d.get("data") or d.get("models") or []
    ids = [(x.get("id") or x.get("name") or "") for x in xs]
    want = [w for w in sys.argv[1:] if w]
    want += [os.path.realpath(w) for w in list(want) if os.path.exists(w)]
    hit = next((i for i in ids if i in want), None)
    if hit is None:
        hit = next((i for i in ids if any(i.endswith("/" + os.path.basename(w)) for w in want)), None)
    # a stated preference that matches nothing prints nothing: the caller then
    # uses the model name itself, which every engine here accepts as an id —
    # better than a confident wrong answer
    print(hit if hit is not None else ("" if want else (ids[0] if ids else "")))
except Exception: print("")' "$@" 2>/dev/null
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
# Args: <engine>. Catches typos before they turn into confusing later failures.
_requireEngine() {
    local engine="${1:?}"
    case "$engine" in
        Llama.cpp|MLX-LM|Ollama) : ;;
        *)  fail "Unknown engine '${engine}'."
            warn "Valid engines:  Llama.cpp | MLX-LM | Ollama"
            local w; w=$(enginesWithModels | tr '\n' ' ')
            [ -n "$w" ] && warn "With models here: ${w% }"
            return 1 ;;
    esac
    case "$engine" in
        Llama.cpp) llamacpp_installed && return 0 ;;
        MLX-LM)    mlxml_installed    && return 0 ;;
        Ollama)    ollama_installed   && return 0 ;;
    esac
    fail "${engine} is not installed."
    case "$engine" in
        Llama.cpp) warn "Install it:  aistackInstallLlamacppEngine" ;;
        MLX-LM)    warn "Install it:  aistackInstallMlxmlEngine" ;;
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
            "engine  : Llama.cpp | MLX-LM | Ollama" \
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
    local sp="${LAUNCH_SYSPROMPT:-default}"
    if [ "$sp" != "default" ] && [ -f "$sp" ]; then
        echo "    (system prompt: $(basename "$sp" .txt) — ${sp})" >&2
        pi --system-prompt "$(cat "$sp")"
    else
        echo "    (system prompt: Pi's own default)" >&2
        pi
    fi
}

# --- OpenCode: OpenAI-compatible, any engine ---------------------------------
# Launch OpenCode against the running endpoint.
# Merges a "local" provider into ~/.config/opencode/opencode.json (backing up
# the old file) with baseURL inside "options" — OpenCode ignores it anywhere
# else — keyed by the id the endpoint really advertises.
aistackLaunchInferenceAgentOpenCode() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aistackLaunchInferenceAgentOpenCode <engine> <model>" \
            "engine  : Llama.cpp | MLX-LM | Ollama" \
            "model   : a tag for that engine — list: engineListInstalled <engine>" \
            "$(_hintExamples aistackLaunchInferenceAgentOpenCode engine-model OpenCode)"
        return 2
    fi
    local engine="$1" model="$2" endpoint cfg="$HOME/.config/opencode/opencode.json" mid
    _requireAgent OpenCode "$engine" || return 1
    _requireEngine "$engine" || return 1
    _requireModel "$engine" "$model" || return 1
    endpoint=$(_resolveEndpointFor "$engine") || return 1
    LAUNCH_ENDPOINT="$endpoint" mid=$(endpointModelId "$model"); [ -z "$mid" ] && mid="$model"
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
    # Nothing is freed, killed or gated when the identical model is already
    # serving: the memory check would fail against memory this very model holds,
    # and the kill prompt would offer to destroy what we are about to rebuild.
    if aistackLaunchInferenceReuse "$engine" "$model" "$ctx" "$bind"; then
        LAUNCH_ENDPOINT="http://${bind}:$(engine_port "$engine")"
    else
        aistackLaunchInferenceFreeResources
        aistackLaunchInferenceKillPrevious "$engine"
        aistackLaunchInferencePrerequisites "$engine" "$model" "$ctx" || return 1
        aistackLaunchInferenceStart "$engine" "$model" "$ctx" "$bind" || return 1
    fi
    # The proxy question comes after the engine is up, because the proxy has to
    # ask the running engine what it calls the model before it can forward to it.
    # A refusal, or a proxy that fails to start, leaves LAUNCH_ENDPOINT pointing
    # at the engine — the session continues either way.
    # Either answer is an instruction about the path the agent will take, so
    # both act: yes (re)starts the proxy with a freshly generated config, no
    # removes one that is already there. Doing nothing on "no" would leave a
    # stale proxy running — especially on the reuse path, which skips the
    # teardown step that would otherwise have caught it.
    if [ "$(aistackLaunchInferenceProxySelector "$engine")" = "yes" ]; then
        aistackLaunchInferenceStartProxy "$engine" "$model" "$bind" || true
    else
        aistackLaunchInferenceStopProxy
    fi
    # The tool server gets the same two-way question, for the same reason.
    if [ "$(aistackLaunchInferenceToolsSelector)" = "yes" ]; then
        aistackLaunchInferenceStartTools || true
    else
        aistackLaunchInferenceStopTools
    fi
    agent=$(aistackLaunchInferenceAgentSelector "$engine")
    LAUNCH_SYSPROMPT=$(aistackLaunchInferenceSystemPromptSelector "$model")
    export LAUNCH_SYSPROMPT
    aistackLaunchInferenceStartAgent "$agent" "$engine" "$model"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    aistackLaunchInference
fi
