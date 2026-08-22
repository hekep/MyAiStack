# aiModelTest.sh — layered stack verification with tokens/second

## What it does

Answers "does the local AI stack actually work, and where exactly is it
broken?" by testing each layer independently instead of judging the whole
chain from inside Claude Code. Reports precise timing and **tokens/second**
using Ollama's own token counters (not estimates). The test prompt lives in a
freely modifiable `PROMPT` variable.

## How it works — six functions

| Function | Layer tested | Pass means |
|---|---|---|
| `aiModelTestServer` | Ollama server reachable (`/api/version`) | daemon is up |
| `aiModelTestGenerate` | Raw generation: sends `$PROMPT`, times it, reads `eval_count`/`eval_duration` | model loads and generates; prints input tok/s, output tokens, and **generation speed in tok/s** |
| `aiModelTestAnthropic` | `/v1/messages` — the Anthropic-format endpoint Claude CLI uses | endpoint answers with well-formed message content. Thinking models (qwen3.x, deepseek-r1) get a generous `max_tokens` — they spend budget on reasoning first, and a small cap yields an empty reply (a real bug this test caught). |
| `aiModelTestToolCall` | Agentic fitness: offers a `get_weather` tool with a **fixed weather prompt** (`TOOL_PROMPT`, independent of `$PROMPT` so an unrelated user prompt can't fake a failure). **Two attempts**: pass on the retry → **FLAKY**, no tool call twice → FAIL. | model emits a well-formed `tool_use` block with the required argument — the operation Claude Code performs constantly |
| `aiModelTestContext` | Context window of the loaded model (`/api/ps`) | ≥ 32k tokens. Ollama's 4k default silently truncates Claude Code's system prompt — the cause of confused/mixed answers. |
| `aiModelTest` | Wrapper: runs all, prints a PASS/FLAKY/FAIL verdict table + total time | — |

Reusable building blocks for wrapper scripts (used by
[testAllAiModels.sh](testAllAiModels.sh.md)): `aiModelTestReset` clears
per-model state, `aiModelTestRun` runs tests 2–5 against `$MODEL`, and the
generation metrics are exported as `G_TOKENS` / `G_TIME` / `G_TPS` alongside
the `R_*` verdicts.

## Measured baseline on this machine (M4 Pro 48 GB, qwen3.6:35b-a3b)

- Generation: **51 tok/s** (matching the compatibility report's 50–80 prediction)
- Prompt processing: ~156 tok/s
- Tool call: correct (`get_weather({"city": "Turku, Finland"})`)
- Context: 32,768 tokens

## Why it is necessary

Judging a local model by running Claude Code end-to-end conflates five
failure modes: dead server, broken endpoint, too-small context, missing
tool-call ability, and genuine model weakness. The first four are fixable
configuration issues; only the last is inherent. This script separates them —
when the verdict table is all-PASS but Claude Code still underwhelms, the
limitation is the model itself, not the stack.

## Usage

```bash
./aiModelTest.sh                      # numbered menu of installed models
./aiModelTest.sh qwen3.6:35b-a3b      # specific model, no menu
PROMPT="Explain APFS snapshots" ./aiModelTest.sh   # custom prompt
```

With no argument, the script sources [aiModelLauncher.sh](aiModelLauncher.sh.md)
and reuses its `launchOllamaModelSelector` — the same numbered menu of
installed models (name + size, pick by number) — so the two tools share one
selector implementation instead of duplicating it. If the launcher script is
missing, it falls back to testing the first downloaded model.
