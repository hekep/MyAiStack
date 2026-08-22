#!/bin/bash
#
# aiModelLauncher.sh — pick a local Ollama model, free resources, launch it,
#                      and connect Claude CLI to it.
#
# Six functions, each usable standalone (source this file), or run the script
# directly to execute the full pipeline:
#
#   1. launchOllamaModelSelector        -> prints menu, returns chosen model
#   2. launchOllamaFreeResources        -> offers to close memory-hungry apps
#   3. launchOllamaModelPrerequisites   -> RAM check for the model, exits if not enough
#   4. launchOllamaModel                -> starts server + loads model, reports
#   5. launchClaudeCliToOllama          -> claude CLI wired to the local model
#   6. launchOllama                     -> wrapper: runs 1-5 in order
#
# Usage:
#   ./aiModelLauncher.sh              # full pipeline
#   source aiModelLauncher.sh         # then call any function yourself
#
set -u

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

info()  { echo "${BLUE}==>${RESET} $*" >&2; }
ok()    { echo "${GREEN} ✓ ${RESET} $*" >&2; }
warn()  { echo "${YELLOW} ! ${RESET} $*" >&2; }
fail()  { echo "${RED} ✗ ${RESET} $*" >&2; }

# Y/n question, Enter = yes
ask_yn() {
    local answer
    printf "%s%s%s [Y/n] " "${BOLD}" "$1" "${RESET}" >&2
    read -r answer </dev/tty || return 1
    case "$answer" in ""|[Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}

# y/N question, Enter = NO — for actions that should not happen by accident
ask_ny() {
    local answer
    printf "%s%s%s [y/N] " "${BOLD}" "$1" "${RESET}" >&2
    read -r answer </dev/tty || return 1
    case "$answer" in [Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}

OLLAMA_PORT=11434
api_host() { echo "${OLLAMA_HOST:-127.0.0.1:${OLLAMA_PORT}}" | sed 's|^http://||;s|/$||'; }
server_up() { curl -sf "http://$(api_host)/api/version" >/dev/null 2>&1; }

# ---------- tuning settings (persisted; previous choice = next default) ------
SETTINGS_FILE="$HOME/.aiModelLauncher.conf"
tune_get() { [ -f "$SETTINGS_FILE" ] && sed -n "s/^$1=//p" "$SETTINGS_FILE" | tail -1; }
tune_set() {
    local tmp
    tmp=$(grep -v "^$1=" "$SETTINGS_FILE" 2>/dev/null)
    { [ -n "$tmp" ] && printf '%s\n' "$tmp"; printf '%s=%s\n' "$1" "$2"; } > "$SETTINGS_FILE"
}

# free-form question with a default; Enter = default. Echoes the answer.
ask_val() {
    local answer
    printf "%s%s%s [%s]: " "${BOLD}" "$1" "${RESET}" "$2" >&2
    read -r answer </dev/tty || { echo "$2"; return; }
    echo "${answer:-$2}"
}

# Claude Code's system prompt is far larger than Ollama's 4k default context.
# Serving with a small context truncates the instructions and produces the
# confused/mixed answers symptom. 32k is the working floor for agentic use.
# Defaults come from the previous session's tuning choices when present.
OLLAMA_CTX="${OLLAMA_CTX:-$(tune_get TUNE_CTX)}"; OLLAMA_CTX="${OLLAMA_CTX:-32768}"
TUNE_KV="${TUNE_KV:-$(tune_get TUNE_KV)}"
TUNE_THINK="${TUNE_THINK:-$(tune_get TUNE_THINK)}"
TUNE_SIDEKICK="${TUNE_SIDEKICK:-$(tune_get TUNE_SIDEKICK)}"
loaded_ctx() {  # context length of the currently loaded model (0 if none)
    curl -sf "http://$(api_host)/api/ps" 2>/dev/null | python3 -c '
import json,sys
try:
    m = json.load(sys.stdin).get("models", [])
    print(m[0].get("context_length", 0) if m else 0)
except Exception:
    print(0)' 2>/dev/null
}

# ---------- 1. model selector ------------------------------------------------
# Prints the chosen model name on stdout; menu/prompts go to the terminal.
launchOllamaModelSelector() {
    command -v ollama >/dev/null 2>&1 || { fail "ollama not installed — run ./install.sh first."; return 1; }
    server_up || { warn "Ollama server not running — starting temporarily to list models."; nohup ollama serve >/dev/null 2>&1 & sleep 2; }

    local models
    models=$(ollama list 2>/dev/null | awk 'NR>1 {print $1"|"$3" "$4}')
    [ -z "$models" ] && { fail "No models downloaded. Pull one first (see install.sh step 7)."; return 1; }

    echo >&2
    echo "${BOLD}Downloaded models:${RESET}" >&2
    local i=1 names=()
    while IFS='|' read -r name size; do
        printf "  %d) %-40s %s\n" "$i" "$name" "$size" >&2
        names+=("$name")
        i=$((i+1))
    done <<< "$models"

    local sel
    while true; do
        printf "\n%sSelect model [1-%d]:%s " "${BOLD}" "${#names[@]}" "${RESET}" >&2
        read -r sel </dev/tty || return 1
        [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#names[@]}" ] && break
        echo "Enter a number between 1 and ${#names[@]}." >&2
    done
    echo "${names[$((sel-1))]}"
}

# ---------- 2. free resources ------------------------------------------------
# Walks EVERY open desktop (GUI) application — no hardcoded list — sorted by
# memory use, biggest first. Per app: show memory, ask "Close? Y/n".
# Safeguards, all generic:
#   - skips the app hosting THIS shell session (found by walking the parent-
#     process chain — works for any terminal: Terminal, iTerm, Warp, VS Code…)
#   - skips Finder (macOS relaunches it anyway) and Ollama itself
launchOllamaFreeResources() {
    info "Freeing resources — scanning all open desktop applications..."

    # ancestor PIDs of this shell: whatever app contains one of these is our host
    local ancestors="" anc=$$
    while [ -n "$anc" ] && [ "$anc" -gt 1 ] 2>/dev/null; do
        ancestors="$ancestors $anc"
        anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
    done

    # every visible (non-background) GUI app: "pid<TAB>name" per line
    local apps
    apps=$(osascript -e 'tell application "System Events"
        set out to ""
        repeat with p in (every application process whose background only is false)
            set out to out & (unix id of p) & tab & (name of p) & linefeed
        end repeat
        return out
    end tell' 2>/dev/null)
    [ -z "$apps" ] && { warn "Could not enumerate desktop apps (Automation permission?) — skipping this step."; return 0; }

    # build "mem_mb|pid|name" rows; memory = sum of every process inside the .app
    # bundle (catches helper/renderer processes of Chrome-style apps)
    local rows="" pid name mem_mb
    while IFS=$'\t' read -r pid name; do
        [ -z "$pid" ] && continue

        case " $ancestors " in *" $pid "*)
            warn "\"$name\" is hosting this session — skipping (close it yourself if wanted)."
            continue ;;
        esac
        case "$name" in
            Finder) continue ;;
            [Oo]llama*) ok "\"$name\" is what we're launching — skipping."; continue ;;
        esac

        # match any process whose path contains "<name>.app/" (case-insensitive,
        # suffix-tolerant: "Code" matches "Visual Studio Code.app")
        mem_mb=$(ps -axo rss=,command= | awk -v app="$(echo "$name" | tr '[:upper:]' '[:lower:]').app/" '
            index(tolower($0), app) {s+=$1} END {printf "%d", s/1024}')
        # fallback: at least the main process itself
        [ "$mem_mb" -eq 0 ] && mem_mb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%d", $1/1024}')
        [ -z "$mem_mb" ] && mem_mb=0

        rows="${rows}${mem_mb}|${pid}|${name}
"
    done <<< "$apps"

    [ -z "$rows" ] && { ok "No closable desktop apps found."; return 0; }

    # biggest memory users first
    local mem pid2 name2
    while IFS='|' read -r mem pid2 name2; do
        [ -z "$name2" ] && continue
        if [ "$mem" -ge 1024 ]; then
            printf "  %-28s using %s%s GB%s of memory. " "$name2" "$BOLD" "$(awk -v m="$mem" 'BEGIN{printf "%.1f", m/1024}')" "$RESET" >&2
        else
            printf "  %-28s using %s%d MB%s of memory. " "$name2" "$BOLD" "$mem" "$RESET" >&2
        fi
        if ask_ny "Close?"; then
            osascript -e "quit app \"$name2\"" 2>/dev/null
            sleep 2
            if kill -0 "$pid2" 2>/dev/null; then
                warn "Graceful quit failed or app is asking to save — force closing."
                kill -9 "$pid2" 2>/dev/null
            fi
            kill -0 "$pid2" 2>/dev/null && fail "\"$name2\" would not close." || ok "\"$name2\" closed."
        else
            ok "Keeping \"$name2\"."
        fi
    done <<< "$(printf '%s' "$rows" | sort -t'|' -k1 -rn)"

    local free_gb
    free_gb=$(vm_stat | awk '/Pages free/ {f=$3} /Pages inactive/ {i=$3} END {gsub(/\./,"",f); gsub(/\./,"",i); printf "%.1f", (f+i)*16384/1073741824}')
    ok "Roughly ${free_gb} GB of memory now free/reclaimable."
}

# ---------- 3. prerequisites check -------------------------------------------
# Args: $1 = model name. Exits non-zero if the machine cannot hold the model.
launchOllamaModelPrerequisites() {
    local model="${1:?model name required}"
    info "Checking hardware prerequisites for ${model}..."

    local size_gb
    size_gb=$(ollama list 2>/dev/null | awk -v m="$model" '$1==m {print $3}')
    [ -z "$size_gb" ] && { fail "Model ${model} not found in 'ollama list'."; return 1; }

    # need: model weights + ~30% KV-cache/overhead + 2 GB runtime
    local need_gb
    need_gb=$(echo "$size_gb" | awk '{printf "%d", $1*1.3 + 2}')

    local total_gb gpu_gb
    total_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    gpu_gb=$(( total_gb * 3 / 4 ))    # macOS default GPU wired limit ~75%

    echo "    Model size on disk : ${size_gb} GB" >&2
    echo "    Estimated need     : ~${need_gb} GB (weights + KV cache + runtime)" >&2
    echo "    Machine RAM        : ${total_gb} GB (GPU can use ~${gpu_gb} GB)" >&2

    if [ "$need_gb" -gt "$gpu_gb" ]; then
        fail "REQUIREMENT NOT MET: ${model} needs ~${need_gb} GB but the GPU allocation is ~${gpu_gb} GB."
        fail "Options: choose a smaller model/quant, or raise the limit: sudo sysctl iogpu.wired_limit_mb=$(( (total_gb-6)*1024 ))"
        return 1
    fi

    # soft check: currently available memory
    local avail_gb
    avail_gb=$(vm_stat | awk '/Pages free/ {f=$3} /Pages inactive/ {i=$3} /Pages speculative/ {s=$3} END {gsub(/\./,"",f); gsub(/\./,"",i); gsub(/\./,"",s); printf "%d", (f+i+s)*16384/1073741824}')
    if [ "$avail_gb" -lt "$need_gb" ]; then
        warn "Only ~${avail_gb} GB currently free — the model needs ~${need_gb} GB."
        warn "macOS will evict caches/swap, but consider closing more apps (step 2)."
    else
        ok "~${avail_gb} GB free — enough for ~${need_gb} GB."
    fi
    ok "Prerequisites met: ${model} fits this machine."
}

# ---------- 3.5 tuning family ------------------------------------------------
# launchOllamaModel<Name>Tuning() — one question each, Enter keeps the shown
# default (current system value, or the previous session's choice).

# GPU wired limit — ALWAYS asked; default is whatever is set right now.
launchOllamaModelGpuTuning() {
    local total_mb cur def_mb cur_disp val
    total_mb=$(( $(sysctl -n hw.memsize) / 1048576 ))
    cur=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    def_mb=$(( total_mb * 3 / 4 ))
    [ "$cur" = "0" ] && cur_disp="0 (macOS default, ~${def_mb} MB usable)" || cur_disp="${cur} MB"
    info "GPU memory limit — current: ${cur_disp}"
    echo "    90% of RAM = $(( total_mb * 9 / 10 )) MB. Keep at least 4096 MB for macOS. 0 = macOS default."
    val=$(ask_val "GPU limit in MB" "$cur")
    case "$val" in *[!0-9]*) warn "Not a number — keeping current."; return 0 ;; esac
    [ "$val" = "$cur" ] && { ok "GPU limit unchanged (${cur_disp})."; return 0; }
    if [ "$val" != "0" ] && [ "$val" -gt $(( total_mb - 4096 )) ]; then
        warn "Refusing ${val} MB — would leave macOS under 4 GB. Keeping current."
        return 0
    fi
    sudo sysctl iogpu.wired_limit_mb="$val" >/dev/null \
        && ok "GPU limit set to ${val} MB (resets at reboot)." \
        || fail "sysctl failed — GPU limit unchanged."
}

# Context window — default: previous choice (or 32768).
launchOllamaModelContextTuning() {
    local val
    info "Context window — bigger helps Claude Code, costs KV-cache memory."
    echo "    16384 light · 32768 Claude Code floor · 65536 recommended with q8_0 KV · 131072 max"
    val=$(ask_val "Context tokens" "$OLLAMA_CTX")
    case "$val" in *[!0-9]*) warn "Not a number — keeping ${OLLAMA_CTX}."; return 0 ;; esac
    OLLAMA_CTX="$val"
    tune_set TUNE_CTX "$val"
    ok "Context: ${OLLAMA_CTX} tokens (applied when the server (re)starts)."
}

