#!/bin/bash
#
# convert.sh — turn a model that ships only as transformers weights into
# something this stack can serve.
#
# The catalogues can only list models somebody else has already quantised,
# which excludes every new or obscure one — and that is where the interesting
# medical work is. This closes that gap for the cheap case: an MLX conversion,
# one command, no build tree.
#
# Converted models land in ~/Models/mlx/<org>__<repo>@<bits>bit, mirroring the
# llama.cpp convention where the FILENAME is the interface: anything in that
# directory is offered by the launcher without a catalogue entry.

MLX_CONVERT_DIR="${MLX_CONVERT_DIR:-$HOME/Models/mlx}"

BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)
info() { [ -n "${AI_STACK_QUIET:-}" ] || echo "${BLUE}==>${RESET} $*" >&2; }
ok()   { [ -n "${AI_STACK_QUIET:-}" ] || echo "${GREEN} ✓ ${RESET} $*" >&2; }
warn() { echo "${YELLOW} ! ${RESET} $*" >&2; }
fail() { echo "${RED} ✗ ${RESET} $*" >&2; }

if ! command -v aiStackUsage >/dev/null 2>&1; then
aiStackUsage() {
    local sig="$1"; shift
    fail "usage: ${sig}"
    local l; for l in "$@"; do echo "         ${l}" >&2; done
    return 2
}
fi
if ! command -v ask_def >/dev/null 2>&1; then
ask_def() {
    local answer hint
    [ "$2" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    printf "\n%s%s%s %s " "${BOLD}" "$1" "${RESET}" "$hint" >&2
    { read -r answer </dev/tty; } 2>/dev/null || { answer=""; echo >&2; }
    case "${answer:-$2}" in [Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}
fi

# Local directory a converted model lands in. Args: <hf-repo> <bits>.
# Same encoding as the llama.cpp filenames, so the two conventions read alike.
_aiStackConvertPath() { echo "${MLX_CONVERT_DIR}/$(printf '%s' "$1" | sed 's|/|__|g')@$2bit"; }

# Report what a HuggingFace repo is and which conversion routes it supports.
# Args: <hf-repo>. Reads config.json and the file tree — a few kilobytes, no
# download. Says what each route would cost before anything is fetched.
aistackConvertProbe() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackConvertProbe <hf-repo>" \
            "repo    : a transformers repo, e.g. one with no GGUF or MLX build" \
            "prints  : architecture, size, and which conversion routes apply" \
            "example : aistackConvertProbe mims-harvard/ATHENA-R1-Qwen3-8B"
        return 2
    fi
    info "aistackConvertProbe — ${1}"
    python3 - "$1" <<'PYEOF'
import json, sys, urllib.request
repo = sys.argv[1]
def api(path):
    try:
        return json.load(urllib.request.urlopen(urllib.request.Request(
            f"https://huggingface.co/api/models/{repo}{path}",
            headers={"User-Agent": "MyAiStack"}), timeout=25))
    except Exception:
        return None
def raw(name):
    try:
        return urllib.request.urlopen(urllib.request.Request(
            f"https://huggingface.co/{repo}/raw/main/{name}",
            headers={"User-Agent": "MyAiStack"}), timeout=25).read().decode()
    except Exception:
        return None

meta = api("")
if meta is None:
    sys.exit("repo not found, or it is gated and needs a login")
tree = api("/tree/main?recursive=1") or []

def total(exts):
    return sum((e.get("lfs") or {}).get("size") or e.get("size") or 0
               for e in tree if e.get("path", "").endswith(exts))
GiB = 1073741824
weights = total((".safetensors", ".bin"))
gguf    = total((".gguf",))

cfg = raw("config.json")
arch, ctx, dtype = "?", 0, "?"
if cfg:
    try:
        c = json.loads(cfg)
        arch = (c.get("architectures") or ["?"])[0]
        ctx = c.get("max_position_embeddings") or 0
        dtype = c.get("torch_dtype") or c.get("dtype") or "?"
    except Exception:
        pass

tmpl = raw("chat_template.jinja") or ""
if not tmpl:
    tc = raw("tokenizer_config.json")
    if tc:
        try:
            t = json.loads(tc).get("chat_template") or ""
            tmpl = t if isinstance(t, str) else json.dumps(t)
        except Exception:
            pass
tools = "tools" in tmpl and "tool_call" in tmpl

print(f"    architecture : {arch}")
print(f"    dtype        : {dtype}")
print(f"    trained ctx  : {ctx or 'unknown'}")
print(f"    weights      : {weights/GiB:.1f} GiB across "
      f"{sum(1 for e in tree if e.get('path','').endswith(('.safetensors','.bin')))} file(s)")
print(f"    tool calling : {'yes' if tools else 'NO — template has no tools branch'}")
print(f"    GGUF present : {'yes (%.1f GiB) — no conversion needed' % (gguf/GiB) if gguf else 'no'}")
print()

MLX_OK = {"Qwen2ForCausalLM","Qwen3ForCausalLM","Qwen3MoeForCausalLM","LlamaForCausalLM",
          "MistralForCausalLM","Gemma2ForCausalLM","Gemma3ForCausalLM","Phi3ForCausalLM",
          "MixtralForCausalLM","GemmaForCausalLM"}
if gguf:
    print("    ROUTE 0  already GGUF — add it to a catalogue instead of converting")
if arch in MLX_OK:
    for bits, ratio in ((8, 0.53), (4, 0.28)):
        est = weights * ratio / GiB
        print(f"    ROUTE MLX  {bits}-bit -> ~{est:.1f} GiB   "
              f"aistackConvertMlx {repo} {bits}")
else:
    print(f"    ROUTE MLX  unknown architecture '{arch}' — mlx_lm may still handle it, "
          "but it is not on the tested list")
print(f"    ROUTE GGUF llama.cpp convert_hf_to_gguf.py — needs the llama.cpp source tree,")
print(f"               which this toolkit does not install. Portable to Debian.")
PYEOF
}

# Convert a transformers repo to a quantised MLX model. Args: <hf-repo> [bits].
# Downloads the weights once, quantises, and writes into ~/Models/mlx so the
# launcher finds it. 8 bits by default: on a small model it is effectively
# lossless, and quantisation degrades structured output — tool calls — before it
# degrades prose.
aistackConvertMlx() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackConvertMlx <hf-repo> [bits]" \
            "bits    : 8 (default) or 4" \
            "writes  : ${MLX_CONVERT_DIR}/<org>__<repo>@<bits>bit" \
            "example : aistackConvertMlx mims-harvard/ATHENA-R1-Qwen3-8B 8"
        return 2
    fi
    local repo="$1" bits="${2:-8}" out
    case "$bits" in 4|8) ;; *) fail "bits must be 4 or 8 — got '${bits}'."; return 1 ;; esac
    command -v mlx_lm.convert >/dev/null 2>&1 || {
        fail "mlx_lm.convert is not on PATH — install the MLX engine first:"
        echo "         aistackInstallMlxmlEngine" >&2
        return 1
    }
    out=$(_aiStackConvertPath "$repo" "$bits")
    if [ -d "$out" ]; then
        ok "Already converted: ${out}"
        return 0
    fi
    info "Converting ${repo} to ${bits}-bit MLX"
    echo "    -> ${out}" >&2
    warn "This downloads the full weights once and is GPU-bound; expect several minutes."
    mkdir -p "$MLX_CONVERT_DIR"
    if ! mlx_lm.convert --hf-path "$repo" -q --q-bits "$bits" --mlx-path "$out"; then
        fail "Conversion failed — see the output above."
        rm -rf "$out"
        return 1
    fi
    ok "Converted: ${out} ($(du -sh "$out" 2>/dev/null | cut -f1))"
    info "Serve it with:  aistackLaunchInference   (it appears in the MLX-LM model list)"
}

