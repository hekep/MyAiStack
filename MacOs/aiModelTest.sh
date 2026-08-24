#!/bin/bash
#
# aiModelTest.sh — layered verification that the local Ollama stack works,
#                  with timing and tokens-per-second reporting.
#
# Tests each layer independently, so a failure points at the exact broken part:
#
#   1. aiModelTestServer      — is the Ollama server reachable?
#   2. aiModelTestGenerate    — raw generation: send $PROMPT, time it, count
#                               tokens, report tokens/second
#   3. aiModelTestAnthropic   — the Anthropic-compatible endpoint Claude CLI
#                               uses (/v1/messages): does it answer properly?
#   4. aiModelTestToolCall    — agentic fitness: given a weather tool, does the
#                               model emit a well-formed tool call? (This is
#                               what Claude Code needs constantly.)
#   5. aiModelTestContext     — is the loaded context window big enough for
#                               Claude Code (>= 32k), or the 4k default?
#   6. aiModelTest            — wrapper: runs all, prints verdict table
#
# Usage:
#   ./aiModelTest.sh                     # tests first downloaded model
#   ./aiModelTest.sh qwen3.6:35b-a3b     # tests a specific model
#
set -u

# ---- freely modifiable test prompt (used by the generation benchmark) -------
PROMPT="${PROMPT:-Hello, check the weather for today. I am in Turku, Finland}"

# The tool-call test uses its own FIXED prompt matched to the get_weather tool,
# independent of $PROMPT — otherwise an unrelated user prompt makes correct
# prose answers look like tool-call failures.
TOOL_PROMPT="Hello, check the weather for today. I am in Turku, Finland"

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)
info()  { echo "${BLUE}==>${RESET} $*"; }
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
fail()  { echo "${RED} ✗ ${RESET} $*"; }

HOSTADDR=$(echo "${OLLAMA_HOST:-127.0.0.1:11434}" | sed 's|^http://||;s|/$||')
case "$HOSTADDR" in *:*) : ;; *) HOSTADDR="${HOSTADDR}:11434" ;; esac
API="http://${HOSTADDR}"

MODEL="${1:-}"
# results (bash 3.2 on macOS has no associative arrays)
R_server=SKIP; R_generate=SKIP; R_anthropic=SKIP; R_toolcall=SKIP; R_context=SKIP
# metrics captured by aiModelTestGenerate (readable by wrapper scripts)
G_TOKENS=0; G_TIME=0; G_TPS=0

# reset all per-model state — call between models when testing several
aiModelTestReset() {
    R_server=SKIP; R_generate=SKIP; R_anthropic=SKIP; R_toolcall=SKIP; R_context=SKIP
    G_TOKENS=0; G_TIME=0; G_TPS=0
}

# the launcher provides the shared numbered model-selector menu
AI_LAUNCHER="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/launchInference.sh"

# ---------- 1. server reachable ----------------------------------------------
aiModelTestServer() {
    info "Test 1 — server reachable at ${API}"
    local v
    v=$(curl -sf --max-time 5 "${API}/api/version" 2>/dev/null)
    if [ -n "$v" ]; then
        ok "Ollama server up: $v"
        R_server=PASS
    else
        fail "No Ollama server at ${API}. Start it with ./launchInference.sh"
        R_server=FAIL
        return 1
    fi
}

# ---------- 2. raw generation: timer + token count + tok/s -------------------
aiModelTestGenerate() {
    info "Test 2 — raw generation with PROMPT: \"${PROMPT}\""
    local t0 t1 resp payload
    payload=$(python3 <<PYEOF
import json
print(json.dumps({"model": "${MODEL}", "prompt": """${PROMPT}""", "stream": False}))
PYEOF
)
    t0=$(date +%s)
    resp=$(curl -sf --max-time 300 "${API}/api/generate" -d "$payload" 2>/dev/null)
    t1=$(date +%s)
    if [ -z "$resp" ]; then
        fail "Generation failed (timeout or model not loadable)."
        R_generate=FAIL
        return 1
    fi
    # Ollama returns exact counters: eval_count (output tokens), eval_duration,
    # prompt_eval_count (input tokens), prompt_eval_duration — nanoseconds.
    # Human-readable lines go to stderr; a machine line (tokens time tok/s)
    # comes back on stdout and lands in G_TOKENS / G_TIME / G_TPS.
    local metrics
    metrics=$(python3 - "$resp" <<'PYEOF'
import json, sys
r = json.loads(sys.argv[1])
out_tok  = r.get("eval_count", 0)
out_ns   = r.get("eval_duration", 1)
in_tok   = r.get("prompt_eval_count", 0)
in_ns    = r.get("prompt_eval_duration", 1)
answer   = r.get("response", "").strip()
e = sys.stderr
print(f"    Answer (first 200 chars): {answer[:200]!r}", file=e)
print(f"    Input : {in_tok} tokens, processed at {in_tok/(in_ns/1e9):,.0f} tok/s", file=e)
print(f"    Output: {out_tok} tokens in {out_ns/1e9:.1f} s", file=e)
print(f"    >>> GENERATION SPEED: {out_tok/(out_ns/1e9):.1f} tokens/second <<<", file=e)
print(f"{out_tok} {out_ns/1e9:.1f} {out_tok/(out_ns/1e9):.1f}")
PYEOF
)
    read -r G_TOKENS G_TIME G_TPS <<< "$metrics"
    ok "Wall time: $((t1 - t0)) s total (includes model load if cold)."
    R_generate=PASS
}

