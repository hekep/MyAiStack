#!/bin/bash
#
# uninstall.sh — Local AI coding stack remover for Debian/Ubuntu
#                (function-based)
#
# Mirror image of install.sh: every layer is an independent function, prefixed
# aistackUninstall*, and they run from the MOST DEPENDENT layer down to the
# foundations — the reverse of the installer's order.
#
#   aistackUninstallSanity               platform check
#   aistackUninstallDiskGate             what the stack is holding (reports only)
#   aistackUninstallLlamacppModels       GGUF files  <- GATE
#   aistackUninstallOllamaModels         Ollama tags <- GATE
#   --- monitoring: observational, nothing depends on it ---
#   aistackUninstallNvtopMonitoring      nvtop
#   aistackUninstallBtopMonitoring       btop
#   aistackUninstallLitellmMonitoring    LiteLLM proxy
#   --- coding agents: what you type into, they sit above the engines ---
#   aistackUninstallClaudeCodingAgent    Claude Code CLI
#   aistackUninstallOpenCodeCodingAgent  OpenCode
#   aistackUninstallPiCodingAgent        Pi
#   --- engines and foundations ---
#   aistackUninstallOllamaEngine         Ollama itself (service, binary, user)
#   aistackUninstallLlamacppEngine       llama.cpp prefix + symlinks
#   aistackUninstallOllamaData           the Ollama model store (destructive)
#   aistackUninstallNode                 Node + npm
#   aistackUninstallUv                   uv
#   aistackUninstallBaseTools            reports only — never removed
#   aistackUninstallVerification         what is left standing
#   aistackUninstall                     wrapper — runs all of the above in order
#
# THE GATE: while any model is still installed, the engines and everything
# under them must stay, so the wrapper stops there. Remove every model to reach
# the foundation layers.
#
# Usage:
#   ./uninstall.sh                 # full pipeline
#   source uninstall.sh            # then call any single function
#
set -u

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

# Print a progress heading ("==> ...") for the layer being removed.
info()  { echo "${BLUE}==>${RESET} $*"; }
# Print a success line — also used for "nothing to remove", so a clean
# machine reads the same as one just cleaned.
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
# Print a caution line: kept-by-choice, or a destructive step about to be
# offered. Not a failure.
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
# Print an error line — a removal that was attempted and did not work.
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

