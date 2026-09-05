#!/bin/bash
#
# uninstall.sh — Local AI coding stack remover (function-based)
#
# Mirror image of install.sh: every layer is an independent function, prefixed
# aistackUninstall*, and they run from the MOST DEPENDENT layer down to the
# foundations — the reverse of the installer's order. Steps carrying "Ollama"
# in the name are engine-specific; the others apply to the stack as a whole.
#
#   aistackUninstallOllamaModels         the models   <- GATE for everything below
#   --- monitoring: observational, nothing depends on it (macOS-specific) ---
#   aistackUninstallMacmonMonitoring     macmon
#   aistackUninstallAnubisMonitoring     Anubis OSS
#   aistackUninstallLitellmMonitoring    LiteLLM proxy
#   --- coding agents: what you type into, they sit above the engines ---
#   aistackUninstallClaudeCodingAgent    Claude Code CLI
#   aistackUninstallOpenCodeCodingAgent  OpenCode
#   aistackUninstallPiCodingAgent        Pi
#   --- engines and foundations ---
#   aistackUninstallMlxmlEngine                  mlx-lm / MLX-LM engine (+ HF cache)
#   aistackUninstallOllamaEngine         Ollama itself (service, formula, .app)
#   aistackUninstallOllamaData           ~/.ollama — model blobs + registry keys
#   aistackUninstallUv                   uv (foundation of mlx-lm)
#   aistackUninstallHomebrew             reports only — never removed
#   aistackUninstallVerification               what is left standing
#   aistackUninstall                     wrapper — runs all of the above in order
#
# THE GATE: while any Ollama model is still installed, Ollama and everything
# under it must stay, so the wrapper stops there. Remove every model to reach
# the foundation layers.
#
# Usage:
#   ./uninstall.sh                 # full pipeline
#   source uninstall.sh            # then call any single function
#
set -u

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

# Print a progress heading ("==> ...") for the layer being removed.
info()  { echo "${BLUE}==>${RESET} $*"; }
# Print a success line — also used for "nothing to remove", so a clean
# machine reads the same as one just cleaned.
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
# Print a caution line: kept-by-choice, or a destructive step about to be
# offered. Not a failure.
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
# Print an error line — a removal that was attempted and did not work.
fail()  { echo "${RED} ✗ ${RESET} $*"; }

# Print a usage message for a function called without its arguments, return 2.
# Args: <signature> [detail lines...]. Anything here can be called standalone
# from a shell, so a bare call must explain itself rather than misbehave.
aiStackUsage() {
    local sig="$1"; shift
    # fail() exists in the wizard scripts but not in every file that needs this
    if command -v fail >/dev/null 2>&1; then fail "usage: ${sig}"
    else echo "✗ usage: ${sig}" >&2; fi
    local l
    for l in "$@"; do echo "         ${l}" >&2; done
    return 2
}

