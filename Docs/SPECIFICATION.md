# MyAiStack — specification

What this project is, what it guarantees, and the rules any change must keep.
Behavioural detail per script lives in the other documents here; this is the
contract they all implement.

## Purpose

Run capable coding models locally — on Apple Silicon macOS and on Debian/Ubuntu
— with every choice explicit and reversible. The stack is assembled from four independent layers, and the
user is never asked a question the machine can answer for itself.

## The four layers

| Layer | What it provides | Members |
|---|---|---|
| **Engine** | serves tokens over HTTP | llama.cpp *(default)*, Ollama, and MLX-LM on macOS only |
| **Coding agent** | what you type into | Pi *(default)*, OpenCode, Claude Code |
| **Models** | weights on disk, per engine | catalogs in `ModelLists/<Engine>/<RAM>_GB_Ram.json` |
| **Monitoring** | observability, optional | macOS: macmon, Anubis OSS, LiteLLM · Debian: nvtop, btop, LiteLLM |

Layers are independent: any engine can be installed without an agent, any agent
without models. The install wizard stops only when **no engine at all** is
present, because nothing below that point can mean anything.

Every choice these layers offer, and what each one determines, is drawn out in
[DecisionTree.md](DecisionTree.md).

### Engine / agent compatibility

The single asymmetry in the design, and the reason compatibility is enforced
rather than assumed:

| Agent | API it speaks | Works with |
|---|---|---|
| Pi | OpenAI-compatible | all three engines |
| OpenCode | OpenAI-compatible | all three engines |
| Claude Code | **Anthropic Messages** | **Ollama only** |

An impossible pairing is never offered — not hidden, but named with the reason.

### Engine facts

| Engine | Port | Model reference | Quants reachable |
|---|---|---|---|
| Ollama | 11434 | registry tag (`qwen3.6:35b-a3b`) | q4_K_M, q8_0 only |
| llama.cpp | 8080 | `hf-repo:QUANT` | Q4/Q5/Q6/Q8 — the full ladder |
| MLX-LM | 8081 | HF repo, quant in the name | 4bit / 6bit / 8bit |

Ollama's registry has no mid quants and its direct HuggingFace pulls fail, so
llama.cpp and MLX-LM are the **only** routes to Q5_K_M / Q6_K / 6bit — and on
Debian, where MLX cannot run, llama.cpp is the only one. Which layer members
exist on which platform is tabulated in [PlatformNotes.md](PlatformNotes.md).

## MCP connectors

An MCP server is a third party's data behind OAuth — a wearable, an issue
tracker, a calendar. `mcp.sh` connects one and makes its tools available to the
coding agents, without the stack ever holding a credential of its own.

### One core, three callers

Everything that reaches the network happens in one shell function. The agents do
not speak MCP at all; they run the same command a person would.

```
shell           aistackMcpCall aidlab aidlab_list_sleep start_date=... end_date=...
Pi              execute() -> bash -c '. mcp.sh && aistackMcpCall ...'
OpenCode        execute() -> Bun.$`bash -c '. mcp.sh && aistackMcpCall ...'`
                                    |
                            _aiStackMcpRpc      <- the only place HTTP happens
                              bearer token, refresh on expiry
                              Mcp-Session-Id, 401 retry
                              JSON or text/event-stream response
```

A tool call from an agent is byte-for-byte what you can type at a prompt, so the
shell is a real test of the agent path rather than a simulation of it. That is
the whole reason for the shape.

### The lifecycle

| Step | What it does |
|---|---|
| `aistackMcpAdd <name> --url <url>` | follows the 401 challenge to the resource metadata, then to the authorization server that actually offers registration, and registers as a public native client |
| `aistackMcpLogin <name>` | PKCE S256, browser consent, one-shot loopback callback, tokens to `~/.aistack/mcp/<name>/tokens.json` at 0600 |
| `aistackMcpBuild <name>` | `tools/list`, caches the schemas, and **generates a plugin per agent** |
| `aistackMcpCall` | one `tools/call`; what the plugins run underneath |

**Login must precede build.** The tool list is per account: what a server offers
depends on who is asking and what they were granted, so a plugin generated
before sign-in would describe somebody else's tool surface.

### Credentials never enter the repo

State lives in `~/.aistack/mcp/<name>/`, never in the working tree — a refresh
token must not sit where a commit can reach it. `tokens.json` is written 0600
through a temporary file and a rename, so a crash cannot leave a half-written
credential. Removing a connector deletes the directory; it cannot revoke access
upstream, and says so.

### The generated plugin is a shim, and does the work a model cannot

The plugin holds no HTTP code. What it does hold is everything a language model
reliably gets wrong, computed in code at the moment tools are registered:

