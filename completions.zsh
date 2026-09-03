# completions.zsh — tab completion for the MCP connectors, zsh.
#
# Sourced by shellFunctions.sh under zsh only. Three levels:
#   aistackMcpCall <TAB>                  connector names
#   aistackMcpCall aidlab <TAB>           tool names, with their descriptions
#   aistackMcpCall aidlab <tool> <TAB>    key= parameters, required ones first
#
# The first two levels read plain text written by aistackMcpBuild, so completing
# never touches the network. Parameters need the cached JSON schema, which is
# also local.
#
# ${(f)"$(...)"} splits on newlines explicitly — zsh does not word-split a plain
# parameter expansion, which is the trap that breaks naive ports from bash.

# zsh's completion system is not on by default: a bare shell (no oh-my-zsh,
# prezto or explicit compinit) has no compdef, and TAB falls back to plain
# filename expansion. Without compinit nothing here can register at all, so
# initialise it when it is missing. -i ignores insecure directories rather than
# prompting at login, which macOS setups routinely trip over. This affects only
# completion; prompts, keybindings and options are left alone.
if (( ! $+functions[compdef] )); then
    autoload -Uz compinit && compinit -i 2>/dev/null
fi
(( $+functions[compdef] )) || return 0

# Completion for the functions taking <name> <tool> [key=value ...].
_aistackMcpComplete() {
    local base="$HOME/.aistack/mcp"
    local -a items keys disp
    local k d
    case $CURRENT in
        2) items=(${(f)"$(ls $base 2>/dev/null)"})
           _describe 'connector' items ;;
        3) items=(${(f)"$(sed $'s/\t/:/' $base/$words[2]/tools.txt 2>/dev/null)"})
           _describe 'tool' items ;;
        *) # Parameters are added with compadd, not _describe: the match must
           # carry NO trailing space, so the value can be typed straight after
           # the "=". -S '' is a compadd option; _describe does not accept it,
           # and passing it there fails with "bad option: -S".
           while IFS=$'\t' read -r k d; do
               [ -n "$k" ] || continue
               keys+=("$k"); disp+=("${(r:22:)k} -- $d")
           done < <(python3 - "$base/$words[2]/tools.json" "$words[3]" 2>/dev/null <<'PYC'
import json, sys
try: tools = json.load(open(sys.argv[1]))["tools"]
except Exception: sys.exit(0)
t = next((t for t in tools if t["name"] == sys.argv[2]), None)
if not t: sys.exit(0)
s = t.get("inputSchema") or {}
props = s.get("properties") or {}; req = s.get("required") or []
for k in sorted(props, key=lambda k: (k not in req, k)):
    p = props[k] or {}
    d = (p.get("description") or p.get("type") or "").strip()
    print(f"{k}=\t{'[required] ' if k in req else ''}{d}")
PYC
           )
           (( $#keys )) && compadd -S '' -l -d disp -a keys ;;
    esac
}

# Completion for the functions taking only <name>.
_aistackMcpNameOnly() {
    local -a n; n=(${(f)"$(ls "$HOME/.aistack/mcp" 2>/dev/null)"})
    _describe 'connector' n
}

compdef _aistackMcpComplete aistackMcpCall aistackMcpTools
compdef _aistackMcpNameOnly aistackMcpLogin aistackMcpBuild aistackMcpRemove \
                            aistackMcpLogout aistackMcpRefresh aistackMcpEnable aistackMcpDisable

# Tell the aistackMcp* functions that completion is live in this shell. They run
# in their own bash process, which inherits exported variables — so this is how
# aistackMcpBuild knows whether to suggest reloading the rc file.
export AI_STACK_COMPLETION=zsh
