# testAllAiModels.sh — benchmark every downloaded model, one comparison table

## What it does

Runs the aiModelTest suite over **every engine and every model that engine has
downloaded**, using one prompt for all of them, and ends with a single
comparison table.

## How it works

1. Asks for the prompt once (empty = *"What would be next best feature to
   code"*) and exports it, so the per-model tests do not ask again.
2. Enumerates engines that have models, and sweeps
   `for each engine → for each of its models`.
3. Per model: `aiModelTestEnsureServing` (starts the Ollama daemon, or
   `llama-server` / `mlx_lm.server` bound to that model) → `aiModelTestServer`
   → `aiModelTestRun`.
4. **Frees the hardware before *and* after every model** — `freeAllEngines`
   unloads all Ollama models, kills our llama-server and any mlx server, then
   **waits (up to 40 s, escalating to SIGKILL) until the processes are really
   gone**, and reports the memory recovered. This is not tidiness: two 30 GB
   models resident at once takes the whole machine down, which is exactly what
   happened before this was hardened. An interrupt (Ctrl-C) runs the same
   cleanup.
   - Teardown never trusts a recorded PID — a reused or stale server has none,
     so it kills by pattern. Our llama-server is matched **by its port**,
     because Ollama runs an internal subprocess of the same name.
   - A **fit pre-flight** (`weights + 4 GB ≤ GPU budget`) skips any single
     model too large for the machine instead of trying and crashing it.
5. Prints the table: **engine · model · tokens · time · tok/s · tools · ctx ·
   total**, with long model ids trimmed from the left so the quant stays
   visible.

Because every engine is measured through the same endpoint with the same
warmup and wall-clock timing, a row from llama.cpp is comparable with a row
from Ollama — which is the whole point of the sweep.

## Why it is necessary

Single-model tests answer "does it work"; choosing a daily driver needs
"compared to what". Running the identical suite over all models with clean
loads and one table makes the speed-vs-reliability trade-off visible in one
place — and re-running after each `ollama pull` keeps the comparison current.

## Usage

```bash
./testAllAiModels.sh
```
