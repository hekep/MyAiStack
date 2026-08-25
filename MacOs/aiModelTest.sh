#!/bin/bash
#
# aiModelTest.sh — layered verification of ONE engine + model, with timing and
#                  tokens-per-second.
#
# Asks which engine, then which of that engine's downloaded models, then tests
# each layer independently so a failure names the broken part:
#
#   aiModelTestEngineSelector  — numeric menu of engines that have models
#   aiModelTestModelSelector   — models downloaded for that engine
#   aiModelTestPromptSelector  — what to send (skipped if PROMPT is set)
#   aiModelTestEnsureServing   — start/point the engine at that model
#   aiModelTestServer          — is the endpoint reachable?
#   aiModelTestGenerate        — OpenAI /v1/chat/completions: tokens, time, tok/s
#   aiModelTestAnthropic       — /v1/messages (Ollama only; SKIP elsewhere)
#   aiModelTestToolCall        — agentic fitness: does it emit a tool call?
#   aiModelTestContext         — is the served context >= 32k?
#   aiModelTestRun             — tests 2-5 against the current engine+model
#   aiModelTest                — wrapper
#
# Measurement is deliberately identical for every engine (same OpenAI endpoint,
# same warmup, same wall-clock timing), so numbers are comparable across them.
#
# Usage:
#   ./aiModelTest.sh                          # menus
#   ./aiModelTest.sh Ollama qwen3.6:35b-a3b   # explicit engine + model
#   PROMPT="..." ./aiModelTest.sh
#
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# engine plumbing (ports, listers, detection, sizes) is shared with the launcher
source "${DIR}/launchInference.sh"

DEFAULT_PROMPT="Hello, check the weather for today. I am in Turku, Finland"
PROMPT="${PROMPT:-}"          # empty unless the caller/env set one
# fixed prompt for the tool test, so an unrelated PROMPT cannot fake a failure
TOOL_PROMPT="Hello, check the weather for today. I am in Turku, Finland"

R_server=SKIP; R_generate=SKIP; R_anthropic=SKIP; R_toolcall=SKIP; R_context=SKIP
G_TOKENS=0; G_TIME=0; G_TPS=0
TEST_ENDPOINT=""; TEST_SERVER_PID=""

# Clear all per-model state before testing another model.
# Resets the five R_* verdicts and the G_* generation metrics, so a sweep never
# reports one model's numbers against another's name.
aiModelTestReset() {
    R_server=SKIP; R_generate=SKIP; R_anthropic=SKIP; R_toolcall=SKIP; R_context=SKIP
    G_TOKENS=0; G_TIME=0; G_TPS=0
}

# enginesWithModels() comes from launchInference.sh (shared filter)

# ---------- engine selector ---------------------------------------------------
# Choose which engine to test; prints it on stdout.
# Offers only engines that have downloaded models — there is nothing to measure
# otherwise — and asks nothing when exactly one qualifies.
aiModelTestEngineSelector() {
    local engines=() e
    while IFS= read -r e; do [ -n "$e" ] && engines+=("$e"); done < <(enginesWithModels)
    if [ "${#engines[@]}" -eq 0 ]; then
        fail "No engine has downloaded models — run ./install.sh first."
        return 1
    fi
    if [ "${#engines[@]}" -eq 1 ]; then
        ok "Only one engine has models: ${engines[0]}"
        echo "${engines[0]}"; return 0
    fi
    echo >&2
    echo "${BOLD}Engines with downloaded models:${RESET}" >&2
    local i=1 n
    for e in "${engines[@]}"; do
        n=$(engineListInstalled "$e" | grep -c . || true)
        printf "  %d) %-12s %s model(s)\n" "$i" "$e" "$n" >&2
        i=$((i+1))
    done
    local sel
    while true; do
        sel=$(ask_val "Select engine [1-${#engines[@]}]" "1")
        case "$sel" in *[!0-9]*|"") echo "Enter a number." >&2; continue ;; esac
        [ "$sel" -ge 1 ] && [ "$sel" -le "${#engines[@]}" ] && break
        echo "Out of range." >&2
    done
    echo "${engines[$((sel-1))]}"
}

