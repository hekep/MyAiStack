#!/bin/bash
#
# testAllAiModels.sh — run the aiModelTest suite over EVERY engine and every
#                      model that engine has downloaded, with one prompt, then
#                      print a single comparison table.
#
# Asks for the test prompt once, then works through:
#   for each engine that has models:
#       for each of its models:
#           start/point the engine at it, run the suite, stop it again
#
# Servers are stopped between models on purpose: a 30 GB model left resident
# would starve the next one and make its numbers meaningless.
#
# Usage:  ./testAllAiModels.sh            PROMPT="..." ./testAllAiModels.sh
#
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${DIR}/aiModelTest.sh"

# ---------- free the hardware between models ---------------------------------
# This is the difference between a clean sweep and an out-of-memory crash: a
# 30 GB model left resident while the next 30 GB model loads takes the machine
# down. So teardown does NOT trust a recorded PID (a reused or stale server has
# none) — it kills by pattern and then WAITS until the memory is really back.
#
# CAREFUL: Ollama runs its own subprocess also called "llama-server", so ours
# is identified by the port we serve on, never by the bare name.
SWEEP_PIDS=""

engineProcsAlive() {
    { llamacppOurPids; pgrep -f "mlx_lm.server" 2>/dev/null; } | grep -c . || true
}
ollamaResident() { ollama ps 2>/dev/null | awk 'NR>1' | grep -c . || true; }

freeAllEngines() {
    local m i alive resident
    # 1. unload every model Ollama is holding (daemon stays: it is cheap)
    if curl -sf --max-time 2 "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
        for m in $(ollama ps 2>/dev/null | awk 'NR>1 {print $1}'); do
            ollama stop "$m" >/dev/null 2>&1
        done
    fi
    # 2. stop our llama-server and any mlx server
    llamacppKillOurs
    pkill -f "mlx_lm.server" 2>/dev/null
    # 3. WAIT until they are actually gone — SIGTERM does not free 30 GB instantly
    for i in $(seq 1 40); do
        alive=$(engineProcsAlive); resident=$(ollamaResident)
        [ "${alive:-0}" -eq 0 ] && [ "${resident:-0}" -eq 0 ] && break
        sleep 1
        [ "$i" -eq 20 ] && { llamacppOurPids | xargs -r kill -9 2>/dev/null; pkill -9 -f "mlx_lm.server" 2>/dev/null; }
    done
    sleep 2
    ok "Hardware free — $(freeMemGb) GB memory available."
}

freeMemGb() {
    vm_stat | awk '/Pages free/{f=$3} /Pages inactive/{i=$3} /Pages speculative/{s=$3}
                   END {gsub(/\./,"",f); gsub(/\./,"",i); gsub(/\./,"",s);
                        printf "%.1f", (f+i+s)*16384/1073741824}'
}

# would this model fit the GPU budget at all? (never start one that cannot —
# that is exactly what crashes the machine)
modelFitsNow() {
    local engine="$1" model="$2" size need gpu limit total
    size=$(engineModelSizeGb "$engine" "$model"); [ "${size:-0}" -lt 1 ] && size=1
    total=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    limit=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    if [ "$limit" -gt 0 ]; then gpu=$(( limit / 1024 )); else gpu=$(( total * 3 / 4 )); fi
    # single-model backstop only: with the teardown above, exactly one model is
    # ever resident, and the sweep runs at the engine's default context — so the
    # generous weights*1.3 allowance used when *choosing* a model would produce
    # false skips here. weights + 4 GB matches what actually loads.
    need=$(( size + 4 ))
    [ "$need" -le "$gpu" ]
}

stopEngineAfterTest() { freeAllEngines; }
cleanupAll()          { freeAllEngines >/dev/null 2>&1; }
trap 'echo; warn "Interrupted — stopping any server this sweep started."; cleanupAll; exit 130' INT TERM

# ---------- the prompt, asked once for the whole sweep -----------------------
DEFAULT_SWEEP_PROMPT="What would be next best feature to code"
if [ -z "${PROMPT:-}" ]; then
    printf "%sPrompt%s [empty = \"%s\"]: " "${BOLD}" "${RESET}" "${DEFAULT_SWEEP_PROMPT}"
    read -r USER_PROMPT </dev/tty || USER_PROMPT=""
    PROMPT="${USER_PROMPT:-$DEFAULT_SWEEP_PROMPT}"
fi
export PROMPT
info "Test prompt: \"${PROMPT}\""

# ---------- anything already serving? ----------------------------------------
# The sweep needs the machine to itself: it stops servers between models so
# each one is measured on an empty machine. Say what is running before taking
# it down, rather than killing the user's session silently.
RUNNING=$(busyEngines)
if [ -n "$RUNNING" ]; then
    echo >&2
    warn "${BOLD}A model is already loaded in memory:${RESET}"
    while IFS='|' read -r eng what mem; do
        [ -z "$eng" ] && continue
        printf "    %-10s %-28s %s\n" "$eng" "$what" "$mem" >&2
    done <<< "$RUNNING"
    warn "Its model stays resident and would distort every measurement — and two"
    warn "big models loaded at once can take the whole machine down."
    if ask_yn "Tear it down and run the sweep?  (n = exit without testing)"; then
        freeAllEngines
    else
        echo >&2
        ok "Exiting — nothing was touched, your loaded model is untouched."
        warn "The sweep needs the machine to itself: it stops engines between models"
        warn "by design, so it cannot run alongside your session."
        exit 0
    fi
