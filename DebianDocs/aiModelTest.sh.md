# aiModelTest.sh — layered stack verification with tokens/second (Debian)

## What it does

Answers "does the local AI stack actually work, and where exactly is it
broken?" by testing each layer independently instead of judging the whole
chain from inside a coding agent. Reports precise timing and **tokens/second**
using the engine's own token counters (not estimates). The test prompt lives in
a freely modifiable `PROMPT` variable.

## How it works

Three questions first — **engine**, then **model**, then **prompt** — and then
five independent layer tests. Measurement is deliberately identical on every
engine (same OpenAI `/v1/chat/completions` endpoint, a warmup request first so
model-load time is not counted, then wall-clock timing).

Because none of that measurement is platform-specific, **a row from this script
on Debian is directly comparable with a row from the macOS script** for the
same model — which is the point of keeping the two implementations in step.

| Function | Layer tested | Pass means |
|---|---|---|
| `aistackModelTestEngineSelector` | — | Numeric menu of engines that actually **have downloaded models**; announced without a question when only one qualifies |
| `aistackModelTestModelSelector` | — | That engine's downloaded models (shares `aistackLaunchInferenceModelSelector`) |
| `aistackModelTestPromptSelector` | — | Asks what to send, defaulting to the weather prompt. Skipped when `PROMPT` is already set (e.g. by the sweep script) |
| `aistackModelTestEnsureServing` | — | Starts or re-points the engine at the chosen model: the Ollama daemon, or `llama-server -m <gguf>` with the right backend argument. A server already serving a *different* model is restarted |
| `aistackModelTestServer` | endpoint reachable | the engine answers |
| `aistackModelTestGenerate` | generation | prints answer, input/output tokens, seconds and **tokens/second** |
| `aistackModelTestAnthropic` | `/v1/messages` | Ollama only — **SKIP** (not FAIL) on llama.cpp, with a note that Claude Code cannot use it but Pi and OpenCode can |
| `aistackModelTestToolCall` | agentic fitness | OpenAI `tools` format on every engine; two attempts, so PASS / **FLAKY** (retry only) / FAIL |
| `aistackModelTestContext` | served context ≥ 32k | Ollama via `/api/ps`, llama.cpp via `/props` |
| `aistackModelTestRun` | tests 2–5 for one engine+model | reusable by the sweep |
| `aistackModelTest` | wrapper + verdict table | Prints the host's memory/accelerator line before testing, so a number always carries its context |

## What differs from the macOS version

Very little, and deliberately so — the whole value of this script is that its
numbers are comparable.

- **No MLX-LM branch.** The context test's third case becomes a generic "this
  engine exposes no context endpoint → WARN" rather than an MLX-specific one,
  and `aistackModelTestEnsureServing` routes an unknown engine through
  `_requireEngine`, which explains MLX-LM properly instead of failing silently.
- **`llama-server` is started with a backend-dependent argument** (`-ngl 999`
  on a GPU build, `-t $(nproc)` on CPU), and the backend is named in the
  "Starting llama-server…" line. On macOS Metal needs neither.
- **The Ollama daemon is started with `OLLAMA_MODELS`** set explicitly, so a
  test never reads a different model store from the one the launcher uses.
- **The verdict header prints the host budget line** — on Linux the same model
  can be GPU-offloaded on one box and CPU-bound on another, so a tok/s figure
  without that context is misleading.
- Both server logs go to `${TMPDIR:-/tmp}` and are named in every failure
  message.

## Reading the verdict

The five tests separate five failure modes that judging a coding agent
end-to-end would conflate: dead server, broken endpoint, too-small context,
missing tool-call ability, and genuine model weakness. The first four are
fixable configuration; only the last is inherent.

- Any **FAIL** → fix that line before forming an opinion of the model.
- **FLAKY** tool calling → the model will behave inconsistently inside an agent.
- **ctx FAIL** → relaunch through `./launchInference.sh` and pick 32K or more.
- All **PASS** but the agent still underwhelms → the limitation is the model,
  not the stack.

On a CPU-only Linux box, expect the generation line to be the one that
disappoints: a 30B-class model at CPU speed is single-digit tokens/second even
when every other test passes. That is a hardware fact, and the sanity step in
`install.sh` warns about it before any of this is downloaded.

## Calling a step directly

Every step is individually callable (see
[installAliases.sh.md](../Docs/installAliases.sh.md)). A step invoked without
its arguments prints usage rather than a bash error, and the hints are resolved
live:

```
$ aistackModelTestContext
 ✗  usage: aistackModelTestContext <engine> <model>
         engine  : Llama.cpp Ollama
         model   : one of that engine's models — list: engineListInstalled <engine>
         result  : sets R_context to PASS / WARN / FAIL
         example : aistackModelTestContext Llama.cpp bartowski/Qwen_Qwen3.6-35B-A3B-GGUF:Q6_K
```

Return code is 2 for a usage error, distinct from a step that ran and failed.

## Usage

```bash
./aiModelTest.sh                                   # engine, model, prompt menus
./aiModelTest.sh Ollama qwen3.6:35b-a3b            # explicit engine + model
PROMPT="Explain ext4 journalling" ./aiModelTest.sh # prompt preset, not asked
```

The script sources [launchInference.sh](launchInference.sh.md) and reuses its
`aistackLaunchInferenceModelSelector` — the same numbered menu of installed
models — so the two tools share one selector implementation instead of
duplicating it.
