#!/bin/bash
#
# noCodexRole.sh — remove OpenAI Codex (CLI) and all its traces, on Debian
#
# Interactive: asks before EVERY removal, raw -> surgical, and reports disk
# space gained after each confirmed step.
#
#   1. Stop running Codex processes
#   2. Uninstall the Codex CLI                 (npm / binary / snap)
#   3. ~/.cache/codex-runtimes                 (usually the biggest chunk)
#   4. ~/.codex                                (auth, config, memories, logs)
#   5. XDG traces: ~/.config, ~/.local/share, ~/.local/state, ~/.cache
#   6. [grey zone] VS Code 'openai.chatgpt' extension — default: keep
#   7. Secret-service entries                  (frees no space — default: keep)
#   8. Final trace scan
#
# WHAT IS DIFFERENT FROM macOS, and why this script is shorter:
#
# On macOS the hard part is disentangling Codex from ChatGPT — they share the
# com.openai.* namespace, Codex task data lives INSIDE ChatGPT's container, and
# a careless "*openai*" delete takes the ChatGPT app with it. On Linux there is
# no official ChatGPT desktop application at all, so that entanglement does not
# exist and those two steps have nothing to protect. What remains is the CLI,
# its XDG directories, and the VS Code extension — which IS still branded
# ChatGPT and is still a grey zone, so it keeps its own step and its default of
# keeping. Any unofficial ChatGPT client (snap, flatpak, AppImage) is detected
# and reported as protected rather than assumed absent.
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