# KV-cache precision — default: previous choice, else q8_0 for 64k+ contexts.
launchOllamaModelKvCacheTuning() {
    local def val
    def="${TUNE_KV:-$( [ "$OLLAMA_CTX" -ge 65536 ] && echo q8_0 || echo f16 )}"
    info "KV-cache precision — q8_0 halves cache memory (uses flash attention), f16 = full."
    val=$(ask_val "KV cache type (f16 / q8_0)" "$def")
    case "$val" in
        f16|q8_0) TUNE_KV="$val"; tune_set TUNE_KV "$val"
                  ok "KV cache: ${TUNE_KV} (applied when the server (re)starts)." ;;
        *) warn "Unknown type — keeping ${def}."; TUNE_KV="$def" ;;
    esac
}

is_thinking_model() { case "$1" in qwen3*|deepseek-r1*|gpt-oss*|magistral*) return 0 ;; *) return 1 ;; esac; }

# Thinking on/off — asked only for thinking-family models; default: previous
# choice, else off (measured FLAKY tool calls here with thinking on).
launchOllamaModelThinkingTuning() {
    local model="${1:?model name required}" def val
    is_thinking_model "$model" || { TUNE_THINK=""; return 0; }
    def="${TUNE_THINK:-off}"
    info "${model} is a thinking model — thinking gives deeper reasoning, but slower"
    info "answers and less consistent tool calls under Claude Code."
    val=$(ask_val "Thinking (on / off)" "$def")
    case "$val" in
        on|off) TUNE_THINK="$val"; tune_set TUNE_THINK "$val"; ok "Thinking: ${TUNE_THINK}." ;;
        *) warn "Use on/off — keeping ${def}."; TUNE_THINK="$def" ;;
    esac
}

