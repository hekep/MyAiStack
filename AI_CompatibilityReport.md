# AI Compatibility Report — Mac mini (M4 Pro, 48 GB)

**Generated:** 2026-08-06
**Host:** Mac mini `Mac16,11` · serial NJ6QT034QX

---

## 1. Hardware inventory

| Component | Detail |
|---|---|
| Chip | Apple M4 Pro |
| CPU | 14 cores — 10 performance + 4 efficiency |
| GPU | 20 cores, Metal 4 |
| Neural Engine | 16-core (M4 generation) |
| Unified memory | **48 GB** (51,539,607,552 bytes) |
| Memory bandwidth | ~273 GB/s (M4 Pro spec) |
| Storage | 460 GB internal — **427 GB used, 9.6 GB free (98 % full)** |
| OS | macOS 26.5.1 (build 25F80) |
| Display | Dell U3821DW, 3840 × 1600 |

### Verdict on the silicon

This is a **strong local-inference box**. Unified memory means the GPU can address essentially all 48 GB, so it runs models that would need a dual-RTX-4090 rig on the PC side. The M4 Pro's ~273 GB/s bandwidth is the real ceiling: it caps *token generation speed*, not model size.

The practical consequence: **sparse Mixture-of-Experts (MoE) models are dramatically better value on this machine than dense models of the same footprint.** A 35B MoE with 3B active parameters reads ~10× less memory per token than a dense 32B, so it generates ~10× faster while being just as smart. Every primary recommendation below is an MoE for exactly this reason.

### ⚠️ Blocking issue: disk space

**9.6 GB free is not enough to do any of this.** A single 4-bit 35B model is ~20 GB. You need to free **60–100 GB** before pulling anything. This is the first action item, ahead of every model choice.

### Current GPU memory allocation

`iogpu.wired_limit_mb` is `0`, meaning macOS default — roughly **75 % of RAM (~36 GB)** available to the GPU. That is fine for the 35B-class recommendation. To run anything in the 40 GB+ range you must raise it:

```bash
sudo sysctl iogpu.wired_limit_mb=44000
```

(Non-persistent — resets on reboot. Leave at least ~6 GB for macOS or you will hit swap and throughput collapses.)

---

## 2. Current software state

| Tool | Status | Assessment |
|---|---|---|
| Ollama | `/usr/local/bin/ollama` — **v0.5.4** | **Severely outdated** (Dec 2024 build). Predates Qwen3 / modern MoE architecture support. Daemon is not running. |
| Installed models | `qwen2.5-coder:7b` (4.7 GB, pulled ~19 months ago) | Still a decent autocomplete model, but two generations behind for agentic work. |
| MLX / `mlx-lm` | Not installed | **This is the main gap.** MLX is Apple's native framework and is the fastest path on this hardware. |
| llama.cpp | Not installed | Optional — Ollama covers the same ground. |
| Python 3 | `/opt/homebrew/bin/python3` | Homebrew Python present, good. |
| Node | `/opt/homebrew/bin/node` | Present. |
| `uv` | Not installed | Recommended for MLX setup. |
| Xcode | Installed | Metal toolchain available. |

---

## 3. Top 3 models for agentic code generation on this machine

Ranked for **agentic** use — multi-turn tool calling, file editing, running tests, long context — not for single-shot completion.

### 🥇 1. Qwen3.6-35B-A3B — the default pick

| | |
|---|---|
| Architecture | Sparse MoE, 256 experts (8 routed + 1 shared), gated-delta-networks |
| Parameters | 35 B total / **3 B active per token** |
| Context | 256 K |
| License | Apache 2.0 |
| Released | 2026-04-16 |
| Reported benchmark | ~73 % SWE-bench Verified |
| Disk @ 4-bit | ~19–21 GB |
| Est. throughput here | **~50–80 tok/s** generation |

