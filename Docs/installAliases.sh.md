# installAliases.sh — the step functions in every shell

## What it does

Makes every step of the toolkit callable from anywhere, by adding two lines to
your shell rc that source [shellFunctions.sh](../shellFunctions.sh):

```bash
./installAliases.sh            # add it (asks first, backs up the rc)
./installAliases.sh --remove   # take it out again
```

After a shell restart:

```bash
aistackHelp                     # list everything available
aistackInstallOllamaModels      # just the Ollama download menu
aistackLaunchInferenceKillPrevious     # free the GPU without a full launch
aistackModelTest Ollama qwen3.6:35b-a3b
aistackUninstallPiCodingAgent
aistackTestAllAiModels
aistackNoRole Docker
```

55 functions at present: `aistackInstall*`, `aistackUninstall*`,
`aistackLaunchInference*`, `aistackModelTest*`, plus the whole-script entry points.

## How it works

`installAliases.sh` writes a marker-delimited block into `~/.zshrc` and/or
`~/.bashrc` (your login shell's rc, plus any other that already exists):

```bash
# >>> MyAiStack >>>
export AI_STACK_HOME="/path/to/MyAiStack"
[ -f "${AI_STACK_HOME}/shellFunctions.sh" ] && . "${AI_STACK_HOME}/shellFunctions.sh"
# <<< MyAiStack <<<
```

- **Idempotent** — the markers mean a re-run replaces the block instead of
  stacking duplicates. Verified: two runs leave exactly one block.
- **Backs up first** — `~/.zshrc.aiStack.bak` before any edit.
- **Reversible** — `--remove` strips the block and leaves the file byte-identical
  to what it was before.
- **Fails soft** — the `[ -f ... ]` guard means a moved or deleted checkout
  makes new shells start normally rather than erroring on every prompt.

`shellFunctions.sh` then defines one wrapper per public function, reading the
names **out of the scripts** so a new step becomes available with no extra
wiring.

## Two deliberate refusals

**It does not source the scripts into your shell.** They define helpers called
`ok`, `warn`, `fail`, `ask` and `info` — sourcing those would shadow anything
else by those names in your session. Each wrapper runs the real function in its
own process, so only prefixed names ever exist in your shell. (Verified: after
loading, `ok`, `warn`, `fail`, `ask` and `info` are all still undefined.)

**It does not run them in zsh.** These are bash scripts and zsh arrays are
1-indexed, so every numbered menu would silently select the wrong item. Every
wrapper executes under `bash` regardless of your shell; the terminal is
inherited, so prompts and menus work normally.

## Why it is necessary

The wizards (`./install.sh`, `./launchInference.sh`) are the front door, but
most day-to-day work is a *single step*: re-open the model menu, free the GPU,
re-test one model. Those are already independent functions — this just removes
the `cd` and the `source` before each one.

`installAliases.sh` is intentionally **not** an OS dispatcher, unlike the other
root scripts: editing a shell rc is identical on every platform, and a per-OS
copy would only be a second place to fix the same bug.
