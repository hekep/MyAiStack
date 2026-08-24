# ModelLists — model catalogs as data

Curated model lists, one JSON file per **engine** and **RAM tier**. The
installer loads the right file at runtime instead of carrying a hardcoded
array, so updating the catalog means editing data, never code.

```
ModelLists/
├── Ollama/          24, 32, 48, 64, 128, 256 _GB_Ram.json   (in use)
├── Llama.cpp/       planned
└── MLX-LM/          planned
```

## Which file gets loaded

`loadModelCatalog` (in `<OsFolder>/install.sh`) picks the file for the
**largest tier ≤ host RAM** — a 96 GB host uses `64_GB_Ram.json`, a 47 GB host
uses `32_GB_Ram.json`. A host below the smallest tier gets the smallest file.
The engine folder comes from `MODEL_LIST_ENGINE` (default `Ollama`).

## Schema

```json
{
  "engine": "Ollama",
  "ram_gb": 48,
  "updated": "2026-08-24",
  "notes": "…what this tier is and how the installer filters it further…",
  "models": [
    {"tag": "qwen3-coder:30b-a3b-q8_0", "size_gb": 30, "description": "…"}
  ]
}
```

- `tag` — the exact identifier the engine pulls (`ollama pull <tag>`).
- `size_gb` — **real download size**, read from the registry manifest (sum of
  layer sizes), not an estimate.
- `models` — curated top-20 for code generation, **biggest first** (the menu
  preserves this order). One object per line, which keeps the
  `sed`-based fallback parser working when `python3` is unavailable.

## Rules for editing

1. **Verify the tag exists before adding it.** The installer probes
   `registry.ollama.ai` and hides unknown tags, but a wrong entry is still
   noise. Get the size from the manifest at the same time:
   `curl -s https://registry.ollama.ai/v2/library/<name>/manifests/<tag>`
   and sum `.layers[].size`.
2. **Respect the tier ceiling.** An entry must satisfy
   `size_gb * 1.3 + 2 ≤ ram_gb - 5` (weights + KV cache + runtime, leaving
   memory for the OS), otherwise it can never be selected and only clutters
   the list.
3. **No `hf.co/*` entries for Ollama** — direct HuggingFace GGUF pulls fail on
   Ollama 0.32 with `context deadline exceeded` at the final commit
   (reproduced repeatedly with complete blob downloads). Retest after an
   Ollama upgrade before reintroducing them.
