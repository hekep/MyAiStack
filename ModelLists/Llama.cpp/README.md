# Llama.cpp model lists

Catalogs for the **llama.cpp** engine (`brew install llama.cpp`), loaded by
`aistackInstallLlamacppModels` via `MODEL_LIST_ENGINE=Llama.cpp`.

Tiers provided: `24`, `32`, `48`, `64` GB. Hosts with more RAM load the 64 GB
list until verified larger entries (70B+ GGUF) are added.

## Tag format

```
<hf-repo>:<QUANT>      e.g. bartowski/Qwen_Qwen3.6-35B-A3B-GGUF:Q6_K
```

The same form llama.cpp's own `-hf` flag takes. `size_gb` is the exact GGUF
file size from the HuggingFace tree API.

## Why this engine matters

It is the **only** engine here that reaches the mid quants: the Ollama registry
carries q4_K_M and q8_0, nothing between, and direct `hf.co/*` pulls through
Ollama fail on 0.32. llama.cpp downloads plain GGUF files, so `Q5_K_M` and
`Q6_K` — the quality sweet spot on a 48 GB machine — become available.

## How downloads work

`llamacppPullModel` resolves the real filename from the repo tree first (naming
differs between uploaders: `Qwen_Qwen3.6-35B-A3B-Q6_K.gguf` vs
`Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf`), then fetches it with
`curl -L -C -` — **resumable**, unlike the Ollama HF path. Files land in
`$LLAMACPP_MODEL_DIR` (default `~/Models/llama.cpp`) named
`org__repo@QUANT.gguf`, an encoding the installer reverses to detect what is
already present.

A download in progress is called `org__repo@QUANT.gguf.part` and is renamed to
`.gguf` only when its size matches the one HuggingFace reports. So the `.gguf`
suffix means **complete**, and an interrupted pull is never mistaken for an
installed model — it stays in the download menu, and re-selecting it resumes.

Run a downloaded model with:

```bash
llama-server -m ~/Models/llama.cpp/<file>.gguf -c 32768
```

## Editing

Follow the rules in [../README.md](../README.md): verify the repo and the quant
file exist, take `size_gb` from the tree API, and respect the tier ceiling
(`size_gb * 1.3 + 2 ≤ ram_gb - 5`).
