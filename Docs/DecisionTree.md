# Decision tree — every choice the stack offers

What you actually pick when you install and run MyAiStack, and what each pick
determines. Platform-neutral: entries marked *macOS only* or *Debian only* are
absent on the other platform, never stubbed.

The contract behind this is [SPECIFICATION.md](SPECIFICATION.md); the per-platform
differences are in [PlatformNotes.md](PlatformNotes.md).

---

## The tree

```
MyAiStack
│
├── Platform                    chosen for you (common.sh → detectOsFolder)
│   ├── Darwin ................. MacOs/
│   ├── Debian / Ubuntu ........ Debian/
│   └── anything else .......... refused with a clear message, never half-run
│
├── Foundations                 prerequisites, installed before anything else
│   ├── macOS .................. Homebrew, uv
│   └── Debian ................. base apt tools, uv, Node
│
├── Engines                     serve tokens over HTTP
│   │                           ── at least one, or the wizard stops ──
│   │
│   ├── llama.cpp .............. both platforms   ·  default YES
│   │   ├── catalog ... ModelLists/Llama.cpp/<RAM>_GB_Ram.json
│   │   ├── model ID .. hf-repo:QUANT
│   │   ├── port ...... 8080
│   │   ├── quants .... Q4 / Q5 / Q6 / Q8 — the full ladder
│   │   └── store ..... ~/Models/llama.cpp        (LLAMACPP_MODEL_DIR)
│   │
│   ├── MLX-LM ................. macOS only (Apple Silicon)  ·  default no
│   │   ├── catalog ... ModelLists/MLX-LM/<RAM>_GB_Ram.json
│   │   ├── model ID .. HuggingFace repo, quant in the name
│   │   ├── port ...... 8081
│   │   ├── quants .... 4bit / 6bit / 8bit
│   │   └── store ..... HuggingFace cache
│   │
│   └── Ollama ................. both platforms   ·  default no
│       ├── catalog ... ModelLists/Ollama/<RAM>_GB_Ram.json
│       ├── model ID .. registry tag
│       ├── port ...... 11434
│       ├── quants .... q4_K_M, q8_0 only
│       └── store ..... ~/.ollama                 (OLLAMA_MODELS on Debian)
│
├── Coding Agents               what you type into
│   ├── Pi ............ OpenAI-compatible ..... any engine    ·  default YES
│   ├── OpenCode ...... OpenAI-compatible ..... any engine    ·  default no
│   └── Claude Code ... Anthropic Messages .... Ollama ONLY   ·  default no
│
├── Tools                       MCP servers the model calls; optional
│   └── ToolUniverse .. biomedical tools, Tool_RAG, Finish  ·  default no
│       ├── port ...... 8765                       (TOOLUNIVERSE_PORT)
│       ├── flags ..... --compact-mode             (TOOLUNIVERSE_ARGS)
│       └── reached .. via MCP connector 'tooluniverse' → generated Pi plugin
│
├── Models                      weights on disk, one menu per installed engine
│   └── (see each engine's catalog above — models are never engine-portable)
│
└── Monitoring                  optional; nothing else depends on it
    ├── macOS .................. macmon, Anubis OSS, LiteLLM
    └── Debian ................. nvtop, btop, LiteLLM
```

---

## Why the tree has this shape

The branches are **independent layers**, not a dependency chain. Any engine can
be installed without an agent; any agent without models; monitoring without
either. That is why this is a tree of choices rather than a sequence of steps —
you can descend any branch and ignore the rest.

The `Models` branch is drawn last but hangs off `Engines`, because a model only
means something relative to the engine that serves it. There is no such thing as
installing "a model" in this stack — you install *a model for an engine*.

---

## The two places the tree is not free

Everything above is optional except at two gates.

**Install gate — no engine, no stack.** After the engine questions, if nothing
was installed, the wizard cancels the rest of itself. Agents, models and
monitoring would all be meaningless without something to serve tokens.

**Uninstall gate — models pin everything below them.** While any model remains
on disk, nothing beneath it is removed and the uninstaller stops. Removing an
engine while its models sit there would strand tens of gigabytes that nothing
can read. The gate is enforced twice: by the wrapper, and independently by the
engine's own uninstall function, so it holds even when that function is called
directly.

---

## What choosing an engine determines

This is the load-bearing decision, because it fixes four things at once:

| | llama.cpp | MLX-LM | Ollama |
|---|---|---|---|
| **Catalog read** | `ModelLists/Llama.cpp/` | `ModelLists/MLX-LM/` | `ModelLists/Ollama/` |
| **Model ID format** | `hf-repo:QUANT` | HF repo, quant in name | registry tag |
| **Quants reachable** | Q4 / Q5 / Q6 / Q8 | 4bit / 6bit / 8bit | q4_K_M, q8_0 only |
| **Downloads to** | `~/Models/llama.cpp` | HuggingFace cache | `~/.ollama` |
| **Serves on** | :8080 | :8081 | :11434 |

Two consequences worth stating plainly:

1. **Model IDs are not interchangeable.** `devstral:24b`,
   `bartowski/mistralai_Devstral-Small-2507-GGUF:Q4_K_M` and
   `mlx-community/Devstral-Small-2507-4bit` are the same underlying model in
   three formats. Pasting one into the wrong engine fails.
2. **Ollama cannot reach the middle of the quant ladder.** Its registry carries
   only `q4_K_M` and `q8_0`, and its direct HuggingFace pulls fail. So llama.cpp
   and MLX-LM are the *only* routes to Q5_K_M / Q6_K / 6bit — and on Debian,
   where MLX cannot run, llama.cpp is the only one. This is why llama.cpp is the
   default engine on both platforms.

---

## What choosing an agent determines

Only one asymmetry exists, and it is enforced rather than assumed:

- **Pi** and **OpenCode** speak the OpenAI-compatible API, which all three
  engines serve. Either works with anything.
- **Claude Code** speaks the Anthropic Messages API, which only Ollama serves.

An impossible pairing is never offered as a menu option — but it is *named with
the reason* rather than silently hidden, so the absence is explainable.

---

## Which model the menu offers you

The catalog is data, not code: curated top-20 per RAM tier, biggest first, with
`size_gb` read from the real upstream manifest rather than estimated.

Selection narrows in this order:

```
largest tier ≤ host RAM
      → fits the CURRENT GPU/memory budget   (size × 1.3 + 2)
      → fits free disk
      → not already installed
      → exists upstream                      (probed, cached 24 h)
```

The budget is live, not fixed — on macOS it is read from
`iogpu.wired_limit_mb`, so raising that sysctl widens the menu on the next run;
on Debian it is total RAM minus `RAM_RESERVE_GB`, so lowering the reserve does
the same. Editing a catalog is editing data; see
[ModelLists/README.md](../ModelLists/README.md).