# ---------- prompt selector ---------------------------------------------------
# Decide what to send the model, storing it in PROMPT.
# Asked only when PROMPT is not already set, so a wrapper such as
# testAllAiModels.sh can ask once for a whole sweep and not be asked again.
aiModelTestPromptSelector() {
    if [ -n "$PROMPT" ]; then
        ok "Prompt: \"${PROMPT}\""
        return 0
    fi
    PROMPT=$(ask_val "Prompt to send to the model" "$DEFAULT_PROMPT")
    [ -z "$PROMPT" ] && PROMPT="$DEFAULT_PROMPT"
    ok "Prompt: \"${PROMPT}\""
}

# ---------- model selector (shared with the launcher) ------------------------
# Choose which of the engine's models to test; prints the tag on stdout.
# Args: <engine>. Shares launchInference.sh's selector so both tools show the
# same menu rather than drifting apart.
aiModelTestModelSelector() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aiModelTestModelSelector <engine>" \
            "$(_hintEngine)" \
            "$(_hintExamples aiModelTestModelSelector engine)"
        return 2
    fi
    aistackLaunchInferenceModelSelector "$1"
}

# ---------- make the engine serve this model ---------------------------------
# Make the engine serve the chosen model, starting or re-pointing it as needed.
# Args: <engine> <model>. Ollama loads on demand; llama.cpp and MLX bind one
# model at server start, so a server on a different model is restarted.
# Sets TEST_ENDPOINT, and TEST_SERVER_PID when this script started the server.
aiModelTestEnsureServing() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aiModelTestEnsureServing <engine> <model>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "effect  : starts or re-points the engine; sets TEST_ENDPOINT" \
            "$(_hintExamples aiModelTestEnsureServing engine-model)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" host="127.0.0.1" port t=0
    port=$(engine_port "$engine")
    TEST_ENDPOINT="http://${host}:${port}"
    TEST_SERVER_PID=""

    case "$engine" in
        Ollama)
            engine_up Ollama "$host" && return 0
            info "Starting the Ollama daemon..."
            OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}" nohup ollama serve >/dev/null 2>&1 &
            TEST_SERVER_PID=$!
            sleep 3
            engine_up Ollama "$host" || { fail "Ollama did not start."; return 1; }
            ;;
        Llama.cpp)
            # the model is bound at server start, so a different model means restart
            local f cur
            f="${LLAMACPP_MODEL_DIR}/$(printf '%s' "$model" | sed 's|/|__|g; s|:|@|').gguf"
            [ -e "$f" ] || { fail "GGUF not found: ${f}"; return 1; }
            if engine_up Llama.cpp "$host"; then
                cur=$(curl -sf --max-time 5 "${TEST_ENDPOINT}/v1/models" 2>/dev/null \
                      | python3 -c 'import json,sys;d=json.load(sys.stdin);xs=d.get("data") or d.get("models") or [];print((xs[0].get("id") or xs[0].get("name") or "") if xs else "")' 2>/dev/null)
                # a server started with --alias reports the tag; an older one
                # (or one started by hand) reports the .gguf path — accept both,
                # so an already-correct 30 GB model is never reloaded needlessly
                case "$cur" in
                    "$model"|*"$(basename "$f")"*) return 0 ;;
                esac
                warn "llama-server is serving something else — restarting it."
                # match the Homebrew binary path: Ollama runs its own runner
                # ALSO called llama-server, and killing that breaks Ollama.
                llamacppKillOurs; sleep 2
            fi
            info "Starting llama-server with $(basename "$f")..."
            nohup llama-server -m "$f" -c "${LLAMACPP_CTX:-32768}" --alias "$model" \
                  --host "$host" --port "$port" \
                  >"${TMPDIR:-/tmp}/llama-server-test.log" 2>&1 &
            TEST_SERVER_PID=$!
            info "Waiting for llama-server to load the model (it answers 503 until ready)..."
            while [ "$t" -lt 600 ] && ! engine_up Llama.cpp "$host"; do sleep 3; t=$((t+3)); done
            engine_up Llama.cpp "$host" || { fail "llama-server did not start — see ${TMPDIR:-/tmp}/llama-server-test.log"; return 1; }
            ;;
        MLX-LM)
            local cur2
            if engine_up MLX-LM "$host"; then
                cur2=$(curl -sf --max-time 5 "${TEST_ENDPOINT}/v1/models" 2>/dev/null \
                       | python3 -c 'import json,sys;d=json.load(sys.stdin);xs=d.get("data") or d.get("models") or [];print((xs[0].get("id") or xs[0].get("name") or "") if xs else "")' 2>/dev/null)
                [ "$cur2" = "$model" ] && return 0
                warn "mlx_lm.server is serving ${cur2:-something else} — restarting it."
                pkill -f "mlx_lm.server" 2>/dev/null; sleep 2
            fi
            info "Starting mlx_lm.server with ${model}..."
            nohup mlx_lm.server --model "$model" --host "$host" --port "$port" \
                  >"${TMPDIR:-/tmp}/mlx-server-test.log" 2>&1 &
            TEST_SERVER_PID=$!
            info "Waiting for mlx_lm.server to load the model..."
            while [ "$t" -lt 600 ] && ! engine_up MLX-LM "$host"; do sleep 3; t=$((t+3)); done
            engine_up MLX-LM "$host" || { fail "mlx_lm.server did not start — see ${TMPDIR:-/tmp}/mlx-server-test.log"; return 1; }
            ;;
    esac
}

