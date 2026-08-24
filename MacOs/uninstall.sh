#!/bin/bash
#
# uninstall.sh — Local AI coding stack remover
# Companion to install.sh
#
# Interactive: asks per item whether to remove it, ONE question at a time,
# in reverse dependency order — most-dependent first, foundations last:
#
#   1. Models              (depend on Ollama)
#   2. mlx-lm              (depends on uv)
#   3. Ollama server/service, then the Ollama install itself
#   4. Ollama data dir ~/.ollama   (destructive — models & keys)
#   5. uv                  (foundation tool)
#   6. Homebrew            (never touched — listed for transparency only)
#
# Safe to re-run; already-removed items are detected and skipped.
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
        read -r answer </dev/tty
        case "$answer" in
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

ollama_server_up() { curl -sf http://localhost:11434/api/version >/dev/null 2>&1; }
free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }

echo "${BOLD}=============================================================${RESET}"
echo "${BOLD} Local AI coding stack — uninstaller${RESET}"
echo "${BOLD} Order: most dependent first -> foundations last${RESET}"
echo "${BOLD}=============================================================${RESET}"

# ---------- Step 1: models (top of the dependency chain) ---------------------
info "Step 1/6 — Ollama models"
if command -v ollama >/dev/null 2>&1; then
    SERVER_STARTED_BY_SCRIPT=0
    if ! ollama_server_up; then
        # need the server up just to list/remove models
        warn "Ollama server not running — starting it temporarily to manage models."
        nohup ollama serve >/dev/null 2>&1 &
        SERVER_STARTED_BY_SCRIPT=1
        sleep 3
    fi
    if ollama_server_up; then
        # numbered menu, mirror of install.sh's model menu: pick a model to
        # remove, menu re-renders, loop until N or until no models remain
        while true; do
            MODELS=$(ollama list 2>/dev/null | awk 'NR>1 {print $1"|"$3" "$4}')
            if [ -z "$MODELS" ]; then
                ok "No models remain — dependencies clear, moving on to the foundations."
                break
            fi
            echo
            echo "${BOLD}Installed models (free disk: $(free_gb) GB):${RESET}"
            i=1; names=()
            while IFS='|' read -r name size; do
                printf "  %2d) %-40s %s\n" "$i" "$name" "$size"
                names+=("$name")
                i=$((i+1))
            done <<< "$MODELS"
            echo "   N) Cancel uninstallation — keep remaining models and everything they depend on"

            printf "\n%sSelect a model to remove [1-%d / N]:%s " "${BOLD}" "${#names[@]}" "${RESET}"
            read -r sel </dev/tty || sel="N"
            case "$sel" in
                [Nn])
                    # models remain -> the foundations they depend on must stay.
                    # N is a full cancel, not a skip.
                    ok "Uninstallation cancelled — remaining models (and Ollama, uv, mlx-lm under them) are kept."
                    [ "$SERVER_STARTED_BY_SCRIPT" -eq 1 ] && pkill -f "ollama serve" 2>/dev/null
                    exit 0 ;;
                *[!0-9]*|"") echo "Enter a number or N."; continue ;;
            esac
            if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#names[@]}" ]; then
                echo "Out of range."; continue
            fi
            m="${names[$((sel-1))]}"
            B=$(free_gb)
            if ollama rm "$m" >/dev/null 2>&1; then
                ok "Removed ${m} — freed $(( $(free_gb) - B )) GB."
            else
                fail "Could not remove ${m}."
            fi
        done
    else
        warn "Could not reach the Ollama server — skipping per-model removal."
        warn "(Models can still be wiped wholesale in step 4 via ~/.ollama.)"
    fi
    if [ "$SERVER_STARTED_BY_SCRIPT" -eq 1 ]; then
        pkill -f "ollama serve" 2>/dev/null || true
    fi
else
    warn "Ollama binary not found — skipping per-model removal (see step 4 for the data dir)."
fi

# ---------- Step 2: mlx-lm (depends on uv) -----------------------------------
info "Step 2/6 — mlx-lm"
if command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q mlx-lm; then
    if ask "Uninstall mlx-lm?"; then
        uv tool uninstall mlx-lm && ok "mlx-lm removed." || fail "mlx-lm removal failed."
        # HuggingFace model cache used by MLX
        if [ -d "$HOME/.cache/huggingface" ]; then
            HF_SIZE=$(du -sh "$HOME/.cache/huggingface" 2>/dev/null | cut -f1)
            if ask "Also delete the HuggingFace model cache (~/.cache/huggingface, ${HF_SIZE})?"; then
                rm -rf "$HOME/.cache/huggingface" && ok "HuggingFace cache deleted."
            fi
        fi
    else
        ok "Keeping mlx-lm."
    fi
else
    ok "mlx-lm not installed — nothing to do."
fi

