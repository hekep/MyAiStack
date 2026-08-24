#!/bin/bash
#
# common.sh — shared code for the AI_Code_generator toolkit.
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
# Prints the OS-specific folder name on stdout.
# Returns 1 (with a message on stderr) when the OS is unsupported.
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

# ---------- dispatch ----------------------------------------------------------
# os_exec <repo-root> <script-name> [args...]
# Replaces the current process with the OS-specific implementation.
os_exec() {
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
