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

OLLAMA_PORT=11434
api_host() { echo "${OLLAMA_HOST:-127.0.0.1:${OLLAMA_PORT}}" | sed 's|^http://||;s|/$||'; }
server_up() { curl -sf "http://$(api_host)/api/version" >/dev/null 2>&1; }

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
        if ask_yn "Close?"; then
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

# ---------- 4. launch server + model -----------------------------------------
# Args: $1 = model name.
launchOllamaModel() {
    local model="${1:?model name required}"
    info "Launching Ollama with ${model}..."

    # server: start only if not already up
    if server_up; then
        ok "Ollama server already running — leaving it as is."
    else
        if command -v brew >/dev/null 2>&1 && brew list ollama >/dev/null 2>&1; then
            brew services start ollama >/dev/null 2>&1 || nohup ollama serve >/dev/null 2>&1 &
        else
            nohup ollama serve >/dev/null 2>&1 &
        fi
        sleep 3
        server_up || { fail "Could not start the Ollama server."; return 1; }
        ok "Ollama server started."
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
        curl -sf "http://$(api_host)/api/generate" \
             -d "{\"model\": \"${model}\", \"keep_alive\": \"60m\"}" >/dev/null \
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

    ANTHROPIC_BASE_URL="http://$(api_host)" \
    ANTHROPIC_AUTH_TOKEN="ollama" \
    ANTHROPIC_API_KEY="" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
    claude --model "$model"
}

# ---------- 6. wrapper: full pipeline ----------------------------------------
launchOllama() {
    local model
    model=$(launchOllamaModelSelector)            || return 1
    ok "Selected: ${model}"
    launchOllamaFreeResources
    launchOllamaModelPrerequisites "$model"       || return 1
    launchOllamaModel "$model"                    || return 1
    launchClaudeCliToOllama "$model"
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    launchOllama
fi