# Stop the server only if this script was the one that started it.
# Leaves a server you were already running alone — the test should not tear
# down a session it did not create.
aiModelTestStopServer() {   # only stops what this script started
    [ -n "${TEST_SERVER_PID:-}" ] || return 0
    kill "$TEST_SERVER_PID" 2>/dev/null
    TEST_SERVER_PID=""
}

# Ask the endpoint which model id it advertises.
# Accepts both the OpenAI shape ({data:[{id}]}) and llama.cpp's ({models:
# [{name}]}), because requests must name the model the server expects.
aiModelTestServedId() {
    curl -sf --max-time 8 "${TEST_ENDPOINT}/v1/models" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    xs=d.get("data") or d.get("models") or []
    print((xs[0].get("id") or xs[0].get("name") or "") if xs else "")
except Exception: print("")' 2>/dev/null
}

# ---------- 1. server reachable ----------------------------------------------
# Test 1: is the engine reachable and ready?
# Args: <engine>. Sets R_server. A failure here stops the suite, since every
# later test would just repeat the same connection error.
aiModelTestServer() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aiModelTestServer <engine>" \
            "$(_hintEngine)" \
            "note    : call aiModelTestEnsureServing first — it sets TEST_ENDPOINT" \
            "$(_hintExamples aiModelTestServer engine)"
        return 2
    fi
    local engine="${1:-}"
    info "Test 1 — ${engine} reachable at ${TEST_ENDPOINT}"
    if engine_up "$engine" "$(echo "$TEST_ENDPOINT" | sed 's|http://||; s|:.*||')"; then
        ok "${engine} is serving."
        R_server=PASS
    else
        fail "No ${engine} server at ${TEST_ENDPOINT}."
        R_server=FAIL
        return 1
    fi
}

# ---------- 2. generation: tokens, time, tok/s -------------------------------
# Test 2: generate text and measure it. Sets R_generate and G_TOKENS/TIME/TPS.
# Args: <engine> <model>. Uses the OpenAI endpoint on every engine, with a
# warmup request first so model-load time is not counted as generation time —
# that is what makes numbers from different engines comparable.
aiModelTestGenerate() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aiModelTestGenerate <engine> <model>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "prompt  : override with PROMPT=... ; sets G_TOKENS/G_TIME/G_TPS" \
            "$(_hintExamples aiModelTestGenerate engine-model)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" served payload resp t0 t1
    served=$(aiModelTestServedId); [ -z "$served" ] && served="$model"
    info "Test 2 — generation with PROMPT: \"${PROMPT}\""

    local warm
    warm=$(python3 - "$served" <<'PYEOF'
import json, sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 1,
                  "messages": [{"role": "user", "content": "hi"}]}))
PYEOF
)
    curl -sf --max-time 300 "${TEST_ENDPOINT}/v1/chat/completions" \
         -H "content-type: application/json" -H "authorization: Bearer local" \
         -d "$warm" >/dev/null 2>&1 || true      # warmup: loads the model

    payload=$(python3 - "$served" <<PYEOF
import json, sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 512,
                  "messages": [{"role": "user", "content": """${PROMPT}"""}]}))
