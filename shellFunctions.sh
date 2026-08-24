#!/bin/bash
#
# shellFunctions.sh — expose the toolkit's step functions to an interactive
#                     shell, without polluting it.
#
# Sourced from ~/.zshrc or ~/.bashrc by installAliases.sh. After that, every
# public step is callable from anywhere:
#
#   installAiStackOllamaModels      # just the Ollama download menu
#   launchInferenceKillPrevious     # free the GPU without a full launch
#   aiModelTest Ollama qwen3.6:35b-a3b
#   uninstallAiStackPiCodingAgent
#   aiStackHelp                     # list everything that is available
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

# Run one function from one script, in its own bash process.
# Args: <script> <function> [args...]. Keeps helper names out of your shell and
# guarantees bash semantics; the terminal is inherited, so prompts still work.
_aiStackRun() {
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
    local script="$1" prefix="$2" fn
    [ -f "$script" ] || return 0
    for fn in $(grep -oE "^${prefix}[A-Za-z]*\(\)" "$script" 2>/dev/null | tr -d '()'); do
        eval "${fn}() { _aiStackRun '${script}' '${fn}' \"\$@\"; }"
        AI_STACK_FUNCS="${AI_STACK_FUNCS} ${fn}"
    done
}

AI_STACK_FUNCS=""
if [ -n "$AI_STACK_OS_DIR" ]; then
    _aiStackDefine "${AI_STACK_OS_DIR}/install.sh"         installAiStack
    _aiStackDefine "${AI_STACK_OS_DIR}/uninstall.sh"       uninstallAiStack
    _aiStackDefine "${AI_STACK_OS_DIR}/launchInference.sh" launchInference
    _aiStackDefine "${AI_STACK_OS_DIR}/aiModelTest.sh"     aiModelTest
fi

# Whole-script entry points, so the shell offers the same commands as the repo.
# These run the root dispatch wrappers, which pick the right OS folder.
testAllAiModels() { "${AI_STACK_HOME}/testAllAiModels.sh" "$@"; }
noRole()          { "${AI_STACK_HOME}/noRole.sh" "$@"; }

# List everything this integration provides, grouped by layer.
# Run aiStackHelp after a shell restart to confirm the wiring took effect and
# to see the step names without opening the scripts.
aiStackHelp() {
    echo "AI stack — repo: ${AI_STACK_HOME}   os: ${AI_STACK_OS_DIR:-UNSUPPORTED}"
    if [ -z "$AI_STACK_OS_DIR" ]; then
        echo "  This OS has no implementations yet — nothing is available."
        return 1
    fi
    local group
    for group in installAiStack uninstallAiStack launchInference aiModelTest; do
        echo
        echo "  ${group}*"
        # shellcheck disable=SC2086
        for f in $AI_STACK_FUNCS; do
            case "$f" in ${group}*) echo "      $f" ;; esac
        done
    done
    echo
    echo "  whole scripts"
    echo "      testAllAiModels    noRole <Role>"
    echo
    echo "  full wizards:  ${AI_STACK_HOME}/install.sh   uninstall.sh   launchInference.sh"
}
