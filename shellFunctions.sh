#!/bin/bash
#
# shellFunctions.sh — expose the toolkit's step functions to an interactive
#                     shell, without polluting it.
#
# Sourced from ~/.zshrc or ~/.bashrc by installAliases.sh. After that, every
# public step is callable from anywhere:
#
#   aistackInstallOllamaModels      # just the Ollama download menu
#   aistackLaunchInferenceKillPrevious     # free the GPU without a full launch
#   aistackModelTest Ollama qwen3.6:35b-a3b
#   aistackUninstallPiCodingAgent
#   aistackHelp                     # list everything that is available
#
# Two things it deliberately does NOT do:
#
#   * It does not source the scripts into your shell. They define helpers named
#     ok, warn, fail, ask and info — sourcing those would shadow anything else
#     by those names in your session. Each call runs in its own process, so
#     only the prefixed names ever exist here.
#   * It does not run them in zsh. These are bash scripts, and zsh arrays are
#     1-indexed, which would silently pick the wrong item in every menu. Every
#     wrapper executes the real function under bash regardless of your shell.
#
# AI_STACK_HOME must point at the repo; installAliases.sh writes it into the rc.

# Running this file does nothing useful: the functions would be defined inside a
# child process that exits immediately. Detect that and say so.
# The test differs per shell — zsh sets $0 to the sourced file, so comparing $0
# would wrongly fire on a legitimate "source" and exit the user's login shell.
_sf_executed=1
if [ -n "${BASH_VERSION:-}" ]; then
    [ "${BASH_SOURCE[0]}" != "$0" ] && _sf_executed=0
elif [ -n "${ZSH_VERSION:-}" ]; then
    # sourced -> ZSH_EVAL_CONTEXT contains "file"; executed -> "toplevel" alone
    case "${ZSH_EVAL_CONTEXT:-}" in *file*) _sf_executed=0 ;; esac
fi
if [ "$_sf_executed" = "1" ]; then
    _sf_dir="$(cd "$(dirname "$0")" && pwd)"
    echo "shellFunctions.sh must be SOURCED, not executed —"
    echo "otherwise its functions are defined in a child process that exits."
    echo
    echo "  For this shell only:"
    echo "      source ${_sf_dir}/shellFunctions.sh"
    echo
    echo "  For every future shell (adds 2 lines to your ~/.zshrc):"
    echo "      ${_sf_dir}/installAliases.sh"
    exit 1
fi
unset _sf_executed

AI_STACK_HOME="${AI_STACK_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)}"

# Resolve the OS folder holding the implementations (MacOs, Debian, ...).
# Uses the same detector the dispatch wrappers use, so the shell integration
# and ./install.sh can never disagree about which files are in play.
_aiStackOsDir() {
    local folder
    folder=$( . "${AI_STACK_HOME}/common.sh" >/dev/null 2>&1; detectOsFolder 2>/dev/null )
    [ -n "$folder" ] && echo "${AI_STACK_HOME}/${folder}"
}
AI_STACK_OS_DIR="$(_aiStackOsDir)"

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