PYEOF
)
    t0=$(python3 -c 'import time;print(time.time())')
    resp=$(curl -sf --max-time 600 "${TEST_ENDPOINT}/v1/chat/completions" \
           -H "content-type: application/json" -H "authorization: Bearer local" \
           -d "$payload" 2>/dev/null)
    t1=$(python3 -c 'import time;print(time.time())')
    if [ -z "$resp" ]; then
        fail "Generation failed (timeout or model would not load)."
        R_generate=FAIL
        return 1
    fi
    local metrics
    metrics=$(python3 - "$resp" "$t0" "$t1" <<'PYEOF'
import json, sys
r = json.loads(sys.argv[1]); elapsed = float(sys.argv[3]) - float(sys.argv[2])
u = r.get("usage", {}) or {}
out = u.get("completion_tokens", 0) or 0
inp = u.get("prompt_tokens", 0) or 0
txt = ""
for c in r.get("choices", []):
    txt += (c.get("message", {}) or {}).get("content", "") or ""
e = sys.stderr
print(f"    Answer (first 200 chars): {txt.strip()[:200]!r}", file=e)
print(f"    Input : {inp} tokens", file=e)
print(f"    Output: {out} tokens in {elapsed:.1f} s (wall clock, after warmup)", file=e)
tps = out / elapsed if elapsed > 0 else 0
print(f"    >>> GENERATION SPEED: {tps:.1f} tokens/second <<<", file=e)
print(f"{out} {elapsed:.1f} {tps:.1f}")
PYEOF
)
    read -r G_TOKENS G_TIME G_TPS <<< "$metrics"
    R_generate=PASS
}

# ---------- 3. Anthropic endpoint (Ollama only) ------------------------------
# Test 3: does /v1/messages work (the API Claude Code needs)? Sets R_anthropic.
# Args: <engine> <model>. SKIP rather than FAIL on llama.cpp and MLX-LM: they
# serve OpenAI-compatible APIs by design, so this is a capability note, not a
# defect. Uses a generous token budget — thinking models reason before replying.
aiModelTestAnthropic() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aiModelTestAnthropic <engine> <model>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "note    : only meaningful for Ollama; SKIPs on the others" \
            "$(_hintExamples aiModelTestAnthropic engine-model Claude)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" resp
    if [ "$engine" != "Ollama" ]; then
        info "Test 3 — Anthropic endpoint: not applicable to ${engine} (OpenAI-compatible only)"
        warn "Claude Code cannot use ${engine}; Pi and OpenCode can."
        R_anthropic=SKIP
        return 0
    fi
    info "Test 3 — Anthropic Messages endpoint (/v1/messages, used by Claude Code)"
    local apayload
    apayload=$(python3 - "$model" <<'PYEOF'
import json, sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 2000,
                  "messages": [{"role": "user", "content": "Reply with exactly: PONG"}]}))
PYEOF
)
    resp=$(curl -sf --max-time 300 "${TEST_ENDPOINT}/v1/messages" \
        -H "content-type: application/json" \
        -H "x-api-key: ollama" -H "anthropic-version: 2023-06-01" \
        -d "$apayload" 2>/dev/null)
    if [ -z "$resp" ]; then
        fail "/v1/messages did not answer — upgrade Ollama."
        R_anthropic=FAIL
        return 1
    fi
    python3 - "$resp" <<'PYEOF' && R_anthropic=PASS || R_anthropic=FAIL
import json, sys
r = json.loads(sys.argv[1])
blocks = r.get("content", [])
txt = "".join(b.get("text","") for b in blocks if b.get("type") == "text")
think = "".join(b.get("thinking","") for b in blocks if b.get("type") == "thinking")
if think:
    print(f"    (thinking model: {len(think)} chars of reasoning first)")
print(f"    Reply: {txt.strip()[:120]!r}")
assert r.get("type") == "message" and txt.strip(), "no text content"
PYEOF
    [ "$R_anthropic" = "PASS" ] && ok "Anthropic-format endpoint works." || fail "Anthropic endpoint malformed."
}