# Ask a yes/no question on the terminal and loop until the answer is clear.
# Reads from /dev/tty so piping stdout does not break the prompt.
# Returns 0 for yes, 1 for no; no Enter-default, since every step here deletes
# something.
ask() {
    if [ $# -lt 1 ]; then
        aiStackUsage "ask <question>" "no default — every step here deletes something" "example : ask \"Delete ~/.codex?\""
        return 2
    fi
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

# Run one privileged command; only needed for a binary outside $HOME.
_asRoot() {
    if [ "$(id -u)" = "0" ]; then "$@"; return $?; fi
    command -v sudo >/dev/null 2>&1 || { fail "sudo is required for: $*"; return 1; }
    sudo "$@"
}

# Human-readable size of a file or directory ('du -sh').
# Args: <path>. Empty output for a missing path, so prompts stay readable.
sizeof() { [ $# -ge 1 ] || { aiStackUsage "sizeof <path>" "example : sizeof ~/.codex"; return 2; }; du -sh "$1" 2>/dev/null | cut -f1; }

# Free space in KB on the filesystem holding a path. Args: [path] (default $HOME).
# Everything Codex leaves behind is under $HOME, so unlike the Docker purge one
# filesystem answers for the whole run.
free_kb() { df -k --output=avail "${1:-$HOME}" 2>/dev/null | awk 'NR==2 {print $1}'; }
# Free space on that filesystem, human-readable. Display only.
free_h()  { df -h --output=avail "${1:-$HOME}" 2>/dev/null | awk 'NR==2 {print $1}'; }
START_KB=$(free_kb)

# Report how much disk a step actually freed.
# Args: <free_kb before the step>. Prints GB / MB / negligible and the new
# free total. Credential steps legitimately report ~0: they hold no disk space.
gain() {
    if [ $# -lt 1 ]; then
        aiStackUsage "gain <free-kb-before>" 'example : b=$(free_kb); rm -rf something; gain "$b"'
        return 2
    fi
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
echo "${BOLD} noCodexRole — remove OpenAI Codex from this system${RESET}"
echo "${BOLD}=============================================================${RESET}"

# There is no official ChatGPT desktop app for Linux, so unlike the macOS
# version there is usually nothing to protect. Unofficial clients do exist,
# and they are named here rather than silently swept up by a *openai* match.
CHATGPT_FOUND=0
if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -qi chatgpt; then
    ok "Protected: ChatGPT snap ($(snap list 2>/dev/null | grep -i chatgpt | awk '{print $1}'))"
    CHATGPT_FOUND=1
fi
if command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -qi chatgpt; then
    ok "Protected: ChatGPT flatpak"
    CHATGPT_FOUND=1
fi
for d in "$HOME/.config/ChatGPT" "$HOME/.config/chatgpt" "$HOME/.local/share/ChatGPT"; do
    [ -d "$d" ] && { ok "Protected: ${d} ($(sizeof "$d"))"; CHATGPT_FOUND=1; }
done
[ "$CHATGPT_FOUND" -eq 0 ] && ok "No ChatGPT client found — there is no official one for Linux, so nothing to protect."

# ---------- Step 1: stop running Codex processes -----------------------------
info "Step 1/8 — Stop running Codex processes"
if pgrep -f "(^|/)codex( |$)" >/dev/null 2>&1; then
    warn "Codex processes running:"
    pgrep -alf "(^|/)codex( |$)" | sed 's/^/    /' | head -5
    if ask "Stop all Codex processes?"; then
        pkill -f "(^|/)codex( |$)" 2>/dev/null; sleep 1
        pkill -9 -f "(^|/)codex( |$)" 2>/dev/null || true
        pgrep -f "(^|/)codex( |$)" >/dev/null 2>&1 && fail "Some survived." || ok "Stopped."
    fi
else
    ok "No Codex processes running."
fi

# ---------- Step 2: the Codex CLI itself -------------------------------------
info "Step 2/8 — Codex CLI"
FOUND_INSTALL=0
if command -v codex >/dev/null 2>&1; then
    FOUND_INSTALL=1
    CODEX_BIN=$(command -v codex)
    warn "codex binary on PATH: $CODEX_BIN"
    if command -v npm >/dev/null 2>&1 && npm ls -g @openai/codex >/dev/null 2>&1; then
        ask "Uninstall @openai/codex (npm -g)?" && { B=$(free_kb); npm uninstall -g @openai/codex && { ok "npm package removed."; gain "$B"; }; }
    elif command -v snap >/dev/null 2>&1 && snap list codex >/dev/null 2>&1; then
        ask "snap remove codex?" && { B=$(free_kb /var); _asRoot snap remove codex && { ok "Snap removed."; gain "$B" /var; }; }
    else
        ask "Delete the binary $CODEX_BIN?" && {
            B=$(free_kb)
            rm -f "$CODEX_BIN" 2>/dev/null || _asRoot rm -f "$CODEX_BIN"
            gain "$B"
        }
    fi
fi
[ "$FOUND_INSTALL" -eq 0 ] && ok "No Codex binary installed (already removed) — proceeding to leftover data."

# ---------- Step 3: runtime cache (usually the biggest chunk) ----------------
info "Step 3/8 — Codex runtime cache"
if [ -d "$HOME/.cache/codex-runtimes" ]; then
    if ask "Delete ~/.cache/codex-runtimes ($(sizeof "$HOME/.cache/codex-runtimes"))?"; then
        B=$(free_kb)
        rm -rf "$HOME/.cache/codex-runtimes" && { ok "Runtime cache deleted."; gain "$B"; } || fail "Deletion failed."
    fi
else
    ok "~/.cache/codex-runtimes not present."
fi

# ---------- Step 4: ~/.codex (auth, config, memories, logs) ------------------
info "Step 4/8 — Codex user data (~/.codex)"
if [ -d "$HOME/.codex" ]; then
    warn "Contains auth.json (login tokens), config.toml, plugins, memories and log databases ($(sizeof "$HOME/.codex"))."
    warn "Deleting logs you out of Codex permanently on this machine."
    if ask "Delete ~/.codex ($(sizeof "$HOME/.codex"))?"; then
        B=$(free_kb)
        rm -rf "$HOME/.codex" && { ok "~/.codex deleted."; gain "$B"; } || fail "Deletion failed."
    fi
else
    ok "~/.codex not present."
fi

# ---------- Step 5: XDG traces -----------------------------------------------
# The Linux counterpart of the macOS ~/Library sweep. Only paths whose LAST
# component names Codex are listed: a bare "openai" match would be exactly the
# careless delete this script exists to avoid.
info "Step 5/8 — Codex traces in the XDG directories"
TRACES=()
for d in "$HOME/.config/codex" "$HOME/.config/openai/codex" \
         "$HOME/.local/share/codex" "$HOME/.local/share/openai/codex" \
         "$HOME/.local/state/codex" "$HOME/.cache/codex" \
         "$HOME/.config/Codex" "$HOME/.local/share/Codex"; do
    [ -e "$d" ] && TRACES+=("$d")
done
if [ ${#TRACES[@]} -gt 0 ]; then
    echo "    Found Codex-specific traces:"
    for t in "${TRACES[@]}"; do echo "      $(sizeof "$t")	$t"; done
    if ask "Remove all ${#TRACES[@]} Codex trace items?"; then
        B=$(free_kb)
        for t in "${TRACES[@]}"; do
            rm -rf "$t" && ok "Removed ${t#"$HOME"/}" || fail "Could not remove $t"
        done
        gain "$B"
    fi
else
    ok "No Codex-specific XDG traces found."
fi

# ---------- Step 6: GREY ZONE — VS Code extension ----------------------------
# Kept from the macOS version because the ambiguity is identical: the extension
# is branded ChatGPT but IS the Codex IDE extension. Both the desktop VS Code
# path and the Remote-SSH server path are checked, since a Linux box is often
# the server end of somebody else's editor.
info "Step 6/8 — VS Code 'openai.chatgpt' extension (this IS the Codex/ChatGPT IDE extension)"
VSC_EXT=()
for base in "$HOME/.vscode/extensions" "$HOME/.vscode-server/extensions" \
            "$HOME/.vscode-oss/extensions" "$HOME/.var/app/com.visualstudio.code/data/vscode/extensions"; do
    [ -d "$base" ] || continue
    while IFS= read -r -d '' e; do VSC_EXT+=("$e"); done < <(find "$base" -maxdepth 1 -name "openai.chatgpt-*" -print0 2>/dev/null)
done
if [ ${#VSC_EXT[@]} -gt 0 ]; then
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

# ---------- Step 7: secret-service entries (frees no space) ------------------
info "Step 7/8 — Stored credentials (secret service / keyring)"
if command -v secret-tool >/dev/null 2>&1; then
    KC_HITS=$(secret-tool search --all service codex 2>/dev/null | head -20)
    if [ -n "$KC_HITS" ]; then
        echo "    Keyring items referencing Codex:"
        echo "$KC_HITS" | sed 's/^/      /'
        warn "Frees no disk space. Keeping them avoids re-login if you ever reinstall."
        if ask "Delete these keyring entries anyway (frees no space)?"; then
            secret-tool clear service codex 2>/dev/null \
                && ok "Entries cleared." \
                || warn "Could not clear them — remove them in Seahorse / your keyring app."
        else
            ok "Keeping the keyring entries."
        fi
    else
        ok "No Codex entries in the secret service."
    fi
else
    ok "secret-tool not installed — nothing to check (Codex stores its token in ~/.codex/auth.json)."
fi

# ---------- Step 8: final trace scan -----------------------------------------
info "Step 8/8 — Final trace scan"
LEFT=$( { ls -d "$HOME/.codex" "$HOME/.cache/codex-runtimes" 2>/dev/null;
          find "$HOME/.config" "$HOME/.local/share" "$HOME/.local/state" "$HOME/.cache" \
               -maxdepth 2 -iname "*codex*" 2>/dev/null;
          command -v codex 2>/dev/null;
        } | sort -u )
if [ -z "$LEFT" ]; then
    ok "CLEAN — no Codex traces found."
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
[ "$CHATGPT_FOUND" -eq 1 ] && ok "Your ChatGPT client and its data were not touched."
echo "${BOLD}Done.${RESET}"