# Run one function from one script, in its own bash process.
# Args: <script> <function> [args...]. Keeps helper names out of your shell and
# guarantees bash semantics; the terminal is inherited, so prompts still work.
_aiStackRun() {
    if [ $# -lt 2 ]; then
        aiStackUsage "_aiStackRun <script> <function> [args...]" "script   : absolute path to a MacOs/*.sh implementation" "function : a function defined in it" "example  : _aiStackRun $AI_STACK_OS_DIR/install.sh aistackInstallVerification"
        return 2
    fi
    local script="$1" func="$2"
    shift 2
    if [ ! -f "$script" ]; then
        echo "AI stack: ${script} not found (AI_STACK_HOME=${AI_STACK_HOME})" >&2
        return 1
    fi
    bash -c '
        script="$1"; func="$2"; shift 2
        . "$script" || exit 1
        "$func" "$@"
    ' _aiStack "$script" "$func" "$@"
}

# Define a wrapper for every public function in one script.
# Args: <script> <name-prefix>. Reads the function names out of the file, so
# adding a step to a script makes it available in the shell with no extra work.
_aiStackDefine() {
    if [ $# -lt 2 ]; then
        aiStackUsage "_aiStackDefine <script> <name-prefix>" "example  : _aiStackDefine $AI_STACK_OS_DIR/install.sh aistackInstall"
        return 2
    fi
    local script="$1" prefix="$2" fn
    [ -f "$script" ] || return 0
    for fn in $(grep -oE "^${prefix}[A-Za-z]*\(\)" "$script" 2>/dev/null | tr -d '()'); do
        eval "${fn}() { _aiStackRun '${script}' '${fn}' \"\$@\"; }"
        AI_STACK_FUNCS="${AI_STACK_FUNCS} ${fn}"
    done
}

AI_STACK_FUNCS=""
if [ -n "$AI_STACK_OS_DIR" ]; then
    _aiStackDefine "${AI_STACK_OS_DIR}/install.sh"         aistackInstall
    _aiStackDefine "${AI_STACK_OS_DIR}/uninstall.sh"       aistackUninstall
    _aiStackDefine "${AI_STACK_OS_DIR}/launchInference.sh" aistackLaunchInference
    _aiStackDefine "${AI_STACK_OS_DIR}/aiModelTest.sh"     aistackModelTest
fi

# MCP connectors are platform-independent — one implementation, no OS folder.
_aiStackDefine "${AI_STACK_HOME}/mcp.sh" aistackMcp

# Whole-script entry points, so the shell offers the same commands as the repo.
# These run the root dispatch wrappers, which pick the right OS folder.
aistackTestAllAiModels() { "${AI_STACK_HOME}/testAllAiModels.sh" "$@"; }
aistackNoRole()          { "${AI_STACK_HOME}/noRole.sh" "$@"; }

# ---------- completion ---------------------------------------------------------
# Tab completion for the MCP connectors lives in a per-shell file. It has to:
# zsh's completion system uses syntax bash cannot even parse, and bash parses
# the whole file regardless of which branch would run.
if [ -n "${BASH_VERSION:-}" ] && [ -f "${AI_STACK_HOME}/completions.bash" ]; then
    . "${AI_STACK_HOME}/completions.bash"
elif [ -n "${ZSH_VERSION:-}" ] && [ -f "${AI_STACK_HOME}/completions.zsh" ]; then
    . "${AI_STACK_HOME}/completions.zsh"
fi

# Offer to switch tab completion on in THIS shell. A connector's tools become
# completable the moment they are built, but the aistackMcp* functions run in a
# child bash process, and a child cannot change its parent's completion state —
# so the offer has to be made out here, where sourcing takes effect.
_aiStackMcpOfferCompletion() {
    [ -z "${AI_STACK_COMPLETION:-}" ] || return 0         # already live
    { : </dev/tty; } 2>/dev/null || return 0              # nobody to ask
    local _f="" _a
    if [ -n "${ZSH_VERSION:-}" ];  then _f="${AI_STACK_HOME}/completions.zsh"; fi
    if [ -n "${BASH_VERSION:-}" ]; then _f="${AI_STACK_HOME}/completions.bash"; fi
    [ -n "$_f" ] && [ -f "$_f" ] || return 0
    printf "\n\033[1mEnable tab completion for aistackMcpCall in this shell?\033[0m [Y/n] "
    { read -r _a </dev/tty; } 2>/dev/null || { _a=""; echo; }
    case "${_a:-y}" in
        [Nn]|[Nn]o) echo "   Skipped. Enable it later with:  source ${_f}" ;;
        *)          . "$_f"; echo "   Tab completion on. Try:  aistackMcpCall <TAB>" ;;
    esac
}

# These three wrappers override the generated ones above. Each ends with tools
# newly available to complete — Add and Login both continue into Build — so each
# is a natural moment to offer completion.
aistackMcpAdd() {
    _aiStackRun "${AI_STACK_HOME}/mcp.sh" aistackMcpAdd "$@"
    local _rc=$?; [ "$_rc" -eq 0 ] && _aiStackMcpOfferCompletion; return "$_rc"
}
aistackMcpLogin() {
    _aiStackRun "${AI_STACK_HOME}/mcp.sh" aistackMcpLogin "$@"
    local _rc=$?; [ "$_rc" -eq 0 ] && _aiStackMcpOfferCompletion; return "$_rc"
}
aistackMcpBuild() {
    _aiStackRun "${AI_STACK_HOME}/mcp.sh" aistackMcpBuild "$@"
    local _rc=$?; [ "$_rc" -eq 0 ] && _aiStackMcpOfferCompletion; return "$_rc"
}

# List everything this integration provides, grouped by layer.
# Run aistackHelp after a shell restart to confirm the wiring took effect and
# to see the step names without opening the scripts.
aistackHelp() {
    echo "AI stack — repo: ${AI_STACK_HOME}   os: ${AI_STACK_OS_DIR:-UNSUPPORTED}"
    if [ -z "$AI_STACK_OS_DIR" ]; then
        echo "  This OS has no engine/agent implementations — only the MCP connectors below."
    fi
    local group
    for group in aistackInstall aistackUninstall aistackLaunchInference aistackModelTest aistackMcp; do
        echo
        echo "  ${group}*"
        # $(echo ...) not $VAR: zsh does not word-split a plain parameter
        # expansion, so "for f in $AI_STACK_FUNCS" would iterate once over the
        # whole string and list nothing.
        for f in $(echo "$AI_STACK_FUNCS"); do
            case "$f" in ${group}*) echo "      $f" ;; esac
        done
    done
    echo
    echo "  whole scripts"
    echo "      aistackTestAllAiModels    aistackNoRole <Role>"
    echo
    echo "  MCP connectors:  aistackMcpAdd <name> --url <url>  ->  aistackMcpLogin <name>"
    echo "      then:        aistackMcpCall <name> <tool> [key=value ...]   (tab-completes)"
    echo
    echo "  full wizards:  ${AI_STACK_HOME}/install.sh   uninstall.sh   launchInference.sh"
}
