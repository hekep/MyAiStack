# Llama.cpp model lists — planned

No catalogs yet. When llama.cpp support is added, drop
`<RAM>_GB_Ram.json` files here using the schema in [../README.md](../README.md)
and run the installer with `MODEL_LIST_ENGINE=Llama.cpp`.

Engine-specific notes for whoever fills this in:

- `tag` should be whatever llama.cpp is driven with — most naturally a
  HuggingFace GGUF reference (`repo:quant`, e.g.
  `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF:Q6_K`) or a local `.gguf` path.
- This engine is the reason to have the folder at all: llama.cpp reaches the
  quantizations Ollama's registry does not carry (Q5_K_M, Q6_K, IQ variants),
  which is exactly what blocked us on the Ollama side.
- `size_gb` must still be the real file size, and the tier ceiling rule
  (`size_gb * 1.3 + 2 ≤ ram_gb - 5`) still applies.