# ---------- 3. Anthropic-compatible endpoint (what Claude CLI uses) ----------
aiModelTestAnthropic() {
    info "Test 3 — Anthropic Messages endpoint (/v1/messages, used by Claude CLI)"
    local resp payload
    # NOTE: generous max_tokens — thinking models (qwen3.x, deepseek-r1) spend
    # budget on reasoning first; a small cap yields an empty text reply.
    payload=$(python3 <<PYEOF
import json
print(json.dumps({"model": "${MODEL}", "max_tokens": 2000,
  "messages": [{"role": "user", "content": "Reply with exactly: PONG"}]}))
PYEOF
)
    resp=$(curl -sf --max-time 120 "${API}/v1/messages" \
        -H "content-type: application/json" \
        -H "x-api-key: ollama" -H "anthropic-version: 2023-06-01" \
        -d "$payload" 2>/dev/null)
    if [ -z "$resp" ]; then
        fail "/v1/messages did not answer — this Ollama version may predate Anthropic support. Upgrade Ollama."
        R_anthropic=FAIL
        return 1
    fi
    python3 - "$resp" <<'PYEOF' && R_anthropic=PASS || R_anthropic=FAIL
import json, sys
r = json.loads(sys.argv[1])
blocks = r.get("content", [])
txt = "".join(b.get("text","") for b in blocks if b.get("type")=="text")
think = "".join(b.get("thinking","") for b in blocks if b.get("type")=="thinking")
if think:
    print(f"    (thinking model: {len(think)} chars of reasoning before the reply)")
print(f"    Reply: {txt.strip()[:120]!r}")
assert r.get("type") == "message" and txt.strip(), "no text content in Anthropic response"
PYEOF
    [ "${R_anthropic}" = "PASS" ] && ok "Anthropic-format endpoint works." || fail "Anthropic endpoint malformed."
}

# ---------- 4. tool calling (the agentic must-have) --------------------------
aiModelTestToolCall() {
    info "Test 4 — tool calling: get_weather tool + fixed weather prompt"
    local resp payload attempt
    payload=$(python3 <<PYEOF
import json
print(json.dumps({
  "model": "${MODEL}", "max_tokens": 300,
  "tools": [{"name": "get_weather", "description": "Get current weather for a city",
             "input_schema": {"type": "object",
                              "properties": {"city": {"type": "string"}},
                              "required": ["city"]}}],
  "messages": [{"role": "user", "content": """${TOOL_PROMPT}"""}]}))
PYEOF
)
    # two attempts: tool use is sampled behavior — one miss means "flaky",
    # two misses means the model genuinely won't call tools
    R_toolcall=FAIL
    for attempt in 1 2; do
        [ "$attempt" = "2" ] && warn "No tool call on attempt 1 — retrying once (flaky vs. never)."
        resp=$(curl -sf --max-time 120 "${API}/v1/messages" \
            -H "content-type: application/json" \
            -H "x-api-key: ollama" -H "anthropic-version: 2023-06-01" \
            -d "$payload" 2>/dev/null)
        if [ -z "$resp" ]; then
            fail "Tool-call request failed."
            return 1
        fi
        if aiModelTestToolCallParse "$resp"; then
            [ "$attempt" = "2" ] && R_toolcall=FLAKY || R_toolcall=PASS
            break
        fi
    done

    case "${R_toolcall}" in
        PASS)  ok   "Well-formed tool call — model is agent-capable at this basic level." ;;
        FLAKY) warn "Tool call succeeded only on retry — expect inconsistent agent behavior." ;;
        *)     fail "Model did not use the tool in 2 attempts. It will struggle badly inside Claude Code." ;;
    esac
}