| Injected | Why |
|---|---|
| today's date | a model has no clock and invents a plausible one |
| eight days of dated weekdays | asked for "last Wednesday" it cannot derive the day, and picks a neighbour |
| host timezone, and wall-clock to UTC conversion | "5 pm" means 5 pm where the user is, not in London |
| a repaired date range | `start == end` is a zero-length window that returns nothing |
| an explanation on an empty result | `{"data":[]}` reads as "you have no data", which is a different claim |
| a `finish` tool | agentic models trained to end a turn with one loop forever without it |

This is the ordinary invariant — *measured, never estimated* — pointed at what
reaches the model. If the shell can compute something exactly, the model should
not be guessing at it.

Optional reduction (`AISTACK_MCP_MAX_RECORDS`, default off) replaces a long
result with computed statistics. It exists for small context windows, where one
page of samples can be a tenth of the budget; a capable model on a large window
is better served the records themselves.

### Generation is checked before it is trusted

The plugin is written from an unquoted heredoc, because it interpolates the
connector name and paths. That means a literal `$` must be escaped and a
backtick is command substitution — both have silently corrupted generated code.
`aistackMcpBuild` refuses to report success unless the output has no empty
property access and balances its braces, parens, brackets and template literals.

### Agent support

| Agent | How | Through the common core |
|---|---|---|
| Pi | generated extension, attached per launch or enabled in its settings | yes |
| OpenCode | one generated tool file per MCP tool, symlinked into its tools directory | yes |
| Claude Code | `claude mcp add`, native, its own OAuth | no |

Claude Code is the exception for the same reason it is elsewhere in this
specification: it does its own thing, and pretending otherwise would be a lie in
the code.

## Naming contract

Every user-facing function is `aistack`-prefixed, so typing `aistack` at the
shell reveals the whole toolkit. Scripts keep plain names.

| Family | Purpose | macOS | Debian |
|---|---|---|---|
| `aistackInstall*` | install one layer member | 18 | 17 |
| `aistackUninstall*` | remove one layer member | 19 | 18 |
| `aistackLaunchInference*` | serve a model, attach an agent, front it with a proxy | 20 | 14 |
| `aistackModelTest*` | verify one engine + model | 15 | 15 |
| `aistackMcp*` | connect an MCP server, generate agent plugins | 11 | — |
| `aistackConvert*` | turn upstream weights into something an engine serves | 4 | — |
| `aistackTestAllAiModels`, `aistackNoRole`, `aistackHelp` | whole-script entry points | 3 | 3 |

`aistackHelp` prints the live list — prefer it to any number written here.

The last two families are **tools, not layers**: they are invoked deliberately
and take no part in the install wizard. Both live in platform-independent root
scripts (`mcp.sh`, `convert.sh`) rather than an OS folder, because nothing in
them differs between platforms except which command opens a browser. Neither is
registered on Debian yet.

**Install and uninstall mirror each other function for function.** The one
exception is `aistackUninstallOllamaData` (`~/.ollama`), which has no install
counterpart because that directory is created by pulling models, not by an
install step. Removing it is a separate decision — it destroys every blob.

Adding a layer member means adding *both* an install and an uninstall function,
plus its detection predicate. The shell integration discovers functions by
prefix, so nothing else needs wiring.

## Invariants

These are the rules that make the toolkit safe to re-run and safe to call
piecemeal. A change that breaks one of these is a bug, however convenient.

1. **Idempotent.** Every step detects what is already done and proposes an
   update only when one genuinely exists. Re-running is a status check.
2. **One question at a time**, and **never a question with one possible
   answer** — a single valid option is announced and used.
3. **Enter is safe.** Destructive prompts default to No; expected ones to Yes.
4. **Hard gates, not warnings.** Insufficient disk or RAM stops the flow.
5. **Measured, never estimated.** Disk from `df` before/after, memory from
   `ps`/`vm_stat`, ports from `lsof`, tokens/sec from the engine's counters.
6. **Every argument-taking function explains itself** when called bare: usage,
   per-argument help, and an example **generated from what is installed**.
   When nothing is possible, it names the command that fixes that.
7. **Fail early, name the fix.** Validate agent → engine → model → compatibility
   → is-anything-serving, in that order, so the first real problem is reported.
8. **One model resident at a time** when testing. Teardown kills *and waits*.
9. **Protect the expensive and the personal.** Model blobs, `~/MyDocker*`,
   `~/.claude`, agent configs and keychain entries are separate decisions from
   the software that uses them.

## Ordering

**Install** runs foundations-first; **uninstall** runs most-dependent-first —
the exact reverse:

```
install:    sanity → disk gate → Homebrew
            → engines → agents → models → monitoring → verification
uninstall:  sanity → disk gate → models (GATE)
            → monitoring → agents → engines → engine data → uv → verification
```