else
    ok "No model is resident — the machine is free for the sweep."
fi

# ---------- what is there to test --------------------------------------------
ENGINES=()
while IFS= read -r e; do [ -n "$e" ] && ENGINES+=("$e"); done < <(enginesWithModels)
if [ "${#ENGINES[@]}" -eq 0 ]; then
    fail "No engine has downloaded models — run ./install.sh first."
    exit 1
fi

TOTAL_MODELS=0
for e in "${ENGINES[@]}"; do
    TOTAL_MODELS=$(( TOTAL_MODELS + $(engineListInstalled "$e" | grep -c . || true) ))
done
info "Sweeping ${#ENGINES[@]} engine(s), ${TOTAL_MODELS} model(s) in total:"
for e in "${ENGINES[@]}"; do
    echo "    ${e}: $(engineListInstalled "$e" | tr '\n' ' ')" >&2
done

# ---------- the sweep ---------------------------------------------------------
ROWS=""
IDX=0
SWEEP_T0=$(date +%s)
for engine in "${ENGINES[@]}"; do
    while IFS= read -r model; do
        [ -z "$model" ] && continue
        IDX=$(( IDX + 1 ))
        echo >&2
        echo "${BOLD}=============================================================${RESET}" >&2
        echo "${BOLD} [${IDX}/${TOTAL_MODELS}] ${engine} — ${model}${RESET}" >&2
        echo "${BOLD}=============================================================${RESET}" >&2

        aiModelTestReset
        # always start from an empty machine — never stack two models
        freeAllEngines
        T0=$(date +%s)
        if ! modelFitsNow "$engine" "$model"; then
            fail "$(engineModelSizeGb "$engine" "$model") GB model cannot fit the GPU budget — SKIPPED."
            warn "Raise it with: sudo sysctl iogpu.wired_limit_mb=... (see launchInference.sh)"
            R_generate=SKIP
            T1=$T0
        elif aiModelTestEnsureServing "$engine" "$model" && aiModelTestServer "$engine"; then
            [ -n "${TEST_SERVER_PID:-}" ] && SWEEP_PIDS="${SWEEP_PIDS} ${TEST_SERVER_PID}"
            aiModelTestRun "$engine" "$model"
            T1=$(date +%s)
        else
            fail "Could not serve ${model} on ${engine} — recording as failed."
            R_generate=FAIL
            T1=$(date +%s)
        fi

        ROWS="${ROWS}${engine}|${model}|${G_TOKENS}|${G_TIME}s|${G_TPS}|${R_toolcall}|${R_context}|$((T1-T0))s
"
        stopEngineAfterTest "$engine" "$model"
    done < <(engineListInstalled "$engine")
done
SWEEP_T1=$(date +%s)
cleanupAll

# ---------- comparison table --------------------------------------------------
echo
echo "${BOLD}============================== Comparison ==============================${RESET}"
printf "${BOLD}%-10s %-42s %7s %7s %8s %-7s %-7s %7s${RESET}\n" \
       "engine" "model" "tokens" "time" "tok/s" "tools" "ctx" "total"
printf '%s\n' "--------------------------------------------------------------------------------------------------"
printf '%s' "$ROWS" | while IFS='|' read -r e m tok t tps tool ctx total; do
    [ -z "$e" ] && continue
    case "$tool" in
        PASS)  tool="${GREEN}PASS${RESET}" ;;
        FLAKY) tool="${YELLOW}FLAKY${RESET}" ;;
        FAIL)  tool="${RED}FAIL${RESET}" ;;
    esac
    case "$ctx" in
        PASS) ctx="${GREEN}ok${RESET}" ;;
        WARN) ctx="${YELLOW}?${RESET}" ;;
        FAIL) ctx="${RED}small${RESET}" ;;
        SKIP) ctx="-" ;;
    esac
    # trim long model ids from the left so the interesting end stays visible
    if [ "${#m}" -gt 42 ]; then m="...${m: -39}"; fi
    printf "%-10s %-42s %7s %7s %8s %-7b %-7b %7s\n" "$e" "$m" "$tok" "$t" "$tps" "$tool" "$ctx" "$total"
done
echo
echo "tokens/time/tok-s = generation only, measured identically on every engine"
echo "                    (same OpenAI endpoint, warmup first, wall-clock timing)."
echo "tools             = tool-calling: PASS / FLAKY (retry only) / FAIL."
echo "ctx               = served context >= 32k?  (- = engine cannot report it)"
echo "total             = whole per-model suite, including loading the model."
echo "Sweep took $(( (SWEEP_T1 - SWEEP_T0) / 60 )) min $(( (SWEEP_T1 - SWEEP_T0) % 60 )) s."
