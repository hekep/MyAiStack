#!/bin/bash
#
# install.sh — Local AI coding stack installer for Debian/Ubuntu
#              (universal, function-based)
#
# The Debian counterpart of MacOs/install.sh. Same shape: every step is an
# independent function, prefixed aistackInstall*, each checking its own
# prerequisites and whether the work is already done, so the script (or any
# single function) can be run any number of times.
#
#   aistackInstallSanity          platform + host RAM + accelerator detection
#   aistackInstallDiskGate        HARD BLOCK until enough free disk
#   aistackInstallBaseTools       apt + the handful of packages everything needs
#   --- engines (at least one required; the wizard stops if none) ---
#   aistackInstallLlamacppEngine  llama.cpp   — default YES; upstream binaries
#   aistackInstallOllamaEngine    Ollama      — default no; managed daemon + API
#   --- shared foundations ---
#   aistackInstallUv              uv        (pulled in automatically by LiteLLM)
#   aistackInstallNode            Node + npm (pulled in by every coding agent)
#   --- coding agents (what you type into) ---
#   aistackInstallPiCodingAgent        Pi        — default YES; any engine
#   aistackInstallOpenCodeCodingAgent  OpenCode  — default no;  any engine
#   aistackInstallClaudeCodingAgent    Claude    — default no;  Ollama only
#   --- models, one step per engine, same order, each skipped if absent ---
#   aistackInstallLlamacppModels  GGUF files    -> ~/Models/llama.cpp
#   aistackInstallOllamaModels    registry tags -> ~/.ollama
#   --- monitoring (optional, Linux-specific) ---
#   aistackInstallNvtopMonitoring      nvtop    — default no; GPU/APU usage
#   aistackInstallBtopMonitoring       btop     — default no; CPU/memory/process
#   aistackInstallLitellmMonitoring    LiteLLM  — default no; proxy logging/OTel
#   aistackInstallVerification    status summary
#   aistackInstall                wrapper — runs all of the above in order
#
# There is no MLX-LM step: MLX is Apple's array framework and runs on Apple
# Silicon only. Every place that would offer it names that reason instead of
# silently dropping it. See ../Docs/PlatformNotes.md.
#
# Serving models (engine choice, context size, network exposure, keeping a
# model resident) is NOT an install concern — that is launchInference.sh.
#
# Usage:
#   ./install.sh                 # full pipeline
#   source install.sh            # then call any single function
#
set -u

# ---------- helpers ----------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

# Print a progress heading ("==> ...") naming the step about to run.
info()  { echo "${BLUE}==>${RESET} $*"; }
# Print a success line — also used for "already installed and current",
# so a re-run reads the same whether work happened or not.
ok()    { echo "${GREEN} ✓ ${RESET} $*"; }
# Print a caution line: a caveat, or something skipped by your choice.
warn()  { echo "${YELLOW} ! ${RESET} $*"; }
# Print an error line for something that was attempted and failed.
fail()  { echo "${RED} ✗ ${RESET} $*"; }

# ---------- Linux platform primitives ----------------------------------------
# Everything the macOS implementation reads from sysctl/vm_stat/df -g is read
# here from /proc and GNU coreutils instead. Kept in one block so the
# platform-specific surface is small and greppable.

# Memory the kernel can actually hand out, in whole GB, from /proc/meminfo.
# This is the number the budget is built from, and it is NOT the size printed
# on the RAM stick: MemTotal excludes firmware-reserved and iGPU-carved memory,
# so a 48 GB machine reports 46.
memTotalGb() { awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo; }

# The machine's nominal RAM size in whole GB — the macOS `hw.memsize` analogue.
# MemTotal is rounded UP to the nearest 4 GB, because RAM is sold in multiples
# of 4 and the model catalogs are keyed by that number: without this, a 48 GB
# Linux host would load the 32 GB tier and hide every model it can actually run.
hostRamGb() {
    local t=$(memTotalGb)
    echo $(( ( (t + 3) / 4 ) * 4 ))
}

# Memory available for a new allocation right now, in whole GB.
# MemAvailable is the kernel's own estimate (free + reclaimable), which is the
# honest analogue of macOS's free+inactive+speculative page arithmetic.
availMemGb() { awk '/^MemAvailable:/ {printf "%d", $2/1048576}' /proc/meminfo; }

# How much RAM to leave for the OS and everything else, in GB.
# Overridable, because a headless box can spare more than a desktop one.
RAM_RESERVE_GB="${RAM_RESERVE_GB:-5}"

# Free space in whole GB on the filesystem holding a path (default $HOME).
# Every disk decision reads this rather than trusting an earlier value: a 30 GB
# download changes the answer mid-run. Models live under $HOME, which on Linux
# is often a different filesystem from /, so the path matters.
free_gb() { df -BG --output=avail "${1:-$HOME}" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $1+0}'; }

# This machine's LAN address, empty when offline.
# `ip route get` names the address the kernel would actually source from, which
# is the one worth binding; `hostname -I` is the fallback on a stripped box.
lan_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

# ---------- accelerator detection --------------------------------------------
# macOS has one answer here — unified memory, addressable by the GPU up to
# iogpu.wired_limit_mb. Linux has four (NVIDIA, ROCm, Vulkan-capable iGPU/dGPU,
# plain CPU) and they differ in whether "GPU memory" is even a separate pool.

# What kind of Vulkan device this machine has: discrete | integrated | none.
# llvmpipe reports PHYSICAL_DEVICE_TYPE_CPU — it is a software rasteriser, not
# an accelerator, and offloading to it means running the model on the CPU the
# slow way. It must never count as a GPU.
vulkanDeviceClass() {
    command -v vulkaninfo >/dev/null 2>&1 || { echo none; return 0; }
    local types
    types=$(vulkaninfo --summary 2>/dev/null | awk -F= '/deviceType/ {gsub(/[ \t]/,"",$2); print $2}')
    case "$types" in
        *DISCRETE_GPU*)   echo discrete ;;
        *INTEGRATED_GPU*) echo integrated ;;
        *)                echo none ;;
    esac
}

# Which accelerator stack is usable, as one word.
# Prints: nvidia | rocm | vulkan | cpu. Ordered by how much llama.cpp gains
# from it, so the first hit is the one worth building/downloading for.
gpuVendor() {
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        echo nvidia; return 0
    fi
    if command -v rocminfo >/dev/null 2>&1 || command -v rocm-smi >/dev/null 2>&1; then
        echo rocm; return 0
    fi
    # a render node plus a real (non-llvmpipe) Vulkan device — the path AMD
    # APUs, Intel iGPUs and unaccelerated discrete cards take
    if [ -e /dev/dri/renderD128 ] && [ "$(vulkanDeviceClass)" != "none" ]; then
        echo vulkan; return 0
    fi
    echo cpu
}

# Dedicated video memory in whole GB, 0 when there is none to speak of.
# Only meaningful for a discrete card: an APU's "VRAM" is carved out of the
# same system RAM the model already has to fit into, so it is not a budget.
gpuVramGb() {
    local mib=0
    case "$(gpuVendor)" in
        nvidia) mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1) ;;
        rocm)   mib=$(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F, 'NR==2 {printf "%d", $2/1048576}') ;;
    esac
    case "${mib:-0}" in ""|*[!0-9]*) mib=0 ;; esac
    echo $(( mib / 1024 ))
}

# The memory budget a model has to fit into, in whole GB.
# On Linux this is system RAM minus a reserve — for CPU inference obviously,
# but also for GPU inference, because the weights are read into host memory on
# the way to the card and a model bigger than RAM cannot be loaded at all.
# VRAM decides how FAST it runs (how many layers offload), not whether it fits;
# that distinction is reported separately by budgetSummary().
inferenceBudgetGb() {
    # memTotalGb, not hostRamGb: the budget must be built from memory that
    # actually exists to be allocated, never from the rounded-up nominal size.
    local b=$(( $(memTotalGb) - RAM_RESERVE_GB ))
    [ "$b" -lt 1 ] && b=1
    echo "$b"
}

# One line describing where the budget came from and what the GPU adds.
# Printed wherever macOS prints its iogpu limit, so the number on screen is
# always explained rather than asserted.
budgetSummary() {
    local v vram
    v=$(gpuVendor); vram=$(gpuVramGb)
    case "$v" in
        nvidia) echo "$(inferenceBudgetGb) GB usable RAM; NVIDIA GPU with ${vram} GB VRAM (layers beyond it run on CPU)" ;;
        rocm)   echo "$(inferenceBudgetGb) GB usable RAM; ROCm GPU with ${vram} GB VRAM (layers beyond it run on CPU)" ;;
        vulkan) if [ "$(vulkanDeviceClass)" = "discrete" ]; then
                    echo "$(inferenceBudgetGb) GB usable RAM; discrete Vulkan GPU, layers offloaded to it"
                else
                    echo "$(inferenceBudgetGb) GB usable RAM; integrated Vulkan GPU sharing that same memory (generation stays on CPU — see PlatformNotes)"
                fi ;;
        *)      echo "$(inferenceBudgetGb) GB usable RAM; CPU inference (no usable GPU backend detected)" ;;
    esac
}

# A real, pasteable tag for one engine — an installed model if there is one,
# otherwise the smallest entry from that engine's catalog.
# Args: <engine>. Prints nothing when neither is available.
_liveTagFor() {
    local engine="$1" t f
    case "$engine" in
        Ollama)    t=$(ollamaListInstalled 2>/dev/null | head -1) ;;
        Llama.cpp) t=$(llamacppListInstalled 2>/dev/null | head -1) ;;
    esac
    [ -n "$t" ] && { echo "$t"; return 0; }
    f=$(MODEL_LIST_ENGINE="$engine" modelListFile "$(hostRamGb)" 2>/dev/null)
    [ -f "$f" ] && python3 -c '
import json,sys
try:
    ms=json.load(open(sys.argv[1]))["models"]
    print(sorted(ms, key=lambda m: m["size_gb"])[0]["tag"])
except Exception: pass' "$f"
}

# Build an "example :" line for the install-side helpers from live data, and
# say what to install first when there is nothing to point at.
# Args: <function-name> <kind>  (kind: ollama-tag | gguf-tag | any)
_hintTagExample() {
    local fn="$1" kind="$2" t pad="\n         "
    case "$kind" in
        ollama-tag) t=$(_liveTagFor Ollama) ;;
        gguf-tag)   t=$(_liveTagFor Llama.cpp) ;;
        *)          t=$(_liveTagFor Ollama); [ -z "$t" ] && t=$(_liveTagFor Llama.cpp) ;;
    esac
    if [ -n "$t" ]; then printf '%s' "example : ${fn} ${t}"; return 0; fi
    printf '%b' "example : none possible yet — nothing installed and no catalog to read.${pad}install an engine:  aistackInstallLlamacppEngine   (or ...OllamaEngine)${pad}then models:        aistackInstallLlamacppModels   (or ...OllamaModels)"
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

