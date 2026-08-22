# testAllAiModels.sh — benchmark every downloaded model, one comparison table

## What it does

Runs the full aiModelTest suite against **every** downloaded Ollama model and
ends with a side-by-side comparison table. One question up front — the test
prompt (empty input defaults to *"What would be next best feature to code"*) —
then it works through the models unattended.

## How it works

1. Sources [aiModelTest.sh](aiModelTest.sh.md) and reuses its functions —
   nothing is duplicated: `aiModelTestServer` (once), then per model
   `aiModelTestReset` → `aiModelTestRun` (generation benchmark, Anthropic
   endpoint, tool-call test with retry, context check).
2. After each model it calls `ollama stop` so the next model loads into clean
   memory and total times stay comparable.
3. Metrics come from the suite's exported variables (`G_TOKENS`, `G_TIME`,
   `G_TPS`, `R_toolcall`) — Ollama's own token counters, not estimates.

Final table columns: **model | tokens | time | tok/s | tool call | total time**
— generation-only numbers for the middle columns; total time is the whole
per-model suite including model load. Tool call is PASS / FLAKY (succeeded
only on retry) / FAIL (refused in 2 attempts).

## Measured result on this machine (M4 Pro 48 GB)

| model | tokens | time | tok/s | tool call | total |
|---|---|---|---|---|---|
| devstral:24b | 149 | 9.0 s | 16.5 | **PASS** | 29 s |
| qwen3.6:35b-a3b | 750 | 14.8 s | 50.7 | **FLAKY** | 39 s |
| qwen2.5-coder:7b | 392 | 8.0 s | 49.2 | **FAIL** | 14 s |

The three verdicts confirm the compatibility report's characterizations:
devstral is the reliable tool-caller (its specialty), qwen3.6 is 3× faster but
inconsistent about tool use (the observed "mixed answers" in Claude Code),
and qwen2.5-coder:7b writes JSON *prose* instead of real tool calls — it
predates agentic training and belongs in autocomplete duty only.

## Why it is necessary

Single-model tests answer "does it work"; choosing a daily driver needs
"compared to what". Running the identical suite over all models with clean
loads and one table makes the speed-vs-reliability trade-off visible in one
place — and re-running after each `ollama pull` keeps the comparison current.

## Usage

```bash
./testAllAiModels.sh
```