# ---------- Step 3: Ollama service + install ---------------------------------
info "Step 3/6 — Ollama application"
OLLAMA_PRESENT=0
brew list ollama >/dev/null 2>&1 && OLLAMA_PRESENT=1
[ -d /Applications/Ollama.app ]  && OLLAMA_PRESENT=1
command -v ollama >/dev/null 2>&1 && OLLAMA_PRESENT=1

if [ "$OLLAMA_PRESENT" -eq 0 ]; then
    ok "Ollama not installed — nothing to do."
else
    if ask "Uninstall Ollama itself? (models handled separately in step 4)"; then
        # 3a. stop whatever service is running first
        if brew services list 2>/dev/null | grep -q "^ollama.*started"; then
            brew services stop ollama && ok "brew service stopped."
        fi
        # LAN LaunchAgent created by install.sh, if any
        LAN_PLIST="$HOME/Library/LaunchAgents/local.ollama.lan.plist"
        if [ -f "$LAN_PLIST" ]; then
            launchctl bootout "gui/$(id -u)" "$LAN_PLIST" 2>/dev/null
            rm -f "$LAN_PLIST" && ok "LAN LaunchAgent removed."
        fi
        osascript -e 'quit app "Ollama"' 2>/dev/null || true
        pkill -f "ollama serve" 2>/dev/null || true
        sleep 1

        # 3b. remove the brew formula if present
        if brew list ollama >/dev/null 2>&1; then
            brew uninstall ollama && ok "Brew formula removed." || fail "brew uninstall failed."
        fi
        # 3c. remove the standalone .app if present
        if [ -d /Applications/Ollama.app ]; then
            rm -rf /Applications/Ollama.app
            rm -rf ~/Library/Application\ Support/Ollama \
                   ~/Library/Caches/com.electron.ollama \
                   ~/Library/Preferences/com.electron.ollama.plist \
                   ~/Library/Saved\ Application\ State/com.electron.ollama.savedState
            ok "Ollama.app and its support files removed."
        fi
        # 3d. leftover symlink from the .app installer
        if [ -L /usr/local/bin/ollama ]; then
            sudo rm -f /usr/local/bin/ollama && ok "Removed /usr/local/bin/ollama symlink."
        fi
    else
        ok "Keeping Ollama."
    fi
fi

# ---------- Step 4: Ollama data directory (destructive) ----------------------
info "Step 4/6 — Ollama data directory (~/.ollama)"
if [ -d "$HOME/.ollama" ]; then
    OSIZE=$(du -sh "$HOME/.ollama" 2>/dev/null | cut -f1)
    warn "~/.ollama holds ALL downloaded models and your Ollama keys (${OSIZE})."
    warn "This is DESTRUCTIVE and not recoverable — models would need re-downloading."
    if ask "Permanently delete ~/.ollama (${OSIZE})?"; then
        if ask "Are you sure? This deletes every model in one go."; then
            rm -rf "$HOME/.ollama" && ok "~/.ollama deleted." || fail "Deletion failed."
        else
            ok "Keeping ~/.ollama."
        fi
    else
        ok "Keeping ~/.ollama."
    fi
else
    ok "~/.ollama does not exist — nothing to do."
fi

# ---------- Step 5: uv (foundation — only after its dependents) --------------
info "Step 5/6 — uv"
if command -v uv >/dev/null 2>&1 && brew list uv >/dev/null 2>&1; then
    REMAINING=$(uv tool list 2>/dev/null | grep -c '^[a-zA-Z]' || true)
    if [ "${REMAINING:-0}" -gt 0 ]; then
        warn "uv still manages ${REMAINING} installed tool(s):"
        uv tool list 2>/dev/null | sed 's/^/    /'
    fi
    if ask "Uninstall uv?"; then
        brew uninstall uv && ok "uv removed." || fail "uv removal failed."
    else
        ok "Keeping uv."
    fi
else
    ok "uv not brew-installed — nothing to do."
fi

# ---------- Step 6: Homebrew (deliberately untouched) ------------------------
info "Step 6/6 — Homebrew"
ok "Homebrew is left untouched — it likely manages software beyond this stack."
echo "    (If you truly want it gone, see https://github.com/homebrew/install#uninstall-homebrew)"

# ---------- summary ----------------------------------------------------------
echo
echo "${BOLD}================= Uninstall summary =================${RESET}"
command -v ollama >/dev/null 2>&1 && warn "Ollama:  still installed ($(ollama --version 2>/dev/null))" || ok "Ollama:  removed"
[ -d "$HOME/.ollama" ]            && warn "Models:  ~/.ollama still present ($(du -sh "$HOME/.ollama" 2>/dev/null | cut -f1))" || ok "Models:  removed"
{ command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q mlx-lm; } \
                                  && warn "mlx-lm:  still installed" || ok "mlx-lm:  removed"
command -v uv >/dev/null 2>&1     && warn "uv:      still installed" || ok "uv:      removed"
echo
echo "Done."