# Ask a yes/no question, looping until the answer is unambiguous.
# Reads /dev/tty so the prompt survives piped output, and aborts when there is
# no terminal. Returns 0 for yes, 1 for no; no Enter-default.
ask() {
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
# Args: <question> <y|n>; the [Y/n] or [y/N] hint reflects it. Optional installs
# pass "n", expected ones pass "y", so a re-run is mostly Enter.
ask_def() {
    if [ $# -lt 2 ]; then
        aiStackUsage "ask_def <question> <y|n>" "example : ask_def \"Install it?\" y"
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

# ---------- apt plumbing ------------------------------------------------------
# Nothing here shells out to apt without going through these two, so the
# "our questions are the ones that matter" rule (no double prompting) is
# enforced in one place, exactly as the macOS side does it with brew -y.

# Run one privileged command, explaining why sudo is needed the first time.
# Args: the command and its arguments. Fails clearly when sudo is absent
# rather than emitting a bare "permission denied" from deep inside a step.
_asRoot() {
    if [ "$(id -u)" = "0" ]; then "$@"; return $?; fi
    command -v sudo >/dev/null 2>&1 || { fail "sudo is required for: $* (and is not installed)."; return 1; }
    sudo "$@"
}

# True when a .deb package is installed.
# Args: <package>. dpkg-query is the only source that distinguishes "installed"
# from "known to apt" — `apt list` conflates them.
_debInstalled() {
    dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null | grep -qx installed
}

# apt-get install, non-interactive, without re-asking what we already asked.
# Args: one or more packages. Refreshes the package lists at most once per run,
# because a stale index is the usual cause of a "package not found" surprise.
APT_UPDATED=0
_aptInstall() {
    [ $# -ge 1 ] || { aiStackUsage "_aptInstall <package> [package...]" "example : _aptInstall btop"; return 2; }
    if [ "$APT_UPDATED" -eq 0 ]; then
        info "Refreshing apt package lists..."
        _asRoot apt-get update -qq || warn "apt-get update failed — continuing with the cached lists."
        APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive _asRoot apt-get install -y -qq "$@"
}

# The newest version apt could install for a package, empty when none.
# Args: <package>. Used for the "offer an upgrade only when one exists" rule.
_aptCandidate() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}'; }
# The version currently installed, empty when the package is absent.
_aptInstalledVersion() { apt-cache policy "$1" 2>/dev/null | awk '/Installed:/ {print $2}'; }

# Install or update one apt-delivered tool, asking only when there is a choice.
# Args: <package> <label> <y|n default> <one-line reason>. Present -> compares
# installed against candidate and asks only when they differ; missing -> offers
# the install at the caller's default. The apt twin of macOS's brew helper.
_aiStackAptTool() {
    if [ $# -lt 4 ]; then
        aiStackUsage "_aiStackAptTool <package> <label> <y|n> <reason>" "example : _aiStackAptTool btop btop n reason-text"
        return 2
    fi
    local pkg="$1" label="$2" def="$3" why="$4" cur cand
    if _debInstalled "$pkg"; then
        cur=$(_aptInstalledVersion "$pkg"); cand=$(_aptCandidate "$pkg")
        ok "${label} present: ${cur}"
        if [ -n "$cand" ] && [ "$cand" != "$cur" ] && [ "$cand" != "(none)" ]; then
            warn "A newer ${label} is available: ${cur} -> ${cand}"
            ask_def "Upgrade ${label} now?" "y" && _aptInstall "$pkg"
        else
            ok "Already the latest version apt offers."
        fi
        return 0
    fi
    echo "    ${why}"
    if ask_def "Install ${label}?" "$def"; then
        _aptInstall "$pkg" && ok "${label} installed." || { fail "apt-get install ${pkg} failed."; return 1; }
    else
        warn "Skipping ${label}."
    fi
}

# ---------- registry tag availability (cached 24 h) --------------------------
# Neither the Ollama registry nor HuggingFace has a list-everything endpoint,
# so this does the next-best thing: one tiny existence probe per candidate tag,
# all in parallel, cached for a day — first run ~2 s, reruns instant. A tag
# containing "/" is a HuggingFace repo (llama.cpp GGUF); otherwise it is an
# Ollama registry tag.
TAG_CHECK_DEADLINE="${TAG_CHECK_DEADLINE:-20}"
TAG_CACHE_DIR="$HOME/.cache/ollama-tag-check"
# Path of the cache entry for one model tag's availability probe.
# Args: <tag>. Slashes and colons become underscores so any tag is a filename.
tag_cache_file() { [ $# -ge 1 ] || { aiStackUsage "tag_cache_file <tag>" "$(_hintTagExample tag_cache_file any)"; return 2; }; echo "$TAG_CACHE_DIR/$(echo "$1" | tr ':/' '__')"; }
# Probe whether one model tag exists upstream, caching the result for 24 h.
# Args: <tag>. A tag containing "/" is a HuggingFace repo, otherwise an Ollama
# registry tag. Meant to be run in parallel for a whole menu; the cache makes
# the first render ~2 s and every later one instant.
tag_check_prefetch() {   # probe one tag and cache the HTTP status
    if [ $# -lt 1 ]; then
        aiStackUsage "tag_check_prefetch <tag>" \
            "tag     : ollama tag, or org/repo[:quant] for HuggingFace" \
            "$(_hintTagExample tag_check_prefetch any)"
        return 2
    fi
    local f code name="${1%%:*}" t="${1#*:}" url
    f=$(tag_cache_file "$1")
    mkdir -p "$TAG_CACHE_DIR"
    [ -f "$f" ] && [ -n "$(find "$f" -mmin -1440 2>/dev/null)" ] && return 0
    case "$name" in
        */*) url="https://huggingface.co/api/models/${name#hf.co/}" ;;   # HF repo: llama.cpp GGUF
        *)   url="https://registry.ollama.ai/v2/library/${name}/manifests/${t}" ;;
    esac
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "$url" 2>/dev/null)
    echo "${code:-000}" > "$f"
}
# Probe a whole menu's tags in parallel, under a hard deadline. Args: <tag>...
# curl's own --max-time bounds a transfer, but not a name lookup that never
# returns: on a flaky or captive network the resolver can outlive it, and a bare
# "wait" then blocks the installer with no way out but Ctrl-C. Stragglers are
# killed when the deadline passes and their tags are simply left unverified,
# which tag_available already treats as available — the model is offered and, at
# worst, fails at download. Interrupting only abandons the check, not the wizard.
_tagVerifyAll() {
    [ $# -ge 1 ] || return 0
    local pids=() pid tag waited=0 alive skipped=0
    trap 'skipped=1' INT
    for tag in "$@"; do
        tag_check_prefetch "$tag" &
        pids+=($!)
    done
    while [ "$waited" -lt "$TAG_CHECK_DEADLINE" ] && [ "$skipped" = "0" ]; do
        alive=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && { alive=1; break; }; done
        [ "$alive" = "0" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    trap - INT
    local stuck=0
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            stuck=$((stuck + 1))
            # reap each one individually with stderr closed: bash announces
            # "Terminated"/"Killed" for a job it reaps, and that noise would
            # look like a failure in the middle of an install
            { pkill -P "$pid"; kill -9 "$pid"; wait "$pid"; } 2>/dev/null
        fi
    done
    { wait; } 2>/dev/null
    if [ "$skipped" = "1" ]; then
        warn "Upstream check skipped — every candidate is offered unverified."
    elif [ "$stuck" -gt 0 ]; then
        warn "${stuck} probe(s) did not answer within ${TAG_CHECK_DEADLINE}s — offered unverified."
        warn "The registry may be slow or unreachable; a download would still tell you."
    fi
    return 0
}

# True when a probed tag exists (HTTP 200).
# Args: <tag>. An unreachable network (000/empty) counts as available: better to
# offer a model and fail at download than to hide everything while offline.
tag_available() {        # 200 = exists; 000/empty (offline) = benefit of the doubt
    if [ $# -lt 1 ]; then
        aiStackUsage "tag_available <tag>" \
            "run tag_check_prefetch <tag> first" \
            "$(_hintTagExample tag_available any)"
        return 2
    fi
    local c
    c=$(cat "$(tag_cache_file "$1")" 2>/dev/null)
    [ "$c" = "200" ] || [ "$c" = "000" ] || [ -z "$c" ]
}

# ---------- Ollama on Linux: where the models actually live ------------------
# The upstream installer registers a systemd service that runs as the 'ollama'
# system user with HOME=/usr/share/ollama, so models pulled through it land in
# /usr/share/ollama/.ollama/models — NOT in ~/.ollama. This stack runs the
# daemon as you, and every path below resolves through this function so both
# layouts are visible rather than one silently looking empty.

# The directory Ollama stores manifests and blobs in.
# Honours $OLLAMA_MODELS, then a non-empty ~/.ollama, then the system service's
# location. Prints a path; the path may not exist yet.
ollamaModelsDir() {
    if [ -n "${OLLAMA_MODELS:-}" ]; then echo "$OLLAMA_MODELS"; return 0; fi
    if [ -d "$HOME/.ollama/models/manifests" ]; then echo "$HOME/.ollama/models"; return 0; fi
    if [ -d /usr/share/ollama/.ollama/models/manifests ]; then echo /usr/share/ollama/.ollama/models; return 0; fi
    echo "$HOME/.ollama/models"
}
# True when the system-wide ollama.service exists (enabled or not).
ollamaSystemService() { systemctl list-unit-files ollama.service >/dev/null 2>&1; }
# True when the system-wide ollama.service is currently running.
ollamaSystemServiceActive() { systemctl is-active --quiet ollama.service 2>/dev/null; }

# ---------- failed-download cleanup ------------------------------------------
# Delete Ollama blobs that no manifest references — the debris of failed pulls.
# Args: [ask] to confirm first, since leftovers can also resume an interrupted
# download. Skips entirely while a pull is running and never touches a file that
# is open, so an in-flight 30 GB download cannot be destroyed by cleanup.
ollama_prune_orphan_blobs() {
    local root blobdir mdir
    root=$(ollamaModelsDir)
    blobdir="${root}/blobs"; mdir="${root}/manifests"
    [ -d "$blobdir" ] || return 0
    if [ ! -w "$blobdir" ]; then
        warn "${blobdir} is not writable by you (system-service layout) — skipping cleanup."
        return 0
    fi
    if pgrep -f "ollama pull" >/dev/null 2>&1; then
        warn "Another 'ollama pull' is running — skipping orphan-blob cleanup."
        return 0
    fi
    # collect the orphans first (referenced-by-no-manifest, not open anywhere)
    local refs f base before after orphans=() total_mb=0 sz
    refs=$(grep -rho 'sha256:[a-f0-9]\{64\}' "$mdir" 2>/dev/null | sort -u | tr ':' '-')
    for f in "$blobdir"/sha256-*; do
        [ -e "$f" ] || continue
        base=$(basename "$f"); base=${base%-partial*}
        echo "$refs" | grep -qx "$base" && continue     # referenced by a model
        lsof "$f" >/dev/null 2>&1 && continue           # open by a process
        orphans+=("$f")
        sz=$(du -m "$f" 2>/dev/null | cut -f1)
        total_mb=$(( total_mb + ${sz:-0} ))
    done
    [ "${#orphans[@]}" -eq 0 ] && { ok "No orphaned download data to clean."; return 0; }

    # mode "ask": leftover data can RESUME an interrupted pull of the same
    # model — let the user choose between disk space and resume
    if [ "${1:-}" = "ask" ]; then
        warn "$(( total_mb / 1024 )) GB of leftover data from failed/interrupted pulls found."
        if ! ask_def "Delete it now? (n = keep it so re-pulling the same model resumes)" "y"; then
            ok "Keeping — re-select the same model and the download resumes from this data."
            return 0
        fi
    fi

    before=$(free_gb "$blobdir")
    for f in "${orphans[@]}"; do rm -f "$f"; done
    after=$(free_gb "$blobdir")
    ok "Cleaned up failed-download leftovers: freed $((after - before)) GB (free now: ${after} GB)."
}

# Where to reach the Ollama API (launchInference.sh may bind it to a LAN IP).
OLLAMA_API="${OLLAMA_API:-127.0.0.1}"
# True when the Ollama API answers on OLLAMA_API:11434.
ollama_server_up() { curl -sf "http://${OLLAMA_API}:11434/api/version" >/dev/null 2>&1; }

# True when Ollama already has this exact tag. Args: <tag>.
model_installed() { [ $# -ge 1 ] || { aiStackUsage "model_installed <ollama-tag>" "$(_hintTagExample model_installed ollama-tag)"; return 2; }; ollamaListInstalled 2>/dev/null | grep -qx "$1"; }

# ---------- engine detection --------------------------------------------------
# Where the upstream llama.cpp tarball is unpacked, and where its binaries are
# linked from. Both under ~/.local so nothing here needs root.
LLAMACPP_PREFIX="${LLAMACPP_PREFIX:-$HOME/.local/opt/llama.cpp}"
LLAMACPP_BINDIR="${LLAMACPP_BINDIR:-$HOME/.local/bin}"

# True when llama.cpp is installed (llama-cli or llama-server on PATH).
llamacpp_installed() { command -v llama-cli >/dev/null 2>&1 || command -v llama-server >/dev/null 2>&1; }
# True when the ollama binary is on PATH.
ollama_installed()   { command -v ollama >/dev/null 2>&1; }

# Space-separated list of engines present, empty when none.
# The wrapper uses this as a gate: with no engine, every step below it — models
# included — would be meaningless, so the wizard stops there.
installed_engines() {
    local e=""
    llamacpp_installed && e="${e} llama.cpp"
    ollama_installed   && e="${e} Ollama"
    echo "${e# }"
}

# Check there is room for a download, and say so either way.
# Args: <GB needed> <what for>. Returns 1 when short, printing both numbers.
# Called immediately before each pull, not once at the start.
require_disk() {
    if [ $# -lt 2 ]; then
        aiStackUsage "require_disk <GB-needed> <what-for>" "example : require_disk 25 qwen3.6-plus-headroom"
        return 2
    fi
    local need=$1 what=$2 have
    have=$(free_gb)
    if [ "$have" -lt "$need" ]; then
        fail "Not enough disk for ${what}: need ~${need} GB free, have ${have} GB."
        return 1
    fi
    ok "Disk OK for ${what} (${have} GB free, need ~${need} GB)."
}

# ---------- step: sanity — platform, RAM, accelerator ------------------------
# Step 1: confirm the machine can run this at all, and measure it.
# Requires a Debian-family Linux and at least 16 GB RAM. Sets TOTAL_GB and
# GPU_GB (here: the usable-RAM budget, see inferenceBudgetGb) which size every
# later menu, and names the accelerator so nothing later has to guess.
aistackInstallSanity() {
    info "aistackInstallSanity — platform, memory and accelerator detection"
    if [ "$(uname -s)" != "Linux" ]; then
        fail "This is the Debian implementation; this machine is $(uname -s)."
        return 1
    fi
    local ids=""
    [ -r /etc/os-release ] && ids=$( . /etc/os-release; echo "${ID:-} ${ID_LIKE:-}" )
    case " ${ids} " in
        *debian*|*ubuntu*) : ;;
        *) fail "Only Debian-based Linux is supported — this is: ${ids:-unknown distribution}."; return 1 ;;
    esac
    ok "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Debian-based Linux}") on $(uname -m)."

    TOTAL_GB=$(hostRamGb)
    GPU_GB=$(inferenceBudgetGb)
    if [ "$TOTAL_GB" -lt 16 ]; then
        fail "Only ${TOTAL_GB} GB RAM — below the 16 GB minimum for local coding models."
        return 1
    fi
    ok "${TOTAL_GB} GB RAM ($(memTotalGb) GB allocatable) — model budget ~${GPU_GB} GB, reserving ${RAM_RESERVE_GB} GB for the OS."
    ok "Accelerator: $(budgetSummary)"
    case "$(gpuVendor)" in
        cpu) warn "CPU-only inference: expect single-digit tokens/second on 30B-class models." ;;
    esac
}

# ---------- step: HARD GATE — disk space -------------------------------------
MIN_DISK_GB=25
RECOMMENDED_DISK_GB=60
# Step 2: HARD BLOCK until there is enough free disk. No bypass.
# Below 25 GB it shows the shortfall and the measured disk hogs, offers the
# three reclaims that actually move the needle on a Debian box (apt archives,
# the journal, the trash), and loops on Enter to re-check.
aistackInstallDiskGate() {
    info "aistackInstallDiskGate — disk space (need >= ${MIN_DISK_GB} GB, ${RECOMMENDED_DISK_GB}+ recommended)"
    local have
    while true; do
        have=$(free_gb)
        if [ "$have" -ge "$MIN_DISK_GB" ]; then
            [ "$have" -lt "$RECOMMENDED_DISK_GB" ] \
                && warn "${have} GB free on $(df --output=target "$HOME" | tail -1) — meets the minimum, below the recommended ${RECOMMENDED_DISK_GB} GB." \
                || ok "${have} GB free — requirement met."
            return 0
        fi
        fail "REQUIREMENT NOT MET: ${have} GB free, need at least ${MIN_DISK_GB} GB (short by $((MIN_DISK_GB - have)) GB)."
        echo
        echo "    ${BOLD}Nothing can be installed until disk space is freed.${RESET}"
        echo "    Usual suspects (actual sizes):"
        local d
        for d in "$HOME/.cache" "$HOME/.ollama" "$HOME/Models" \
                 "$HOME/.local/share/Trash" "$HOME/.cache/huggingface" \
                 /var/lib/docker /var/cache/apt/archives /var/log; do
            [ -d "$d" ] && echo "      $(du -sh "$d" 2>/dev/null | awk '{print $1}')	$d"
        done
        command -v journalctl >/dev/null 2>&1 && \
            echo "      $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | tail -1)	systemd journal"

        # the three reclaims that are safe, measurable and usually large
        if ask_def "Free the apt package cache and autoremove orphaned packages (sudo)?" "n"; then
            local b; b=$(free_gb /var)
            _asRoot apt-get clean >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive _asRoot apt-get autoremove -y -qq >/dev/null 2>&1
            ok "apt cleanup freed $(( $(free_gb /var) - b )) GB."
        fi
        if command -v journalctl >/dev/null 2>&1 && ask_def "Trim the systemd journal to 200 MB (sudo)?" "n"; then
            local b2; b2=$(free_gb /var)
            _asRoot journalctl --vacuum-size=200M >/dev/null 2>&1
            ok "Journal trim freed $(( $(free_gb /var) - b2 )) GB."
        fi
        if [ -d "$HOME/.local/share/Trash" ] && [ -n "$(ls -A "$HOME/.local/share/Trash" 2>/dev/null)" ] \
           && ask_def "Empty the trash ($(du -sh "$HOME/.local/share/Trash" 2>/dev/null | cut -f1))?" "n"; then
            local b3; b3=$(free_gb)
            rm -rf "$HOME/.local/share/Trash"/* 2>/dev/null
            ok "Emptying the trash freed $(( $(free_gb) - b3 )) GB."
        fi

        printf "    %sPress Enter to re-check, or type q to quit:%s " "${BOLD}" "${RESET}"
        local REPLY=""
        read -r REPLY </dev/tty || { echo; fail "No interactive terminal available — aborting."; exit 1; }
        [ "$REPLY" = "q" ] || [ "$REPLY" = "Q" ] && { echo "Aborted — re-run once ${MIN_DISK_GB}+ GB is free."; return 1; }
    done
}

# ---------- step: base tools -------------------------------------------------
# Step 3: the handful of packages every later step assumes.
# The Debian counterpart of aistackInstallHomebrew: apt itself is always there,
# so what needs establishing is the small set of tools the rest of the script
# shells out to. Declining ends the wizard rather than half-building a stack.
BASE_PACKAGES="curl ca-certificates tar gzip python3 jq lsof procps iproute2"
aistackInstallBaseTools() {
    info "aistackInstallBaseTools — the packages every later step needs"
    command -v apt-get >/dev/null 2>&1 || { fail "apt-get not found — this is not a Debian-family system."; return 1; }

    local missing="" p
    for p in $BASE_PACKAGES; do
        _debInstalled "$p" || missing="${missing} ${p}"
    done
    if [ -z "$missing" ]; then
        ok "All base tools present: ${BASE_PACKAGES}"
        return 0
    fi
    warn "Missing:${missing}"
    echo "    Everything below shells out to these — curl for downloads, python3 for"
    echo "    JSON, jq/lsof/ss for the measurements this toolkit refuses to estimate."
    ask_def "Install them with apt now?" "y" || { fail "Everything below requires these tools."; return 1; }
    # shellcheck disable=SC2086
    _aptInstall $missing || { fail "apt-get install failed."; return 1; }
    ok "Base tools installed."
}

# ---------- llama.cpp: upstream release binaries -----------------------------
# Debian has no llama.cpp package, so the engine comes from the project's own
# releases: a tarball of statically-laid-out binaries plus their .so files.
# The "latest" GitHub endpoint points at a different tag series, so the release
# list is scanned for the newest build (bNNNNN) that actually carries the asset.

# The asset-name fragment for the accelerator worth using on this machine.
# Prints e.g. "ubuntu-vulkan-x64". NVIDIA deliberately maps to vulkan: upstream
# publishes no Linux CUDA tarball, and Vulkan drives NVIDIA cards well — a
# source build is offered separately for anyone who wants CUDA proper.
llamacppPreferredAsset() {
    local arch flavour
    case "$(uname -m)" in
        x86_64)  arch="x64" ;;
        aarch64) arch="arm64" ;;
        s390x)   echo "ubuntu-s390x"; return 0 ;;
        *)       arch="x64" ;;
    esac
    case "$(gpuVendor)" in
        rocm)            flavour="rocm" ;;
        vulkan|nvidia)   flavour="vulkan" ;;
        *)               flavour="" ;;
    esac
    [ -n "$flavour" ] && echo "ubuntu-${flavour}-${arch}" || echo "ubuntu-${arch}"
}

# Resolve one release asset: prints "<build-tag> <download-url>".
# Args: <asset-fragment>. Walks the most recent releases because a single
# release may omit a flavour, and returns nothing when none carry it.
llamacppResolveAsset() {
    [ $# -ge 1 ] || { aiStackUsage "llamacppResolveAsset <asset-fragment>" "example : llamacppResolveAsset ubuntu-x64"; return 2; }
    # NB: python3 -c, NOT "python3 - <<HEREDOC". A heredoc feeding the script
    # to python REPLACES stdin, so json.load(sys.stdin) would read the script
    # text instead of the piped JSON and silently resolve nothing.
    curl -sf --max-time 25 "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10" 2>/dev/null \
    | python3 -c '
import json, re, sys
frag = sys.argv[1]
try:
    rels = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for r in rels:
    tag = r.get("tag_name", "")
    if not re.fullmatch(r"b\d+", tag):
        continue
    for a in r.get("assets", []):
        n = a.get("name", "")
        if frag in n and n.endswith(".tar.gz"):
            print(tag, a.get("browser_download_url", ""))
            sys.exit(0)
' "$1"
}

# The build number of the installed llama.cpp, empty when not installed.
# `llama-cli --version` prints "build 10618", which is directly comparable with
# the bNNNNN release tags — so the update check needs no state file.
llamacppInstalledBuild() {
    llamacpp_installed || return 0
    llama-cli --version 2>&1 | sed -n 's/.*build \([0-9]*\).*/\1/p' | head -1
}

# Which ggml backend the installed llama.cpp actually carries.
# Inspects the libraries beside the resolved binary, because that is the only
# statement that stays true when the engine was installed some other way.
# Prints: cuda | hip | vulkan | sycl | cpu | unknown.
llamacppBackend() {
    local bin dir
    bin=$(command -v llama-server 2>/dev/null || command -v llama-cli 2>/dev/null) || { echo unknown; return 0; }
    dir=$(dirname "$(readlink -f "$bin")")
    if   ls "$dir"/libggml-cuda.so*   >/dev/null 2>&1; then echo cuda
    elif ls "$dir"/libggml-hip.so*    >/dev/null 2>&1; then echo hip
    elif ls "$dir"/libggml-vulkan.so* >/dev/null 2>&1; then echo vulkan
    elif ls "$dir"/libggml-sycl.so*   >/dev/null 2>&1; then echo sycl
    elif ls "$dir"/libggml-cpu*.so    >/dev/null 2>&1; then echo cpu
    else echo unknown
    fi
}

# Unpack a release tarball into the prefix and link its binaries onto PATH.
# Args: <tarball> <build-tag>. Verifies the binary actually RUNS before
# declaring success — upstream builds against a newer glibc than Debian stable
# ships, and a tarball that unpacks but cannot execute is the failure mode this
# check exists to catch.
llamacppInstallTarball() {
    if [ $# -lt 2 ]; then
        aiStackUsage "llamacppInstallTarball <tarball> <build-tag>" "example : llamacppInstallTarball /tmp/llama.tar.gz b10618"
        return 2
    fi
    local tarball="$1" tag="$2" b
    rm -rf "${LLAMACPP_PREFIX}.new"
    mkdir -p "${LLAMACPP_PREFIX}.new" "$LLAMACPP_BINDIR"
    tar -xzf "$tarball" -C "${LLAMACPP_PREFIX}.new" --strip-components=1 || {
        fail "Could not unpack ${tarball}."
        rm -rf "${LLAMACPP_PREFIX}.new"; return 1
    }
    # prove it runs on THIS system before replacing a working install
    if ! "${LLAMACPP_PREFIX}.new/llama-cli" --version >/dev/null 2>&1; then
        fail "The upstream binary does not run on this system:"
        "${LLAMACPP_PREFIX}.new/llama-cli" --version 2>&1 | sed 's/^/      /' | head -3
        warn "Usually a glibc mismatch — upstream builds on a newer Ubuntu than Debian stable."
        warn "Build from source instead:  aistackInstallLlamacppEngine   (choose 'build from source')"
        rm -rf "${LLAMACPP_PREFIX}.new"
        return 1
    fi
    rm -rf "$LLAMACPP_PREFIX"
    mv "${LLAMACPP_PREFIX}.new" "$LLAMACPP_PREFIX"
    for b in "$LLAMACPP_PREFIX"/llama-*; do
        [ -x "$b" ] && [ ! -d "$b" ] || continue
        ln -sf "$b" "${LLAMACPP_BINDIR}/$(basename "$b")"
    done
    echo "$tag" > "${LLAMACPP_PREFIX}/.aistack-build"
    ok "llama.cpp ${tag} installed in ${LLAMACPP_PREFIX}, linked into ${LLAMACPP_BINDIR}."
    case ":${PATH}:" in
        *":${LLAMACPP_BINDIR}:"*) : ;;
        *) warn "${LLAMACPP_BINDIR} is not on your PATH — add it:"
           warn "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
    esac
}

# Build llama.cpp from source into the prefix.
# The fallback for two real cases: a distro older than the upstream binaries'
# glibc, and NVIDIA users who want CUDA rather than Vulkan. Slow (minutes), so
# it is never the default — but it is the only path that always works.
llamacppBuildFromSource() {
    local src="${LLAMACPP_PREFIX}.src" flags="" b
    info "Building llama.cpp from source (this takes several minutes)."
    # two kinds of prerequisite: commands we can test for directly, and dev
    # packages that provide headers rather than a binary — checked with dpkg
    local need="" p
    for p in git cmake; do
        command -v "$p" >/dev/null 2>&1 || need="${need} ${p}"
    done
    for p in build-essential libcurl4-openssl-dev; do
        _debInstalled "$p" || need="${need} ${p}"
    done
    if [ -n "$need" ]; then
        echo "    Build prerequisites missing:${need}"
        ask_def "Install them with apt?" "y" || { fail "Cannot build without them."; return 1; }
        # shellcheck disable=SC2086
        _aptInstall $need || return 1
    fi
    if command -v nvcc >/dev/null 2>&1; then
        flags="-DGGML_CUDA=ON"
        ok "CUDA toolkit found (nvcc) — building with the CUDA backend."
    elif [ "$(gpuVendor)" = "rocm" ] && command -v hipcc >/dev/null 2>&1; then
        flags="-DGGML_HIP=ON"
        ok "ROCm found (hipcc) — building with the HIP backend."
    elif [ "$(gpuVendor)" = "vulkan" ]; then
        flags="-DGGML_VULKAN=ON"
        ok "Vulkan available — building with the Vulkan backend."
        _debInstalled libvulkan-dev || _aptInstall libvulkan-dev glslc || warn "Vulkan headers missing — the build may fall back to CPU."
    else
        ok "Building the CPU backend."
    fi
    rm -rf "$src"
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$src" || { fail "git clone failed."; return 1; }
    # shellcheck disable=SC2086
    cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON $flags \
        && cmake --build "$src/build" --config Release -j "$(nproc)" \
        || { fail "Build failed — see the output above."; return 1; }
    rm -rf "$LLAMACPP_PREFIX"
    mkdir -p "$LLAMACPP_PREFIX" "$LLAMACPP_BINDIR"
    cp -a "$src/build/bin/." "$LLAMACPP_PREFIX/" 2>/dev/null || { fail "Could not collect the built binaries."; return 1; }
    for b in "$LLAMACPP_PREFIX"/llama-*; do
        [ -x "$b" ] && [ ! -d "$b" ] || continue
        ln -sf "$b" "${LLAMACPP_BINDIR}/$(basename "$b")"
    done
    echo "source-$(cd "$src" && git rev-parse --short HEAD)" > "${LLAMACPP_PREFIX}/.aistack-build"
    rm -rf "$src"
    ok "llama.cpp built and installed in ${LLAMACPP_PREFIX}."
}

# ---------- engine step: llama.cpp (asked first, default YES) ----------------
# Engine step, default YES: install llama.cpp from the project's own releases.
# Recommended first because it is the only engine here that reaches the Q5_K_M
# and Q6_K quants — Ollama's registry carries q4_K_M and q8_0 and nothing
# between. Already installed: compares the build number against the newest
# release and offers an upgrade only when one exists.
aistackInstallLlamacppEngine() {
    info "aistackInstallLlamacppEngine — llama.cpp (GGUF engine)"
    local asset resolved tag url cur
    asset=$(llamacppPreferredAsset)

    if llamacpp_installed; then
        cur=$(llamacppInstalledBuild)
        ok "llama.cpp present: build ${cur:-unknown}, backend $(llamacppBackend), at $(command -v llama-server || command -v llama-cli)"
        resolved=$(llamacppResolveAsset "$asset")
        tag=${resolved%% *}
        if [ -z "$tag" ]; then
            ok "Update check skipped (GitHub unreachable)."
        elif [ -n "$cur" ] && [ "${tag#b}" -gt "$cur" ] 2>/dev/null; then
            warn "A newer llama.cpp is available: build ${cur} -> ${tag}"
            if ask_def "Upgrade llama.cpp now?" "y"; then
                url=${resolved#* }
                local tmp; tmp=$(mktemp -d)
                info "Downloading ${asset} (${tag})..."
                curl -L --fail --progress-bar -o "${tmp}/llama.tar.gz" "$url" \
                    && llamacppInstallTarball "${tmp}/llama.tar.gz" "$tag"
                rm -rf "$tmp"
            fi
        else
            ok "Already the latest release."
        fi
        return 0
    fi

    echo "    The only engine here that reaches the Q5_K_M / Q6_K quants —"
    echo "    Ollama's registry stops at q4_K_M and q8_0."
    echo "    Debian has no llama.cpp package, so this installs the project's own"
    echo "    Linux build into ${LLAMACPP_PREFIX} (no root needed)."
    echo "    Backend chosen for this machine: ${asset}   [$(budgetSummary)]"
    case "$(gpuVendor)" in
        nvidia) warn "NVIDIA detected. Upstream ships no Linux CUDA tarball, so the Vulkan build"
                warn "is used — it drives NVIDIA well. Choose the source build for CUDA proper." ;;
    esac
    if ! ask_def "Install llama.cpp?" "y"; then
        warn "Skipping llama.cpp."
        return 0
    fi

    # two ways in; only ask when both are genuinely on the table
    local how=1
    echo
    echo "  1) Upstream release binary  (${asset}) — seconds, no compiler"
    echo "  2) Build from source        — minutes; needed on older Debian, or for CUDA"
    printf "%sHow should llama.cpp be installed? [1-2]%s [1]: " "${BOLD}" "${RESET}"
    read -r how </dev/tty || how=1
    [ -z "$how" ] && how=1
    if [ "$how" = "2" ]; then
        llamacppBuildFromSource
        return $?
    fi

    resolved=$(llamacppResolveAsset "$asset")
    if [ -z "$resolved" ]; then
        fail "No ${asset} tarball found in the recent llama.cpp releases."
        warn "Build from source instead — re-run and choose option 2."
        return 1
    fi
    tag=${resolved%% *}; url=${resolved#* }
    local tmp; tmp=$(mktemp -d)
    info "Downloading llama.cpp ${tag} (${asset})..."
    if curl -L --fail --progress-bar -o "${tmp}/llama.tar.gz" "$url"; then
        llamacppInstallTarball "${tmp}/llama.tar.gz" "$tag" || {
            rm -rf "$tmp"
            if ask_def "Build from source instead?" "y"; then llamacppBuildFromSource; return $?; fi
            return 1
        }
    else
        fail "Download failed."
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
}

# ---------- step: Ollama engine ----------------------------------------------
# Engine step, default no: install Ollama through its official Linux installer.
# Its advantages are a managed daemon and the Anthropic API that Claude Code
# needs; its quant ladder is the narrowest. The installer also registers a
# system service that stores models somewhere else entirely — that clash is
# resolved here, in the same slot where the macOS version resolves Ollama.app.
aistackInstallOllamaEngine() {
    info "aistackInstallOllamaEngine — the Ollama runtime"

    if ollama_installed; then
        ok "Ollama present: $(ollama --version 2>/dev/null | head -1)"
        local latest cur
        cur=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        latest=$(curl -sf --max-time 10 https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "A newer Ollama is available: ${cur} -> ${latest}"
            ask_def "Upgrade Ollama now (re-runs the official installer)?" "y" \
                && { curl -fsSL https://ollama.com/install.sh | sh; ok "Now: $(ollama --version 2>/dev/null | head -1)"; }
        elif [ -z "$latest" ]; then
            ok "Update check skipped (GitHub unreachable)."
        else
            ok "Already the latest version."
        fi
        _aistackOllamaServiceDecision
        return 0
    fi

    warn "Ollama not installed."
    echo "    Optional — llama.cpp can serve models instead. Ollama's advantages:"
    echo "    a managed daemon, an Anthropic-compatible API for the Claude CLI, and"
    echo "    one-command pulls; its quant ladder is the narrowest."
    echo "    The official installer needs root and registers a systemd service."
    ask_def "Install Ollama (curl -fsSL https://ollama.com/install.sh | sh)?" "n" \
        || { warn "Skipping Ollama."; return 0; }
    curl -fsSL https://ollama.com/install.sh | sh || { fail "The Ollama installer failed."; return 1; }
    ollama_installed || { fail "Ollama is still not on PATH after installing."; return 1; }
    ok "Installed: $(ollama --version 2>/dev/null | head -1)"
    _aistackOllamaServiceDecision
}

# Resolve the system-service / user-daemon clash, once, with the reason stated.
# The upstream service runs as the 'ollama' user with its own model store; this
# stack runs the daemon as you so it can set context length and bind address
# per launch. Both want port 11434, so one of them has to give way.
_aistackOllamaServiceDecision() {
    ollamaSystemService || return 0
    local sysdir=/usr/share/ollama/.ollama/models n=0
    [ -d "$sysdir/manifests" ] && n=$(find "$sysdir/manifests" -type f 2>/dev/null | wc -l)
    if ! ollamaSystemServiceActive && ! systemctl is-enabled --quiet ollama.service 2>/dev/null; then
        ok "The system-wide ollama.service exists but is disabled — this stack runs its own daemon."
        return 0
    fi
    echo
    warn "Ollama registered a system service (runs as the 'ollama' user)."
    echo "    It stores models in ${sysdir} (${n} manifest(s) there now),"
    echo "    while this stack runs the daemon as YOU, with models in ~/.ollama, so"
    echo "    that context length and bind address can be chosen per launch."
    echo "    Both want port 11434 — leaving the service enabled means whichever"
    echo "    started first wins, and models split across two directories."
    if ask_def "Disable the system-wide ollama.service (recommended)?" "y"; then
        _asRoot systemctl disable --now ollama.service >/dev/null 2>&1 \
            && ok "System service stopped and disabled — launchInference.sh will run Ollama as you." \
            || fail "Could not disable ollama.service."
        [ "${n:-0}" -gt 0 ] && warn "The ${n} model(s) under ${sysdir} stay there; re-pull them, or set OLLAMA_MODELS=${sysdir}."
    else
        warn "Keeping the system service. Model steps will read ${sysdir},"
        warn "and pulls need it running — this stack will not start its own daemon."
    fi
}

# ---------- Ollama daemon, only so that pulls work -------------------------
# Start the Ollama daemon if it is not already up, quietly.
# Downloads need the daemon, but serving is launchInference.sh's job — so this
# deliberately does not ask about context size or network exposure. Prefers the
# system service when it is the one in charge, so nothing fights over the port.
ollama_ensure_daemon() {
    ollama_server_up && return 0
    if ollamaSystemService && systemctl is-enabled --quiet ollama.service 2>/dev/null; then
        info "Starting the system-wide ollama.service (needed to download models)..."
        _asRoot systemctl start ollama.service >/dev/null 2>&1
        sleep 3
        ollama_server_up && { ok "Daemon running on ${OLLAMA_API}:11434 (system service)."; return 0; }
    fi
    info "Starting the Ollama daemon (needed to download models)..."
    OLLAMA_MODELS="$(ollamaModelsDir)" nohup ollama serve >/dev/null 2>&1 &
    sleep 3
    ollama_server_up || { fail "Could not start the Ollama daemon."; return 1; }
    ok "Daemon running on ${OLLAMA_API}:11434 (models in $(ollamaModelsDir))."
}

# ---------- step: uv ---------------------------------------------------------
# Install uv, the Python tool manager LiteLLM is delivered through.
# Args: [required] to install without asking, used when another step depends on
# it — you already agreed to that tool, so being asked again is noise.
# Debian has no uv package, so this is Astral's own installer into ~/.local/bin.
aistackInstallUv() {
    info "aistackInstallUv — Python tool manager (needed by LiteLLM)"
    if command -v uv >/dev/null 2>&1; then
        ok "uv present: $(uv --version)"
        return 0
    fi
    if [ "${1:-}" != "required" ]; then
        ask_def "Install uv (curl -LsSf https://astral.sh/uv/install.sh | sh)?" "y" \
            || { warn "Skipping — LiteLLM will be unavailable."; return 1; }
    else
        info "uv is required here — installing it."
    fi
    curl -LsSf https://astral.sh/uv/install.sh | sh || { fail "uv install failed."; return 1; }
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 && ok "uv installed: $(uv --version)" || { fail "uv is not on PATH after installing."; return 1; }
}

# ---------- step: Node + npm -------------------------------------------------
# Install Node and npm, which all three coding agents are delivered through.
# Args: [required] to install without asking, used by the agent steps.
# On Debian this is a real step rather than an assumption: npm's default global
# prefix is /usr/lib, so `npm install -g` would need root for every agent —
# the prefix is moved to ~/.local instead, which is where uv and llama.cpp
# already put their binaries.
aistackInstallNode() {
    info "aistackInstallNode — Node.js and npm (needed by every coding agent)"
    if command -v npm >/dev/null 2>&1; then
        ok "Node present: $(node --version 2>/dev/null)  npm $(npm --version 2>/dev/null)"
        local major
        major=$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
        if [ -n "$major" ] && [ "$major" -lt 20 ] 2>/dev/null; then
            warn "Node ${major} is older than the coding agents expect (20+)."
            warn "Newer Node:  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs"
        fi
        _aistackNpmUserPrefix
        return 0
    fi
    if [ "${1:-}" != "required" ]; then
        ask_def "Install Node.js and npm with apt?" "y" || { warn "Skipping — no coding agent can be installed."; return 1; }
    else
        info "A coding agent needs Node — installing it."
    fi
    _aptInstall nodejs npm || { fail "apt-get install nodejs npm failed."; return 1; }
    ok "Node installed: $(node --version 2>/dev/null)  npm $(npm --version 2>/dev/null)"
    _aistackNpmUserPrefix
}

# Point npm's global prefix at ~/.local when the current one needs root.
# Without this every `npm install -g` in this script would either fail or
# demand sudo — and a root-owned global store then owns the agents' updates
# too. Idempotent: a prefix that is already writable is left exactly as it is.
_aistackNpmUserPrefix() {
    command -v npm >/dev/null 2>&1 || return 0
    local prefix
    prefix=$(npm config get prefix 2>/dev/null)
    if [ -n "$prefix" ] && [ -w "$prefix" ]; then
        ok "npm global prefix: ${prefix} (writable — global installs need no root)."
        return 0
    fi
    warn "npm's global prefix is ${prefix:-unset}, which is not writable by you."
    echo "    Every 'npm install -g' would need sudo, and root would then own the"
    echo "    agents' own update path."
    if ask_def "Point npm's global prefix at ~/.local instead?" "y"; then
        mkdir -p "$HOME/.local/bin"
        npm config set prefix "$HOME/.local" && ok "npm prefix set to ${HOME}/.local"
        export PATH="$HOME/.local/bin:$PATH"
        case ":${PATH}:" in
            *":${HOME}/.local/bin:"*) : ;;
            *) warn "Add ~/.local/bin to your PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
        esac
    else
        warn "Leaving it — global installs below will need sudo."
    fi
}

# ---------- Coding agents ------------------------------------------------------
# The agent is the thing you actually type into; the engine only serves tokens.
# Compatibility matters and is enforced in launchInference.sh:
#   Pi, OpenCode  -> any OpenAI-compatible endpoint (both engines here)
#   Claude Code   -> Anthropic Messages API only (Ollama)

# True when the Pi coding agent is on PATH.
pi_installed()       { command -v pi >/dev/null 2>&1; }
# True when OpenCode is on PATH.
opencode_installed() { command -v opencode >/dev/null 2>&1; }
# True when the Claude Code CLI is on PATH.
claude_installed()   { command -v claude >/dev/null 2>&1; }

# Space-separated list of coding agents present, empty when none.
installed_agents() {
    local a=""
    pi_installed       && a="${a} Pi"
    opencode_installed && a="${a} OpenCode"
    claude_installed   && a="${a} Claude"
    echo "${a# }"
}

# --- Pi (default YES) ---------------------------------------------------------
PI_NPM_PKG="@earendil-works/pi-coding-agent"
# Coding-agent step, default YES: install Pi and its local-model plugin.
# Recommended because it works with every engine here — it drives any
# OpenAI-compatible endpoint. Already installed: checks npm and offers an update
# only when a newer version exists.
aistackInstallPiCodingAgent() {
    info "aistackInstallPiCodingAgent — Pi (minimal terminal coding harness)"
    if pi_installed; then
        local cur latest
        cur=$(pi --version 2>/dev/null | head -1 | tr -d 'v')
        ok "Pi present: ${cur:-unknown}"
        latest=$(npm view "$PI_NPM_PKG" version 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "Pi update available: ${cur} -> ${latest}"
            ask_def "Update Pi now?" "y" && npm install -g --ignore-scripts "$PI_NPM_PKG"
        elif [ -z "$latest" ]; then
            ok "Update check skipped (npm registry unreachable)."
        else
            ok "Pi ${cur} is up to date."
        fi
        return 0
    fi
    echo "    Works with every engine here: it talks to any OpenAI-compatible server."
    if ! ask_def "Install the Pi coding agent?" "y"; then
        warn "Skipping Pi."
        return 0
    fi
    aistackInstallNode required || { fail "Pi needs Node — not installed."; return 1; }
    npm install -g --ignore-scripts "$PI_NPM_PKG" || { fail "npm install failed."; return 1; }
    ok "Pi installed: $(pi --version 2>/dev/null | head -1)"
    # local model discovery, so /models lists what our engines serve
    info "Adding local-model discovery (pi install npm:pi-local-models)..."
    pi install npm:pi-local-models >/dev/null 2>&1 \
        && ok "pi-local-models added." \
        || warn "Could not add pi-local-models — run 'pi install npm:pi-local-models' by hand."
}

# --- OpenCode (default NO) ----------------------------------------------------
# Coding-agent step, default no: install OpenCode from npm.
# Also engine-agnostic. There is no Debian package and no brew here, so npm is
# the single channel — which also makes the update check unambiguous.
aistackInstallOpenCodeCodingAgent() {
    info "aistackInstallOpenCodeCodingAgent — OpenCode (terminal agentic coder)"
    if opencode_installed; then
        local cur latest
        cur=$(opencode --version 2>/dev/null | head -1 | tr -d 'v')
        ok "OpenCode present: ${cur:-unknown}"
        latest=$(npm view opencode-ai version 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "An OpenCode update is available: ${cur} -> ${latest}"
            ask_def "Update OpenCode now?" "y" && npm install -g opencode-ai
        elif [ -z "$latest" ]; then
            ok "Update check skipped (npm registry unreachable)."
        else
            ok "Already up to date."
        fi
        return 0
    fi
    echo "    Also engine-agnostic: it drives any OpenAI-compatible endpoint."
    if ! ask_def "Install the OpenCode coding agent?" "n"; then
        warn "Skipping OpenCode."
        return 0
    fi
    aistackInstallNode required || { fail "OpenCode needs Node — not installed."; return 1; }
    npm install -g opencode-ai && ok "OpenCode installed." || { fail "npm install failed."; return 1; }
}

# --- Claude Code (default NO; Ollama-only) ------------------------------------
# Coding-agent step, default no: install the Claude Code CLI.
# Default no because it speaks the Anthropic API, so of the engines here it works
# with Ollama alone. Already installed: compares against the npm registry (which
# works for the native build too) and asks only when an update exists.
aistackInstallClaudeCodingAgent() {
    info "aistackInstallClaudeCodingAgent — Claude Code CLI"
    if claude_installed; then
        # rerun path: version check is AUTOMATIC (works for npm and native
        # installs alike); the update question appears only when needed,
        # defaulting to Y.
        local cur latest
        cur=$(claude --version 2>/dev/null | awk '{print $1}')
        ok "claude present: ${cur:-unknown}"
        latest=$(curl -sf --max-time 10 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "claude-code update available: ${cur} -> ${latest}"
            if ask_def "Update claude-code now?" "y"; then
                if command -v npm >/dev/null 2>&1 && npm ls -g @anthropic-ai/claude-code >/dev/null 2>&1; then
                    npm install -g @anthropic-ai/claude-code
                else
                    claude update
                fi
                ok "Now: $(claude --version 2>/dev/null | head -1)"
            fi
        elif [ -z "$latest" ]; then
            ok "Update check skipped (registry unreachable)."
        else
            ok "claude-code ${cur} is up to date."
        fi
        return 0
    fi

    # first-run path: not installed — propose installation
    warn "claude CLI not installed."
    echo "    Note: Claude Code speaks the Anthropic API, so of the engines here it"
    echo "    only works with Ollama. Pi and OpenCode work with both."
    if ! ask_def "Install Claude Code now?" "n"; then
        warn "Skipped."
        return 0
    fi
    # the native installer needs nothing else; npm is used when it is already there
    if command -v npm >/dev/null 2>&1; then
        npm install -g @anthropic-ai/claude-code \
            && { ok "Installed: $(claude --version 2>/dev/null | head -1)"; return 0; }
        warn "npm install failed — falling back to the native installer."
    fi
    curl -fsSL https://claude.ai/install.sh | bash \
        && ok "Installed: $(claude --version 2>/dev/null | head -1)" \
        || fail "Both installers failed."
}

# ---------- per-engine adapters ----------------------------------------------
# Each engine supplies two functions: one that lists what is already installed
# (one tag per line) and one that downloads a tag. aiStackModelMenu does the
# rest, identically for every engine.

# List Ollama model tags, one per line.
# Falls back to reading the manifests when the daemon is down: the models are on
# disk either way, and without this a stopped daemon makes Ollama look like it
# has none — hiding it from menus it belongs in. The manifest root is resolved
# by ollamaModelsDir(), because Linux has two possible locations.
ollamaListInstalled() {
    if ollama list >/dev/null 2>&1; then
        ollama list 2>/dev/null | awk 'NR>1 {print $1}'
        return 0
    fi
    local base f rel ns name tag
    base="$(ollamaModelsDir)/manifests"
    [ -d "$base" ] || return 0
    find "$base" -type f 2>/dev/null | while read -r f; do
        rel=${f#"$base"/}                 # <registry>/<namespace>/<name>/<tag>
        rel=${rel#*/}                     # drop the registry host
        ns=${rel%%/*}; rel=${rel#*/}
        name=${rel%%/*}; tag=${rel#*/}
        [ "$ns" = "library" ] && echo "${name}:${tag}" || echo "${ns}/${name}:${tag}"
    done | sort
}

# Download one Ollama model, surviving the failures that actually happen.
# Args: <tag>. Retries transient errors up to three times (the download resumes
# each time), reports the real error rather than a guess, and keeps resumable
# data while cleaning up after a permanent failure.
ollamaPullModel() {
    if [ $# -lt 1 ]; then
        aiStackUsage "ollamaPullModel <ollama-tag>" \
            "$(_hintTagExample ollamaPullModel ollama-tag)"
        return 2
    fi
    local tag="$1" pull_log attempt ok_pull=0 last_err=""
    info "Pulling ${tag}..."
    pull_log=$(mktemp "${TMPDIR:-/tmp}/ollama-pull.XXXXXX")
    for attempt in 1 2 3; do
        ollama pull "$tag" 2>&1 | tee "$pull_log"
        if [ "${PIPESTATUS[0]}" -eq 0 ]; then ok_pull=1; break; fi
        last_err=$(grep -i "error" "$pull_log" | tail -1)
        # transient errors (timeouts, resets): retry — the download RESUMES
        if [ "$attempt" -lt 3 ] && grep -qiE "deadline exceeded|timeout|connection reset|unexpected EOF|TLS handshake|502|503" "$pull_log"; then
            warn "Transient error: ${last_err}"
            warn "Retrying (attempt $((attempt+1))/3) — resumes from already-downloaded data..."
            sleep 5
        else
            break
        fi
    done
    if [ "$ok_pull" -eq 1 ]; then
        ok "${tag} downloaded."
    else
        fail "Pull failed after ${attempt} attempt(s). Actual error:"
        fail "  ${last_err:-unknown (see output above)}"
        if grep -qiE "deadline exceeded|timeout|connection reset|unexpected EOF" "$pull_log"; then
            warn "Keeping downloaded data so a re-try resumes. (Cleanup runs on next step entry if you abandon it.)"
        else
            warn "Permanent-looking error (bad tag/manifest) — cleaning up its disk space."
            ollama_prune_orphan_blobs
        fi
    fi
    rm -f "$pull_log"
    [ "$ok_pull" -eq 1 ]
}

# --- llama.cpp: plain GGUF files, downloaded with resumable curl --------------
LLAMACPP_MODEL_DIR="${LLAMACPP_MODEL_DIR:-$HOME/Models/llama.cpp}"

# Local path for one llama.cpp tag: org__repo@QUANT.gguf under the model dir.
# Args: <tag>. The encoding is reversible, which is how the launcher turns files
# on disk back into tags without keeping a separate index.
llamacppLocalFile() {
    if [ $# -lt 1 ]; then
        aiStackUsage "llamacppLocalFile <tag>" \
            "tag     : hf-repo:QUANT" \
            "$(_hintTagExample llamacppLocalFile gguf-tag)"
        return 2
    fi
    echo "${LLAMACPP_MODEL_DIR}/$(printf '%s' "$1" | sed 's|/|__|g; s|:|@|').gguf"
}
# List downloaded GGUFs as tags by reversing that filename encoding.
llamacppListInstalled() {
    [ -d "$LLAMACPP_MODEL_DIR" ] || return 0
    local f b
    for f in "$LLAMACPP_MODEL_DIR"/*.gguf; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .gguf)
        printf '%s\n' "$(printf '%s' "$b" | sed 's|@|:|; s|__|/|g')"
    done
}
# List GGUF downloads that were interrupted, as "tag<TAB>bytes-so-far".
# A .part file holds real disk and is invisible to every menu, so the model
# step reports them rather than letting them accumulate unseen.
llamacppListPartial() {
    [ -d "$LLAMACPP_MODEL_DIR" ] || return 0
    local f b
    for f in "$LLAMACPP_MODEL_DIR"/*.gguf.part; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .gguf.part)
        printf '%s\t%s\n' "$(printf '%s' "$b" | sed 's|@|:|; s|__|/|g')" "$(fileSizeBytes "$f")"
    done
}

# Size of a file in bytes, 0 when it does not exist.
# Linux uses stat -c%s; the macOS copy of this function uses stat -f%z. That
# one flag is the whole platform difference in the download path.
fileSizeBytes() { [ -e "${1:-}" ] && stat -c%s "$1" 2>/dev/null || echo 0; }

# Download one GGUF for llama.cpp.
# Args: <tag>. Resolves the real filename AND its size from the repo tree first
# — uploaders name files differently, and the size is what makes "finished" a
# fact instead of an assumption — then fetches with curl -C - so an interrupted
# download resumes instead of restarting.
#
# The bytes land in <name>.gguf.part and are renamed to <name>.gguf only once
# the file is complete. Without that, an in-progress download already satisfies
# the *.gguf glob every lister here uses, so a half-downloaded model shows up as
# installed, reports 0 GB, is hidden from the download menu, and fails to load.
llamacppPullModel() {
    if [ $# -lt 1 ]; then
        aiStackUsage "llamacppPullModel <tag>" \
            "tag     : hf-repo:QUANT — downloads the GGUF into ${LLAMACPP_MODEL_DIR}" \
            "$(_hintTagExample llamacppPullModel gguf-tag)"
        return 2
    fi
    # NB: separate statements on purpose. bash expands every argument to
    # "local" before assigning any of them, so "local a=$1 b=${a%:*}" leaves b
    # empty — or worse, silently picks up a same-named variable from the
    # caller's scope (local is dynamically scoped).
    local tag="$1" out part meta file expected have url repo quant
    repo="${tag%:*}"
    quant="${tag##*:}"
    out=$(llamacppLocalFile "$tag")
    part="${out}.part"
    mkdir -p "$LLAMACPP_MODEL_DIR"

    # resolve the real filename and its size — uploaders name files differently,
    # and LFS entries carry the true byte count in .lfs.size
    info "Resolving the ${quant} GGUF in ${repo}..."
    meta=$(curl -sf --max-time 25 "https://huggingface.co/api/models/${repo}/tree/main" 2>/dev/null \
        | python3 -c "
import json, sys
q = sys.argv[1]
try:
    t = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for e in t:
    p = e.get('path', '')
    if e.get('type') != 'directory' and p.endswith('-%s.gguf' % q):
        lfs = e.get('lfs') or {}
        print('%s\t%s' % (p, lfs.get('size') or e.get('size') or 0))
        break
" "$quant" 2>/dev/null)
    file=${meta%%$'\t'*}
    expected=${meta##*$'\t'}
    case "${expected:-}" in ''|*[!0-9]*) expected=0 ;; esac
    if [ -z "$file" ]; then
        fail "No ${quant} GGUF found in ${repo} — skipping."
        return 1
    fi

    # a .part that is already complete only needs its rename — the previous run
    # may have been interrupted between the last byte and the mv
    if [ -e "$part" ] && [ "$expected" -gt 0 ] && [ "$(fileSizeBytes "$part")" -eq "$expected" ]; then
        mv -f "$part" "$out"
        ok "${tag} was already fully downloaded — completed it ($(du -h "$out" 2>/dev/null | cut -f1))."
        return 0
    fi

    if [ -e "$out" ]; then
        have=$(fileSizeBytes "$out")
        if [ "$expected" -eq 0 ] || [ "$have" -eq "$expected" ]; then
            ok "${tag} is already downloaded ($(du -h "$out" 2>/dev/null | cut -f1))."
            return 0
        fi
        # a short .gguf is debris from an interrupted download taken before
        # completed files were distinguished by name — reopen it as .part so
        # this run resumes it rather than ignoring it or starting over
        warn "${out} is incomplete ($(( have / 1048576 )) MB of $(( expected / 1048576 )) MB) — resuming it."
        mv -f "$out" "$part"
    fi

    url="https://huggingface.co/${repo}/resolve/main/${file}"
    info "Downloading ${file}"
    echo "    -> ${out}"
    echo "    (arrives as $(basename "$part") and is renamed only when complete, so an"
    echo "     interrupted pull resumes and never looks like an installed model)"
    if curl -L --fail --progress-bar -C - -o "$part" "$url"; then
        have=$(fileSizeBytes "$part")
        if [ "$expected" -gt 0 ] && [ "$have" -ne "$expected" ]; then
            fail "Got ${have} bytes, expected ${expected} — keeping the partial file for a retry:"
            fail "  ${part}"
            return 1
        fi
        mv -f "$part" "$out"
        ok "${tag} downloaded ($(du -h "$out" 2>/dev/null | cut -f1))."
        return 0
    fi
    fail "Download failed — the partial file is kept so a retry resumes:"
    fail "  ${part}"
    return 1
}

MODEL_LIST_ENGINE="${MODEL_LIST_ENGINE:-Ollama}"
AI_MODEL_CATALOG=()

# repo root = parent of the OS folder holding this script
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# modelListFile <host_ram_gb> — largest tier <= host RAM (smallest if below all)
modelListFile() {
    if [ $# -lt 1 ]; then
        aiStackUsage "modelListFile <host-ram-gb>" "example : modelListFile $(hostRamGb)"
        return 2
    fi
    local ram="$1" dir f tier best="" smallest=""
    dir="${REPO_ROOT}/ModelLists/${MODEL_LIST_ENGINE}"
    [ -d "$dir" ] || return 1
    for f in "$dir"/*_GB_Ram.json; do
        [ -e "$f" ] || continue
        tier=$(basename "$f"); tier=${tier%_GB_Ram.json}
        case "$tier" in ""|*[!0-9]*) continue ;; esac
        if [ -z "$smallest" ] || [ "$tier" -lt "$smallest" ]; then smallest="$tier"; fi
        if [ "$tier" -le "$ram" ]; then
            if [ -z "$best" ] || [ "$tier" -gt "$best" ]; then best="$tier"; fi
        fi
    done
    [ -z "$best" ] && best="$smallest"          # host below every tier
    [ -z "$best" ] && return 1                  # no lists at all
    echo "${dir}/${best}_GB_Ram.json"
}

# parseModelJson <file> — emit "tag|size_gb|description" per model
parseModelJson() {
    if [ $# -lt 1 ]; then
        aiStackUsage "parseModelJson <catalog.json>" "example : parseModelJson ModelLists/Ollama/48_GB_Ram.json"
        return 2
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$1" <<'PYEOF'
import json, sys
for m in json.load(open(sys.argv[1])).get("models", []):
    print("%s|%s|%s" % (m["tag"], m["size_gb"], m.get("description", "")))
PYEOF
    else
        # fallback: the generator writes exactly one model object per line
        sed -n 's/.*"tag": *"\([^"]*\)".*"size_gb": *\([0-9]*\).*"description": *"\([^"]*\)".*/\1|\2|\3/p' "$1"
    fi
}

# loadModelCatalog [host_ram_gb] — fill AI_MODEL_CATALOG from the JSON list
loadModelCatalog() {
    local ram="${1:-${TOTAL_GB:-0}}" file line
    [ "$ram" -gt 0 ] 2>/dev/null || ram=$(hostRamGb)
    file=$(modelListFile "$ram") || {
        fail "No model lists found in ModelLists/${MODEL_LIST_ENGINE}/ — cannot offer models."
        return 1
    }
    AI_MODEL_CATALOG=()
    while IFS= read -r line; do
        [ -n "$line" ] && AI_MODEL_CATALOG+=("$line")
    done < <(parseModelJson "$file")
    if [ "${#AI_MODEL_CATALOG[@]}" -eq 0 ]; then
        fail "Could not parse $(basename "$file") — no models loaded."
        return 1
    fi
    ok "Model list: ${MODEL_LIST_ENGINE}/$(basename "$file") — ${#AI_MODEL_CATALOG[@]} models (host RAM ${ram} GB)."
}

# ---------- generic model menu, shared by every engine -----------------------
# The model menu, shared by both engines.
# Args: <EngineFolder> <list-installed-fn> <pull-fn>. Loads that engine's
# catalog, hides models that do not fit the memory budget or free disk, are
# already installed, or do not exist upstream — then loops until you answer N.
aiStackModelMenu() {
    if [ $# -lt 3 ]; then
        aiStackUsage "aiStackModelMenu <EngineFolder> <list-fn> <pull-fn>" "EngineFolder : Ollama | Llama.cpp" "example : aiStackModelMenu Ollama ollamaListInstalled ollamaPullModel"
        return 2
    fi
    local engine="$1" list_fn="$2" pull_fn="$3"

    [ -z "${TOTAL_GB:-}" ] && TOTAL_GB=$(hostRamGb)
    MODEL_LIST_ENGINE="$engine"
    loadModelCatalog "$TOTAL_GB" || return 1

    # the budget is system RAM minus the OS reserve — there is no separate,
    # raisable GPU allocation on Linux the way macOS has iogpu.wired_limit_mb
    GPU_GB=$(inferenceBudgetGb)
    local vram; vram=$(gpuVramGb)
    ok "Memory budget: ${GPU_GB} GB — $(budgetSummary)"
    if [ "${vram:-0}" -gt 0 ]; then
        echo "    Models larger than ${vram} GB still run, with the overflow layers on CPU."
    fi
    echo "    Lower the OS reserve to widen the menu:  RAM_RESERVE_GB=3 aistackInstall${engine%%.*}Models"

    while true; do
        local downloaded have_disk
        downloaded=$("$list_fn")
        have_disk=$(free_gb)
        echo
        echo "    Already installed for ${engine}:"
        [ -n "$downloaded" ] && echo "$downloaded" | sed 's/^/      /' || echo "      (none)"

        local menu_tags=() menu_lines=() entry tag size desc need hidden_disk=0
        for entry in "${AI_MODEL_CATALOG[@]}"; do
            IFS='|' read -r tag size desc <<< "$entry"
            need=$(( size * 13 / 10 + 2 ))                    # weights*1.3 + 2 GB overhead
            [ "$need" -gt "$GPU_GB" ] && continue             # doesn't fit this host's RAM
            echo "$downloaded" | grep -qxF "$tag" && continue # already present
            if [ $(( size + 5 )) -gt "$have_disk" ]; then     # doesn't fit free disk
                hidden_disk=$((hidden_disk+1)); continue
            fi
            menu_tags+=("$tag")
            menu_lines+=("$(printf '%-52s %3d GB  (needs ~%d GB RAM)  %s' "$tag" "$size" "$need" "$desc")")
        done
        [ "$hidden_disk" -gt 0 ] && warn "${hidden_disk} model(s) hidden — larger than the ${have_disk} GB of free disk allows."
        [ "${#menu_tags[@]}" -eq 0 ] && { ok "No further ${engine} models fit this host — done."; return 0; }

        info "Verifying ${#menu_tags[@]} candidate tags upstream (parallel, cached 24 h, ${TAG_CHECK_DEADLINE}s limit)..."
        _tagVerifyAll "${menu_tags[@]}"
        local avail_tags=() avail_lines=() j
        for j in "${!menu_tags[@]}"; do
            if tag_available "${menu_tags[$j]}"; then
                avail_tags+=("${menu_tags[$j]}"); avail_lines+=("${menu_lines[$j]}")
            else
                warn "Not available upstream (hidden): ${menu_tags[$j]}"
            fi
        done
        [ "${#avail_tags[@]}" -eq 0 ] && { ok "No available ${engine} models remain — done."; return 0; }
        menu_tags=("${avail_tags[@]}"); menu_lines=("${avail_lines[@]}")
        while [ "${#menu_tags[@]}" -gt 25 ]; do
            unset 'menu_tags[${#menu_tags[@]}-1]' 'menu_lines[${#menu_lines[@]}-1]'
        done

        echo
        echo "${BOLD}${engine} models that fit this machine (~${GPU_GB} GB usable memory, ${have_disk} GB free disk):${RESET}"
        local i
        for i in "${!menu_tags[@]}"; do printf "  %2d) %s\n" $((i+1)) "${menu_lines[$i]}"; done
        echo "   N) No download — finish this step"

        local sel
        printf "\n%sSelect a %s model to download [1-%d / N]:%s " "${BOLD}" "$engine" "${#menu_tags[@]}" "${RESET}"
        read -r sel </dev/tty || { echo; fail "No interactive terminal — aborting."; return 1; }
        case "$sel" in
            [Nn]) ok "${engine} model downloads finished."; return 0 ;;
            *[!0-9]*|"") echo "Enter a number or N."; continue ;;
        esac
        if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#menu_tags[@]}" ]; then echo "Out of range."; continue; fi

        tag="${menu_tags[$((sel-1))]}"
        size=$(printf '%s\n' "${AI_MODEL_CATALOG[@]}" | awk -F'|' -v t="$tag" '$1==t {print $2; exit}')
        if require_disk $(( size + 5 )) "${tag} (~${size} GB + headroom)"; then
            "$pull_fn" "$tag" "$size"
        fi
        # loop: menu re-renders without the model just downloaded
    done
}

# ---------- model steps, one per engine (same order as the engine steps) ------
# Model step for llama.cpp: GGUF files into ~/Models/llama.cpp.
# Skipped with a notice when llama.cpp is not installed, since the other engine
# may well be the one in use.
aistackInstallLlamacppModels() {
    info "aistackInstallLlamacppModels — GGUF models for llama.cpp"
    if ! llamacpp_installed; then
        warn "llama.cpp is not installed — skipping its model list."
        return 0
    fi
    echo "    Download directory: ${LLAMACPP_MODEL_DIR}"
    # interrupted downloads hold real disk and appear in no menu, so name them
    # here — where re-selecting the same model is what resumes them
    local t b
    if [ -n "$(llamacppListPartial)" ]; then
        warn "Interrupted downloads found (re-select the same model to resume):"
        while IFS=$'\t' read -r t b; do
            [ -n "$t" ] && printf "      %-52s %s MB so far\n" "$t" "$(( b / 1048576 ))"
        done < <(llamacppListPartial)
    fi
    aiStackModelMenu "Llama.cpp" llamacppListInstalled llamacppPullModel
}

# Model step for Ollama: registry tags into the Ollama model store.
# Skipped when Ollama is absent. Prunes the debris of earlier failed pulls first,
# so the free-space numbers the menu shows are honest.
aistackInstallOllamaModels() {
    info "aistackInstallOllamaModels — models for Ollama"
    if ! ollama_installed; then
        warn "Ollama is not installed — skipping its model list."
        return 0
    fi
    echo "    Model store: $(ollamaModelsDir)"
    ollama_ensure_daemon || return 1
    # clean leftovers of interrupted/failed pulls first, so free-space is honest
    ollama_prune_orphan_blobs ask
    aiStackModelMenu "Ollama" ollamaListInstalled ollamaPullModel
}

# ---------- Monitoring -------------------------------------------------------
# Optional observability around the stack. Linux-specific by nature: macmon and
# Anubis OSS are Apple-only, so their slots are filled by nvtop (the accelerator)
# and btop (everything else), with LiteLLM carried across unchanged.

# True when nvtop is installed.
nvtop_installed()   { command -v nvtop >/dev/null 2>&1; }
# True when btop is installed.
btop_installed()    { command -v btop >/dev/null 2>&1; }
# True when the litellm CLI is available (installed as a uv tool).
litellm_installed() { command -v litellm >/dev/null 2>&1 || { command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^litellm'; }; }

# Space-separated list of monitoring tools present, empty when none.
# Used by the verification step, and by anything that wants to report the
# stack's observability without re-probing each tool.
installed_monitoring() {
    local m=""
    nvtop_installed   && m="${m} nvtop"
    btop_installed    && m="${m} btop"
    litellm_installed && m="${m} litellm"
    echo "${m# }"
}

# Monitoring step, default no: nvtop — live GPU/APU utilisation and memory for
# AMD, Intel and NVIDIA. The closest Linux equivalent of macmon's GPU half; the
# CPU half is btop's job below.
aistackInstallNvtopMonitoring() {
    info "aistackInstallNvtopMonitoring — nvtop (GPU/APU monitor)"
    if [ "$(gpuVendor)" = "cpu" ]; then
        warn "No usable GPU backend detected — nvtop would have nothing to show. Skipping."
        return 0
    fi
    _aiStackAptTool nvtop "nvtop" "n" \
        "Live GPU/APU utilisation, memory and per-process usage — run it beside a model."
}

# Monitoring step, default no: btop — CPU, memory, disk and process view.
# On a CPU-inference box this is the meter that matters, because the model's
# cost shows up as cores and resident memory rather than GPU wattage.
aistackInstallBtopMonitoring() {
    info "aistackInstallBtopMonitoring — btop (system monitor)"
    _aiStackAptTool btop "btop" "n" \
        "CPU, memory and process view — on CPU inference this is where the cost shows."
}

# Monitoring step, default no: LiteLLM — an OpenAI-compatible proxy that logs
# every request and can export OpenTelemetry traces. Sits in front of the
# engines, so you can see what an agent actually sent and what it cost.
# Delivered through uv, exactly as on macOS.
aistackInstallLitellmMonitoring() {
    info "aistackInstallLitellmMonitoring — LiteLLM proxy (request logging / OpenTelemetry)"
    if litellm_installed; then
        local cur latest
        cur=$(uv tool list 2>/dev/null | awk '/^litellm /{print $2}' | tr -d 'v')
        ok "LiteLLM present: ${cur:-unknown}"
        latest=$(curl -sf --max-time 10 https://pypi.org/pypi/litellm/json 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null)
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            warn "LiteLLM update available: ${cur} -> ${latest}"
            ask_def "Update LiteLLM now?" "y" && uv tool upgrade litellm
        elif [ -z "$latest" ]; then
            ok "Update check skipped (PyPI unreachable)."
        else
            ok "LiteLLM ${cur} is up to date."
        fi
        return 0
    fi
    echo "    An OpenAI-compatible proxy in front of your engines: logs every request,"
    echo "    exports OpenTelemetry traces, and gives one endpoint for several models."
    if ! ask_def "Install the LiteLLM proxy?" "n"; then
        warn "Skipping LiteLLM."
        return 0
    fi
    aistackInstallUv required || { fail "LiteLLM needs uv — not installed."; return 1; }
    uv tool install "litellm[proxy]" && ok "LiteLLM installed." || { fail "litellm install failed."; return 1; }
}

# ---------- step: verification -----------------------------------------------
# Final step: report what is installed — engines, agents, tooling, models.
# Read-only. Benchmarking lives in aiModelTest.sh, and serving in
# launchInference.sh; installing should not start or measure anything.
aistackInstallVerification() {
    info "aistackInstallVerification — status summary"
    echo
    echo "${BOLD}================= Install summary =================${RESET}"
    ok "Host:      $( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}"), $(hostRamGb) GB RAM, $(nproc) cores"
    ok "Budget:    $(budgetSummary)"
    echo "${BOLD}  Engines${RESET}"
    if llamacpp_installed; then
        ok "llama.cpp: build $(llamacppInstalledBuild), ${BOLD}$(llamacppBackend)${RESET} backend"
    else
        warn "llama.cpp: not installed"
    fi
    if ollama_installed; then
        ok "Ollama:    $(ollama --version 2>/dev/null | head -1)"
        ollama_server_up && ok "  server:  running on ${OLLAMA_API}:11434" || warn "  server:  not running"
        ollamaSystemService && { systemctl is-enabled --quiet ollama.service 2>/dev/null \
            && warn "  service: system-wide ollama.service is ENABLED (models in /usr/share/ollama)" \
            || ok "  service: system-wide ollama.service disabled (this stack runs its own)"; }
    else
        warn "Ollama:    not installed"
    fi
    warn "MLX-LM:    not available on Linux (Apple Silicon only)"
    echo "${BOLD}  Coding agents${RESET}"
    pi_installed       && ok "Pi:        $(pi --version 2>/dev/null | head -1)"       || warn "Pi:        not installed"
    opencode_installed && ok "OpenCode:  $(opencode --version 2>/dev/null | head -1)" || warn "OpenCode:  not installed"
    claude_installed   && ok "Claude:    $(claude --version 2>/dev/null | head -1)"   || warn "Claude:    not installed (Ollama-only agent)"
    echo "${BOLD}  Monitoring${RESET}"
    nvtop_installed   && ok "nvtop:     $(nvtop --version 2>/dev/null | head -1)" || warn "nvtop:     not installed"
    btop_installed    && ok "btop:      $(btop --version 2>/dev/null | head -1)"  || warn "btop:      not installed"
    litellm_installed && ok "LiteLLM:   installed"                                || warn "LiteLLM:   not installed"
    echo "${BOLD}  Tooling${RESET}"
    command -v uv   >/dev/null 2>&1 && ok "uv:        $(uv --version)"        || warn "uv:        not installed"
    command -v npm  >/dev/null 2>&1 && ok "node/npm:  $(node --version 2>/dev/null) / $(npm --version 2>/dev/null)" \
                                    || warn "node/npm:  not installed"

    echo "${BOLD}  Models${RESET}"
    if llamacpp_installed; then
        local n
        n=$(llamacppListInstalled | grep -c . || true)
        echo "    llama.cpp (${LLAMACPP_MODEL_DIR}): ${n:-0}"
        llamacppListInstalled | sed 's/^/      /'
    fi
    if ollama_installed; then
        local o
        o=$(ollamaListInstalled | grep -c . || true)
        echo "    Ollama ($(ollamaModelsDir)): ${o:-0}"
        ollamaListInstalled | sed 's/^/      /'
    fi
    echo
    echo "    Benchmark them with ./aiModelTest.sh or ./testAllAiModels.sh"
}

# ---------- wrapper ----------------------------------------------------------
# Wrapper: sanity, disk gate, base tools, engines, agents, models, verification.
# Hard-fails on the foundations and stops entirely when no engine was installed.
# Every step is independently callable, so this is only the convenient order.
aistackInstall() {
    echo "${BOLD}=============================================================${RESET}"
    echo "${BOLD} Local AI coding stack — installer (Debian, re-runnable)${RESET}"
    echo "${BOLD}=============================================================${RESET}"
    aistackInstallSanity        || return 1
    aistackInstallDiskGate      || return 1
    aistackInstallBaseTools     || return 1

    # --- engine layer: most-recommended first, each independently optional ---
    aistackInstallLlamacppEngine
    aistackInstallOllamaEngine

    # GATE: nothing below this line means anything without an engine
    local engines
    engines=$(installed_engines)
    if [ -z "$engines" ]; then
        echo
        fail "No inference engine installed — cancelling the rest of the wizard."
        warn "Re-run and accept at least one of llama.cpp / Ollama."
        return 1
    fi
    ok "Engines available: ${engines}"

    # --- coding agents: what you type into (engine-compatibility enforced
    #     later by launchInference.sh) ---
    aistackInstallPiCodingAgent
    aistackInstallOpenCodeCodingAgent
    aistackInstallClaudeCodingAgent

    # --- model layer: same order as the engines, each skipped if absent ------
    aistackInstallLlamacppModels
    aistackInstallOllamaModels

    # --- monitoring: optional observability, asked before the verdict ---
    aistackInstallNvtopMonitoring
    aistackInstallBtopMonitoring
    aistackInstallLitellmMonitoring

    aistackInstallVerification
}

# ---------- run pipeline when executed (not sourced) -------------------------
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    aistackInstall
fi
