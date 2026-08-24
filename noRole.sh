#!/bin/bash
#
# noRole.sh — unified dispatcher for the no<Role>Role.sh purge scripts.
#
# Discovers which no*Role.sh scripts exist in the OS folder (MacOs/, Debian/)
# and launches the right one:
#
#   ./noRole.sh Docker      # launches no<Role>Role.sh matching "docker"
#   ./noRole.sh codex       # case-insensitive
#   ./noRole.sh             # no parameter: offers every available role,
#                           # one y/N question each (default: No)
#
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

FOLDER=$(detectOsFolder) || exit 1

# ---------- discover available roles in the OS folder ------------------------
ROLES=()
for f in "${DIR}/${FOLDER}"/no*Role.sh; do
    [ -e "$f" ] || continue
    r=$(basename "$f"); r=${r#no}; r=${r%Role.sh}
    ROLES+=("$r")
done
if [ "${#ROLES[@]}" -eq 0 ]; then
    echo "✗ No no<Role>Role.sh scripts available for ${FOLDER}." >&2
    exit 1
fi

# ---------- parameter given: launch the matching role ------------------------
if [ "$#" -ge 1 ]; then
    ARG="$1"; shift
    want=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')
    for r in "${ROLES[@]}"; do
        if [ "$(echo "$r" | tr '[:upper:]' '[:lower:]')" = "$want" ]; then
            exec "${DIR}/${FOLDER}/no${r}Role.sh" "$@"
        fi
    done
    echo "✗ Unknown role '${ARG}'. Available roles for ${FOLDER}:" >&2
    printf '    %s\n' "${ROLES[@]}" >&2
    exit 1
fi

# ---------- no parameter: offer each available role, y/N (default No) --------
for r in "${ROLES[@]}"; do
    printf "Run no%sRole.sh — remove everything %s-related? [y/N] " "$r" "$r"
    read -r answer </dev/tty || answer=""
    case "$answer" in
        [Yy]|[Yy]es) "${DIR}/${FOLDER}/no${r}Role.sh" ;;
        *) echo "  Skipped ${r}." ;;
    esac
done
