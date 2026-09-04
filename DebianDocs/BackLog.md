# Debian backlog — what the Linux side is still missing

The macOS and Debian trees mirror each other file for file, and most
differences between them are *intentional* platform divergence (MLX-LM,
Homebrew, macmon and Anubis exist only on macOS; apt, Node, btop, nvtop and
the Vulkan/CUDA llama.cpp delivery exist only here). This file lists the
remainder: features that exist on the macOS side — or are planned — and have
no Debian counterpart yet. Compiled 2026-09-04 from a function-level diff of
`MacOs/*.sh` vs `Debian/*.sh` at the `aistackMcp` merge.

## 1. LiteLLM proxy runtime (the big one)

Debian *installs* and *uninstalls* LiteLLM (`aistackInstallLitellmMonitoring`,
`aistackUninstallLitellmMonitoring`) — but the entire proxy lifecycle from the
`aistack_proxy` work exists only in `MacOs/launchInference.sh`:

| Missing function | Purpose |
|---|---|
| `aistackLaunchInferenceStartProxy` | start LiteLLM in front of the running engine |
| `aistackLaunchInferenceStopProxy` | stop only our proxy instance |
| `aistackLaunchInferenceProxyLog` | tail the request/latency log |
| `aistackLaunchInferenceProxySelector` | the launch-flow y/n step that offers the proxy |
| helpers: `litellm_up`, `litellmOurPids`, `litellmKillOurs`, `_aiStackWriteProxyLogger` | pid ownership, log plumbing |

So on Debian the proxy can be installed but never started, and
`DebianDocs/README.md` already lists LiteLLM in the Monitoring layer — the
docs are one step ahead of the code. Porting notes: pid discovery must come
from `/proc` / `ss` instead of macOS `lsof` conventions, and log paths should
follow the XDG-ish conventions the other Debian steps use.

## 2. `aistackLaunchInferenceReuse`

macOS can attach a new agent session to an engine that is already serving
(`aistackLaunchInferenceReuse`). Debian always goes through a full
launch decision. Same port-probing logic would work here — the probes
(`lsof`/`ss`) already exist on the Debian side for the kill-previous step.

## 3. MCP family — needs a live verification pass, not a port

`mcp.sh` is shared root-level code and deliberately platform-independent
(the browser opener is resolved at runtime). But every live-call fix in its
history was exercised on the Mac. Untested on the Linux box:

- OAuth login flow on a headless / ssh-only host (callback on
  `MCP_CALLBACK_PORT`, no local browser — the printed-URL path is the one
  that matters here);
- **bash** tab completion (`completions.bash`): the zsh path got several
  rounds of fixes, the Linux box has no zsh, and the "switch on tab
  completion" offer after `aistackMcpBuild` must pick the bashrc path;
- the `aistackMcpAdd` → `aistackMcpLogin` handoff under a plain bash login
  shell.

## 4. Documentation parity

- `DebianDocs/launchInference.sh.md` documents no proxy functions — correct
  today, must grow together with item 1.
- The root-level modules (`mcp.sh`, `shellFunctions.sh`, `completions.*`,
  `installAliases.sh`) are documented from the macOS perspective; a
  Debian-flavoured pass (bashrc instead of zshrc, no-zsh caveats) is pending.

## 5. Training / fine-tuning backend (forward-looking)

The planned Training / Dataset pipeline layer is engine-agnostic by design:
on Apple Silicon the fine-tuning backend will be MLX-LM, and the Debian
counterpart — CUDA / Transformers / PEFT — has no implementation, no
installer step, and no catalog notes yet. Nothing on either platform is
built yet; this item exists so the Debian backend is planned as a peer, not
retrofitted after an MLX-only implementation.

The model side is already in place: MedGemma 4B (the first fine-tuning
target) is in the shared `Llama.cpp` and `Ollama` catalogs that Debian
consumes; only `MLX-LM/` has no Debian consumer, by design.
