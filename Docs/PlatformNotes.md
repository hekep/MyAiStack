# Platform notes — macOS and Debian

What the two implementations share, where they diverge, and why. The contract
they both implement is in [SPECIFICATION.md](SPECIFICATION.md); this document
is the delta.

Read it before changing either side: most of what looks like an inconsistency
below is a platform fact, and most of the rest is a trap somebody already fell
into.

---

## The rule

**The contract is identical. Only the primitives differ.**

Everything in SPECIFICATION.md holds on both platforms: the four layers, the
`aistack` naming, the nine invariants, install/uninstall ordering, the model
gate, "measured never estimated", "one question at a time", "Enter is safe".

What changes is *what a measurement reads* and *what a package manager is
called*. When a step cannot be honoured on a platform, it is **named with its
reason** rather than silently dropped — that is itself part of the contract
(invariant 2: never a question with one possible answer).

---

## Identical on both platforms

| | |
|---|---|
| **Layer model** | Engine → coding agent → models → monitoring |
| **Naming** | `aistackInstall*`, `aistackUninstall*`, `aistackLaunchInference*`, `aistackModelTest*` |
| **Invariants** | All nine, including the uninstall gate and the usage-on-bare-call rule (return 2) |
| **Ordering** | Install foundations-first, uninstall most-dependent-first |
| **Agent compatibility** | Pi and OpenCode drive any OpenAI endpoint; Claude Code needs the Anthropic API, so Ollama only |
| **Ports** | Ollama 11434, llama.cpp 8080 |
| **Model catalogs** | The same `ModelLists/<Engine>/<RAM>_GB_Ram.json` files. GGUF and Ollama tags are engine facts, not OS facts |
| **GGUF filename encoding** | `org__repo@QUANT.gguf`, reversible, so a file on disk maps back to a tag. A download in flight is `.gguf.part` and is renamed only once its size matches HuggingFace's, so `.gguf` always means complete |
| **Test suite** | Same five layer tests, same OpenAI endpoint, same warmup, same wall-clock timing — so **tok/s from a Mac and a Debian box are directly comparable** |
| **Persisted choices** | `~/.aistackLaunchInference.conf`, same keys |
| **Shell integration** | One `installAliases.sh` for both; `shellFunctions.sh` discovers functions by prefix out of whichever OS folder `detectOsFolder` returns |
| **Agent config files** | `~/.pi/agent/local-models.json`, `~/.config/opencode/opencode.json`, backed up before writing |

The shell integration is worth calling out: it was already OS-agnostic, and
needed **no changes** for the port. It reads the function names out of the
implementation files, so a platform with more steps simply exposes more of
them.

---

## Layer membership

| Layer | macOS | Debian | Why |
|---|---|---|---|
| **Engine** | llama.cpp, MLX-LM, Ollama | llama.cpp, Ollama | MLX is Apple's array framework, Apple Silicon only |
| **Coding agent** | Pi, OpenCode, Claude Code | Pi, OpenCode, Claude Code | All three are cross-platform |
| **Monitoring** | macmon, Anubis OSS, LiteLLM | nvtop, btop, LiteLLM | macmon reads Apple SoC counters; Anubis OSS ships as a macOS 15+ app bundle |
| **Foundations** | Homebrew, uv | base apt packages, uv, **Node** | See below |

**MLX-LM has no stub on Debian.** There is no `aistackInstallMlxmlEngine` that
prints "unavailable" — a function that can never do anything is not a step. But
every place that could plausibly be asked about it answers properly:
`_requireEngine MLX-LM` explains it is Apple Silicon only and points at
llama.cpp for the same quality band, and the install summary lists it under
Engines as *"not available on Linux (Apple Silicon only)"*. `ModelLists/MLX-LM/`
therefore has no Debian consumer, which its own README already anticipated.

**Node is an explicit step on Debian** (`aistackInstallNode`), where macOS only
warned that npm was missing. On a Mac, Homebrew's node arrives with a
user-writable prefix as a side effect of installing almost anything; on Debian
`apt install nodejs npm` leaves npm's global prefix at `/usr/lib`, so every
`npm install -g` for an agent would need root — and root would then own the
agents' own update path. The step exists to move that prefix to `~/.local`.