The uninstall **gate**: while any model remains, nothing beneath it is removed
and the wizard stops. `aistackUninstallOllamaEngine` enforces the same rule
independently, so it holds even when called directly.

## Platform dispatch

Root `*.sh` are thin wrappers: they source `common.sh`, detect the OS, and exec
the real implementation from that OS's folder.

```
MacOs/     Apple Silicon macOS
Debian/    Debian/Ubuntu
other      refused with a clear message, never half-run
```

Both folders implement this whole specification. What differs between them is
never the contract, only the primitives — which measurement command, which
package manager — and every difference is recorded in
[PlatformNotes.md](PlatformNotes.md). Always invoke the root wrappers so the
same commands work on both.

A layer member that cannot exist on a platform is **absent there, not stubbed**
— but the place you would look for it explains why. Asking the Debian launcher
for `MLX-LM` gets "Apple Silicon only, use Llama.cpp for the same quality band",
not "unknown engine".

## Model catalogs are data

`ModelLists/<Engine>/<RAM>_GB_Ram.json` — curated top-20 per RAM tier, biggest
first. `size_gb` is the **real** download size read from the upstream manifest,
never an estimate. Editing the catalog is editing data, never code.

Selection: the largest tier ≤ host RAM; then filtered by the *current* GPU
limit (`size × 1.3 + 2`), by free disk, by what is already installed, and by
existence upstream (probed and cached 24 h) so a listed model can never 404.

## Shell integration

`installAliases.sh` writes a marker-delimited block into the shell rc that
sources `shellFunctions.sh`. It is idempotent, backs the rc up, and `--remove`
restores it exactly.

Two deliberate refusals, both load-bearing:

- **Scripts are not sourced into your shell.** They define helpers named `ok`,
  `warn`, `fail`, `ask`, `info`; each function runs in its own bash process so
  those names never reach your session.
- **Functions do not run under zsh.** These are bash scripts and zsh arrays are
  1-indexed, so every numbered menu would select the wrong item.

## Environment knobs

| Variable | Effect | Where |
|---|---|---|
| `AI_STACK_HOME` | repo location (written into the rc) | both |
| `MODEL_LIST_ENGINE` | which catalog folder to read | both |
| `LLAMACPP_MODEL_DIR` | GGUF location (default `~/Models/llama.cpp`) | both |
| `OLLAMA_CTX` / `FREE_MIN_MB` | context floor; process-closing threshold | both |
| `PROMPT` | test prompt, suppresses the prompt question | both |
| `RAM_RESERVE_GB` | RAM held back from the model budget (default 5) — the Linux counterpart of raising `iogpu.wired_limit_mb` | Debian |
| `LLAMACPP_PREFIX` / `LLAMACPP_BINDIR` | where the engine is unpacked and linked (default `~/.local/opt/llama.cpp`, `~/.local/bin`) | Debian |
| `LLAMACPP_NGL` / `LLAMACPP_THREADS` | override the backend-derived `-ngl` / `-t` passed to llama-server | Debian |
| `OLLAMA_MODELS` | which of Linux's two model stores to use | Debian |

Per-user choices persist in `~/.aistackLaunchInference.conf` and become the next
run's defaults — the same file and keys on both platforms.

## Platform traps

Hard-won, and cheap to re-break. These are the macOS-side traps; the Linux ones
(and which of these apply to both) are in
[PlatformNotes.md](PlatformNotes.md#platform-traps).

- **Ollama runs its own `llama-server` subprocess.** Match ours by port; killing
  by name breaks Ollama's runner and poisons its Metal state.
- **llama-server answers 503 on `/health` and `/v1/models` while loading.**
  "Port open" is not "ready".
- **`llama-server` needs `--alias`**, or it advertises the `.gguf` path and
  agents infer a runtime from the filename.
- **`ollama list` needs the daemon**; model presence and size must fall back to
  reading `~/.ollama/models/manifests`.
- **zsh does not word-split a plain `$var`** (it does split `$(cmd)`), and sets
  `$0` to the sourced file. Both have caused real bugs here.
- **bash expands every `local` argument before assigning any**, so
  `local a="$1" b="${a%:*}"` silently leaves `b` empty — or picks up the
  caller's variable, which is worse.
- **Engines clamp context silently.** A model trained for 32K accepts `-c 524288`
  and serves 32K, having allocated KV cache for the request. Only Ollama can be
  asked its ceiling in advance (`/api/show`), so the launcher reports what is
  actually served and flags the gap.
- **Two big models resident at once will take the machine down.**
- **macOS local Time Machine snapshots pin freed disk**, so cleanup can look
  ineffective until they are deleted.