# Ask a yes/no question, looping until the answer is unambiguous.
# Reads /dev/tty so the prompt survives piped output; aborts if there is no
# terminal at all. Returns 0 for yes, 1 for no, with no Enter-default.
ask() {
    if [ $# -lt 1 ]; then
        aiStackUsage "ask <question>" "no default — answer y or n explicitly" "example : ask \"Remove the model?\""
        return 2
    fi
    local answer
    while true; do
        printf "\n%s%s%s [y/n] " "${BOLD}" "$1" "${RESET}"
        read -r answer </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
        case "$answer" in
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Ask a yes/no question where Enter picks a caller-supplied default.
# Args: <question> <y|n>. The hint shown ([Y/n] or [y/N]) reflects that default.
# Destructive steps pass "n" so a stray Enter can never delete anything.
ask_def() {
    if [ $# -lt 2 ]; then
        aiStackUsage "ask_def <question> <y|n>" "example : ask_def \"Remove it?\" n"
        return 2
    fi
    local answer hint
    [ "$2" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf "\n%s%s%s %s " "${BOLD}" "$1" "${RESET}" "$hint"
        read -r answer </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
        case "$answer" in
            "") [ "$2" = "y" ] && return 0 || return 1 ;;
            [Yy]|[Yy]es) return 0 ;;
            [Nn]|[Nn]o)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Free space in whole GB on the filesystem holding a path (default $HOME).
# Sampled before and after each removal so the script can report what was
# actually freed rather than what 'du' predicted.
free_gb() { df -BG --output=avail "${1:-$HOME}" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $1+0}'; }
# Human-readable size of a path ('du -sh'), empty when it does not exist.
# Shown inside prompts so a deletion is never agreed to blind.
sizeof()  { [ $# -ge 1 ] || { aiStackUsage "sizeof <path>" "example : sizeof ~/.ollama"; return 2; }; du -sh "$1" 2>/dev/null | cut -f1; }

# Run one privileged command, failing clearly when sudo is not available.
_asRoot() {
    if [ "$(id -u)" = "0" ]; then "$@"; return $?; fi
    command -v sudo >/dev/null 2>&1 || { fail "sudo is required for: $*"; return 1; }
    sudo "$@"
}
# True when a .deb package is installed (not merely known to apt).
_debInstalled() { dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null | grep -qx installed; }
# apt-get purge/remove, non-interactive.
_aptRemove() { DEBIAN_FRONTEND=noninteractive _asRoot apt-get remove -y -qq "$@"; }

# ---------- paths and detection ----------------------------------------------
LLAMACPP_MODEL_DIR="${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}"
LLAMACPP_PREFIX="${LLAMACPP_PREFIX:-$HOME/.local/opt/llama.cpp}"
LLAMACPP_BINDIR="${LLAMACPP_BINDIR:-$HOME/.local/bin}"

# The directory Ollama stores manifests and blobs in.
# Linux has two possible locations — the system service's /usr/share/ollama and
# your own ~/.ollama — and the destructive step must name the right one.
ollamaModelsDir() {
    if [ -n "${OLLAMA_MODELS:-}" ]; then echo "$OLLAMA_MODELS"; return 0; fi
    if [ -d "$HOME/.ollama/models/manifests" ]; then echo "$HOME/.ollama/models"; return 0; fi
    if [ -d /usr/share/ollama/.ollama/models/manifests ]; then echo /usr/share/ollama/.ollama/models; return 0; fi
    echo "$HOME/.ollama/models"
}
# True when the Ollama API answers on localhost.
# Model listing and removal both need the daemon, so several layers check this
# before deciding whether to start one temporarily.
ollama_server_up() { curl -sf http://localhost:11434/api/version >/dev/null 2>&1; }
# True when the system-wide ollama.service exists.
ollamaSystemService() { systemctl list-unit-files ollama.service >/dev/null 2>&1; }

# GGUF models on disk for llama.cpp, as engine tags. Args: none.
llamacppListInstalled() {
    local dir="$LLAMACPP_MODEL_DIR" f b
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.gguf; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .gguf)
        printf '%s\n' "$(printf '%s' "$b" | sed 's|@|:|; s|__|/|g')"
    done
}
# Ollama model tags, from the daemon or straight off the disk. Args: none.
ollamaListInstalled() {
    if ollama list >/dev/null 2>&1; then
        ollama list 2>/dev/null | awk 'NR>1 {print $1}'
        return 0
    fi
    local base f rel ns name tag
    base="$(ollamaModelsDir)/manifests"
    [ -d "$base" ] || return 0
    find "$base" -type f 2>/dev/null | while read -r f; do
        rel=${f#"$base"/}; rel=${rel#*/}
        ns=${rel%%/*}; rel=${rel#*/}
        name=${rel%%/*}; tag=${rel#*/}
        [ "$ns" = "library" ] && echo "${name}:${tag}" || echo "${ns}/${name}:${tag}"
    done | sort
}
# How many models Ollama has installed on disk.
# The engine layer refuses to uninstall Ollama while this is non-zero, which
# keeps the dependency rule true even when a function is called directly.
ollama_model_count() { ollamaListInstalled 2>/dev/null | grep -c . ; }

# Mirror of aistackInstallSanity: confirm this is a machine the Debian
# implementations apply to before touching anything. Args: none.
aistackUninstallSanity() {
    info "aistackUninstallSanity — platform check"
    if [ "$(uname -s)" != "Linux" ]; then
        fail "These are the Debian implementations; this is $(uname -s)."
        return 1
    fi
    local ids=""
    [ -r /etc/os-release ] && ids=$( . /etc/os-release; echo "${ID:-} ${ID_LIKE:-}" )
    case " ${ids} " in
        *debian*|*ubuntu*) : ;;
        *) fail "Only Debian-based Linux is supported — this is: ${ids:-unknown}."; return 1 ;;
    esac
    ok "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Debian-based Linux}") — proceeding."
}

# Mirror of aistackInstallDiskGate. The installer BLOCKS below a disk minimum;
# the inverse is not a gate — removing things can only free space — so this
# reports what each layer is currently holding, to inform what to remove.
aistackUninstallDiskGate() {
    info "aistackUninstallDiskGate — what the stack is holding (nothing is blocked)"
    local sz
    _report() {  # <label> <path>
        [ -e "$2" ] || return 0
        sz=$(sizeof "$2")
        printf "    %-40s %s\n" "$1" "$sz"
    }
    _report "Ollama models ($(ollamaModelsDir))" "$(ollamaModelsDir)"
    _report "llama.cpp GGUFs" "$LLAMACPP_MODEL_DIR"
    _report "llama.cpp engine" "$LLAMACPP_PREFIX"
    _report "HuggingFace cache" "${HF_HOME:-$HOME/.cache/huggingface}"
    _report "uv tools" "$HOME/.local/share/uv"
    unset -f _report
    ok "Free disk now: $(free_gb) GB — removals below will add to it."
}

# ---------- layer: models — the gate -----------------------------------------
# Shared numbered menu for removing models of one engine — the mirror of the
# installer's download menu. Args: <engine> <list-fn> <remove-fn>.
# Returns 0 when no models remain, 1 when the user stops with some left.
_aistackModelRemoveMenu() {
    local engine="$1" list_fn="$2" remove_fn="$3" models i names sel m before
    while true; do
        models=$("$list_fn")
        if [ -z "$models" ]; then
            ok "No ${engine} models remain."
            return 0
        fi
        echo
        echo "${BOLD}${engine} models (free disk: $(free_gb) GB):${RESET}"
        i=1; names=()
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            printf "  %2d) %-52s %s\n" "$i" "$m" "$("${remove_fn}_size" "$m")"
            names+=("$m"); i=$((i+1))
        done <<< "$models"
        echo "   N) Keep the rest — stop here"
        # Enter means N — keep everything; bad input re-asks here, not the whole menu.
        local _sel_ok=0
        while [ "$_sel_ok" -eq 0 ]; do
        printf "\n%sRemove which %s model? [1-%d / N, Enter = N]:%s " "${BOLD}" "$engine" "${#names[@]}" "${RESET}"
            read -r sel </dev/tty || sel="N"
            case "$sel" in
                ""|[Nn]) return 1 ;;
                *[!0-9]*) echo "Enter a number or N."; continue ;;
            esac
            if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#names[@]}" ]; then echo "Out of range (1-${#names[@]})."; continue; fi
            _sel_ok=1
        done
        m="${names[$((sel-1))]}"
        before=$(free_gb)
        if "$remove_fn" "$m"; then
            ok "Removed ${m} — freed $(( $(free_gb) - before )) GB."
        else
            fail "Could not remove ${m}."
        fi
    done
}