# Sidekick — small resident model for Claude Code's background (Haiku) tasks;
# asked only when a small model exists. Default: previous choice.
launchOllamaModelSidekickTuning() {
    local model="${1:?model name required}" candidates def val
    candidates=$(ollama list 2>/dev/null | awk -v m="$model" \
        'NR>1 && $1!=m { if ($4=="MB" || ($4=="GB" && $3+0<=8)) print $1 }')
    [ -z "$candidates" ] && { TUNE_SIDEKICK=""; return 0; }
    def="${TUNE_SIDEKICK:-$(echo "$candidates" | head -1)}"
    info "Claude Code uses a small 'Haiku' tier for background tasks — a small local"
    info "model there keeps the big model free. Candidates:"
    echo "$candidates" | sed 's/^/      /'
    val=$(ask_val "Sidekick model (or 'none' = main model does everything)" "$def")
    if [ "$val" = "none" ]; then
        TUNE_SIDEKICK=""; tune_set TUNE_SIDEKICK "none"
        ok "No sidekick — ${model} handles all tiers."
    elif echo "$candidates" | grep -qx "$val"; then
        TUNE_SIDEKICK="$val"; tune_set TUNE_SIDEKICK "$val"
        ok "Sidekick for background tasks: ${TUNE_SIDEKICK}."
    else
        warn "'${val}' is not an installed small model — keeping ${def}."
        [ "$def" = "none" ] && TUNE_SIDEKICK="" || TUNE_SIDEKICK="$def"
    fi
}

