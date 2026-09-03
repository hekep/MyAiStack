# completions.zsh — tab completion for the MCP connectors, zsh.
#
# Sourced by shellFunctions.sh under zsh only. Same three levels as the bash
# file, but zsh can show a description beside each candidate, so the parameter
# hint appears inline: required flag, type or description, per argument.
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
    local -a items
    case $CURRENT in
        2) items=(${(f)"$(ls $base 2>/dev/null)"})
           _describe 'connector' items ;;
        3) items=(${(f)"$(sed $'s/\t/:/' $base/$words[2]/tools.txt 2>/dev/null)"})
           _describe 'tool' items ;;
        *) items=(${(f)"$(python3 - $base/$words[2]/tools.json $words[3] 2>/dev/null <<'PYC'
import json, sys
try: tools = json.load(open(sys.argv[1]))["tools"]
except Exception: sys.exit(0)
t = next((t for t in tools if t["name"] == sys.argv[2]), None)
if not t: sys.exit(0)
s = t.get("inputSchema") or {}
props = s.get("properties") or {}; req = s.get("required") or []
for k in sorted(props, key=lambda k: (k not in req, k)):
    p = props[k] or {}
    d = (p.get("description") or p.get("type") or "").replace(":", "\\:")
    print(f"{k}=:{'[required] ' if k in req else ''}{d}")
PYC
)"})
           _describe -S '' 'parameter' items ;;      # -S '' : no space after "key="
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