# Where one llama.cpp tag lives on disk. Args: <tag>.
llamacppPathFor() {
    [ $# -ge 1 ] || { aiStackUsage "llamacppPathFor <tag>" "example : llamacppPathFor org/repo-GGUF:Q8_0"; return 2; }
    echo "${LLAMACPP_MODEL_DIR}/$(printf '%s' "$1" | sed 's|/|__|g; s|:|@|').gguf"
}
# Delete one llama.cpp GGUF. Args: <tag>.
llamacppRemoveModel()      { rm -f "$(llamacppPathFor "$1")"; }
# Size of one llama.cpp GGUF, for the menu. Args: <tag>.
llamacppRemoveModel_size() { sizeof "$(llamacppPathFor "$1")"; }
# Delete one Ollama model through the daemon. Args: <tag>.
ollamaRemoveModel()        { ollama rm "$1" >/dev/null 2>&1; }
# Size of one Ollama model, as the daemon reports it. Args: <tag>.
ollamaRemoveModel_size()   { ollama list 2>/dev/null | awk -v t="$1" '$1==t {print $3" "$4; exit}'; }

# Remove llama.cpp GGUF models — mirror of aistackInstallLlamacppModels.
# Returns 0 when none remain, so the engine layer below may proceed.
aistackUninstallLlamacppModels() {
    info "aistackUninstallLlamacppModels — GGUF files in ${LLAMACPP_MODEL_DIR}"
    if [ -z "$(llamacppListInstalled)" ]; then
        ok "No llama.cpp models — nothing to do."
        return 0
    fi
    _aistackModelRemoveMenu "Llama.cpp" llamacppListInstalled llamacppRemoveModel
}

# Layer 1 and the GATE: remove Ollama models one at a time from a numbered menu.
# Mirrors the installer's download menu — pick a number, see the freed GB, the
# menu re-renders — and starts the daemon temporarily if it is not running.
# Returns 0 only when NO models remain; 1 (models left, or N) stops the wizard,
# because nothing a model depends on may be removed while it exists.
aistackUninstallOllamaModels() {
    info "aistackUninstallOllamaModels — the Ollama models (gate for every layer below)"
    if ! command -v ollama >/dev/null 2>&1; then
        ok "Ollama is not installed — no models to remove."
        return 0
    fi
    if [ -z "$(ollamaListInstalled)" ]; then
        ok "No Ollama models — nothing to do."
        return 0
    fi

    local started=0
    if ! ollama_server_up; then
        warn "Ollama server not running — starting it temporarily to manage models."
        OLLAMA_MODELS="$(ollamaModelsDir)" nohup ollama serve >/dev/null 2>&1 &
        started=1
        sleep 3
    fi
    if ! ollama_server_up; then
        warn "Could not reach the Ollama server — cannot remove models one by one."
        warn "They can still be wiped wholesale via aistackUninstallOllamaData."
        [ "$started" -eq 1 ] && pkill -f "ollama serve" 2>/dev/null
        return 1
    fi

    local rc
    _aistackModelRemoveMenu "Ollama" ollamaListInstalled ollamaRemoveModel
    rc=$?
    [ "$started" -eq 1 ] && pkill -f "ollama serve" 2>/dev/null
    return $rc
}

# ---------- layer: monitoring -------------------------------------------------
# Purely observational: nothing in the stack depends on these, so they come off
# first. nvtop and btop replace macOS's macmon and Anubis OSS.

# Remove one apt-installed monitoring tool, defaulting to keeping it.
# Args: <package> <label> <why keeping is reasonable>.
_aistackUninstallAptTool() {
    local pkg="$1" label="$2" why="$3"
    if ! _debInstalled "$pkg"; then
        ok "${label} not installed — nothing to do."
        return 0
    fi
    warn "${label} at $(command -v "$pkg" 2>/dev/null || echo "(package ${pkg})")"
    echo "    ${why}"
    if ask_def "Uninstall ${label}?" "n"; then
        _aptRemove "$pkg" && ok "${label} removed." || fail "apt-get remove ${pkg} failed."
    else
        ok "Keeping ${label}."
    fi
}

# Remove nvtop (GPU/APU monitor).
# Default No: it is tiny, useful beside any GPU workload, and unrelated to
# whether you keep the models.
aistackUninstallNvtopMonitoring() {
    info "aistackUninstallNvtopMonitoring — nvtop"
    _aistackUninstallAptTool nvtop "nvtop" \
        "Small, and useful beside any GPU workload — not just this stack's."
}

# Remove btop (system monitor).
# Default No, for the same reason: it is a general-purpose tool that happens to
# have been installed here.
aistackUninstallBtopMonitoring() {
    info "aistackUninstallBtopMonitoring — btop"
    _aistackUninstallAptTool btop "btop" \
        "A general system monitor that happens to have been installed here."
}

# Remove the LiteLLM proxy (a uv tool).
# Default No. Offers its config directory separately, since ~/.litellm can hold
# provider keys you would not want to re-enter.
aistackUninstallLitellmMonitoring() {
    info "aistackUninstallLitellmMonitoring — LiteLLM proxy"
    if ! command -v uv >/dev/null 2>&1 || ! uv tool list 2>/dev/null | grep -q '^litellm'; then
        ok "LiteLLM not installed — nothing to do."
        return 0
    fi
    if ask_def "Uninstall LiteLLM?" "n"; then
        uv tool uninstall litellm && ok "LiteLLM removed." || fail "LiteLLM removal failed."
    else
        ok "Keeping LiteLLM."
        return 0
    fi
    if [ -d "$HOME/.litellm" ]; then
        warn "LiteLLM config lives in ~/.litellm ($(sizeof "$HOME/.litellm")) — it may hold provider keys."
        ask_def "Delete ~/.litellm as well?" "n" && { rm -rf "$HOME/.litellm" && ok "~/.litellm deleted."; }
    fi
}

# ---------- layer: coding agents ---------------------------------------------
# The agents sit above the engines: they are what you type into. Removed before
# any engine, so nothing is pulled out from under a working agent.

# Remove the Pi coding agent (npm package, either publisher scope).
# Defaults to No. Offers ~/.pi — config, plugins, session transcripts — as a
# separate question, since that is your data rather than the program.
aistackUninstallPiCodingAgent() {
    info "aistackUninstallPiCodingAgent — Pi coding agent"
    if ! command -v pi >/dev/null 2>&1; then
        ok "Pi not installed — nothing to do."
        return 0
    fi
    warn "Pi $(pi --version 2>/dev/null | head -1) at $(command -v pi)"
    if ! ask_def "Uninstall Pi?" "n"; then
        ok "Keeping Pi."
        return 0
    fi
    if command -v npm >/dev/null 2>&1; then
        npm uninstall -g @earendil-works/pi-coding-agent >/dev/null 2>&1 \
            || npm uninstall -g @mariozechner/pi-coding-agent >/dev/null 2>&1
    fi
    command -v pi >/dev/null 2>&1 && fail "'pi' still resolves — remove it by hand." || ok "Pi removed."
    if [ -d "$HOME/.pi" ]; then
        warn "Pi config/plugins live in ~/.pi ($(sizeof "$HOME/.pi"))."
        ask_def "Delete ~/.pi as well?" "n" && { rm -rf "$HOME/.pi" && ok "~/.pi deleted."; }
    fi
}

# Remove OpenCode (an npm package here — there is no Debian package).
# Defaults to No, and offers ~/.config/opencode separately so provider settings
# survive a reinstall unless you say otherwise.
aistackUninstallOpenCodeCodingAgent() {
    info "aistackUninstallOpenCodeCodingAgent — OpenCode"
    if ! command -v opencode >/dev/null 2>&1; then
        ok "OpenCode not installed — nothing to do."
        return 0
    fi
    warn "OpenCode $(opencode --version 2>/dev/null | head -1) at $(command -v opencode)"
    if ! ask_def "Uninstall OpenCode?" "n"; then
        ok "Keeping OpenCode."
        return 0
    fi
    if command -v npm >/dev/null 2>&1; then
        npm uninstall -g opencode-ai && ok "npm package removed." || fail "npm uninstall failed."
    fi
    command -v opencode >/dev/null 2>&1 && warn "'opencode' still resolves — another install may exist."
    if [ -d "$HOME/.config/opencode" ]; then
        warn "OpenCode config lives in ~/.config/opencode."
        ask_def "Delete it as well?" "n" && { rm -rf "$HOME/.config/opencode" && ok "Config deleted."; }
    fi
}

# ---------- layer: Claude Code CLI -------------------------------------------
# Remove the Claude Code CLI (npm package or native installer layout).
# Defaults to No — it may be the very session you are typing in.
# ~/.claude (sessions, settings, memory) is never touched by this script.
aistackUninstallClaudeCodingAgent() {
    info "aistackUninstallClaudeCodingAgent — Claude Code CLI"
    if ! command -v claude >/dev/null 2>&1; then
        ok "claude CLI not installed — nothing to do."
        return 0
    fi
    local bin ver
    bin=$(command -v claude)
    ver=$(claude --version 2>/dev/null | head -1)
    warn "claude ${ver} at ${bin}"
    warn "This is the tool that drives the local models — and possibly this session."
    ok "Your sessions, settings and memory in ~/.claude are NEVER touched by this script."
    if ! ask_def "Uninstall the Claude Code CLI?" "n"; then
        ok "Keeping the Claude CLI."
        return 0
    fi
    if command -v npm >/dev/null 2>&1 && npm ls -g @anthropic-ai/claude-code >/dev/null 2>&1; then
        npm uninstall -g @anthropic-ai/claude-code && ok "npm package removed." || fail "npm uninstall failed."
    else
        # native installer layout: ~/.local/bin/claude -> ~/.local/share/claude/versions/<ver>
        local store="$HOME/.local/share/claude"
        rm -f "$bin" && ok "Removed ${bin}."
        if [ -d "$store" ]; then
            if ask_def "Also remove the version store ${store} ($(sizeof "$store"))?" "y"; then
                rm -rf "$store" && ok "Version store removed."
            fi
        fi
    fi
    command -v claude >/dev/null 2>&1 && warn "'claude' still resolves — another install may exist." \
                                      || ok "Claude CLI removed."
}

# ---------- layer: Ollama itself ---------------------------------------------
# Remove the Ollama runtime itself, models excluded.
# Refuses while any model is installed, so the rule holds even when called
# directly. The Linux install is a binary in /usr/local plus a systemd unit and
# a dedicated system user — all three are undone here, none of them by apt.
aistackUninstallOllamaEngine() {
    info "aistackUninstallOllamaEngine — the Ollama runtime"
    local present=0
    command -v ollama >/dev/null 2>&1 && present=1
    [ -x /usr/local/bin/ollama ] && present=1
    ollamaSystemService && present=1
    if [ "$present" -eq 0 ]; then
        ok "Ollama not installed — nothing to do."
        return 0
    fi

    # never remove the engine while models still depend on it
    local n
    n=$(ollama_model_count 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 0 ]; then
        fail "${n} model(s) still installed — refusing to remove Ollama."
        fail "Run aistackUninstallOllamaModels first."
        return 1
    fi

    if ! ask_def "Uninstall Ollama? (its model store is a separate step)" "y"; then
        ok "Keeping Ollama."
        return 0
    fi

    # stop every way it can be running: the systemd unit and a bare serve
    if ollamaSystemService; then
        _asRoot systemctl disable --now ollama.service >/dev/null 2>&1 && ok "systemd ollama.service stopped and disabled."
        _asRoot rm -f /etc/systemd/system/ollama.service
        _asRoot systemctl daemon-reload >/dev/null 2>&1
        ok "Unit file removed."
    fi
    pkill -f "ollama serve" 2>/dev/null || true
    sleep 1

    # the official installer's layout — no package manager involved
    local p
    for p in /usr/local/bin/ollama /usr/bin/ollama; do
        [ -e "$p" ] && { _asRoot rm -f "$p" && ok "Removed ${p}."; }
    done
    [ -d /usr/local/lib/ollama ] && { _asRoot rm -rf /usr/local/lib/ollama && ok "Removed /usr/local/lib/ollama."; }

    # the installer also creates a system user and group
    if id ollama >/dev/null 2>&1; then
        warn "The installer created a system user 'ollama' (home /usr/share/ollama)."
        if ask_def "Remove the 'ollama' user and group?" "y"; then
            _asRoot userdel ollama >/dev/null 2>&1 && ok "User removed."
            _asRoot groupdel ollama >/dev/null 2>&1 || true
        else
            ok "Keeping the 'ollama' user."
        fi
    fi
    command -v ollama >/dev/null 2>&1 && warn "'ollama' still resolves: $(command -v ollama)" || ok "Ollama removed."
}

# ---------- layer: llama.cpp engine ------------------------------------------
# Remove the llama.cpp engine — mirror of aistackInstallLlamacppEngine.
# Refuses while GGUFs remain, the same rule the Ollama engine layer follows.
# Removes only what this stack installed: the prefix and the symlinks that
# point into it, so a distro or hand-built llama.cpp elsewhere is left alone.
aistackUninstallLlamacppEngine() {
    info "aistackUninstallLlamacppEngine — llama.cpp"
    if ! command -v llama-server >/dev/null 2>&1 && ! command -v llama-cli >/dev/null 2>&1 \
       && [ ! -d "$LLAMACPP_PREFIX" ]; then
        ok "llama.cpp not installed — nothing to do."
        return 0
    fi
    local n
    n=$(llamacppListInstalled | grep -c . || true)
    if [ "${n:-0}" -gt 0 ]; then
        fail "${n} GGUF model(s) still on disk — refusing to remove llama.cpp."
        fail "Run aistackUninstallLlamacppModels first."
        return 1
    fi
    if [ ! -d "$LLAMACPP_PREFIX" ]; then
        warn "llama.cpp is on PATH at $(command -v llama-server || command -v llama-cli),"
        warn "but not in ${LLAMACPP_PREFIX} — this stack did not install it, so it is left alone."
        return 0
    fi
    warn "llama.cpp in ${LLAMACPP_PREFIX} ($(sizeof "$LLAMACPP_PREFIX"))"
    if ! ask_def "Uninstall llama.cpp?" "y"; then
        ok "Keeping llama.cpp."
        return 0
    fi
    pkill -f "llama-server .*--port 8080" 2>/dev/null
    # only the symlinks that actually point into our prefix
    local l target removed=0
    for l in "$LLAMACPP_BINDIR"/llama-*; do
        [ -L "$l" ] || continue
        target=$(readlink -f "$l")
        case "$target" in "$LLAMACPP_PREFIX"/*) rm -f "$l"; removed=$((removed+1)) ;; esac
    done
    [ "$removed" -gt 0 ] && ok "Removed ${removed} symlink(s) from ${LLAMACPP_BINDIR}."
    local before; before=$(free_gb)
    rm -rf "$LLAMACPP_PREFIX" && ok "llama.cpp removed — freed $(( $(free_gb) - before )) GB." \
                             || fail "Could not remove ${LLAMACPP_PREFIX}."
}

# ---------- layer: the Ollama model store (destructive) ----------------------
# Delete the Ollama model store: every model blob plus this machine's registry
# keypair. The only unrecoverable step here, so it shows the size, asks twice,
# and both questions default to No. Kept separate from the engine on purpose:
# losing the program costs minutes, losing the blobs costs hours of downloading.
aistackUninstallOllamaData() {
    local root parent
    root=$(ollamaModelsDir)
    parent=$(dirname "$root")
    info "aistackUninstallOllamaData — ${parent} (model blobs + registry keypair)"
    if [ ! -d "$parent" ]; then
        ok "${parent} does not exist — nothing to do."
        return 0
    fi
    local sz before
    sz=$(sizeof "$parent")
    warn "${parent} holds every downloaded blob and this machine's Ollama keypair (${sz})."
    warn "DESTRUCTIVE and unrecoverable — models would have to be downloaded again."
    if ask_def "Permanently delete ${parent} (${sz})?" "n"; then
        if ask_def "Are you sure? This wipes every model blob in one go." "n"; then
            before=$(free_gb "$parent")
            if [ -w "$(dirname "$parent")" ]; then rm -rf "$parent"; else _asRoot rm -rf "$parent"; fi
            [ -d "$parent" ] && fail "Deletion failed." \
                             || ok "${parent} deleted — freed $(( $(free_gb "$(dirname "$parent")") - before )) GB."
        else
            ok "Keeping ${parent}."
        fi
    else
        ok "Keeping ${parent}."
    fi
}

# ---------- layer: Node (foundation of the coding agents) --------------------
# Remove Node and npm, the foundation all three agents were installed through.
# Lists anything npm still manages globally first — removing Node would leave
# those unusable — and defaults to No for that reason.
aistackUninstallNode() {
    info "aistackUninstallNode — Node.js and npm"
    if ! command -v node >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
        ok "Node not installed — nothing to do."
        return 0
    fi
    if ! _debInstalled nodejs; then
        ok "Node is on PATH at $(command -v node) but was not installed by apt — leaving it alone."
        return 0
    fi
    local remaining
    remaining=$(npm ls -g --depth=0 2>/dev/null | tail -n +2 | grep -c '' || true)
    if [ "${remaining:-0}" -gt 0 ]; then
        warn "npm still manages ${remaining} global package(s) — removing Node breaks them:"
        npm ls -g --depth=0 2>/dev/null | tail -n +2 | sed 's/^/    /'
    fi
    warn "Node is a general-purpose runtime — plenty outside this stack may need it."
    if ask_def "Uninstall Node and npm (apt)?" "n"; then
        _aptRemove nodejs npm && ok "Node removed." || fail "apt-get remove failed."
    else
        ok "Keeping Node."
    fi
}

# ---------- layer: uv (foundation of LiteLLM) --------------------------------
# Remove uv, the foundation LiteLLM was installed through.
# Lists any other tools uv still manages first — removing it would leave them
# unmanaged — and defaults to No for that reason.
aistackUninstallUv() {
    info "aistackUninstallUv — uv"
    if ! command -v uv >/dev/null 2>&1; then
        ok "uv not installed — nothing to do."
        return 0
    fi
    local remaining
    remaining=$(uv tool list 2>/dev/null | grep -c '^[a-zA-Z]' || true)
    if [ "${remaining:-0}" -gt 0 ]; then
        warn "uv still manages ${remaining} tool(s) — removing uv leaves them unmanaged:"
        uv tool list 2>/dev/null | sed 's/^/    /'
    fi
    if ! ask_def "Uninstall uv?" "n"; then
        ok "Keeping uv."
        return 0
    fi
    # uv is installed by Astral's script into ~/.local/bin, not by apt
    if uv self uninstall >/dev/null 2>&1; then
        ok "uv removed (uv self uninstall)."
    else
        rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx" && ok "uv binaries removed."
    fi
    if [ -d "$HOME/.local/share/uv" ]; then
        warn "uv's tool store is ~/.local/share/uv ($(sizeof "$HOME/.local/share/uv"))."
        ask_def "Delete it as well?" "n" && { rm -rf "$HOME/.local/share/uv" && ok "Tool store deleted."; }
    fi
}

# ---------- layer: base tools (never removed) --------------------------------
# Report the base packages and deliberately leave them alone.
# curl, python3, jq and the rest are how the rest of this machine works too, so
# removing them is never offered — the counterpart of macOS keeping Homebrew.
aistackUninstallBaseTools() {
    info "aistackUninstallBaseTools — curl, python3, jq, lsof, ..."
    ok "Base tools are left untouched — the rest of the system depends on them too."
    echo "    (Remove them by hand if you really mean to: sudo apt-get remove curl jq lsof)"
}

# ---------- status ------------------------------------------------------------
# Print what is still standing: engines, agents, models, foundations, free disk.
# Also printed when the model gate stops the run, so a cancelled uninstall still
# ends with an accurate picture.
aistackUninstallVerification() {
    echo
    echo "${BOLD}================= What is left =================${RESET}"
    command -v llama-server >/dev/null 2>&1 && warn "llama.cpp: still installed ($(command -v llama-server))" \
                                            || ok   "llama.cpp: removed"
    command -v ollama >/dev/null 2>&1 && warn "Ollama:    still installed ($(ollama --version 2>/dev/null | head -1))" \
                                      || ok   "Ollama:    removed"
    [ -n "$(llamacppListInstalled)" ]  && warn "GGUFs:     ${LLAMACPP_MODEL_DIR} ($(sizeof "$LLAMACPP_MODEL_DIR"))" \
                                       || ok   "GGUFs:     removed"
    [ -d "$(dirname "$(ollamaModelsDir)")" ] && warn "Ollama models: $(dirname "$(ollamaModelsDir)") present ($(sizeof "$(dirname "$(ollamaModelsDir)")"))" \
                                             || ok   "Ollama models: removed"
    command -v nvtop >/dev/null 2>&1    && warn "nvtop:     still installed" || ok "nvtop:     removed"
    command -v btop >/dev/null 2>&1     && warn "btop:      still installed" || ok "btop:      removed"
    { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^litellm'; } \
                                        && warn "LiteLLM:   still installed" || ok "LiteLLM:   removed"
    command -v pi >/dev/null 2>&1       && warn "Pi:        still installed" || ok "Pi:        removed"
    command -v opencode >/dev/null 2>&1 && warn "OpenCode:  still installed" || ok "OpenCode:  removed"
    command -v claude >/dev/null 2>&1   && warn "claude:    still installed ($(claude --version 2>/dev/null | head -1))" \
                                        || ok   "claude:    removed"
    command -v node >/dev/null 2>&1   && warn "node:      still installed ($(node --version 2>/dev/null))" || ok "node:      removed"
    command -v uv >/dev/null 2>&1     && warn "uv:        still installed" || ok "uv:        removed"
    ok "base tools: kept (by design)"
    echo "    Free disk: $(free_gb) GB"
}

# ---------- wrapper ----------------------------------------------------------
# Wrapper: run every layer from most-dependent down to the foundations.
# Models first (the gate), then monitoring, agents, engines and their data.
# Stops after the gate when models remain, keeping everything they need.
aistackUninstall() {
    echo "${BOLD}=============================================================${RESET}"
    echo "${BOLD} Local AI coding stack — uninstaller (Debian)${RESET}"
    echo "${BOLD} Order: most dependent layer first -> foundations last${RESET}"
    echo "${BOLD}=============================================================${RESET}"
    aistackUninstallSanity || return 1
    aistackUninstallDiskGate

    # THE GATE — every engine's models must be gone before anything they
    # depend on may be removed. One step per engine, mirroring the installer.
    local left=0
    aistackUninstallLlamacppModels || left=1
    aistackUninstallOllamaModels   || left=1
    if [ "$left" = "1" ]; then
        echo
        warn "${BOLD}Uninstallation stopped: models are still installed.${RESET}"
        warn "Engines, agents, monitoring and the foundations are all kept — models depend on them."
        warn "Remove every model to continue, or run a single layer directly:"
        warn "  source uninstall.sh && aistackUninstallBtopMonitoring"
        aistackUninstallVerification
        exit 0
    fi

    # monitoring first: nothing depends on it
    aistackUninstallNvtopMonitoring
    aistackUninstallBtopMonitoring
    aistackUninstallLitellmMonitoring

    # then the coding agents — they sit above the engines
    aistackUninstallClaudeCodingAgent
    aistackUninstallOpenCodeCodingAgent
    aistackUninstallPiCodingAgent

    # then the engines, reverse of the order the installer offers them
    aistackUninstallOllamaEngine
    aistackUninstallLlamacppEngine

    # engine data, then the foundations
    aistackUninstallOllamaData
    aistackUninstallNode
    aistackUninstallUv
    aistackUninstallBaseTools
    aistackUninstallVerification
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    aistackUninstall
fi
