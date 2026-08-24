# MLX-LM model lists — planned

No catalogs yet. When MLX-LM support is added, drop `<RAM>_GB_Ram.json` files
here using the schema in [../README.md](../README.md) and run the installer
with `MODEL_LIST_ENGINE=MLX-LM`.

Engine-specific notes for whoever fills this in:

- `tag` should be the HuggingFace repo MLX loads directly, typically from the
  `mlx-community` org (e.g. `mlx-community/Qwen3.6-35B-A3B-4bit`).
- MLX quantization names differ from GGUF: `-4bit`, `-6bit`, `-8bit`,
  `-bf16` rather than `Q4_K_M`/`Q6_K`. Do not copy Ollama tags across.
- MLX is Apple-silicon only, so these lists are relevant to `MacOs/` and have
  no Debian counterpart.
- `mlx-lm` is already installed by `installOllamaMlx`; it generally reaches
  higher throughput than Ollama on this hardware, which is the motivation for
  supporting it as a second engine.
