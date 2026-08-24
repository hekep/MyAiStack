#!/bin/bash
#
# noCodexRole.sh — remove OpenAI Codex (CLI/app) and all its traces
#
# PROTECTED: the ChatGPT application and its data remain untouched:
#   - /Applications/ChatGPT.app
#   - ~/Library/Application Support/com.openai.chat   (ChatGPT container)
#   - ~/Library/Application Support/ChatGPT
#   - ~/Library/Caches/com.openai.chat, WebKit, prefs, ChatGPTHelper
#
# Interactive: asks before EVERY removal, raw -> surgical, and reports
# disk space gained after each confirmed step.
#
#   1. Stop running Codex processes
#   2. Uninstall Codex package/binary (npm / brew / manual) if present
#   3. ~/.cache/codex-runtimes            (~1.6 GB — biggest chunk)
#   4. ~/.codex                           (~550 MB — auth, config, memories)
#   5. Codex-specific ~/Library traces    (caches, prefs, logs, cookies)
#   6. [grey zone] Codex task data INSIDE ChatGPT's container — default: keep
#   7. [grey zone] VS Code 'openai.chatgpt' (Codex) extensions — default: keep
#   8. Keychain entries                   (frees no space — default: keep)
#   9. Final trace scan
#
set -u

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

# Print a progress heading ("==> ...").
# All narration goes through these four helpers so colour handling and
# stream choice stay in one place.
info()  { echo "${BLUE}==>${RESET} $*"; }
# Print a success line (green check).
# Used for both "did it" and "already true", since a re-run should read the
# same whether the work happened now or earlier.
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
# Print a caution line (yellow !) — something worth reading, not a failure.
# Also used for "skipped by your choice", so the transcript records decisions.
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
# Print an error line (red x).
# Only for things that did not work; a declined question is a warn, not a fail.
fail()  { echo "${RED} ✗ ${RESET} $*"; }