# Ask a yes/no question, looping until the answer is unambiguous.
# Reads /dev/tty so the prompt survives piped output; aborts if there is no
# terminal at all. Returns 0 for yes, 1 for no, with no Enter-default.
ask() {
    if [ $# -lt 1 ]; then
        aiStackUsage "ask <question>" "no default — answer y or n explicitly" "example : ask \"Remove the model?\""
        return 2
    fi
    local answer
    while true; do
        printf "\n%s%s%s [y/n] " "${BOLD}" "$1" "${RESET}"
        read -r answer </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
        case "$answer" in
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Ask a yes/no question where Enter picks a caller-supplied default.
# Args: <question> <y|n>. The hint shown ([Y/n] or [y/N]) reflects that default.
# Destructive steps pass "n" so a stray Enter can never delete anything.
ask_def() {
    if [ $# -lt 2 ]; then
        aiStackUsage "ask_def <question> <y|n>" "example : ask_def "Remove it?" n"
        return 2
    fi
    local answer hint
    [ "$2" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf "\n%s%s%s %s " "${BOLD}" "$1" "${RESET}" "$hint"
        read -r answer </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
        case "$answer" in
            "") [ "$2" = "y" ] && return 0 || return 1 ;;
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Free space on the data volume in whole GB.
# Sampled before and after each removal so the script can report what was
# actually freed rather than what 'du' predicted.
free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }
# Human-readable size of a path ('du -sh'), empty when it does not exist.
# Shown inside prompts so a deletion is never agreed to blind.
sizeof()  { [ $# -ge 1 ] || { aiStackUsage "sizeof <path>" "example : sizeof ~/.ollama"; return 2; }; du -sh "$1" 2>/dev/null | cut -f1; }
# True when the Ollama API answers on localhost.
# Model listing and removal both need the daemon, so several layers check this
# before deciding whether to start one temporarily.
ollama_server_up() { curl -sf http://localhost:11434/api/version >/dev/null 2>&1; }
# How many models Ollama has installed on disk.
# The engine layer refuses to uninstall Ollama while this is non-zero, which
# keeps the dependency rule true even when a function is called directly.
ollama_model_count() { ollama list 2>/dev/null | awk 'NR>1' | grep -c . ; }

# Mirror of aistackInstallSanity: confirm this is a machine the MacOs
# implementations apply to before touching anything. Args: none.
aistackUninstallSanity() {
    info "aistackUninstallSanity — platform check"
    if [ "$(uname -s)" != "Darwin" ]; then
        fail "These are the macOS implementations; this is $(uname -s)."
        return 1
    fi
    ok "macOS $(sw_vers -productVersion 2>/dev/null) — proceeding."
}

# Mirror of aistackInstallDiskGate. The installer BLOCKS below a disk minimum;
# the inverse is not a gate — removing things can only free space — so this
# reports what each layer is currently holding, to inform what to remove.
aistackUninstallDiskGate() {
    info "aistackUninstallDiskGate — what the stack is holding (nothing is blocked)"
    local total=0 sz
    _report() {  # <label> <path-or-empty> <fallback-size>
        [ -n "$2" ] && [ -e "$2" ] || { [ -n "$3" ] || return 0; }
        sz="${3:-$(sizeof "$2")}"
        printf "    %-34s %s\n" "$1" "$sz"
    }
    [ -d "$HOME/.ollama" ]        && _report "Ollama models (~/.ollama)"      "$HOME/.ollama"
    [ -d "${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}" ] && \
        _report "llama.cpp GGUFs" "${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}"
    [ -d "${HF_HOME:-$HOME/.cache/huggingface}" ] && \
        _report "HuggingFace cache (MLX etc.)" "${HF_HOME:-$HOME/.cache/huggingface}"
    unset -f _report
    ok "Free disk now: $(free_gb) GB — removals below will add to it."
}

# ---------- layer: Ollama models — the gate ----------------------------------
# Layer 1 and the GATE: remove models one at a time from a numbered menu.
# Mirrors the installer's download menu — pick a number, see the freed GB, the
# menu re-renders — and starts the daemon temporarily if it is not running.
# Returns 0 only when NO models remain; 1 (models left, or N) stops the wizard,
# because nothing a model depends on may be removed while it exists.
aistackUninstallOllamaModels() {
    info "aistackUninstallOllamaModels — the Ollama models (gate for every layer below)"
    if ! command -v ollama >/dev/null 2>&1; then
        ok "Ollama is not installed — no models to remove."
        return 0
    fi

    local started=0
    if ! ollama_server_up; then
        warn "Ollama server not running — starting it temporarily to manage models."
        nohup ollama serve >/dev/null 2>&1 &
        started=1
        sleep 3
    fi
    if ! ollama_server_up; then
        warn "Could not reach the Ollama server — cannot enumerate models."
        warn "Models can still be wiped wholesale via aistackUninstallOllamaData (~/.ollama)."
        [ "$started" -eq 1 ] && pkill -f "ollama serve" 2>/dev/null
        return 1
    fi

    local models i names name size sel m before
    while true; do
        models=$(ollama list 2>/dev/null | awk 'NR>1 {print $1"|"$3" "$4}')
        if [ -z "$models" ]; then
            ok "No models remain — dependencies clear, descending to the foundations."
            [ "$started" -eq 1 ] && pkill -f "ollama serve" 2>/dev/null
            return 0
        fi

        echo
        echo "${BOLD}Installed models (free disk: $(free_gb) GB):${RESET}"
        i=1; names=()
        while IFS='|' read -r name size; do
            printf "  %2d) %-40s %s\n" "$i" "$name" "$size"
            names+=("$name")
            i=$((i+1))
        done <<< "$models"
        echo "   N) Cancel uninstallation — keep remaining models and everything they depend on"

        # Enter means N — keep everything; bad input re-asks here, not the whole menu.
        local _sel_ok=0
        while [ "$_sel_ok" -eq 0 ]; do
        printf "\n%sSelect a model to remove [1-%d / N, Enter = N]:%s " "${BOLD}" "${#names[@]}" "${RESET}"
            read -r sel </dev/tty || sel="N"
            case "$sel" in
                ""|[Nn])
                    [ "$started" -eq 1 ] && pkill -f "ollama serve" 2>/dev/null
                    return 1 ;;
                *[!0-9]*) echo "Enter a number or N."; continue ;;
            esac
            if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#names[@]}" ]; then echo "Out of range (1-${#names[@]})."; continue; fi
            _sel_ok=1
        done

        m="${names[$((sel-1))]}"
        before=$(free_gb)
        if ollama rm "$m" >/dev/null 2>&1; then
            ok "Removed ${m} — freed $(( $(free_gb) - before )) GB."
        else
            fail "Could not remove ${m}."
        fi
    done
}

# ---------- layer: mlx-lm (depends on uv) ------------------------------------
# Remove the MLX-LM engine (the mlx-lm uv tool).
# Then offers the HuggingFace model cache separately and defaults to keeping it:
# it is pure re-downloadable cache, but often the largest item on the disk.
aistackUninstallMlxmlEngine() {
    info "aistackUninstallMlxmlEngine — the MLX-LM engine (mlx-lm)"
    if ! command -v uv >/dev/null 2>&1 || ! uv tool list 2>/dev/null | grep -q '^mlx-lm'; then
        ok "mlx-lm not installed — nothing to do."
        return 0
    fi
    if ask_def "Uninstall mlx-lm?" "y"; then
        uv tool uninstall mlx-lm && ok "mlx-lm removed." || fail "mlx-lm removal failed."
    else
        ok "Keeping mlx-lm."
        return 0
    fi
    # the HuggingFace cache MLX downloads into is separate and often huge
    if [ -d "$HOME/.cache/huggingface" ]; then
        local hf before
        hf=$(sizeof "$HOME/.cache/huggingface")
        warn "HuggingFace model cache: ~/.cache/huggingface (${hf}) — re-downloadable."
        if ask_def "Delete the HuggingFace cache too (${hf})?" "n"; then
            before=$(free_gb)
            rm -rf "$HOME/.cache/huggingface" \
                && ok "Cache deleted — freed $(( $(free_gb) - before )) GB." \
                || fail "Deletion failed."
        else
            ok "Keeping the HuggingFace cache."
        fi
    fi
}

# ---------- layer: models, one step per engine (mirrors the installer) -------

# GGUF models on disk for llama.cpp, as engine tags. Args: none.
llamacppListInstalled() {
    local dir="${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}" f b
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.gguf; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .gguf)
        printf '%s\n' "$(printf '%s' "$b" | sed 's|@|:|; s|__|/|g')"
    done
}

# MLX models in the HuggingFace cache, as repo ids. Args: none.
mlxmlListInstalled() {
    local cache="${HF_HOME:-$HOME/.cache/huggingface}/hub" d b
    [ -d "$cache" ] || return 0
    for d in "$cache"/models--*; do
        [ -d "$d" ] || continue
        b=$(basename "$d")
        printf '%s\n' "$(printf '%s' "${b#models--}" | sed 's|--|/|')"
    done
}

# Shared numbered menu for removing models of one engine — the mirror of the
# installer's download menu. Args: <engine> <list-fn> <path-fn>.
# Returns 0 when no models remain, 1 when the user stops with some left.
_aistackModelRemoveMenu() {
    local engine="$1" list_fn="$2" path_fn="$3" models i names sel m target before
    while true; do
        models=$("$list_fn")
        if [ -z "$models" ]; then
            ok "No ${engine} models remain."
            return 0
        fi
        echo
        echo "${BOLD}${engine} models (free disk: $(free_gb) GB):${RESET}"
        i=1; names=()
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            printf "  %2d) %-52s %s\n" "$i" "$m" "$(sizeof "$("$path_fn" "$m")")"
            names+=("$m"); i=$((i+1))
        done <<< "$models"
        echo "   N) Keep the rest — stop here"
        # Enter means N — keep everything; bad input re-asks here, not the whole menu.
        local _sel_ok=0
        while [ "$_sel_ok" -eq 0 ]; do
        printf "\n%sRemove which ${engine} model? [1-%d / N, Enter = N]:%s " "${BOLD}" "${#names[@]}" "${RESET}"
            read -r sel </dev/tty || sel="N"
            case "$sel" in
                ""|[Nn]) return 1 ;;
                *[!0-9]*) echo "Enter a number or N."; continue ;;
            esac
            if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#names[@]}" ]; then echo "Out of range (1-${#names[@]})."; continue; fi
            _sel_ok=1
        done
        m="${names[$((sel-1))]}"
        target=$("$path_fn" "$m")
        before=$(free_gb)
        if rm -rf "$target"; then
            ok "Removed ${m} — freed $(( $(free_gb) - before )) GB."
        else
            fail "Could not remove ${target}."
        fi
    done
}

# Where one llama.cpp tag lives on disk. Args: <tag>.
llamacppPathFor() {
    [ $# -ge 1 ] || { aiStackUsage "llamacppPathFor <tag>" "example : llamacppPathFor org/repo-GGUF:Q8_0"; return 2; }
    echo "${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}/$(printf '%s' "$1" | sed 's|/|__|g; s|:|@|').gguf"
}

# Where one MLX repo lives in the HuggingFace cache. Args: <repo>.
mlxmlPathFor() {
    [ $# -ge 1 ] || { aiStackUsage "mlxmlPathFor <hf-repo>" "example : mlxmlPathFor mlx-community/Model-4bit"; return 2; }
    echo "${HF_HOME:-$HOME/.cache/huggingface}/hub/models--$(printf '%s' "$1" | sed 's|/|--|')"
}

# Remove llama.cpp GGUF models — mirror of aistackInstallLlamacppModels.
# Returns 0 when none remain, so the engine layer below may proceed.
aistackUninstallLlamacppModels() {
    info "aistackUninstallLlamacppModels — GGUF files in ${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}"
    if ! command -v llama-server >/dev/null 2>&1 && [ -z "$(llamacppListInstalled)" ]; then
        ok "No llama.cpp models — nothing to do."
        return 0
    fi
    _aistackModelRemoveMenu "Llama.cpp" llamacppListInstalled llamacppPathFor
}

# Remove MLX models from the HuggingFace cache — mirror of
# aistackInstallMlxmlModels. Note the cache is shared with anything else using
# HuggingFace, so only the model directories chosen here are touched.
aistackUninstallMlxmlModels() {
    info "aistackUninstallMlxmlModels — MLX models in the HuggingFace cache"
    if [ -z "$(mlxmlListInstalled)" ]; then
        ok "No MLX models in the cache — nothing to do."
        return 0
    fi
    _aistackModelRemoveMenu "MLX-LM" mlxmlListInstalled mlxmlPathFor
}

# Remove the llama.cpp engine — mirror of aistackInstallLlamacppEngine.
# Refuses while GGUFs remain, the same rule the Ollama engine layer follows.
aistackUninstallLlamacppEngine() {
    info "aistackUninstallLlamacppEngine — llama.cpp"
    if ! command -v llama-server >/dev/null 2>&1 && ! command -v llama-cli >/dev/null 2>&1; then
        ok "llama.cpp not installed — nothing to do."
        return 0
    fi
    local n
    n=$(llamacppListInstalled | grep -c . || true)
    if [ "${n:-0}" -gt 0 ]; then
        fail "${n} GGUF model(s) still on disk — refusing to remove llama.cpp."
        fail "Run aistackUninstallLlamacppModels first."
        return 1
    fi
    if ! ask_def "Uninstall llama.cpp?" "y"; then
        ok "Keeping llama.cpp."
        return 0
    fi
    pkill -f "llama-server .*--port 8080" 2>/dev/null
    brew uninstall llama.cpp && ok "llama.cpp removed." || fail "brew uninstall failed."
}

# ---------- layer: monitoring -------------------------------------------------
# Purely observational: nothing in the stack depends on these, so they come off
# first. macOS-specific, like their install counterparts.

# Remove macmon (Apple Silicon performance monitor).
# Default No: it is small, useful beside any workload, and unrelated to whether
# you keep the models — so removing it is rarely what you actually want.
aistackUninstallMacmonMonitoring() {
    info "aistackUninstallMacmonMonitoring — macmon"
    if ! command -v macmon >/dev/null 2>&1; then
        ok "macmon not installed — nothing to do."
        return 0
    fi
    warn "macmon $(macmon --version 2>/dev/null | head -1) at $(command -v macmon)"
    if ask_def "Uninstall macmon?" "n"; then
        brew uninstall macmon && ok "macmon removed." || fail "brew uninstall failed."
    else
        ok "Keeping macmon."
    fi
}

# Remove Anubis OSS (the local-LLM benchmarking app).
# Default No. Offers brew's --zap afterwards, which also clears the app's
# support files and — importantly — your saved benchmark history, so that is a
# separate question rather than part of the uninstall.
aistackUninstallAnubisMonitoring() {
    info "aistackUninstallAnubisMonitoring — Anubis OSS"
    local app="/Applications/Anubis OSS.app"
    if [ ! -d "$app" ] && ! brew list --cask anubis-oss >/dev/null 2>&1; then
        ok "Anubis OSS not installed — nothing to do."
        return 0
    fi
    warn "Anubis OSS at ${app}"
    if ! ask_def "Uninstall Anubis OSS?" "n"; then
        ok "Keeping Anubis OSS."
        return 0
    fi
    if brew list --cask anubis-oss >/dev/null 2>&1; then
        brew uninstall --cask anubis-oss && ok "Anubis OSS removed." || fail "brew uninstall failed."
    else
        rm -rf "$app" && ok "Removed ${app}."
    fi
    warn "Its data (benchmark history, preferences) lives in ~/Library/... com.uncsoft.anubisoss"
    if ask_def "Also delete that data (brew --zap)?" "n"; then
        brew uninstall --cask --zap anubis-oss >/dev/null 2>&1 \
            || rm -rf ~/Library/Application\ Support/com.uncsoft.anubisoss \
                      ~/Library/Caches/com.uncsoft.anubisoss \
                      ~/Library/Preferences/com.uncsoft.anubisoss.plist \
                      ~/Library/Saved\ Application\ State/com.uncsoft.anubisoss.savedState
        ok "Anubis OSS data deleted."
    else
        ok "Keeping your benchmark history."
    fi
}

# Remove the LiteLLM proxy (a uv tool).
# Default No. Offers its config directory separately, since ~/.litellm can hold
# provider keys you would not want to re-enter.
aistackUninstallLitellmMonitoring() {
    info "aistackUninstallLitellmMonitoring — LiteLLM proxy"
    if ! command -v uv >/dev/null 2>&1 || ! uv tool list 2>/dev/null | grep -q '^litellm'; then
        ok "LiteLLM not installed — nothing to do."
        return 0
    fi
    if ask_def "Uninstall LiteLLM?" "n"; then
        uv tool uninstall litellm && ok "LiteLLM removed." || fail "LiteLLM removal failed."
    else
        ok "Keeping LiteLLM."
        return 0
    fi
    if [ -d "$HOME/.litellm" ]; then
        warn "LiteLLM config lives in ~/.litellm ($(sizeof "$HOME/.litellm")) — it may hold provider keys."
        ask_def "Delete ~/.litellm as well?" "n" && { rm -rf "$HOME/.litellm" && ok "~/.litellm deleted."; }
    fi
}

# ---------- layer: coding agents ---------------------------------------------
# The agents sit above the engines: they are what you type into. Removed before
# any engine, so nothing is pulled out from under a working agent.

# Remove the Pi coding agent (npm package, either publisher scope).
# Defaults to No. Offers ~/.pi — config, plugins, session transcripts — as a
# separate question, since that is your data rather than the program.
aistackUninstallPiCodingAgent() {
    info "aistackUninstallPiCodingAgent — Pi coding agent"
    if ! command -v pi >/dev/null 2>&1; then
        ok "Pi not installed — nothing to do."
        return 0
    fi
    warn "Pi $(pi --version 2>/dev/null | head -1) at $(command -v pi)"
    if ! ask_def "Uninstall Pi?" "n"; then
        ok "Keeping Pi."
        return 0
    fi
    if command -v npm >/dev/null 2>&1; then
        npm uninstall -g @earendil-works/pi-coding-agent >/dev/null 2>&1 \
            || npm uninstall -g @mariozechner/pi-coding-agent >/dev/null 2>&1
    fi
    command -v pi >/dev/null 2>&1 && fail "'pi' still resolves — remove it by hand." || ok "Pi removed."
    if [ -d "$HOME/.pi" ]; then
        warn "Pi config/plugins live in ~/.pi ($(sizeof "$HOME/.pi"))."
        ask_def "Delete ~/.pi as well?" "n" && { rm -rf "$HOME/.pi" && ok "~/.pi deleted."; }
    fi
}

# Remove OpenCode, using whichever channel installed it (brew, else npm).
# Defaults to No, and offers ~/.config/opencode separately so provider settings
# survive a reinstall unless you say otherwise.
aistackUninstallOpenCodeCodingAgent() {
    info "aistackUninstallOpenCodeCodingAgent — OpenCode"
    if ! command -v opencode >/dev/null 2>&1; then
        ok "OpenCode not installed — nothing to do."
        return 0
    fi
    warn "OpenCode $(opencode --version 2>/dev/null | head -1) at $(command -v opencode)"
    if ! ask_def "Uninstall OpenCode?" "n"; then
        ok "Keeping OpenCode."
        return 0
    fi
    if brew list opencode >/dev/null 2>&1; then
        brew uninstall opencode && ok "Brew formula removed." || fail "brew uninstall failed."
    elif command -v npm >/dev/null 2>&1; then
        npm uninstall -g opencode-ai && ok "npm package removed." || fail "npm uninstall failed."
    fi
    if [ -d "$HOME/.config/opencode" ]; then
        warn "OpenCode config lives in ~/.config/opencode."
        ask_def "Delete it as well?" "n" && { rm -rf "$HOME/.config/opencode" && ok "Config deleted."; }
    fi
}

# ---------- layer: Claude Code CLI -------------------------------------------
# Remove the Claude Code CLI (npm package or native installer layout).
# Defaults to No — it may be the very session you are typing in.
# ~/.claude (sessions, settings, memory) is never touched by this script.
aistackUninstallClaudeCodingAgent() {
    info "aistackUninstallClaudeCodingAgent — Claude Code CLI"
    if ! command -v claude >/dev/null 2>&1; then
        ok "claude CLI not installed — nothing to do."
        return 0
    fi
    local bin ver
    bin=$(command -v claude)
    ver=$(claude --version 2>/dev/null | head -1)
    warn "claude ${ver} at ${bin}"
    warn "This is the tool that drives the local models — and possibly this session."
    ok "Your sessions, settings and memory in ~/.claude are NEVER touched by this script."
    if ! ask_def "Uninstall the Claude Code CLI?" "n"; then
        ok "Keeping the Claude CLI."
        return 0
    fi
    if command -v npm >/dev/null 2>&1 && npm ls -g @anthropic-ai/claude-code >/dev/null 2>&1; then
        npm uninstall -g @anthropic-ai/claude-code && ok "npm package removed." || fail "npm uninstall failed."
    else
        # native installer layout: ~/.local/bin/claude -> ~/.local/share/claude/versions/<ver>
        local store="$HOME/.local/share/claude"
        rm -f "$bin" && ok "Removed ${bin}."
        if [ -d "$store" ]; then
            if ask_def "Also remove the version store ${store} ($(sizeof "$store"))?" "y"; then
                rm -rf "$store" && ok "Version store removed."
            fi
        fi
    fi
    command -v claude >/dev/null 2>&1 && warn "'claude' still resolves — another install may exist." \
                                      || ok "Claude CLI removed."
}

# ---------- layer: Ollama itself ---------------------------------------------
# Remove the Ollama runtime itself, models excluded.
# Refuses while any model is installed, so the rule holds even when called
# directly. Stops every way it can run (brew service, LAN LaunchAgent, app,
# bare serve), then removes the formula, the .app and its stray symlink.
aistackUninstallOllamaEngine() {
    info "aistackUninstallOllamaEngine — the Ollama runtime"
    local present=0
    brew list ollama >/dev/null 2>&1 && present=1
    [ -d /Applications/Ollama.app ]  && present=1
    command -v ollama >/dev/null 2>&1 && present=1
    if [ "$present" -eq 0 ]; then
        ok "Ollama not installed — nothing to do."
        return 0
    fi

    # never remove the engine while models still depend on it
    local n
    n=$(ollama_model_count 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 0 ]; then
        fail "${n} model(s) still installed — refusing to remove Ollama."
        fail "Run aistackUninstallOllamaModels first."
        return 1
    fi

    if ! ask_def "Uninstall Ollama? (its data directory is a separate step)" "y"; then
        ok "Keeping Ollama."
        return 0
    fi

    # stop every way it can be running: brew service, LAN LaunchAgent, app, bare serve
    if brew services list 2>/dev/null | grep -q "^ollama.*started"; then
        brew services stop ollama >/dev/null 2>&1 && ok "brew service stopped."
    fi
    local lan_plist="$HOME/Library/LaunchAgents/local.ollama.lan.plist"
    if [ -f "$lan_plist" ]; then
        launchctl bootout "gui/$(id -u)" "$lan_plist" 2>/dev/null
        rm -f "$lan_plist" && ok "LAN LaunchAgent removed."
    fi
    osascript -e 'quit app "Ollama"' 2>/dev/null || true
    pkill -f "ollama serve" 2>/dev/null || true
    sleep 1

    if brew list ollama >/dev/null 2>&1; then
        brew uninstall ollama && ok "Brew formula removed." || fail "brew uninstall failed."
    fi
    if [ -d /Applications/Ollama.app ]; then
        rm -rf /Applications/Ollama.app \
               ~/Library/Application\ Support/Ollama \
               ~/Library/Caches/com.electron.ollama \
               ~/Library/Preferences/com.electron.ollama.plist \
               ~/Library/Saved\ Application\ State/com.electron.ollama.savedState
        ok "Ollama.app and its support files removed."
    fi
    [ -L /usr/local/bin/ollama ] && { sudo rm -f /usr/local/bin/ollama && ok "Removed /usr/local/bin/ollama symlink."; }
    return 0
}

# ---------- layer: Ollama data directory (destructive) -----------------------
# Delete ~/.ollama: every model blob plus this machine's registry keypair.
# The only unrecoverable step here, so it shows the size, asks twice, and both
# questions default to No. Kept separate from the engine on purpose: losing the
# program costs minutes, losing the blobs costs hours of downloading.
aistackUninstallOllamaData() {
    info "aistackUninstallOllamaData — ~/.ollama (model blobs + registry keypair)"
    if [ ! -d "$HOME/.ollama" ]; then
        ok "~/.ollama does not exist — nothing to do."
        return 0
    fi
    local sz before
    sz=$(sizeof "$HOME/.ollama")
    warn "~/.ollama holds every downloaded blob and this machine's Ollama keypair (${sz})."
    warn "DESTRUCTIVE and unrecoverable — models would have to be downloaded again."
    if ask_def "Permanently delete ~/.ollama (${sz})?" "n"; then
        if ask_def "Are you sure? This wipes every model blob in one go." "n"; then
            before=$(free_gb)
            rm -rf "$HOME/.ollama" \
                && ok "~/.ollama deleted — freed $(( $(free_gb) - before )) GB." \
                || fail "Deletion failed."
        else
            ok "Keeping ~/.ollama."
        fi
    else
        ok "Keeping ~/.ollama."
    fi
}

# ---------- layer: uv (foundation of mlx-lm) ---------------------------------
# Remove uv, the foundation MLX-LM was installed through.
# Lists any other tools uv still manages first — removing it would leave them
# unmanaged — and defaults to No for that reason.
aistackUninstallUv() {
    info "aistackUninstallUv — uv"
    if ! command -v uv >/dev/null 2>&1 || ! brew list uv >/dev/null 2>&1; then
        ok "uv not brew-installed — nothing to do."
        return 0
    fi
    local remaining
    remaining=$(uv tool list 2>/dev/null | grep -c '^[a-zA-Z]' || true)
    if [ "${remaining:-0}" -gt 0 ]; then
        warn "uv still manages ${remaining} tool(s) — removing uv leaves them unmanaged:"
        uv tool list 2>/dev/null | sed 's/^/    /'
    fi
    if ask_def "Uninstall uv?" "n"; then
        brew uninstall uv && ok "uv removed." || fail "uv removal failed."
    else
        ok "Keeping uv."
    fi
}

# ---------- layer: Homebrew (never removed) ----------------------------------
# Report Homebrew and deliberately leave it alone.
# It manages software far beyond this stack, so removing it is never offered;
# the upstream uninstall instructions are printed instead.
aistackUninstallHomebrew() {
    info "aistackUninstallHomebrew — Homebrew"
    if ! command -v brew >/dev/null 2>&1; then
        ok "Homebrew not installed."
        return 0
    fi
    ok "Homebrew is left untouched — it manages software far beyond this stack."
    echo "    (To remove it anyway: https://github.com/homebrew/install#uninstall-homebrew)"
}

# ---------- status ------------------------------------------------------------
# Print what is still standing: engines, agents, models, uv, brew, free disk.
# Also printed when the model gate stops the run, so a cancelled uninstall still
# ends with an accurate picture.
aistackUninstallVerification() {
    echo
    echo "${BOLD}================= What is left =================${RESET}"
    command -v ollama >/dev/null 2>&1 && warn "Ollama:  still installed ($(ollama --version 2>/dev/null))" \
                                      || ok   "Ollama:  removed"
    [ -d "$HOME/.ollama" ]            && warn "Models:  ~/.ollama present ($(sizeof "$HOME/.ollama"))" \
                                      || ok   "Models:  removed"
    { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^mlx-lm'; } \
                                      && warn "mlx-lm:  still installed" || ok "mlx-lm:  removed"
    command -v macmon >/dev/null 2>&1   && warn "macmon:  still installed" || ok "macmon:  removed"
    [ -d "/Applications/Anubis OSS.app" ] && warn "Anubis:  still installed" || ok "Anubis:  removed"
    command -v pi >/dev/null 2>&1       && warn "Pi:      still installed" || ok "Pi:      removed"
    command -v opencode >/dev/null 2>&1 && warn "OpenCode: still installed" || ok "OpenCode: removed"
    command -v claude >/dev/null 2>&1   && warn "claude:  still installed ($(claude --version 2>/dev/null | head -1))" \
                                        || ok   "claude:  removed"
    command -v uv >/dev/null 2>&1     && warn "uv:      still installed" || ok "uv:      removed"
    command -v brew >/dev/null 2>&1   && ok   "brew:    kept (by design)"
    echo "    Free disk: $(free_gb) GB"
}

# ---------- wrapper ----------------------------------------------------------
# Wrapper: run every layer from most-dependent down to the foundations.
# Models first (the gate), then coding agents, then engines and their data.
# Stops after the gate when models remain, keeping everything they need.
aistackUninstall() {
    echo "${BOLD}=============================================================${RESET}"
    echo "${BOLD} Local AI coding stack — uninstaller${RESET}"
    echo "${BOLD} Order: most dependent layer first -> foundations last${RESET}"
    echo "${BOLD}=============================================================${RESET}"
    aistackUninstallSanity || return 1
    aistackUninstallDiskGate

    # THE GATE — every engine's models must be gone before anything they
    # depend on may be removed. One step per engine, mirroring the installer.
    local left=0
    aistackUninstallLlamacppModels || left=1
    aistackUninstallMlxmlModels    || left=1
    aistackUninstallOllamaModels   || left=1
    if [ "$left" = "1" ]; then
        echo
        warn "${BOLD}Uninstallation stopped: models are still installed.${RESET}"
        warn "Engines, agents, monitoring and uv are all kept — models depend on them."
        warn "Remove every model to continue, or run a single layer directly:"
        warn "  source uninstall.sh && aistackUninstallMacmonMonitoring"
        aistackUninstallVerification
        exit 0
    fi

    # monitoring first: nothing depends on it
    aistackUninstallMacmonMonitoring
    aistackUninstallAnubisMonitoring
    aistackUninstallLitellmMonitoring

    # then the coding agents — they sit above the engines
    aistackUninstallClaudeCodingAgent
    aistackUninstallOpenCodeCodingAgent
    aistackUninstallPiCodingAgent

    # then the engines, reverse of the order the installer offers them
    aistackUninstallOllamaEngine
    aistackUninstallMlxmlEngine
    aistackUninstallLlamacppEngine

    # engine data, then the foundations
    aistackUninstallOllamaData
    aistackUninstallUv
    aistackUninstallHomebrew
    aistackUninstallVerification
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    aistackUninstall
fi