# Wrapper for the whole family.
launchOllamaModelTuning() {
    local model="${1:?model name required}"
    echo
    info "${BOLD}Tuning — Enter keeps the value shown in [brackets] (current/previous).${RESET}"
    launchOllamaModelGpuTuning
    launchOllamaModelContextTuning
    launchOllamaModelKvCacheTuning
    launchOllamaModelThinkingTuning "$model"
    launchOllamaModelSidekickTuning "$model"
}

# ---------- 4. launch server + model -----------------------------------------
# Args: $1 = model name.
launchOllamaModel() {
    local model="${1:?model name required}"
    info "Launching Ollama with ${model}..."

    # server: must run with a Claude-Code-sized context window (OLLAMA_CTX)
    if server_up; then
        ok "Ollama server already running."
        local ctx
        ctx=$(loaded_ctx)
        if [ -n "$ctx" ] && [ "$ctx" != "0" ] && [ "$ctx" -lt "$OLLAMA_CTX" ]; then
            warn "Loaded model has a ${ctx}-token context — too small for Claude Code (needs ${OLLAMA_CTX})."
            if ask_yn "Restart the server with OLLAMA_CONTEXT_LENGTH=${OLLAMA_CTX}?"; then
                brew services stop ollama >/dev/null 2>&1
                pkill -f "ollama serve" 2>/dev/null; sleep 2
                OLLAMA_CONTEXT_LENGTH="$OLLAMA_CTX" OLLAMA_FLASH_ATTENTION=1 \
                    OLLAMA_KV_CACHE_TYPE="${TUNE_KV:-f16}" nohup ollama serve >/dev/null 2>&1 &
                sleep 3
                server_up || { fail "Server did not come back up."; return 1; }
                ok "Server restarted (context ${OLLAMA_CTX}, KV cache ${TUNE_KV:-f16})."
            fi
        fi
    else
        OLLAMA_CONTEXT_LENGTH="$OLLAMA_CTX" OLLAMA_FLASH_ATTENTION=1 \
            OLLAMA_KV_CACHE_TYPE="${TUNE_KV:-f16}" nohup ollama serve >/dev/null 2>&1 &
        sleep 3
        server_up || { fail "Could not start the Ollama server."; return 1; }
        ok "Ollama server started (context ${OLLAMA_CTX}, KV cache ${TUNE_KV:-f16})."
    fi

    # already loaded models?
    local loaded
    loaded=$(ollama ps 2>/dev/null | awk 'NR>1 {print $1}')
    if echo "$loaded" | grep -qx "$model"; then
        ok "${model} is already loaded — nothing to do."
    else
        local other
        for other in $loaded; do
            warn "Another model is loaded: ${other}"
            if ask_yn "Bring ${other} down and replace it with ${model}?"; then
                ollama stop "$other" && ok "${other} stopped."
            else
                warn "Keeping ${other} loaded too — both will share GPU memory."
            fi
        done
        info "Loading ${model} into memory (first token may take a while)..."
        local load_body="{\"model\": \"${model}\", \"keep_alive\": \"60m\"}"
        if [ "${TUNE_THINK:-}" = "off" ] && is_thinking_model "$model"; then
            load_body="{\"model\": \"${model}\", \"keep_alive\": \"60m\", \"think\": false}"
        fi
        curl -sf "http://$(api_host)/api/generate" -d "$load_body" >/dev/null \
            || { fail "Failed to load ${model}."; return 1; }
        ok "${model} loaded (kept in memory for 60 min of idle)."
    fi

    # ---- final report ----
    local mem_gb cpu_pct
    mem_gb=$(ps -axo rss,comm | awk '/[o]llama/ {s+=$1} END {printf "%.1f", s/1048576}')
    cpu_pct=$(ps -axo %cpu,comm | awk '/[o]llama/ {s+=$1} END {printf "%.1f", s}')
    echo >&2
    echo "${BOLD}=================== Ollama status ===================${RESET}" >&2
    ok "Up and running on port: http://$(api_host)"
    ok "Model: ${model}"
    ok "Memory usage: ${mem_gb} GB   Processor usage: ${cpu_pct} %"
    ollama ps 2>/dev/null | sed 's/^/    /' >&2
}

