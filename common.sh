#!/bin/bash
#
# common.sh — shared code for the MyAiStack toolkit.
#
# Sourced by the thin wrapper scripts in the repo root. Each wrapper detects
# the host OS and dispatches to the real implementation in the OS-specific
# folder:
#
#   MacOs/    — Apple Silicon macOS implementations (complete)
#   Debian/   — Debian/Ubuntu implementations (to be generated later)
#
# Unsupported systems (e.g. Fedora/RHEL-based Linux, Windows) exit with a
# clear message instead of half-running.

# ---------- OS detection ------------------------------------------------------
# Map the running OS to the folder holding its implementations.
# Prints "MacOs" on Darwin and "Debian" on Debian/Ubuntu (matched via ID and
# ID_LIKE in /etc/os-release). Anything else — Fedora/RHEL, Windows — is a hard
# stop: prints why on stderr and returns 1 rather than half-running.
detectOsFolder() {
    local sys ids
    sys=$(uname -s)
    case "$sys" in
        Darwin)
            echo "MacOs"
            ;;
        Linux)
            ids=""
            [ -r /etc/os-release ] && ids=$( . /etc/os-release; echo "${ID:-} ${ID_LIKE:-}" )
            case " ${ids} " in
                *debian*|*ubuntu*)
                    echo "Debian"
                    ;;
                *)
                    echo "UNSUPPORTED: only Debian-based Linux is supported — this is: ${ids:-unknown distribution}" >&2
                    return 1
                    ;;
            esac
            ;;
        *)
            echo "UNSUPPORTED OS: ${sys} (supported: macOS, Debian-based Linux)" >&2
            return 1
            ;;
    esac
}

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

# ---------- dispatch ----------------------------------------------------------
# Dispatch to the OS-specific implementation of a script.
# Args: <repo-root> <script-name> [args...] — replaces this process with
# <repo-root>/<OsFolder>/<script-name>, forwarding every argument.
# Exits 1 with a clear message when the OS is unsupported or that folder has no
# such script yet (e.g. running install.sh on Debian before it is ported).
os_exec() {
    if [ $# -lt 2 ]; then
        aiStackUsage "os_exec <repo-root> <script-name> [args...]" "repo-root : the MyAiStack checkout" "script    : install.sh | launchInference.sh | ..." "example   : os_exec /path/to/MyAiStack install.sh"
        return 2
    fi
    local root="$1" script="$2" folder target
    shift 2
    folder=$(detectOsFolder) || exit 1
    target="${root}/${folder}/${script}"
    if [ ! -f "$target" ]; then
        echo "✗ ${script} has no ${folder} implementation yet (expected: ${target})." >&2
        exit 1
    fi
    [ -x "$target" ] || chmod +x "$target" 2>/dev/null
    exec "$target" "$@"
}
