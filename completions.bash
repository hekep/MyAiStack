# completions.bash — tab completion for the MCP connectors, bash.
#
# Sourced by shellFunctions.sh under bash only. Three levels:
#   aistackMcpCall <TAB>                  connector names
#   aistackMcpCall aidlab <TAB>           tool names
#   aistackMcpCall aidlab <tool> <TAB>    key= parameters, required ones first
#
# The first two levels read plain text written by aistackMcpBuild, so completing
# never touches the network. Descriptions need JSON, so bash offers them via
# "aistackMcpTools <name> <tool>" instead — zsh shows them inline.

# Print every connector that has been added.
_aiStackMcpCompleteNames() { ls "$HOME/.aistack/mcp" 2>/dev/null; }
# Print the tool names of one connector. Args: <name>.
_aiStackMcpCompleteTools() { cut -f1 "$HOME/.aistack/mcp/$1/tools.txt" 2>/dev/null; }
# Print "key=" for each parameter of one tool, required first. Args: <name> <tool>.
_aiStackMcpCompleteParams() {
    python3 - "$HOME/.aistack/mcp/$1/tools.json" "$2" 2>/dev/null <<'PYC'
import json, sys
try: tools = json.load(open(sys.argv[1]))["tools"]
except Exception: sys.exit(0)
t = next((t for t in tools if t["name"] == sys.argv[2]), None)
if not t: sys.exit(0)
s = t.get("inputSchema") or {}
props = s.get("properties") or {}; req = s.get("required") or []
print(" ".join(f"{k}=" for k in sorted(props, key=lambda k: (k not in req, k))))
PYC
}

# Completion for the functions taking <name> <tool> [key=value ...].
_aistackMcpComplete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    case "$COMP_CWORD" in
        1) COMPREPLY=($(compgen -W "$(_aiStackMcpCompleteNames)" -- "$cur")) ;;
        2) COMPREPLY=($(compgen -W "$(_aiStackMcpCompleteTools "${COMP_WORDS[1]}")" -- "$cur")) ;;
        *) compopt -o nospace 2>/dev/null      # leave the cursor right after "key="
           COMPREPLY=($(compgen -W "$(_aiStackMcpCompleteParams "${COMP_WORDS[1]}" "${COMP_WORDS[2]}")" -- "$cur")) ;;
    esac
}

# Completion for the functions taking only <name>.
_aistackMcpNameOnly() {
    COMPREPLY=($(compgen -W "$(_aiStackMcpCompleteNames)" -- "${COMP_WORDS[COMP_CWORD]}"))
}

complete -F _aistackMcpComplete aistackMcpCall aistackMcpTools
complete -F _aistackMcpNameOnly aistackMcpLogin aistackMcpBuild aistackMcpRemove \
                                aistackMcpLogout aistackMcpRefresh aistackMcpEnable aistackMcpDisable