**Why this one.** It is the best fit for M4 Pro that exists right now. Only 3 B parameters activate per token, so the 273 GB/s bandwidth ceiling barely bites — you get 35B-class reasoning at 3B-class speed. Apache 2.0 means no license friction for commercial work. The 256 K context matters more than it sounds: an agent re-reads files, test output, and its own prior reasoning every turn, and short-context models thrash on real repos.

Comfortably inside the default ~36 GB GPU allocation, with room left over for a large KV cache.

---

### 🥈 2. Qwen3-Coder-Next (80B-A3B) — the ceiling, with caveats

| | |
|---|---|
| Architecture | Sparse MoE |
| Parameters | 80 B total / **3 B active per token** |
| Context | 256 K |
| Reported benchmarks | 70.6 % SWE-Agent · 71.1 % MiniSWE-Agent · 71.3 % OpenHands |
| Disk @ 4-bit | ~42–45 GB |
| Disk @ 3-bit | ~33–36 GB |

**Why.** This is the strongest open coding model that can physically fit in 48 GB. Also 3 B active, so generation speed stays in the same range as the 35B despite 2× the weights.

**The honest caveat.** 4-bit at ~43 GB on a 48 GB machine is genuinely tight. You would need to raise `iogpu.wired_limit_mb` to ~44000, run headless or close to it, and you would still have very little room for KV cache at long context — which defeats the purpose for agentic work. **Run this at 3-bit (~34 GB) instead**, where it fits with breathing room. If 3-bit quality degradation is noticeable on your workload, fall back to #1 — the 35B at 4-bit will likely beat the 80B at 3-bit in practice.

Treat this as a stretch pick, not the daily driver.

---

### 🥉 3. Devstral Small 24B — the reliable agentic workhorse

| | |
|---|---|
| Architecture | Dense, 24 B |
| Vendor | Mistral |
| License | Apache 2.0 |
| Disk @ 4-bit | ~14 GB |
| Est. throughput here | ~12–16 tok/s |

**Why.** Purpose-built and tuned for agentic scaffolds (OpenHands and similar) rather than chat, and it shows in tool-call reliability — it emits well-formed tool calls and recovers from errors more consistently than general models of its size. Small footprint means you can keep it resident alongside other work.

**Trade-off.** Dense architecture, so it's the slowest of the three despite being the smallest — every token reads all 14 GB. Use it when tool-calling discipline matters more than raw speed, or as a second opinion / fallback when the Qwen models get stuck.

---

### Quick comparison

| Model | Total / Active | 4-bit size | Est. speed | Fits comfortably? | Best for |
|---|---|---|---|---|---|
| Qwen3.6-35B-A3B | 35B / 3B | ~20 GB | ~50–80 tok/s | ✅ Yes | **Daily agentic driver** |
| Qwen3-Coder-Next | 80B / 3B | ~43 GB | ~40–60 tok/s | ⚠️ Use 3-bit | Hardest problems |
| Devstral Small | 24B dense | ~14 GB | ~12–16 tok/s | ✅ Yes | Tool-call reliability |

*Throughput figures are estimates derived from M4 Pro bandwidth and active-parameter count, not measured on this machine. Benchmark it yourself before trusting the numbers.*

---

## 4. Your specific questions

### "Any GWEN models?"

