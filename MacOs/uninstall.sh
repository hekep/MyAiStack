#!/bin/bash
#
# uninstall.sh — Local AI coding stack remover (function-based)
#
# Mirror image of install.sh: every layer is an independent function, prefixed
# uninstallAiStack*, and they run from the MOST DEPENDENT layer down to the
# foundations — the reverse of the installer's order. Steps carrying "Ollama"
# in the name are engine-specific; the others apply to the stack as a whole.
#
#   uninstallAiStackOllamaModels   the Ollama models   <- GATE for everything below
#   uninstallAiStackMlx            mlx-lm (+ HuggingFace cache)
#   uninstallAiStackClaudeCli      Claude Code CLI
#   uninstallAiStackOllamaEngine   Ollama itself (service, brew formula, .app)
#   uninstallAiStackOllamaData     ~/.ollama — every model blob + registry keys
#   uninstallAiStackUv             uv (foundation of mlx-lm)
#   uninstallAiStackHomebrew       reports only — never removed
#   uninstallAiStackStatus         what is left standing
#   uninstallAiStack               wrapper — runs all of the above in order
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

info()  { echo "${BLUE}==>${RESET} $*"; }
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
fail()  { echo "${RED} ✗ ${RESET} $*"; }

ask() {
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

# Enter picks the caller's default: ask_def "Q?" y|n
ask_def() {
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

free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }
sizeof()  { du -sh "$1" 2>/dev/null | cut -f1; }
ollama_server_up() { curl -sf http://localhost:11434/api/version >/dev/null 2>&1; }
ollama_model_count() { ollama list 2>/dev/null | awk 'NR>1' | grep -c . ; }

# ---------- layer: Ollama models — the gate ----------------------------------
# Numbered menu mirroring install.sh's download menu: pick a model to remove,
# menu re-renders, until none are left or the user cancels.
# Returns 0 when NO models remain (safe to descend), 1 when any remain.
uninstallAiStackOllamaModels() {
    info "uninstallAiStackOllamaModels — the Ollama models (gate for every layer below)"
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
        warn "Models can still be wiped wholesale via uninstallAiStackOllamaData (~/.ollama)."
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

        printf "\n%sSelect a model to remove [1-%d / N]:%s " "${BOLD}" "${#names[@]}" "${RESET}"
        read -r sel </dev/tty || sel="N"
        case "$sel" in
            [Nn])
                [ "$started" -eq 1 ] && pkill -f "ollama serve" 2>/dev/null
                return 1 ;;
            *[!0-9]*|"") echo "Enter a number or N."; continue ;;
        esac
        if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#names[@]}" ]; then
            echo "Out of range."; continue
        fi

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
uninstallAiStackMlx() {
    info "uninstallAiStackMlx — mlx-lm and its model cache"
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

# ---------- layer: Claude Code CLI -------------------------------------------
uninstallAiStackClaudeCli() {
    info "uninstallAiStackClaudeCli — Claude Code CLI"
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
uninstallAiStackOllamaEngine() {
    info "uninstallAiStackOllamaEngine — the Ollama runtime"
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
        fail "Run uninstallAiStackOllamaModels first."
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
uninstallAiStackOllamaData() {
    info "uninstallAiStackOllamaData — ~/.ollama (model blobs + registry keypair)"
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
uninstallAiStackUv() {
    info "uninstallAiStackUv — uv"
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
uninstallAiStackHomebrew() {
    info "uninstallAiStackHomebrew — Homebrew"
    if ! command -v brew >/dev/null 2>&1; then
        ok "Homebrew not installed."
        return 0
    fi
    ok "Homebrew is left untouched — it manages software far beyond this stack."
    echo "    (To remove it anyway: https://github.com/homebrew/install#uninstall-homebrew)"
}

# ---------- status ------------------------------------------------------------
uninstallAiStackStatus() {
    echo
    echo "${BOLD}================= What is left =================${RESET}"
    command -v ollama >/dev/null 2>&1 && warn "Ollama:  still installed ($(ollama --version 2>/dev/null))" \
                                      || ok   "Ollama:  removed"
    [ -d "$HOME/.ollama" ]            && warn "Models:  ~/.ollama present ($(sizeof "$HOME/.ollama"))" \
                                      || ok   "Models:  removed"
    { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^mlx-lm'; } \
                                      && warn "mlx-lm:  still installed" || ok "mlx-lm:  removed"
    command -v claude >/dev/null 2>&1 && warn "claude:  still installed ($(claude --version 2>/dev/null | head -1))" \
                                      || ok   "claude:  removed"
    command -v uv >/dev/null 2>&1     && warn "uv:      still installed" || ok "uv:      removed"
    command -v brew >/dev/null 2>&1   && ok   "brew:    kept (by design)"
    echo "    Free disk: $(free_gb) GB"
}

# ---------- wrapper ----------------------------------------------------------
uninstallAiStack() {
    echo "${BOLD}=============================================================${RESET}"
    echo "${BOLD} Local AI coding stack — uninstaller${RESET}"
    echo "${BOLD} Order: most dependent layer first -> foundations last${RESET}"
    echo "${BOLD}=============================================================${RESET}"

    # THE GATE — while models exist, nothing below them may be removed.
    if ! uninstallAiStackOllamaModels; then
        echo
        warn "${BOLD}Uninstallation stopped: Ollama models are still installed.${RESET}"
        warn "Ollama, mlx-lm, the Claude CLI and uv are all kept — models depend on them."
        warn "Remove every model to continue, or run a single layer function directly:"
        warn "  source uninstall.sh && uninstallAiStackMlx"
        uninstallAiStackStatus
        exit 0
    fi

    uninstallAiStackMlx
    uninstallAiStackClaudeCli
    uninstallAiStackOllamaEngine
    uninstallAiStackOllamaData
    uninstallAiStackUv
    uninstallAiStackHomebrew
    uninstallAiStackStatus
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    uninstallAiStack
fi
