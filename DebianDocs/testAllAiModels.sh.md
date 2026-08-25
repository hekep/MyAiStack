# testAllAiModels.sh — benchmark every downloaded model, one table (Debian)

## What it does

Runs the aistackModelTest suite over **every engine and every model that engine
has downloaded**, using one prompt for all of them, and ends with a single
comparison table.

## How it works

1. Asks for the prompt once (empty = *"What would be next best feature to
   code"*) and exports it, so the per-model tests do not ask again. Prints the
   host's memory/accelerator line, because every number below depends on it.
2. **Before any test runs**, checks whether a model is already loaded
   (`busyEngines`: Ollama-resident models and our llama-server — an *idle*
   Ollama daemon does not count, it holds nothing). If something is loaded it is
   listed with its memory, and you are asked **"Tear it down and run the sweep?
   [Y/n]"** — **n exits immediately**, touching nothing, because the sweep stops
   engines between models by design and cannot run alongside your session.
3. Enumerates engines that have models, and sweeps
   `for each engine → for each of its models`.
4. Per model: `aistackModelTestEnsureServing` → `aistackModelTestServer` →
   `aistackModelTestRun`.
5. **Frees the hardware before *and* after every model** — `freeAllEngines`
   unloads all Ollama models, kills our llama-server, then **waits (up to 40 s,
   escalating to SIGKILL at 20 s) until the processes are really gone**, and
   reports the memory recovered from `/proc/meminfo`. This is not tidiness: two
   30 GB models resident at once takes the whole machine down. An interrupt
   (Ctrl-C) runs the same cleanup.
   - Teardown never trusts a recorded PID — a reused or stale server has none,
     so it kills by pattern. Our llama-server is matched **by its port**.
   - A **fit pre-flight** (`weights + 4 GB ≤ memory budget`) skips any single
     model too large for the machine instead of trying and crashing it.
6. Prints the table: **engine · model · tokens · time · tok/s · tools · ctx ·
   total**, with long model ids trimmed from the left so the quant stays
   visible, followed by the host line and the llama.cpp backend in use.

Because every engine is measured through the same endpoint with the same warmup
and wall-clock timing, a row from llama.cpp is comparable with a row from
Ollama — and with a row from the same model on a Mac.

## What differs from the macOS version

- **Memory is read from `/proc/meminfo` `MemAvailable`**, the kernel's own
  estimate of what a new allocation could get, rather than summing `vm_stat`
  page classes.
- **No `mlx_lm.server` to kill**, so teardown is one pattern rather than two.
- **The skip message names the Linux lever**: `RAM_RESERVE_GB=3`, not
  `sudo sysctl iogpu.wired_limit_mb=…`.
- **The footer reports the llama.cpp backend** (`cpu`, `vulkan`, `cuda`, …).
  On Linux the same GGUF can be GPU-offloaded on one machine and CPU-bound on
  another, so a table without that line cannot be interpreted later.
- **Why the teardown matters more here.** On macOS, overcommitting unified
  memory means swapping. On Linux it means the OOM killer chooses a victim,
  and it may well choose your desktop session rather than the model. The wait
  loop is the same code; the consequence of skipping it is worse.

## Why it is necessary

Single-model tests answer "does it work"; choosing a daily driver needs
"compared to what". Running the identical suite over all models with clean
loads and one table makes the speed-vs-reliability trade-off visible in one
place — and re-running after each download keeps the comparison current.

## Usage

```bash
./testAllAiModels.sh
PROMPT="Write a bash function that..." ./testAllAiModels.sh
```