# ---------- 4. tool calling (OpenAI format — every engine) -------------------
# Test 4: can the model emit a well-formed tool call? Sets R_toolcall.
# Args: <engine> <model>. The agentic make-or-break, so it is tried twice:
# PASS first time, FLAKY only on the retry, FAIL after two misses. Uses a fixed
# weather prompt so an unrelated PROMPT cannot make a correct answer look wrong.
aiModelTestToolCall() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aiModelTestToolCall <engine> <model>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "result  : sets R_toolcall to PASS / FLAKY / FAIL" \
            "$(_hintExamples aiModelTestToolCall engine-model)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" served payload resp attempt
    served=$(aiModelTestServedId); [ -z "$served" ] && served="$model"
    info "Test 4 — tool calling: get_weather + fixed weather prompt"
    payload=$(python3 - "$served" <<PYEOF
import json, sys
print(json.dumps({
  "model": sys.argv[1], "max_tokens": 400,
  "tools": [{"type": "function", "function": {
      "name": "get_weather", "description": "Get current weather for a city",
      "parameters": {"type": "object",
                     "properties": {"city": {"type": "string"}},
                     "required": ["city"]}}}],
  "messages": [{"role": "user", "content": """${TOOL_PROMPT}"""}]}))
PYEOF
)
    R_toolcall=FAIL
    for attempt in 1 2; do
        [ "$attempt" = "2" ] && warn "No tool call on attempt 1 — retrying once (flaky vs. never)."
        resp=$(curl -sf --max-time 300 "${TEST_ENDPOINT}/v1/chat/completions" \
               -H "content-type: application/json" -H "authorization: Bearer local" \
               -d "$payload" 2>/dev/null)
        [ -z "$resp" ] && { fail "Tool-call request failed."; return 1; }
        if aiModelTestToolCallParse "$resp"; then
            [ "$attempt" = "2" ] && R_toolcall=FLAKY || R_toolcall=PASS
            break
        fi
    done
    case "$R_toolcall" in
        PASS)  ok   "Well-formed tool call — agent-capable at this basic level." ;;
        FLAKY) warn "Tool call succeeded only on retry — expect inconsistent agent behaviour." ;;
        *)     fail "No tool call in 2 attempts. It will struggle inside a coding agent." ;;
    esac
}

# Parse one chat-completions response and judge the tool call.
# Args: <response json>. Returns 0 for a get_weather call carrying the required
# argument, 1 when the model answered in prose instead (and prints what it said).
aiModelTestToolCallParse() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aiModelTestToolCallParse <response-json>" \
            "internal: judges one /v1/chat/completions reply for a tool call" 'example : aiModelTestToolCallParse "$(cat reply.json)"  # pass the JSON as one argument'
        return 2
    fi
    python3 - "$1" <<'PYEOF'
import json, sys
r = json.loads(sys.argv[1])
for c in r.get("choices", []):
    m = c.get("message", {}) or {}
    calls = m.get("tool_calls") or []
    if calls:
        f = calls[0].get("function", {}) or {}
        print(f"    Model called tool: {f.get('name')}({f.get('arguments')})")
        assert f.get("name") == "get_weather", "wrong tool"
        args = f.get("arguments") or "{}"
        if isinstance(args, str):
            args = json.loads(args)
        assert "city" in args, "missing required arg"
        print(f"    finish_reason: {c.get('finish_reason')}")
        break
else:
    txt = "".join((c.get("message", {}) or {}).get("content", "") or ""
                  for c in r.get("choices", []))
    print(f"    NO tool call — answered in prose instead: {txt.strip()[:120]!r}")
    raise SystemExit(1)
PYEOF
}

# ---------- 5. served context window -----------------------------------------
# Test 5: is the served context big enough for agentic work? Sets R_context.
# Args: <engine> <model>. Ollama reports it via /api/ps, llama.cpp via /props;
# MLX-LM cannot report it at all, so that is WARN rather than a verdict.
# Under 32k an agent's system prompt alone overflows — the classic silent fault.
aiModelTestContext() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aiModelTestContext <engine> <model>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "result  : sets R_context; MLX-LM cannot report it (WARN)" \
            "$(_hintExamples aiModelTestContext engine-model)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}" ctx=0 host
    host=$(echo "$TEST_ENDPOINT" | sed 's|http://||; s|:.*||')
    info "Test 5 — served context window (agents want >= 32k)"
    case "$engine" in
        Ollama)
            ctx=$(curl -sf --max-time 8 "http://${host}:$(engine_port Ollama)/api/ps" 2>/dev/null | python3 -c '
import json,sys
try:
    m=json.load(sys.stdin).get("models",[])
    print(m[0].get("context_length",0) if m else 0)
except Exception: print(0)' 2>/dev/null)
            ;;
        Llama.cpp)
            ctx=$(curl -sf --max-time 8 "${TEST_ENDPOINT}/props" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("default_generation_settings",{}).get("n_ctx", d.get("n_ctx",0)) or 0)