# List models converted locally, with their size. Args: none.
aistackConvertList() {
    [ -d "$MLX_CONVERT_DIR" ] || { warn "Nothing converted yet — ${MLX_CONVERT_DIR} does not exist."; return 0; }
    local d n=0
    for d in "$MLX_CONVERT_DIR"/*@*bit; do
        [ -d "$d" ] || continue
        n=$((n+1))
        printf '  %-52s %s\n' "$(basename "$d" | sed 's|__|/|g; s|@|  @|')" "$(du -sh "$d" 2>/dev/null | cut -f1)" >&2
    done
    [ "$n" = "0" ] && warn "Nothing converted yet."
    return 0
}

# Remove a converted model. Args: <hf-repo> [bits].
aistackConvertRemove() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackConvertRemove <hf-repo> [bits]" \
            "example : aistackConvertRemove mims-harvard/ATHENA-R1-Qwen3-8B 8"
        return 2
    fi
    local out; out=$(_aiStackConvertPath "$1" "${2:-8}")
    [ -d "$out" ] || { ok "Not present: ${out}"; return 0; }
    warn "${out} holds $(du -sh "$out" 2>/dev/null | cut -f1)."
    ask_def "Delete it?" "n" || { ok "Kept."; return 0; }
    rm -rf "$out" && ok "Deleted."
}
