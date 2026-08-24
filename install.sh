#!/bin/bash
# OS-dispatch wrapper — the real implementation lives in <OsFolder>/install.sh
# (MacOs/ today; Debian/ later). OS detection + dispatch: common.sh.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"
os_exec "$DIR" "install.sh" "$@"
