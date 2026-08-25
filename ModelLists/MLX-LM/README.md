# MLX-LM model lists

Catalogs for the **MLX-LM** engine (`uv tool install mlx-lm`), loaded by
`aistackInstallMlxmlModels` via `MODEL_LIST_ENGINE=MLX-LM`.

Tiers provided: `24`, `32`, `48`, `64` GB. Hosts with more RAM load the 64 GB
list until verified larger entries are added. MLX is Apple-silicon only, so
these lists have no Debian counterpart.

## Tag format

```
<hf-repo>              e.g. mlx-community/Qwen3.6-35B-A3B-6bit
```

The HuggingFace repo MLX loads directly. **Quantization is part of the repo
name** — `-4bit`, `-6bit`, `-8bit` — not a separate field, and the names do not
map to GGUF quants: do not copy Ollama or llama.cpp tags across. `size_gb` is
the sum of the weight files from the HuggingFace tree API.

## Why this engine matters

MLX is Apple's own array framework and generally the fastest inference path on
this hardware. It also publishes **6-bit** builds, which (like llama.cpp's
Q6_K) sit in the quality band the Ollama registry skips.

## How downloads work

`mlxmlPullModel` calls `huggingface_hub.snapshot_download` through
`uv run --with huggingface-hub`, so no extra permanent dependency is needed.
Models land in the standard HuggingFace cache
(`${HF_HOME:-~/.cache/huggingface}/hub`) as `models--org--repo`, which the
installer reverses to detect what is already present. Downloads resume from
already-fetched shards.

Run a downloaded model with:

```bash
mlx_lm.generate --model mlx-community/<repo> --prompt "..."
```

## Editing

Follow the rules in [../README.md](../README.md): verify the repo exists, take
`size_gb` from the tree API, and respect the tier ceiling
(`size_gb * 1.3 + 2 ≤ ram_gb - 5`).
