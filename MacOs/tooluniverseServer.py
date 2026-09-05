#!/usr/bin/env python3
"""
tooluniverseServer.py — ToolUniverse's MCP server, with the Tool_RAG embedder on Metal.

Run with the tool's own interpreter, so the installed tooluniverse, torch and
sentence-transformers are the ones in play:

    ~/.local/share/uv/tools/tooluniverse/bin/python MacOs/tooluniverseServer.py \
        --host 127.0.0.1 --port 8765 --compact-mode

Every argument is passed through to tooluniverse.smcp_server.run_http_server,
i.e. this is `tooluniverse-smcp-server` plus one change.

Why it exists. ToolUniverse loads mims-harvard/ToolRAG-T1-GTE-Qwen2-1.5B (the
embedding model behind Tool_RAG / Tool_Finder / find_tools) with
`device = "cuda" if torch.cuda.is_available() else "cpu"` and no other branch
(tool_finder_embedding.py, load_rag_model). On Apple Silicon that means a 1.5B
encoder in fp32 on the CPU: 5.75 GiB and slow. torch has Metal (MPS) and
sentence-transformers accepts device="mps"; nothing in ToolUniverse lets you
say so. This wrapper replaces that one method and nothing else — the rest of
the path already follows the model's device (the cached tool embeddings are
loaded to `self.rag_model.device`; rag_infer moves them to the query's device).

Knobs (environment):
    TOOLUNIVERSE_DEVICE   mps | cpu     default: mps when available, else cpu
    TOOLUNIVERSE_DTYPE    float16 | bfloat16 | float32
                                        default: float16 on mps (2.9 GiB), float32 on cpu

A wrapper rather than an edit inside the venv: `uv tool upgrade tooluniverse`
recreates the venv and would silently discard an edit. If upstream ever grows a
device/dtype config key, delete this file and go back to the console script.
"""

import os
import sys


def _patch():
    import torch
    from tooluniverse import tool_finder_embedding as tfe

    mps = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())
    device = os.environ.get("TOOLUNIVERSE_DEVICE") or ("mps" if mps else "cpu")
    if device == "mps" and not mps:
        print("[MyAiStack] TOOLUNIVERSE_DEVICE=mps but Metal is not available — using cpu", file=sys.stderr)
        device = "cpu"
    dtype_name = os.environ.get("TOOLUNIVERSE_DTYPE") or ("float16" if device == "mps" else "float32")
    dtype = getattr(torch, dtype_name)

    upstream = tfe.ToolFinderEmbedding.load_rag_model

    def load_rag_model(self):
        # hosted embedding backends (OpenAI etc.) take upstream's path untouched
        if getattr(self, "use_openai_embedding", False):
            return upstream(self)
        from sentence_transformers import SentenceTransformer

        tfe.logger.info(f"[MyAiStack] loading {self.toolfinder_model} on {device} as {dtype_name}")
        self.rag_model = SentenceTransformer(
            self.toolfinder_model,
            device=device,
            trust_remote_code=self.trust_remote_code,
            model_kwargs={"torch_dtype": dtype},
        )
        # identical to upstream from here on
        self.rag_model.max_seq_length = 4096
        self.rag_model.tokenizer.padding_side = "right"
        tfe.logger.info(f"[MyAiStack] model device after loading: {self.rag_model.device}")
        # RSS does not count Metal buffers; this is the number that does.
        if device == "mps":
            try:
                cur = torch.mps.current_allocated_memory() / 2**30
                drv = torch.mps.driver_allocated_memory() / 2**30
                tfe.logger.info(f"[MyAiStack] embedder memory: Metal allocated {cur:.2f} GiB, driver {drv:.2f} GiB")
            except Exception as e:  # older torch without the counters
                tfe.logger.info(f"[MyAiStack] embedder memory: Metal counters unavailable ({e})")

    tfe.ToolFinderEmbedding.load_rag_model = load_rag_model
    return device, dtype_name


def main():
    device, dtype_name = _patch()
    print(f"[MyAiStack] Tool_RAG embedder will load on {device} as {dtype_name} "
          f"(TOOLUNIVERSE_DEVICE / TOOLUNIVERSE_DTYPE to change)", file=sys.stderr)
    from tooluniverse.smcp_server import run_http_server
    run_http_server()


if __name__ == "__main__":
    main()
