#!/bin/bash
#
# testAllAiModels.sh — run the aiModelTest suite against EVERY downloaded
#                      Ollama model and print a comparison table.
#
# Asks for the test prompt first (empty input uses a sensible default), then
# for each model: generation benchmark, Anthropic endpoint, tool-call test,
# context check. Each model is unloaded afterwards so the next one loads into
# clean memory.
#
# Final table columns: model | tokens | time | tokens/sec | tool call | total time
#
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# pull in the reusable test functions (the source guard in aiModelTest.sh
# prevents its own wrapper from auto-running)
source "${DIR}/aiModelTest.sh"

# ---------- ask for the prompt -----------------------------------------------
DEFAULT_PROMPT="What would be next best feature to code"
printf "%sPrompt%s [empty = \"%s\"]: " "${BOLD}" "${RESET}" "${DEFAULT_PROMPT}"
read -r USER_PROMPT </dev/tty || USER_PROMPT=""
PROMPT="${USER_PROMPT:-$DEFAULT_PROMPT}"
info "Test prompt: \"${PROMPT}\""

# ---------- preconditions ----------------------------------------------------
aiModelTestServer || exit 1
MODELS=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')
[ -z "$MODELS" ] && { fail "No models downloaded."; exit 1; }
N=$(echo "$MODELS" | wc -l | tr -d ' ')
info "Testing ${N} downloaded model(s):"
echo "$MODELS" | sed 's/^/      /'

# ---------- run the suite per model ------------------------------------------
ROWS=""
i=0
for MODEL in $MODELS; do
    i=$((i+1))
    echo
    echo "${BOLD}=============================================================${RESET}"
    echo "${BOLD} [${i}/${N}] ${MODEL}${RESET}"
    echo "${BOLD}=============================================================${RESET}"

    aiModelTestReset
    T0=$(date +%s)
    aiModelTestRun
    T1=$(date +%s)
    TOTAL=$((T1 - T0))

    ROWS="${ROWS}${MODEL}|${G_TOKENS}|${G_TIME}s|${G_TPS}|${R_toolcall}|${TOTAL}s
"
    # unload so the next model gets clean memory (and total times stay fair)
    ollama stop "$MODEL" >/dev/null 2>&1
done

# ---------- comparison table -------------------------------------------------
echo
echo "${BOLD}======================== Comparison =========================${RESET}"
printf "${BOLD}%-28s %8s %8s %10s %-10s %10s${RESET}\n" \
       "model" "tokens" "time" "tok/s" "tool call" "total time"
printf '%s\n' "-----------------------------------------------------------------------------"
printf '%s' "$ROWS" | while IFS='|' read -r m tok t tps tool total; do
    [ -z "$m" ] && continue
    case "$tool" in
        PASS)  tool="${GREEN}PASS${RESET}" ;;
        FLAKY) tool="${YELLOW}FLAKY${RESET}" ;;
        FAIL)  tool="${RED}FAIL${RESET}" ;;
    esac
    printf "%-28s %8s %8s %10s %-10b %10s\n" "$m" "$tok" "$t" "$tps" "$tool" "$total"
done
echo
echo "tokens/time/tok-s = generation only (Ollama's own counters)."
echo "total time        = full per-model suite incl. model load and all four tests."