# ---------- 5. Claude CLI -> Ollama ------------------------------------------
# Args: $1 = model name. Launches claude in the CURRENT working directory.
launchClaudeCliToOllama() {
    local model="${1:?model name required}"
    command -v claude >/dev/null 2>&1 || { fail "claude CLI not installed. Install: npm install -g @anthropic-ai/claude-code"; return 1; }

    info "Launching Claude CLI in $(pwd) connected to ${model} via Ollama..."
    warn "Local models are weaker than hosted Claude — expect slower, simpler agentic behavior."

    # session mode — resume/continue are purely local (JSONL under ~/.claude),
    # so they work identically with a local model backend.
    # Asked ONLY when previous sessions exist for this directory; otherwise
    # silently starts a new session.
    local smode="new" sflag="" proj_dir n_sessions answer
    proj_dir="$HOME/.claude/projects/$(pwd | sed 's|[/_.]|-|g')"
    if ls "$proj_dir"/*.jsonl >/dev/null 2>&1; then
        n_sessions=$(ls "$proj_dir"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
        info "${n_sessions} previous session(s) found for this directory."
        answer=$(ask_val "Session: C = continue latest, r = resume picker, n = new" "C")
        case "$answer" in
            [Cc]) smode="continue"; sflag="--continue" ;;
            [Rr]) smode="resume";   sflag="--resume" ;;
            [Nn]) smode="new" ;;
            *) warn "Unknown answer '${answer}' — continuing latest."; smode="continue"; sflag="--continue" ;;
        esac
        ok "Session mode: ${smode}."
    fi

    # NOTE: Remote Control (--remote-control / claude remote-control) does NOT
    # work here — it requires api.anthropic.com + claude.ai login, and is
    # disabled whenever ANTHROPIC_BASE_URL points at a non-Anthropic host.
    # Remote use of THIS stack = bind Ollama to the LAN (install.sh step 4)
    # and run claude on the remote machine pointing at this Mac's IP.

    # background (Haiku) tier: the tuned sidekick model if one was chosen
    local haiku="${TUNE_SIDEKICK:-}"
    case "$haiku" in ""|none) haiku="$model" ;; esac
    [ "$haiku" != "$model" ] && ok "Background (Haiku) tier -> ${haiku}"

    ANTHROPIC_BASE_URL="http://$(api_host)" \
    ANTHROPIC_AUTH_TOKEN="ollama" \
    ANTHROPIC_API_KEY="" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku" \
    claude --model "$model" $sflag
}

# ---------- 6. wrapper: full pipeline ----------------------------------------
launchOllama() {
    local model
    model=$(launchOllamaModelSelector)            || return 1
    ok "Selected: ${model}"
    launchOllamaFreeResources
    launchOllamaModelPrerequisites "$model"       || return 1
    launchOllamaModelTuning "$model"
    launchOllamaModel "$model"                    || return 1
    launchClaudeCliToOllama "$model"
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    launchOllama
fi