# parse one /v1/messages response: 0 = valid get_weather tool call, 1 = not
aiModelTestToolCallParse() {
    python3 - "$1" <<'PYEOF'
import json, sys
r = json.loads(sys.argv[1])
tools = [b for b in r.get("content", []) if b.get("type") == "tool_use"]
if tools:
    t = tools[0]
    print(f"    Model called tool: {t['name']}({json.dumps(t.get('input',{}))})")
    assert t["name"] == "get_weather", "wrong tool"
    assert "city" in t.get("input", {}), "missing required arg"
    print(f"    stop_reason: {r.get('stop_reason')}")
else:
    txt = "".join(b.get("text","") for b in r.get("content",[]) if b.get("type")=="text")
    print(f"    NO tool call — model answered in prose instead: {txt.strip()[:120]!r}")
    raise SystemExit(1)
PYEOF
}

# ---------- 5. context window size -------------------------------------------
aiModelTestContext() {
    info "Test 5 — loaded context window (Claude Code needs >= 32k)"
    local ctx tries=0
    while : ; do
        ctx=$(curl -sf "${API}/api/ps" 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
ms = d.get('models', [])
print(ms[0].get('context_length', 0) if ms else 0)" 2>/dev/null)
        [ -n "$ctx" ] && [ "$ctx" != "0" ] && break
        tries=$((tries+1))
        [ "$tries" -gt 1 ] && break
        # model got unloaded between tests — load it and retry once
        info "No model loaded right now — loading ${MODEL} to measure its context..."
        curl -sf --max-time 300 "${API}/api/generate" \
             -d "{\"model\": \"${MODEL}\", \"keep_alive\": \"5m\"}" >/dev/null 2>&1
    done
    if [ -z "$ctx" ] || [ "$ctx" = "0" ]; then
        warn "Could not read context length even after loading ${MODEL}."
        R_context=WARN
        return 0
    fi
    if [ "$ctx" -ge 32768 ]; then
        ok "Context window: ${ctx} tokens — enough for Claude Code."
        R_context=PASS
    else
        fail "Context window is only ${ctx} tokens. Claude Code's system prompt alone overflows it —"
        fail "this causes exactly the confused/mixed answers seen. Fix: restart the server with"
        fail "  ./launchInference.sh sets the context when it starts the engine"
        R_context=FAIL
    fi
}

# ---------- suite: tests 2-5 against the current $MODEL ----------------------
# Reusable per-model runner: set MODEL (and optionally call aiModelTestReset)
# then call this. Used by aiModelTest and by testAllAiModels.sh.
aiModelTestRun() {
    aiModelTestGenerate
    aiModelTestAnthropic
    aiModelTestToolCall
    aiModelTestContext
}

# ---------- 6. wrapper -------------------------------------------------------
aiModelTest() {
    command -v ollama >/dev/null 2>&1 || { fail "ollama not installed."; return 1; }
    command -v python3 >/dev/null 2>&1 || { fail "python3 required for JSON parsing."; return 1; }

    aiModelTestServer || return 1

    if [ -z "$MODEL" ]; then
        # no argument: offer the same numbered menu of installed models that
        # launchInference.sh provides it (launchInferenceModelSelector)
        if [ -f "$AI_LAUNCHER" ]; then
            source "$AI_LAUNCHER"
            MODEL=$(launchInferenceModelSelector Ollama) || { fail "No model selected."; return 1; }
        else
            MODEL=$(ollama list 2>/dev/null | awk 'NR==2 {print $1}')
            [ -z "$MODEL" ] && { fail "No models downloaded."; return 1; }
            warn "launchInference.sh not found — testing first downloaded: ${MODEL}"
        fi
    fi
    info "Model under test: ${BOLD}${MODEL}${RESET}"

    local T0 T1
    T0=$(date +%s)
    aiModelTestRun
    T1=$(date +%s)

    echo
    echo "${BOLD}================= Verdict =================${RESET}"
    local k v
    for k in server generate anthropic toolcall context; do
        eval "v=\${R_$k}"
        case "$v" in
            PASS)       ok   "$k" ;;
            WARN|FLAKY) warn "$k ($v)" ;;
            *)          fail "$k" ;;
        esac
    done
    echo "    Total test time: $((T1 - T0)) s"
    echo
    local fails=0 warns=0
    for k in "$R_server" "$R_generate" "$R_anthropic" "$R_toolcall" "$R_context"; do
        case "$k" in FAIL) fails=$((fails+1)) ;; WARN|FLAKY) warns=$((warns+1)) ;; esac
    done
    if [ "$fails" -gt 0 ]; then
        warn "${BOLD}Fix the FAIL lines above before judging the model inside Claude Code.${RESET}"
    elif [ "$warns" -gt 0 ]; then
        ok "${BOLD}No failures — stack works.${RESET}"
        warn "WARN lines above could not be fully verified; re-run to confirm."
    else
        ok "${BOLD}Stack is fit for Claude CLI use.${RESET}"
    fi
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    aiModelTest
fi