except Exception: print(0)' 2>/dev/null)
            ;;
        MLX-LM)
            warn "mlx_lm.server exposes no context endpoint — cannot verify."
            R_context=WARN
            return 0
            ;;
    esac
    [ -z "$ctx" ] && ctx=0
    if [ "$ctx" -eq 0 ]; then
        warn "Could not read the served context length."
        R_context=WARN
    elif [ "$ctx" -ge 32768 ]; then
        ok "Context window: ${ctx} tokens — enough for agentic use."
        R_context=PASS
    else
        fail "Context window is only ${ctx} tokens — a coding agent's system prompt alone overflows it."
        fail "Fix: relaunch via ./launchInference.sh and pick 32K or more."
        R_context=FAIL
    fi
}

# ---------- suite -------------------------------------------------------------
# Run tests 2-5 against one engine and model.
# Args: <engine> <model>. Split out from the wrapper so a sweep can reuse the
# suite without re-asking any of the selection questions.
aiModelTestRun() {
    if [ $# -lt 2 ]; then
        aiStackUsage "aiModelTestRun <engine> <model>" \
            "$(_hintEngine)" \
            "$(_hintModel)" \
            "runs    : tests 2-5; serve the model first (aiModelTestEnsureServing)" \
            "$(_hintExamples aiModelTestRun engine-model)"
        return 2
    fi
    local engine="${1:-}" model="${2:-}"
    aiModelTestGenerate  "$engine" "$model"
    aiModelTestAnthropic "$engine" "$model"
    aiModelTestToolCall  "$engine" "$model"
    aiModelTestContext   "$engine" "$model"
}

# ---------- wrapper -----------------------------------------------------------
# Wrapper: select engine, model and prompt, serve the model, run the suite.
# Args: [engine] [model] — either may be given to skip its menu.
# Ends with a verdict table and a plain reading of it: fix FAIL lines before
# judging the model, because most of them are configuration, not capability.
aiModelTest() {
    command -v python3 >/dev/null 2>&1 || { fail "python3 is required."; return 1; }
    local engine="${1:-}" model="${2:-}" T0 T1
    [ -z "$engine" ] && { engine=$(aiModelTestEngineSelector) || return 1; }
    [ -z "$model" ]  && { model=$(aiModelTestModelSelector "$engine") || return 1; }
    aiModelTestPromptSelector
    info "Testing ${BOLD}${model}${RESET} on ${BOLD}${engine}${RESET}"

    aiModelTestEnsureServing "$engine" "$model" || return 1
    aiModelTestServer "$engine" || return 1

    T0=$(date +%s)
    aiModelTestRun "$engine" "$model"
    T1=$(date +%s)

    echo >&2
    echo "${BOLD}================= Verdict =================${RESET}" >&2
    local k v
    for k in server generate anthropic toolcall context; do
        eval "v=\${R_$k}"
        case "$v" in
            PASS)       ok   "$k" ;;
            WARN|FLAKY) warn "$k ($v)" ;;
            SKIP)       echo "    - $k (not applicable)" >&2 ;;
            *)          fail "$k" ;;
        esac
    done
    echo "    Total test time: $((T1 - T0)) s" >&2
    echo >&2

    local fails=0 warns=0
    for v in "$R_server" "$R_generate" "$R_anthropic" "$R_toolcall" "$R_context"; do
        case "$v" in FAIL) fails=$((fails+1)) ;; WARN|FLAKY) warns=$((warns+1)) ;; esac
    done
    if [ "$fails" -gt 0 ]; then
        warn "${BOLD}Fix the FAIL lines before judging the model itself.${RESET}"
    elif [ "$warns" -gt 0 ]; then
        ok "${BOLD}No failures — the stack works.${RESET}"
    else
        ok "${BOLD}${engine} + ${model} is fit for agentic use.${RESET}"
    fi
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    aiModelTest "$@"
fi