**Homebrew maps to two things, not one.** `aistackInstallHomebrew` establishes a
package manager that may be absent. On Debian apt is always present, so the
equivalent step is `aistackInstallBaseTools`: it establishes the small set of
packages the rest of the scripts shell out to (`curl ca-certificates tar gzip
python3 jq lsof procps iproute2`). Both refuse to continue when declined, and
both have a report-only uninstall counterpart that never removes anything.

### Function counts

| | macOS | Debian |
|---|---|---|
| `aistackInstall*` | 18 | 17 |
| `aistackUninstall*` | 19 | 18 |
| `aistackLaunchInference*` | 14 | 14 |
| `aistackModelTest*` | 15 | 15 |
| prefixed subtotal | 66 | 64 |
| whole-script entry points | 3 | 3 |
| **total** | **69** | **67** |

The launcher and test families are identical; only install and uninstall track
their platform's layer members (−1 engine, +1 foundation, −2 monitoring, +1
monitoring).

Counted from the sources, not from memory: `grep -cE '^aistackInstall[A-Za-z]*\(\)'`
and so on. Earlier revisions of README.md and SPECIFICATION.md quoted "55",
which never matched the per-family table beside it — those are corrected. Do
not hard-code any of these numbers in new prose; `aistackHelp` prints the live
list for whichever platform you are on.

---

## Delivery mechanisms

| Component | macOS | Debian |
|---|---|---|
| llama.cpp | `brew install llama.cpp` | upstream release tarball → `~/.local/opt/llama.cpp`, symlinked into `~/.local/bin`; **or** build from source |
| Ollama | brew formula (migrating an `Ollama.app`) | `curl -fsSL https://ollama.com/install.sh \| sh` (root; registers a systemd unit) |
| MLX-LM | `uv tool install mlx-lm` | — |
| uv | brew | `curl -LsSf https://astral.sh/uv/install.sh \| sh` (no Debian package) |
| Node | brew (assumed) | `apt install nodejs npm` + npm prefix moved to `~/.local` |
| Pi | npm | npm |
| OpenCode | brew, npm fallback | npm (no Debian package, no brew) |
| Claude Code | npm or native installer | npm if present, else the native installer |
| Monitoring | brew / brew cask | apt (nvtop, btop) + uv (LiteLLM) |

### llama.cpp is the biggest delivery difference

Debian has no llama.cpp package, so the Debian installer resolves a release
asset from `github.com/ggml-org/llama.cpp` itself. Three things about that are
worth knowing:

1. **The `releases/latest` endpoint is useless here.** It points at a different
   tag series (`v0.2.0`, one asset). The build tarballs live on `bNNNNN` tags,
   so `llamacppResolveAsset` walks the ten most recent releases and takes the
   newest that actually carries the asset it wants. A single release can omit a
   flavour.
2. **Backend is chosen from the hardware, and NVIDIA is a special case.**
   Upstream publishes `ubuntu-x64` (CPU), `ubuntu-vulkan-x64`,
   `ubuntu-rocm-*-x64`, plus arm64 and s390x — but **no Linux CUDA tarball**
   (CUDA builds are Windows-only). So an NVIDIA machine is given the Vulkan
   build, which drives NVIDIA well, and told that the source build is the route
   to CUDA proper.
3. **The binary is verified to actually run before it replaces anything.**
   Upstream builds on a newer Ubuntu than Debian stable ships, so the tarball
   can unpack perfectly and then fail on glibc. `llamacppInstallTarball`
   extracts to `<prefix>.new`, runs `llama-cli --version`, and only then swaps
   it in — falling back to offering the source build. Extraction success is not
   evidence of a working install.

The tarball is flat: binaries and their `.so` files in one directory. Symlinks
into `~/.local/bin` work because the dynamic linker resolves `$ORIGIN` from the
executable's *real* path.

`llamacppBackend()` then reads which backend is present from the libraries
beside the resolved binary (`libggml-cuda.so`, `libggml-vulkan.so`, …) rather
than from a state file — so it stays correct if llama.cpp was installed some
other way.