# Ask a yes/no question on the terminal and loop until the answer is clear.
# Reads from /dev/tty so piping stdout does not break the prompt.
# Returns 0 for yes, 1 for no; no Enter-default, since every step here deletes
# something.
ask() {
    local answer
    while true; do
        printf "\n%s%s%s [y/n] " "${BOLD}" "$1" "${RESET}"
        read -r answer </dev/tty || { echo; fail "No interactive terminal — aborting."; exit 1; }
        case "$answer" in
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Human-readable size of a file or directory ('du -sh').
# Args: <path>. Empty output for a missing path, so prompts stay readable.
sizeof() { du -sh "$1" 2>/dev/null | cut -f1; }

# Free space on the data volume in KB, as an integer.
# The before/after probe for gain(); df reflects what was really released.
free_kb() { df -k /System/Volumes/Data | awk 'NR==2 {print $4}'; }
# Free space on the data volume, human-readable (e.g. "114Gi").
# Display only — free_kb() is what the arithmetic uses.
free_h()  { df -h /System/Volumes/Data | awk 'NR==2 {print $4}'; }
START_KB=$(free_kb)

# Report how much disk a step actually freed.
# Args: <free_kb before the step>. Prints GB / MB / negligible and the new
# free total. Keychain steps legitimately report ~0: they hold no disk space.
gain() {
    local d=$(( $(free_kb) - $1 ))
    [ "$d" -lt 0 ] && d=0
    if [ "$d" -ge 1048576 ]; then
        ok "Space gained: $(awk -v k="$d" 'BEGIN{printf "%.1f GB", k/1048576}')  (free now: $(free_h))"
    elif [ "$d" -ge 1024 ]; then
        ok "Space gained: $(( d / 1024 )) MB  (free now: $(free_h))"
    else
        ok "Space gained: negligible (<1 MB)  (free now: $(free_h))"
    fi
}

echo "${BOLD}=============================================================${RESET}"
echo "${BOLD} noCodexRole — remove OpenAI Codex, keep ChatGPT${RESET}"
echo "${BOLD}=============================================================${RESET}"
[ -d /Applications/ChatGPT.app ] && ok "Protected: /Applications/ChatGPT.app"
ok "Protected: ChatGPT data (com.openai.chat, ChatGPT app support, caches)"

# ---------- Step 1: stop running Codex processes -----------------------------
info "Step 1/9 — Stop running Codex processes"
if pgrep -if "codex" >/dev/null 2>&1; then
    warn "Codex processes running:"
    pgrep -lif "codex" | sed 's/^/    /' | head -5
    if ask "Stop all Codex processes?"; then
        pkill -f "codex" 2>/dev/null; sleep 1
        pkill -9 -f "codex" 2>/dev/null || true
        pgrep -if "codex" >/dev/null 2>&1 && fail "Some survived." || ok "Stopped."
    fi
else
    ok "No Codex processes running."
fi

# ---------- Step 2: the Codex package/binary itself --------------------------
info "Step 2/9 — Codex CLI / application"
FOUND_INSTALL=0
if command -v codex >/dev/null 2>&1; then
    FOUND_INSTALL=1
    CODEX_BIN=$(command -v codex)
    warn "codex binary on PATH: $CODEX_BIN"
    if npm ls -g @openai/codex >/dev/null 2>&1; then
        ask "Uninstall @openai/codex (npm -g)?" && { B=$(free_kb); npm uninstall -g @openai/codex && { ok "npm package removed."; gain "$B"; }; }
    elif brew list codex >/dev/null 2>&1; then
        ask "Uninstall codex (brew)?" && { B=$(free_kb); brew uninstall codex && { ok "brew formula removed."; gain "$B"; }; }
    else
        ask "Delete the binary $CODEX_BIN?" && { B=$(free_kb); rm -f "$CODEX_BIN" 2>/dev/null || sudo rm -f "$CODEX_BIN"; gain "$B"; }
    fi
fi
if [ -d "/Applications/Codex.app" ]; then
    FOUND_INSTALL=1
    ask "Delete /Applications/Codex.app ($(sizeof /Applications/Codex.app))?" && { B=$(free_kb); rm -rf /Applications/Codex.app; gain "$B"; }
fi
[ "$FOUND_INSTALL" -eq 0 ] && ok "No Codex binary/app installed (already removed) — proceeding to leftover data."

# ---------- Step 3: runtime cache (biggest chunk) ----------------------------
info "Step 3/9 — Codex runtime cache"
if [ -d "$HOME/.cache/codex-runtimes" ]; then
    if ask "Delete ~/.cache/codex-runtimes ($(sizeof "$HOME/.cache/codex-runtimes"))?"; then
        B=$(free_kb)
        rm -rf "$HOME/.cache/codex-runtimes" && { ok "Runtime cache deleted."; gain "$B"; } || fail "Deletion failed."
    fi
else
    ok "~/.cache/codex-runtimes not present."
fi

# ---------- Step 4: ~/.codex (auth, config, memories, logs) ------------------
info "Step 4/9 — Codex user data (~/.codex)"
if [ -d "$HOME/.codex" ]; then
    warn "Contains auth.json (login tokens), config.toml, plugins, memories and log databases ($(sizeof "$HOME/.codex"))."
    warn "Deleting logs you out of Codex permanently on this machine (ChatGPT login is separate and unaffected)."
    if ask "Delete ~/.codex ($(sizeof "$HOME/.codex"))?"; then
        B=$(free_kb)
        rm -rf "$HOME/.codex" && { ok "~/.codex deleted."; gain "$B"; } || fail "Deletion failed."
    fi
else
    ok "~/.codex not present."
fi

# ---------- Step 5: Codex-specific Library traces ----------------------------
info "Step 5/9 — Codex traces in ~/Library (ChatGPT data excluded)"
TRACES=()
for d in "$HOME/Library/Caches/Codex" \
         "$HOME/Library/Caches/com.openai.codex" \
         "$HOME/Library/Application Support/Codex" \
         "$HOME/Library/Application Support/com.openai.codex" \
         "$HOME/Library/Application Support/OpenAI/Codex" \
         "$HOME/Library/Preferences/com.openai.codex.plist" \
         "$HOME/Library/HTTPStorages/com.openai.codex" \
         "$HOME/Library/HTTPStorages/com.openai.codex.binarycookies" \
         "$HOME/Library/Logs/com.openai.codex" \
         "$HOME/Library/Saved Application State/com.openai.codex.savedState" \
         "$HOME/Library/WebKit/com.openai.codex"; do
    [ -e "$d" ] && TRACES+=("$d")
done
if [ ${#TRACES[@]} -gt 0 ]; then
    echo "    Found Codex-specific traces:"
    for t in "${TRACES[@]}"; do echo "      $(sizeof "$t")	$t"; done
    if ask "Remove all ${#TRACES[@]} Codex trace items?"; then
        B=$(free_kb)
        for t in "${TRACES[@]}"; do
            rm -rf "$t" && ok "Removed ${t#$HOME/}" || fail "Could not remove $t"
        done
        gain "$B"
    fi
else
    ok "No Codex-specific Library traces found."
fi

# ---------- Step 6: GREY ZONE — Codex task data inside ChatGPT ---------------
info "Step 6/9 — Codex task data INSIDE ChatGPT's container (grey zone)"
CHATGPT_CODEX=()
while IFS= read -r -d '' p; do CHATGPT_CODEX+=("$p"); done < <(find "$HOME/Library/Application Support/com.openai.chat" -maxdepth 1 -iname "codex-*" -print0 2>/dev/null)
if [ ${#CHATGPT_CODEX[@]} -gt 0 ]; then
    warn "These live inside ChatGPT's own data and power its Codex-tasks view:"
    for t in "${CHATGPT_CODEX[@]}"; do echo "      $(sizeof "$t")	${t#$HOME/}"; done
    warn "RECOMMENDED: KEEP — deleting may confuse the ChatGPT app you want to keep."
    if ask "Delete Codex task data from inside ChatGPT anyway?"; then
        B=$(free_kb)
        for t in "${CHATGPT_CODEX[@]}"; do rm -rf "$t" && ok "Removed ${t#$HOME/}"; done
        gain "$B"
    else
        ok "Keeping ChatGPT's Codex task data (recommended)."
    fi
else
    ok "None found."
fi

# ---------- Step 7: GREY ZONE — VS Code extension ----------------------------
info "Step 7/9 — VS Code 'openai.chatgpt' extension (this IS the Codex/ChatGPT IDE extension)"
VSC_EXT=( "$HOME"/.vscode/extensions/openai.chatgpt-* )
if [ -e "${VSC_EXT[0]}" ]; then
    N=${#VSC_EXT[@]}
    TOTAL=$(du -shc "${VSC_EXT[@]}" 2>/dev/null | tail -1 | cut -f1)
    warn "Found ${N} installed version(s) of the OpenAI ChatGPT/Codex VS Code extension (${TOTAL} total)."
    warn "It is branded ChatGPT — if you use it in VS Code, KEEP it."
    if ask "Remove ALL ${N} versions of the extension (${TOTAL})?"; then
        B=$(free_kb)
        rm -rf "${VSC_EXT[@]}" && ok "All versions removed."
        gain "$B"
    elif [ "$N" -gt 1 ] && ask "Keep only the newest version and delete the $(( N - 1 )) older duplicates?"; then
        B=$(free_kb)
        NEWEST=$(printf '%s\n' "${VSC_EXT[@]}" | sort -V | tail -1)
        for e in "${VSC_EXT[@]}"; do
            [ "$e" = "$NEWEST" ] && continue
            rm -rf "$e" && ok "Removed old $(basename "$e")"
        done
        ok "Kept $(basename "$NEWEST")."
        gain "$B"
    else
        ok "Keeping the extension."
    fi
else
    ok "No openai.chatgpt VS Code extensions found."
fi

# ---------- Step 8: keychain entries (frees no space) ------------------------
info "Step 8/9 — Keychain entries"
KC_HITS=$(security dump-keychain 2>/dev/null | grep -i 'codex' | grep '"svce"' | sed 's/.*"\([^"]*\)"$/\1/' | sort -u)
if [ -n "$KC_HITS" ]; then
    echo "    Keychain items referencing Codex:"
    echo "$KC_HITS" | sed 's/^/      /'
    warn "Frees no disk space. Keeping them avoids re-login if you ever reinstall."
    if ask "Delete these keychain entries anyway (frees no space)?"; then
        echo "$KC_HITS" | while read -r svc; do
            security delete-generic-password -s "$svc" >/dev/null 2>&1 \
                && ok "Deleted keychain item: $svc" \
                || warn "Could not delete: $svc (remove manually in Keychain Access)"
        done
    else
        ok "Keeping keychain entries."
    fi
else
    ok "No Codex keychain entries found."
fi

# ---------- Step 9: final trace scan -----------------------------------------
info "Step 9/9 — Final trace scan (ChatGPT items excluded)"
LEFT=$( { ls -d "$HOME/.codex" "$HOME/.cache/codex-runtimes" /Applications/Codex.app 2>/dev/null;
          find "$HOME/Library" -maxdepth 3 -iname "*codex*" 2>/dev/null;
          command -v codex 2>/dev/null;
        } | grep -v "com.openai.chat/" | sort -u )
if [ -z "$LEFT" ]; then
    ok "CLEAN — no Codex traces found outside ChatGPT."
else
    warn "Remaining items (kept by your choices above, or need manual review):"
    echo "$LEFT" | sed 's/^/      /'
fi

# ---------- summary ----------------------------------------------------------
echo
echo "${BOLD}================= Space summary =================${RESET}"
TOTAL_D=$(( $(free_kb) - START_KB ))
[ "$TOTAL_D" -lt 0 ] && TOTAL_D=0
if [ "$TOTAL_D" -ge 1048576 ]; then
    ok "Total space gained this run: $(awk -v k="$TOTAL_D" 'BEGIN{printf "%.1f GB", k/1048576}')"
else
    ok "Total space gained this run: $(( TOTAL_D / 1024 )) MB"
fi
ok "Free space now: $(free_h)"
echo
[ -d /Applications/ChatGPT.app ] && ok "ChatGPT.app: still installed (protected)"
[ -d "$HOME/Library/Application Support/com.openai.chat" ] && ok "ChatGPT data: intact (protected)"
echo "${BOLD}Done.${RESET}"
