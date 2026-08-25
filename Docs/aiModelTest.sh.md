# aiModelTest.sh — layered stack verification with tokens/second

## What it does

Answers "does the local AI stack actually work, and where exactly is it
broken?" by testing each layer independently instead of judging the whole
chain from inside Claude Code. Reports precise timing and **tokens/second**
using Ollama's own token counters (not estimates). The test prompt lives in a
freely modifiable `PROMPT` variable.

## How it works

Three questions first — **engine**, then **model**, then **prompt** — and then
five independent layer tests. Measurement is deliberately identical on every
engine (same OpenAI `/v1/chat/completions` endpoint, a warmup request first so
model-load time is not counted, then wall-clock timing), so numbers from
different engines are directly comparable.

| Function | Layer tested | Pass means |
|---|---|---|
| `aistackModelTestEngineSelector` | — | Numeric menu of engines that actually **have downloaded models**; announced without a question when only one qualifies |
| `aistackModelTestModelSelector` | — | That engine's downloaded models (shares `aistackLaunchInferenceModelSelector`) |
| `aistackModelTestPromptSelector` | — | Asks what to send, defaulting to the weather prompt. Skipped when `PROMPT` is already set (e.g. by the sweep script) |
| `aistackModelTestEnsureServing` | — | Starts or re-points the engine at the chosen model: Ollama daemon, or `llama-server -m <gguf>`, or `mlx_lm.server --model <repo>`. A server already serving a *different* model is restarted |
| `aistackModelTestServer` | endpoint reachable | the engine answers |
| `aistackModelTestGenerate` | generation | prints answer, input/output tokens, seconds and **tokens/second** |
| `aistackModelTestAnthropic` | `/v1/messages` | Ollama only — **SKIP** (not FAIL) on llama.cpp and MLX-LM, with a note that Claude Code cannot use them but Pi and OpenCode can |
| `aistackModelTestToolCall` | agentic fitness | OpenAI `tools` format on every engine; two attempts, so PASS / **FLAKY** (retry only) / FAIL |
| `aistackModelTestContext` | served context ≥ 32k | Ollama via `/api/ps`, llama.cpp via `/props`; MLX-LM cannot report it (**WARN**) |
| `aistackModelTestRun` | tests 2–5 for one engine+model | reusable by the sweep |
| `aistackModelTest` | wrapper + verdict table | — |

## Measured baseline on this machine (M4 Pro 48 GB, qwen3.6:35b-a3b)

- Generation: **51 tok/s** (matching the compatibility report's 50–80 prediction)
- Prompt processing: ~156 tok/s
- Tool call: correct (`get_weather({"city": "Turku, Finland"})`)
- Context: 32,768 tokens


## Calling a step directly

Every step is individually callable (see [installAliases.sh.md](installAliases.sh.md)). A step invoked without its
arguments prints usage rather than a bash error, and the hints are resolved
live — the engine line names what this machine actually has:

```
$ aistackLaunchInferencePrerequisites
 ✗  usage: aistackLaunchInferencePrerequisites <engine> <model> <context-tokens>
         engine  : Llama.cpp Ollama
         model   : one of that engine's models — list: engineListInstalled <engine>
         context : tokens, e.g. 32768 / 65536 / 131072
         example : aistackLaunchInferencePrerequisites Ollama qwen3.6:35b-a3b 32768
```

Return code is 2 for a usage error, distinct from a step that ran and failed.

## Why it is necessary

Judging a local model by running Claude Code end-to-end conflates five
failure modes: dead server, broken endpoint, too-small context, missing
tool-call ability, and genuine model weakness. The first four are fixable
configuration issues; only the last is inherent. This script separates them —
when the verdict table is all-PASS but Claude Code still underwhelms, the
limitation is the model itself, not the stack.

## Usage

```bash
./aiModelTest.sh                                   # engine, model, prompt menus
./aiModelTest.sh Ollama qwen3.6:35b-a3b            # explicit engine + model
PROMPT="Explain APFS snapshots" ./aiModelTest.sh   # prompt preset, not asked
```

With no argument, the script sources [launchInference.sh](launchInference.sh.md)
and reuses its `aistackLaunchInferenceModelSelector` — the same numbered menu of
installed models (name + size, pick by number) — so the two tools share one
selector implementation instead of duplicating it. If the launcher script is
missing, it falls back to testing the first downloaded model.