---

## The memory model — the deepest difference

This is the one place where a faithful port is impossible, because the
platforms do not agree on what memory *is*.

**macOS**: unified memory. One pool, and the GPU may address up to
`iogpu.wired_limit_mb` of it (~75 % by default, raisable with `sysctl`). "Does
this model fit?" has one answer, and the answer can be *widened by the user*.

**Linux**: two cases, neither of them that.

- *Integrated GPU or CPU-only* (this project's reference Debian box: AMD Ryzen
  with Vega graphics): there is one pool again, but no separate GPU budget to
  raise. The limit is simply RAM.
- *Discrete GPU*: VRAM is a genuinely separate pool. But VRAM decides **how
  fast** a model runs, not **whether it fits** — llama.cpp offloads the layers
  that fit and runs the rest on the CPU, and the weights pass through host
  memory either way.

So the Debian side computes:

```
budget = MemTotal - RAM_RESERVE_GB     (default reserve 5 GB, overridable)
```

and treats VRAM as a *speed* annotation, not a gate:
`aistackLaunchInferencePrerequisites` fails only when the model exceeds the RAM
budget, and **warns** when it exceeds VRAM ("the overflow layers run on CPU").
`budgetSummary()` prints one line naming which case the machine is in, wherever
macOS would have printed its `iogpu` limit.

The macOS advice *"raise it: `sudo sysctl iogpu.wired_limit_mb=…`"* becomes
*"lower the reserve: `RAM_RESERVE_GB=3 …`"* — the same lever, at the other end.

### MemTotal is not the size of your RAM

The trap that made this worth a section. `/proc/meminfo` `MemTotal` excludes
firmware-reserved and iGPU-carved memory: a 48 GB machine reports **46 GB**.
Since the model catalogs are keyed by RAM tier, using that number directly
loads `32_GB_Ram.json` on a 48 GB host and hides every model it can actually
run.

Hence two functions, and they are not interchangeable:

- `memTotalGb()` — the raw allocatable figure. **The budget is built from this**,
  because a budget must be made of memory that exists.
- `hostRamGb()` — `memTotalGb` rounded **up to the nearest 4 GB**, the machine's
  nominal size, matching what macOS's `hw.memsize` reports. **Catalog tier
  selection uses this.** RAM is sold in multiples of 4, so the rounding is safe.

### Free memory

macOS sums free + inactive + speculative pages from `vm_stat` (× 16384). Linux
has `MemAvailable`, which is the kernel's own estimate of what a new allocation
could get — strictly better, and used directly.

### GPU offload is not automatically a win

macOS has one answer: Metal offloads everything, always, and it is faster.
Linux does not, and the difference is large enough to be worth measuring per
machine rather than assuming.

Benchmarked on the reference Debian box (Ryzen 5 7430U, 6 physical / 12 logical
cores, Radeon Vega RENOIR iGPU; Qwen2.5-Coder-7B Q4_K_M; `llama-bench -p 64
-n 32`, error bars ±0.02–0.03):

