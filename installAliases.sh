#!/bin/bash
#
# installAliases.sh — make the toolkit's step functions available in every new
#                     login shell, by sourcing shellFunctions.sh from your rc.
#
# Unlike the other root scripts this is NOT an OS dispatcher: editing ~/.zshrc
# or ~/.bashrc is the same work on every platform, and a per-OS copy would only
# be a second place to fix the same bug.
#
#   ./installAliases.sh            # add the block (asks first, backs up the rc)
#   ./installAliases.sh --remove   # take it out again
#
# It is idempotent: the block is delimited by markers, so re-running replaces
# it rather than stacking duplicates.
#
set -u

BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

# Print a progress heading for the step being performed.
info()  { echo "${BLUE}==>${RESET} $*"; }
# Print a success line — also used for "already correct", so a re-run reads the
# same whether it changed anything or not.
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
# Print a caution line: something skipped, or a caveat worth reading.
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
# Print an error line for something that was attempted and failed.
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

# Ask a yes/no question where Enter picks the caller's default.
# Args: <question> <y|n>. Reads /dev/tty so it works with piped output, and
# treats a missing terminal as the default rather than hanging.
ask_def() {
    if [ $# -lt 2 ]; then
        aiStackUsage "ask_def <question> <y|n>" "example : ask_def "Install it?" y"
        return 2
    fi
    local answer hint
    [ "$2" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    printf "\n%s%s%s %s " "${BOLD}" "$1" "${RESET}" "$hint"
    read -r answer </dev/tty 2>/dev/null || answer=""
    case "${answer:-$2}" in [Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BEGIN="# >>> MyAiStack >>>"
END="# <<< MyAiStack <<<"
# the project was called MyAiStack before; an rc written back then is
# still cleaned up, so a rename cannot leave two blocks behind
LEGACY_BEGIN="# >>> AI_Code_generator >>>"
LEGACY_END="# <<< AI_Code_generator <<<"

# Which rc files to touch: the one for your login shell, plus any other that
# already exists, so the functions are there whichever shell you land in.
# Prints one path per line.
rcCandidates() {
    local login_shell
    login_shell=$(basename "${SHELL:-/bin/zsh}")
    case "$login_shell" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        *)    echo "$HOME/.zshrc" ;;
    esac
    [ -f "$HOME/.zshrc" ]  && echo "$HOME/.zshrc"
    [ -f "$HOME/.bashrc" ] && echo "$HOME/.bashrc"
}

# The block written into an rc file: two lines, guarded so a missing repo (or a
# machine where the checkout has moved) degrades to doing nothing.
# Args: none. Prints the block on stdout.
rcBlock() {
    cat <<BLOCK
${BEGIN}
export AI_STACK_HOME="${REPO}"
[ -f "\${AI_STACK_HOME}/shellFunctions.sh" ] && . "\${AI_STACK_HOME}/shellFunctions.sh"
${END}
BLOCK
}

# Remove any existing block from one rc file, in place.
# Args: <rc file>. Leaves the file untouched when no block is present, so it is
# safe to call before writing a fresh one.
rcStrip() {
    if [ $# -lt 1 ]; then
        aiStackUsage "rcStrip <rc-file>" "rc-file : e.g. ~/.zshrc — removes this project's block, leaves the rest" "example : rcStrip ~/.zshrc"
        return 2
    fi
    local rc="$1"
    [ -f "$rc" ] || return 0
    grep -qE "^(${BEGIN}|${LEGACY_BEGIN})$" "$rc" 2>/dev/null || return 0
    python3 - "$rc" "$BEGIN" "$END" "$LEGACY_BEGIN" "$LEGACY_END" <<'PYEOF'
import sys
rc, begin, end, lbegin, lend = sys.argv[1:6]
out, skip = [], False
for line in open(rc):
    s = line.rstrip("\n")
    if s in (begin, lbegin): skip = True; continue
    if s in (end, lend):     skip = False; continue
    if not skip:             out.append(line)
while out and out[-1].strip() == "": out.pop()
open(rc, "w").write("".join(out) + ("\n" if out else ""))
PYEOF
}

# Add (or refresh) the block in one rc file, after backing the file up.
# Args: <rc file>. Existing blocks are replaced rather than duplicated, which
# is what makes re-running this script safe.
rcInstall() {
    if [ $# -lt 1 ]; then
        aiStackUsage "rcInstall <rc-file>" "rc-file : e.g. ~/.zshrc — backs it up, then writes the block" "example : rcInstall ~/.zshrc"
        return 2
    fi
    local rc="$1"
    if [ -f "$rc" ]; then
        cp "$rc" "${rc}.aiStack.bak"
        ok "Backed up $(basename "$rc") -> $(basename "$rc").aiStack.bak"
    else
        touch "$rc"
    fi
    rcStrip "$rc"
    { [ -s "$rc" ] && echo ""; rcBlock; } >> "$rc"
    ok "Wired into ${rc}"
}

# --- remove mode --------------------------------------------------------------
if [ "${1:-}" = "--remove" ]; then
    info "installAliases.sh --remove — taking the block out of your shell rc"
    found=0
    for rc in $(rcCandidates | sort -u); do
        if [ -f "$rc" ] && grep -qE "^(${BEGIN}|${LEGACY_BEGIN})$" "$rc" 2>/dev/null; then
            cp "$rc" "${rc}.aiStack.bak"
            rcStrip "$rc"
            ok "Removed from ${rc} (backup: $(basename "$rc").aiStack.bak)"
            found=1
        fi
    done
    [ "$found" -eq 0 ] && ok "Nothing to remove — no block found."
    echo
    echo "    Open a new shell (or: exec \$SHELL) for it to take effect."
    exit 0
fi

# --- install mode -------------------------------------------------------------
echo "${BOLD}=============================================================${RESET}"
echo "${BOLD} Make the AI stack functions available in every shell${RESET}"
echo "${BOLD}=============================================================${RESET}"

if [ ! -f "${REPO}/shellFunctions.sh" ]; then
    fail "shellFunctions.sh not found next to this script (${REPO})."
    exit 1
fi

# what the user gets, stated before anything is changed
COUNT=$(AI_STACK_HOME="$REPO" bash -c '. "$0/shellFunctions.sh" >/dev/null 2>&1; echo $AI_STACK_FUNCS' "$REPO" | wc -w | tr -d ' ')
info "Repo: ${REPO}"
if [ "${COUNT:-0}" -gt 0 ]; then
    ok "${COUNT} step functions would become available (aistackInstall*, uninstallAiStack*, aistackLaunchInference*, aiModelTest*, testAllAiModels, noRole, aiStackHelp)."
else
    warn "No functions resolved — this OS may have no implementations yet."
fi

echo
echo "    This appends to your shell rc:"
rcBlock | sed 's/^/      /'
echo
warn "Nothing is sourced into your shell itself: each call runs in its own"
warn "bash process, so helper names like ok/warn/fail never reach your session."

TARGETS=$(rcCandidates | sort -u)
echo
echo "    Files to update:"
for rc in $TARGETS; do
    if [ -f "$rc" ] && grep -qE "^(${BEGIN}|${LEGACY_BEGIN})$" "$rc" 2>/dev/null; then
        echo "      ${rc}  (existing block will be replaced)"
    else
        echo "      ${rc}"
    fi
done

if ! ask_def "Add it now?" "y"; then
    warn "Nothing changed. You can still source it per-shell:"
    echo "      AI_STACK_HOME='${REPO}' . '${REPO}/shellFunctions.sh'"
    exit 0
fi

for rc in $TARGETS; do rcInstall "$rc"; done

echo
ok "Done. Start a new shell, or run:"
echo "      exec \$SHELL"
echo "    then:"
echo "      aiStackHelp"
echo
echo "    To undo:  ${REPO}/installAliases.sh --remove"