You mean **Qwen** (Alibaba's family) — and yes, it's the answer, not a footnote. Two of the top three above are Qwen. As of mid-2026 the Qwen3-Coder line is the strongest open-weight option for local agentic coding, and the MoE variants happen to be the single best architectural match for Apple Silicon's bandwidth constraint.

You already have `qwen2.5-coder:7b` installed. Keep it — it's still useful for fast inline autocomplete — but it is not an agentic model. It predates the tool-calling and long-context work that makes Qwen3.6 viable as an agent.

**Migration path:** upgrade Ollama → pull Qwen3.6-35B-A3B → keep the 7B for editor autocomplete.

### "Any StarCoder-style models?"

Short answer: **they exist, but don't use them for what you're asking.**

**StarCoder2** (BigCode — Hugging Face + ServiceNow) is still the current release and has **no announced successor**:

- Sizes: 3 B / 7 B / 15 B
- Released February 2024 — over two years old
- Trained on The Stack v2, 600+ languages, 4 T+ tokens for the 15B
- Grouped Query Attention, **16 K context** with 4 K sliding window
- Trained with a **Fill-in-the-Middle** objective
- License: **BigCode OpenRAIL-M** (not a standard OSI license — has use restrictions, worth reading if this is commercial)

**Why it's the wrong tool here.** StarCoder2 is a *base completion* model. It has no instruction tuning, no tool-calling, no agentic post-training, and a 16 K context window that a coding agent will blow through in two or three turns. It was built to predict the middle of a file, and it's still respectable at that.

For agentic code generation it isn't competitive with any of the three above. The lineage — StarCoder → StarCoder2 → nothing — has effectively been overtaken by the Qwen-Coder and Devstral lines, which absorbed the FIM capability while adding everything agentic work requires.

**If you specifically want FIM / inline autocomplete** (the actual StarCoder use case), your best option on this machine is the `qwen2.5-coder:7b` you already have, or its 3B sibling for lower latency. Both were trained with FIM and both outperform StarCoder2-15B at a fraction of the size. There is no reason to pull StarCoder2 in 2026.

---

## 5. Recommended setup path

### Step 0 — Free disk space (blocking)

Nothing below works until this is done. Target **60–100 GB free**.

```bash
df -h /System/Volumes/Data
```

Usual suspects on a dev machine: `~/Library/Developer/Xcode/DerivedData`, old simulator runtimes, Docker images, `node_modules` trees, `~/Library/Caches`.

### Step 1 — Upgrade Ollama

v0.5.4 is roughly 19 months stale and will not load modern MoE architectures.

> **Note:** `brew upgrade ollama` fails on this machine with `Error: ollama not installed` — the existing install is the standalone **Ollama.app**, not a Homebrew package, so brew has no record of it. The `/usr/local/bin/ollama` CLI is just a symlink created by the app.

**Recommended path: uninstall the graphical version, reinstall via Homebrew.**

#### 1a. Uninstall the graphical Ollama.app

```bash
osascript -e 'quit app "Ollama"'
rm -rf /Applications/Ollama.app
sudo rm -f /usr/local/bin/ollama
rm -rf ~/Library/Application\ Support/Ollama ~/Library/Caches/com.electron.ollama ~/Library/Preferences/com.electron.ollama.plist ~/Library/Saved\ Application\ State/com.electron.ollama.savedState
```

**Do NOT delete `~/.ollama`** — that's where your models (and keys) live. It's shared by both install methods, so `qwen2.5-coder:7b` survives the switch.

#### 1b. Install via Homebrew

```bash
brew install ollama
```

Then either run the server on demand with `ollama serve`, or register it as a background service that starts on login:

```bash
brew services start ollama
```

#### 1c. Verify

```bash
ollama --version && ollama list
```

Expect a 0.12.x-or-newer version and your existing `qwen2.5-coder:7b` still listed.

#### Why Homebrew over the .app

| | Homebrew formula | Standalone .app |
|---|---|---|
| Updates | `brew upgrade` — same command as everything else, scriptable, no GUI interaction | Built-in updater; requires the app running and manual clicks, easy to ignore (this machine sat 19 months behind) |
| Footprint | CLI + server binary only | Electron GUI wrapper + menu-bar item consuming RAM for a tool you drive from the terminal anyway |
| Service management | `brew services start/stop ollama` — standard launchd control | App decides when the daemon runs; less transparent |
| Uninstall | `brew uninstall ollama` — clean, tracked | Manual file hunt (see 1a) |
| Version pinning / rollback | Possible via brew | Not really |

For a dev machine where Ollama is used headless by agents and editors, the GUI adds nothing — the formula is the better fit. (If you prefer keeping the GUI, `brew install --cask ollama-app` gives you the app under brew management, which at least fixes the update problem.)

### Step 2 — Install MLX (recommended)

MLX is Apple's own array framework and generally gives the best throughput on Apple Silicon, particularly for MoE models. Worth having alongside Ollama.

```bash
brew install uv && uv tool install mlx-lm
```

### Step 3 — Pull the primary model

```bash
ollama pull qwen3.6:35b-a3b-q4_K_M
```

Exact tag naming varies — run `ollama list` against the registry after upgrading to confirm the current tag before pulling ~20 GB.

### Step 4 — Verify it actually performs

```bash
ollama run qwen3.6:35b-a3b-q4_K_M --verbose "Write a Python function that merges two sorted lists."
```

`--verbose` prints eval rate. If you are not seeing tens of tokens/sec, check Activity Monitor for swap pressure — that means the model plus KV cache exceeded the GPU allocation.

### Step 5 — Only if you need more capability

Raise the GPU wired limit and try Qwen3-Coder-Next at 3-bit:

```bash
sudo sysctl iogpu.wired_limit_mb=44000
```

---

## 6. Summary

| Question | Answer |
|---|---|
| Is this Mac capable? | **Yes** — 48 GB unified memory puts it in the top tier of consumer local-inference hardware. |
| Biggest blocker | **Disk space.** 9.6 GB free. Free 60–100 GB first. |
| Second blocker | Ollama v0.5.4 is ~19 months old and cannot load the recommended models. It's the standalone .app, not brew-managed — see Step 1 for the uninstall/reinstall path. |
| Best single model | **Qwen3.6-35B-A3B** — Apache 2.0, 256 K context, ~20 GB, fast on this chip. |
| Qwen models? | Yes — Qwen is the leading family for this use case, and MoE variants suit Apple Silicon particularly well. |
| StarCoder models? | StarCoder2 exists (3B/7B/15B) but is from Feb 2024, capped at 16 K context, and has no agentic tuning. Not recommended. Use `qwen2.5-coder:7b` for FIM instead. |
| Biggest upgrade lever | Install **MLX** — native Apple Silicon inference, meaningfully faster than the Ollama default path. |

---

## Sources

- [Qwen3.6-35B-A3B: Agentic Coding Power, Now Open to All — qwen.ai](https://qwen.ai/blog?id=qwen3.6-35b-a3b)
- [Qwen/Qwen3.6-35B-A3B — 35B / 3B active · MoE · 256K ctx — vLLM Recipes](https://recipes.vllm.ai/Qwen/Qwen3.6-35B-A3B)
- [Qwen3-Coder-Next Technical Report (arXiv, 2026-03-03)](https://arxiv.org/pdf/2603.00729)
- [Qwen3.6-35B-A3B: 73.4% SWE-Bench, Runs Locally — BuildFastWithAI](https://www.buildfastwithai.com/blogs/qwen3-6-35b-a3b-review)
- [Best Local LLM for Coding in 2026: Picks by VRAM & RAM — WhatLLM.org](https://whatllm.org/best-local-llm-for-coding)
- [Best Local Coding LLMs 2026: Kimi K2.6, Qwen, Devstral — PromptQuorum](https://www.promptquorum.com/local-llms/best-local-llms-for-coding)
- [Best Ollama Models for Apple Silicon 2026: 16GB–128GB — PromptQuorum](https://www.promptquorum.com/local-llms/best-models-apple-silicon-2026)
- [StarCoder2 and The Stack v2 — Hugging Face Blog](https://huggingface.co/blog/starcoder2)
- [StarCoder2 — Local Setup, VRAM, and Use Cases (2026) — local-llm.net](https://www.local-llm.net/models/starcoder2/)
- [Best Local LLM for Coding in 2026 — Tembo.io](https://www.tembo.io/blog/best-local-llm-for-coding)