| flag | prompt (pp64) | generation (tg32) |
|---|---|---|
| `-ngl 0` | 51.66 t/s | **8.19 t/s** |
| `-ngl 999` | 59.24 t/s | **7.61 t/s** |
| `-t 4` | 50.84 t/s | 7.99 t/s |
| `-t 6` (llama.cpp's own default) | 46.92 t/s | **8.16 t/s** |
| `-t 12` (`nproc`) | 45.66 t/s | **6.72 t/s** |

Two results that contradict the obvious choice:

1. **Offloading to an integrated GPU loses 7 % of generation speed** while
   gaining 15 % on prompt processing. An iGPU shares the CPU's memory
   bandwidth, and token generation is bandwidth-bound rather than
   compute-bound. Interactive coding is generation-dominated, so the Debian
   launcher does **not** pass `-ngl` on an integrated GPU. A discrete card has
   its own memory and does not have this problem, so it still gets `-ngl 999`.
   `LLAMACPP_NGL` opts in for prompt-heavy work.

   **And in `llama-server` it does nothing whatsoever on this hardware.** Same
   1624-token prompt, same 20-token reply, cold server each time:

   | server flags | prompt | generation |
   |---|---|---|
   | *(none)* | 58.27 t/s | 7.30 t/s |
   | `-ngl 999` | 58.54 t/s | 7.30 t/s |
   | `--device Vulkan0 -ngl 999` | 59.22 t/s | 7.29 t/s |

   Identical within noise — and llama-server's log never mentions Vulkan while
   llama-bench's does, so the server process never loads the Vulkan backend even
   though `llama-server --list-devices` cheerfully reports `Vulkan0`. Serving is
   the only path this toolkit uses, so a `-ngl` there would promise offload and
   deliver none. **A benchmark result does not automatically transfer to the
   binary you actually run** — which is why the launcher measures the server,
   not just the benchmark tool.
2. **Passing `-t $(nproc)` is 18 % slower than passing no `-t` at all**, because
   `nproc` counts logical CPUs and two hyperthreads on a core share one memory
   port. llama.cpp already defaults to the physical core count. The correct
   flag is no flag; `LLAMACPP_THREADS` overrides.

Both defaults were originally written the other way round, on reasoning that
sounded right and was wrong. This is what invariant 5 — *measured, never
estimated* — is for, and it applies to the toolkit's own settings, not only to
the numbers it reports to the user.

---

## Primitive mapping

| Purpose | macOS | Debian |
|---|---|---|
| Total RAM | `sysctl -n hw.memsize` | `/proc/meminfo` `MemTotal` (+ round up, see above) |
| Free memory | `vm_stat` page arithmetic | `/proc/meminfo` `MemAvailable` |
| GPU budget | `sysctl -n iogpu.wired_limit_mb` | none — RAM minus reserve; `nvidia-smi` / `rocm-smi` for VRAM |
| Accelerator present | always Metal | `nvidia-smi` \| `rocminfo` \| `/dev/dri` + `vulkaninfo` \| none |
| CPU count | — | `nproc` (passed to llama-server as `-t`) |
| Free disk | `df -g /System/Volumes/Data` | `df -BG --output=avail <path>` — **per path** |
| Directory size | `du -sh` | `du -sh`, with a `sudo` retry for root-owned trees |
| LAN address | `ipconfig getifaddr en0` | `ip -4 route get 1.1.1.1` → `src`, else `hostname -I` |
| Listening ports | `lsof` | `lsof` / `ss` |
| Service control | `brew services`, `launchctl` | `systemctl` (system and `--user`) |
| Package manager | `brew`, `brew --cask` | `apt-get`, `dpkg-query`, plus `snap` where relevant |
| Installed-version check | `brew outdated <formula>` | `apt-cache policy` Installed vs Candidate |
| Credentials | `security` (Keychain) | `secret-tool` (libsecret / Secret Service) |
| GUI applications | `osascript` → System Events | no equivalent — see below |
| Quit an application | `osascript -e 'quit app "X"'` | `kill -TERM`, then `-KILL` after a grace period |
| Reclaimable disk | delete local Time Machine snapshots (`tmutil`) | `apt-get clean`, `apt-get autoremove`, `journalctl --vacuum-size`, empty `~/.local/share/Trash` |

### Free disk is per-path on Linux

macOS reads one data volume and is done. On a Linux box `/`, `/home`,
`/var/lib/docker` and a bind-mounted VM disk can each be a different
filesystem, so `free_gb`/`free_kb` take a path, and `gain()` in the purge
scripts reports against the filesystem the removed thing actually lived on.
A single "total gained" number would be a fiction.

### There is no list of "open applications"

`aistackLaunchInferenceFreeResources` is the one function whose *mechanism*
had to be reinvented rather than translated. macOS asks the window server for
processes with a UI. Linux has no equivalent that is present on every desktop,
and none at all on a headless box.

The Debian version works from the process table instead: your own processes,
grouped by executable basename, RSS summed per group — so a browser is one
question, not forty. It skips:

- everything in this shell's process ancestry (both by pid and by name), so it
  can never offer to close the terminal it is running in;
- session infrastructure that a desktop cannot survive losing (`systemd`,
  `gnome-shell`, `Xorg`/`Xwayland`, `pipewire`, `wireplumber`, `dbus-*`,
  `gnome-keyring-daemon`, `polkitd`, `at-spi*`, `sshd`, shells, `tmux`);
- the stack's own engines and monitors;
- anything under `FREE_MIN_MB` (default 100).

It states plainly that summed RSS counts shared pages more than once, so the
number is a ranking rather than a total. Enter still means No.

---

## Ollama on Linux: two daemons, two model stores

The single most consequential runtime difference, and the one most likely to
produce "my models disappeared".

The official Linux installer registers a **system service** that runs as the
`ollama` system user with `HOME=/usr/share/ollama`. Models pulled through it
land in `/usr/share/ollama/.ollama/models` — **not** `~/.ollama`.

This stack runs the daemon **as you**, because it sets `OLLAMA_CONTEXT_LENGTH`,
`OLLAMA_HOST`, flash attention and KV cache type per launch, and a system unit
cannot be given per-launch settings. Both want port 11434.

The port resolves this in three places:

1. **`aistackInstallOllamaEngine`** asks once, right after installing, whether
   to `systemctl disable --now ollama` — defaulting to yes, and saying how many
   manifests are already in the system location. This sits in exactly the slot
   where the macOS version offers to migrate an `Ollama.app` to the brew
   formula: same question, same place, different clash.
2. **`ollamaModelsDir()`** resolves `$OLLAMA_MODELS` → a non-empty `~/.ollama`
   → the system location, and *every* path in the port goes through it, so
   neither store is ever invisible. Our daemon is always started with
   `OLLAMA_MODELS` set explicitly so the two cannot disagree.
3. **`aistackLaunchInferenceStart`** detects an active system service holding
   the port, explains that it will ignore the chosen context size, and offers
   to stop it — refusing rather than silently serving at the wrong context.

`ollama_prune_orphan_blobs` additionally checks the blob directory is writable
before doing anything, since the system-service layout is owned by another
user.

---

## Docker and Codex purges

Same design on both sides — ask before every step, raw → surgical, report the
disk actually freed — but the target is a different shape.

### noDockerRole.sh

macOS Docker Desktop hides in five ownership domains (app bundle, root
LaunchDaemons, root symlinks, per-user Library, keychain). Debian Docker is
**packages**, which changes three things:

- **apt has to remove it**, and the *repository* that would reinstall it has to
  go too — otherwise the next `apt upgrade` offers it straight back. That is a
  step macOS has no analogue for.
- **The heavy directories are system paths** (`/var/lib/docker`,
  `/var/lib/containerd`) rather than user ones, so they need root and are
  measured on their own filesystem.
- **Docker Desktop's VM disk is routinely a bind mount** onto a second disk.
  This is a real hazard, not a hypothetical: on the reference box
  `~/.docker/desktop/vms/0/data` is 89 GB bind-mounted from another NVMe
  partition, with an `/etc/fstab` entry. `rm -rf` through a live mount empties
  the *other* filesystem and leaves the mount and its fstab line behind — the
  worst of both outcomes. `removeMaybeMounted()` therefore asks `findmnt`
  first, unmounts, and offers to comment out the fstab line (backing the file
  up).

The Linux script also removes what macOS has no concept of: the systemd units,
and the **`docker` group** — membership of which is effectively root on the
machine, so on a Docker-free system it is a privilege with nothing behind it.

`~/MyDocker*` stays protected, with one addition: `isProtected()` also refuses
anything bind-mounted from the same source as a protected directory, because a
protected directory that is a mountpoint is precisely the easiest thing to
destroy by accident.

### noCodexRole.sh

The Debian version is **shorter, and that is the finding**. On macOS the hard
part is disentangling Codex from ChatGPT: shared `com.openai.*` namespace,
Codex task data inside ChatGPT's container, a ChatGPT-branded VS Code
extension. On Linux **there is no official ChatGPT desktop application**, so
that entanglement does not exist and two of the nine steps have nothing to
protect.

What survives: the CLI (npm, binary or snap), `~/.codex`,
`~/.cache/codex-runtimes`, the XDG directories — and the VS Code extension,
which is still branded ChatGPT and still a grey zone, so it keeps its own step
and its default of keeping. Both `~/.vscode/extensions` and
`~/.vscode-server/extensions` are checked, since a Linux box is often the
server end of somebody else's editor.

Unofficial ChatGPT clients (snap, flatpak, XDG config dirs) are **detected and
reported as protected** rather than assumed absent.

---

## Platform traps

### Linux-specific (found during this port)

- **`MemTotal` is not your RAM size** — firmware reserves some. Round up for
  tier selection, use the raw value for the budget. See above.
- **`releases/latest` on the llama.cpp repo is the wrong tag series.** Walk the
  release list for `bNNNNN`.
- **A prebuilt binary that unpacks is not a binary that runs.** Upstream builds
  against a newer glibc than Debian stable. Execute it before installing it.
- **npm's default global prefix needs root** on Debian, unlike Homebrew's node.
- **Ollama's system service uses a different model directory**, and it is owned
  by another user. See the section above.
- **Deleting through a live bind mount** empties the backing filesystem and
  leaves the mount. Always `findmnt` first.
- **Disk gain is per-filesystem.** One "space freed" total is a fiction on a
  multi-disk box.
- **`ps` `comm` is truncated to 15 characters.** The process grouping keys on
  the basename of `args[0]` instead.
- **No CUDA tarball for Linux upstream.** Vulkan or a source build.
- **`vulkaninfo` lists `llvmpipe` as a device** (`PHYSICAL_DEVICE_TYPE_CPU`). It
  is a software rasteriser, so a machine with no real GPU still "has Vulkan".
  Accelerator detection must require `DISCRETE_GPU` or `INTEGRATED_GPU`.
- **`-ngl` on an integrated GPU costs generation speed** — measured, see below.
- **`-t $(nproc)` is slower than passing no `-t` at all** — measured, see below.
- **A pipe into `python3 - <<'EOF'` is silently empty.** The heredoc supplies
  the *script* on stdin, so `json.load(sys.stdin)` reads the script text, not
  the piped data. Use `python3 -c` when data arrives on stdin; the heredoc form
  is only safe when the data comes from a file argument.
- **`ufw` can be active** and silently drop LAN connections to a bound engine,
  so the network selector says which port to allow.

### macOS-specific (unchanged, from SPECIFICATION.md)

- Ollama runs its own `llama-server` subprocess — match ours **by port**, never
  by name. *(The Debian port keeps the port-scoped match: it is correct on both,
  and cheap.)*
- `llama-server` answers 503 on `/health` and `/v1/models` while loading —
  "port open" is not "ready". *(True on both; kept verbatim.)*
- `llama-server` needs `--alias`, or agents infer a runtime from the filename.
  *(True on both.)*
- Engines clamp context silently; only Ollama can be asked its ceiling in
  advance. *(True on both.)*
- macOS local Time Machine snapshots pin freed disk. *(No Linux analogue;
  replaced by apt cache / journal / trash reclaims.)*
- `bash` expands every `local` argument before assigning any. *(Shell fact, not
  a platform one — true on both, and the comment is kept in both files.)*
- zsh does not word-split a plain `$var`. *(Same — the shell integration refuses
  to run under zsh on both platforms.)*

---

## What is not ported, and why

| | Why |
|---|---|
| **MLX-LM** (engine, models, catalogs) | Apple Silicon only. Named with its reason wherever it could be asked for |
| **macmon** | Reads Apple SoC power counters. `nvtop` covers the accelerator, `btop` the rest |
| **Anubis OSS** | macOS 15+ app bundle; no Linux build |
| **Time Machine snapshot deletion** | No analogue. The disk gate offers apt cache, journal and trash instead |
| **`Ollama.app` migration** | No Ollama desktop app on Linux. The equivalent clash is the systemd service, handled in the same slot |
| **Codex ↔ ChatGPT grey zones** | No official ChatGPT desktop app on Linux |

Nothing above is a stub. A step that cannot mean anything on a platform is
absent from that platform, and the place where you would have looked for it
tells you why.
