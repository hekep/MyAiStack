#!/bin/bash
#
# mcp.sh — MCP connectors for MyAiStack.
#
# Gives the stack read access to remote MCP servers (OAuth, HTTP transport) and
# exposes each server's tools three ways from ONE implementation:
#
#   shell      aistackMcpCall aidlab aidlab_get_profile
#   Pi         a generated extension whose execute() runs the line above
#   OpenCode   a generated tool file per MCP tool, doing the same
#
# Everything HTTP happens in _aiStackMcpRpc. A tool call from an agent is
# byte-for-byte what you can type at the shell, so the shell is a real test of
# the agent path rather than a simulation of it.
#
# Platform-independent: the only OS difference is the browser opener, resolved
# at use. State lives in ~/.aistack/mcp/<name>/, never in the repo — tokens.json
# holds a refresh token and is written 0600.

MCP_HOME="${MCP_HOME:-$HOME/.aistack/mcp}"
MCP_CALLBACK_PORT="${MCP_CALLBACK_PORT:-49999}"
MCP_PROTOCOL="2025-06-18"

# ---------- output ------------------------------------------------------------
# All progress goes to stderr so stdout carries only data — aistackMcpCall's
# stdout is the tool result, which the agent shims read directly.
# AI_STACK_QUIET=1 (set by those shims) drops info/ok; warnings and errors stay.
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true); YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

# Print a progress heading naming the step about to run.
info() { [ -n "${AI_STACK_QUIET:-}" ] || echo "${BLUE}==>${RESET} $*" >&2; }
# Print a success line — also used for "already done", so a re-run reads the same.
ok()   { [ -n "${AI_STACK_QUIET:-}" ] || echo "${GREEN} ✓ ${RESET} $*" >&2; }
# Print a caution line: a caveat, or something skipped by your choice.
warn() { echo "${YELLOW} ! ${RESET} $*" >&2; }
# Print an error line for something that was attempted and failed.
fail() { echo "${RED} ✗ ${RESET} $*" >&2; }

# Print a usage message for a function called without its arguments, return 2.
# Local copy: mcp.sh is sourced standalone by the agent shims, which never load
# common.sh. Args: <signature> [detail lines...].
if ! command -v aiStackUsage >/dev/null 2>&1; then
aiStackUsage() {
    local sig="$1"; shift
    fail "usage: ${sig}"
    local l
    for l in "$@"; do echo "         ${l}" >&2; done
    return 2
}
fi

# Ask a yes/no question where Enter picks a caller-supplied default.
# Args: <question> <y|n>. Reads /dev/tty so prompts survive piped output; with
# no terminal the default is taken rather than aborting, so the agent shims and
# non-interactive runs never hang.
if ! command -v ask_def >/dev/null 2>&1; then
ask_def() {
    if [ $# -lt 2 ]; then
        aiStackUsage "ask_def <question> <y|n>" "example : ask_def \"Wire this into Pi?\" y"
        return 2
    fi
    local answer hint
    [ "$2" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    printf "\n%s%s%s %s " "${BOLD}" "$1" "${RESET}" "$hint" >&2
    # the redirection itself fails without a terminal, so the whole read is
    # wrapped — not just read's own stderr — and the default is taken silently
    { read -r answer </dev/tty; } 2>/dev/null || { answer=""; echo >&2; }
    case "${answer:-$2}" in [Yy]|[Yy]es) return 0 ;; *) return 1 ;; esac
}
fi

# True when a real terminal is reachable, so a prompt would be seen and answered.
# Tests /dev/tty rather than [ -t 0 ]: these functions run in a child bash whose
# stdin is often redirected even when the user is sitting right there. Scripts,
# cron jobs and agent shims fail this and are never prompted.
_aiStackMcpInteractive() { { : </dev/tty; } 2>/dev/null; }

# ---------- connector state ---------------------------------------------------
# Print the state directory for a connector. No side effects, no existence check
# — callers that need the connector to exist use _aiStackMcpRequire.
_aiStackMcpDir() { echo "${MCP_HOME}/$1"; }

# Print the names of every connector that has been added, one per line.
# Empty output (not an error) when none exist yet.
_aiStackMcpNames() {
    local d
    [ -d "$MCP_HOME" ] || return 0
    for d in "$MCP_HOME"/*/; do
        [ -f "${d}server.json" ] && basename "$d"
    done
}

# Print the first connector name, for usage examples. Empty when none exist.
_aiStackMcpFirstName() { _aiStackMcpNames | head -1; }

# Read one field out of a connector's server.json. Args: <name> <field>.
# Fails with the command that would create the connector when it is unknown.
_aiStackMcpField() {
    local name="$1" field="$2" f
    f="$(_aiStackMcpDir "$name")/server.json"
    [ -f "$f" ] || { fail "Unknown connector '${name}'."; return 1; }
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],""); print(" ".join(v) if isinstance(v,list) else v)' "$f" "$field"
}

# Guard for every function taking a connector name: verify it exists, else name
# the fix. Args: <name>.
_aiStackMcpRequire() {
    local name="$1"
    [ -f "$(_aiStackMcpDir "$name")/server.json" ] && return 0
    fail "No connector named '${name}'."
    local have; have=$(_aiStackMcpNames | tr '\n' ' ')
    if [ -n "$have" ]; then echo "         Added: ${have}" >&2
    else echo "         Add one first:  aistackMcpAdd aidlab --url https://my.aidlab.com/mcp" >&2; fi
    return 1
}

# ---------- tokens ------------------------------------------------------------
# Exchange the stored refresh token for a fresh access token and rewrite
# tokens.json (0600, atomic). Args: <name>. The refresh_token is carried over
# when the server does not return a new one.
_aiStackMcpRefresh() {
    local name="$1" dir; dir=$(_aiStackMcpDir "$name")
    [ -f "$dir/tokens.json" ] || { fail "No tokens for '${name}' — run: aistackMcpLogin ${name}"; return 1; }
    info "Refreshing the ${name} access token..."
    python3 - "$dir" "$name" <<'PY'
import json, os, sys, time, urllib.parse, urllib.request, urllib.error
d, name = sys.argv[1], sys.argv[2]
s = json.load(open(f"{d}/server.json")); t = json.load(open(f"{d}/tokens.json"))
if not t.get("refresh_token"):
    sys.exit(f"no refresh token stored — run: aistackMcpLogin {name}")
body = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": t["refresh_token"],
                               "client_id": s["client_id"], "resource": s["resource"]}).encode()
req = urllib.request.Request(s["token_endpoint"], data=body, headers={
    "content-type": "application/x-www-form-urlencoded", "accept": "application/json"})
try:
    n = json.load(urllib.request.urlopen(req, timeout=20))
except urllib.error.HTTPError as e:
    sys.exit(f"refresh rejected ({e.code}): {e.read().decode()[:200]} — run: aistackMcpLogin {name}")
n.setdefault("refresh_token", t["refresh_token"])
n["expires_at"] = int(time.time()) + int(n.get("expires_in", 3600)) - 30
n["obtained"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
tmp = f"{d}/tokens.json.tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f: json.dump(n, f, indent=2)
os.replace(tmp, f"{d}/tokens.json")
PY
}

# Print a currently-valid access token for a connector, refreshing first when
# the stored one has expired. Args: <name>.
_aiStackMcpBearer() {
    local name="$1" dir exp now
    dir=$(_aiStackMcpDir "$name")
    [ -f "$dir/tokens.json" ] || { fail "Not signed in to '${name}' — run: aistackMcpLogin ${name}"; return 1; }
    exp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("expires_at",0))' "$dir/tokens.json")
    now=$(date +%s)
    if [ "${exp:-0}" -le "$now" ]; then
        _aiStackMcpRefresh "$name" || return 1
    fi
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$dir/tokens.json"
}

# ---------- the one HTTP path -------------------------------------------------
# One JSON-RPC round trip to a connector's MCP endpoint. Args:
# <name> <method> [params-json]. Prints the "result" object on stdout.
# Handles bearer/refresh, Mcp-Session-Id, 401-retry, and both response
# encodings (application/json and text/event-stream). THE ONLY PLACE HTTP HAPPENS.
_aiStackMcpRpc() {
    if [ $# -lt 2 ]; then
        aiStackUsage "_aiStackMcpRpc <name> <method> [params-json]" \
            "example : _aiStackMcpRpc $(_aiStackMcpFirstName || echo aidlab) tools/list '{}'"
        return 2
    fi
    local name="$1" method="$2" params="${3:-}" dir url tok sid id code attempt rc
    local hdrs body
    [ -z "$params" ] && params='{}'
    dir=$(_aiStackMcpDir "$name")
    url=$(_aiStackMcpField "$name" url) || return 1
    hdrs=$(mktemp) || return 1
    body=$(mktemp) || { rm -f "$hdrs"; return 1; }

    for attempt in 1 2; do
        tok=$(_aiStackMcpBearer "$name") || { rm -f "$hdrs" "$body"; return 1; }
        sid=$(cat "$dir/.session" 2>/dev/null)
        id=$$$RANDOM
        local -a extra=()
        [ -n "$sid" ] && extra=(-H "mcp-session-id: ${sid}")
        code=$(curl -s -o "$body" -D "$hdrs" -w '%{http_code}' --max-time 90 -X POST "$url" \
            -H 'content-type: application/json' \
            -H 'accept: application/json, text/event-stream' \
            -H "mcp-protocol-version: ${MCP_PROTOCOL}" \
            -H "authorization: Bearer ${tok}" \
            "${extra[@]}" \
            -d "{\"jsonrpc\":\"2.0\",\"id\":\"${id}\",\"method\":\"${method}\",\"params\":${params}}")
        if [ "$code" = "401" ] && [ "$attempt" = "1" ]; then
            _aiStackMcpRefresh "$name" || { rm -f "$hdrs" "$body"; return 1; }
            continue
        fi
        break
    done

    # remember the session id when the server issues one — it is echoed on every
    # later request in the same session
    local newsid
    newsid=$(sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: *//p' "$hdrs" | tr -d '\r' | head -1)
    [ -n "$newsid" ] && printf '%s' "$newsid" > "$dir/.session"

    case "$code" in
        2??) ;;
        *) fail "${name} ${method}: HTTP ${code} — $(head -c 200 "$body")"; rm -f "$hdrs" "$body"; return 1 ;;
    esac

    python3 - "$body" "$id" "$method" <<'PY'
import json, sys
body = open(sys.argv[1]).read(); want = sys.argv[2]; method = sys.argv[3]
msg = None
if body.lstrip().startswith("{"):
    try: msg = json.loads(body)
    except ValueError: sys.exit(f"{method}: response was not JSON")
else:                                     # SSE: take the data: line whose id matches
    for line in body.splitlines():
        if line.startswith("data:"):
            try:
                m = json.loads(line[5:].strip())
            except ValueError:
                continue
            if str(m.get("id")) == want:
                msg = m; break
if msg is None:    sys.exit(f"{method}: no response carrying id {want}")
if "error" in msg:
    e = msg["error"]
    sys.exit(f"{method}: {e.get('message', e) if isinstance(e, dict) else e}")
json.dump(msg.get("result", {}), sys.stdout)
PY
    rc=$?
    rm -f "$hdrs" "$body"
    return $rc
}

# Send a JSON-RPC notification (no id, no response expected). Args: <name> <method>.
_aiStackMcpNotify() {
    local name="$1" method="$2" url tok sid dir
    dir=$(_aiStackMcpDir "$name")
    url=$(_aiStackMcpField "$name" url) || return 1
    tok=$(_aiStackMcpBearer "$name") || return 1
    sid=$(cat "$dir/.session" 2>/dev/null)
    local -a extra=()
    [ -n "$sid" ] && extra=(-H "mcp-session-id: ${sid}")
    curl -s -o /dev/null --max-time 30 -X POST "$url" \
        -H 'content-type: application/json' \
        -H 'accept: application/json, text/event-stream' \
        -H "mcp-protocol-version: ${MCP_PROTOCOL}" \
        -H "authorization: Bearer ${tok}" \
        "${extra[@]}" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\"}"
}

# Run the MCP handshake once per shell process. Args: <name>. Subsequent calls
# are no-ops, so every public function can call it without counting round trips.
_AISTACK_MCP_INITED=""
_aiStackMcpInit() {
    local name="$1"
    case " ${_AISTACK_MCP_INITED} " in *" ${name} "*) return 0 ;; esac
    rm -f "$(_aiStackMcpDir "$name")/.session"
    _aiStackMcpRpc "$name" initialize \
        "{\"protocolVersion\":\"${MCP_PROTOCOL}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"MyAiStack\",\"version\":\"1\"}}" \
        >/dev/null || return 1
    _aiStackMcpNotify "$name" notifications/initialized
    _AISTACK_MCP_INITED="${_AISTACK_MCP_INITED} ${name}"
}

# ---------- add ---------------------------------------------------------------
# Register MyAiStack as an OAuth client of a remote MCP server and record how to
# reach it. Args: <name> --url <mcp-url>. Follows the 401 challenge to the
# resource metadata, then to the authorization server that actually offers
# registration, then does RFC 7591 dynamic client registration. Asks which
# installed coding agents should get this connector; writes no tokens (that is
# aistackMcpLogin) and no tool shims (that is aistackMcpBuild).
# Discover a server's OAuth configuration and register as a client. Args:
# <name> <url> <target-dir>. Writes <target-dir>/server.json on success and
# touches nothing else, so a caller can point this at a scratch directory and
# keep the previous registration until it is known to have worked.
_aiStackMcpRegister() {
    local name="$1" url="$2" dir="$3" hdr rm_url meta reg
    info "Registering ${name} → ${url}"

    # 1. the challenge: an MCP server tells us where its resource metadata lives
    hdr=$(curl -s -D - -o /dev/null --max-time 20 -X POST "$url" \
        -H 'content-type: application/json' \
        -H 'accept: application/json, text/event-stream' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"${MCP_PROTOCOL}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"MyAiStack\",\"version\":\"1\"}}}") \
        || { fail "Could not reach ${url}."; return 1; }
    rm_url=$(printf '%s' "$hdr" | sed -n 's/.*resource_metadata="\([^"]*\)".*/\1/p' | tr -d '\r' | head -1)
    if [ -z "$rm_url" ]; then
        fail "No resource_metadata in the WWW-Authenticate header."
        warn "Either this is not an OAuth-protected MCP server, or it needs no auth at all."
        return 1
    fi
    ok "Resource metadata: ${rm_url}"

    # 2. resource → authorization server. RFC 8414 inserts the issuer's path
    #    BETWEEN /.well-known/... and the host, which is easy to get wrong: the
    #    root well-known often exists too and advertises NO registration_endpoint.
    meta=$(python3 - "$rm_url" <<'PY'
import json, sys, urllib.parse, urllib.request
pr = json.load(urllib.request.urlopen(sys.argv[1], timeout=20))
iss = pr["authorization_servers"][0]
u = urllib.parse.urlparse(iss); path = u.path.rstrip("/")
cands = [f"{u.scheme}://{u.netloc}/.well-known/oauth-authorization-server{path}",
         f"{u.scheme}://{u.netloc}/.well-known/openid-configuration{path}",
         f"{u.scheme}://{u.netloc}{path}/.well-known/oauth-authorization-server",
         f"{u.scheme}://{u.netloc}/.well-known/oauth-authorization-server"]
best = None
for c in cands:
    try: d = json.load(urllib.request.urlopen(c, timeout=20))
    except Exception: continue
    if "registration_endpoint" in d:            # the one we can actually register against
        d["_resource"] = pr["resource"]; d["_scopes"] = pr.get("scopes_supported", [])
        print(json.dumps(d)); sys.exit(0)
    best = best or d
sys.exit("no authorization server offering dynamic client registration was found"
         + (f" (nearest: {best.get('issuer')})" if best else ""))
PY
) || { fail "Discovery failed: no registration endpoint for ${url}."; return 1; }
    ok "Authorization server: $(printf '%s' "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin)["issuer"])')"

    # 3. dynamic client registration. Servers implementing the MCP profile are
    #    strict here: a loopback IP (not "localhost"), both grant types, and no
    #    extra keys — unknown properties are rejected without saying which.
    reg=$(printf '%s' "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin)["registration_endpoint"])')
    mkdir -p "$dir"
    info "Registering as a public native client (callback 127.0.0.1:${MCP_CALLBACK_PORT})..."
    curl -s --max-time 25 -X POST "$reg" -H 'content-type: application/json' -d "{
        \"client_name\": \"MyAiStack\",
        \"application_type\": \"native\",
        \"redirect_uris\": [\"http://127.0.0.1:${MCP_CALLBACK_PORT}/callback\"],
        \"grant_types\": [\"authorization_code\", \"refresh_token\"],
        \"response_types\": [\"code\"],
        \"token_endpoint_auth_method\": \"none\"
      }" > "$dir/.reg.json"
    if ! grep -q '"client_id"' "$dir/.reg.json" 2>/dev/null; then
        fail "Registration refused: $(head -c 300 "$dir/.reg.json")"
        rm -f "$dir/.reg.json"; rmdir "$dir" 2>/dev/null
        return 1
    fi

    # 4. one document describing the connector
    python3 - "$dir" "$name" "$url" "$meta" <<'PY'
import json, sys, datetime
d, name, url, meta = sys.argv[1:5]
m = json.loads(meta); r = json.load(open(f"{d}/.reg.json"))
json.dump({
    "name": name, "url": url, "resource": m["_resource"], "issuer": m["issuer"],
    "authorization_endpoint": m["authorization_endpoint"],
    "token_endpoint": m["token_endpoint"], "registration_endpoint": m["registration_endpoint"],
    "client_id": r["client_id"], "redirect_uri": r["redirect_uris"][0],
    "scopes": r.get("scope", " ".join(m["_scopes"])).split(),
    "agents": {},
    "added": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(f"{d}/server.json", "w"), indent=2)
PY
    rm -f "$dir/.reg.json"

    return 0
}

aistackMcpAdd() {
    if [ $# -lt 3 ] || [ "$2" != "--url" ]; then
        aiStackUsage "aistackMcpAdd <name> --url <mcp-url>" \
            "name    : [a-z][a-z0-9-]* — becomes /mcp-<name> in Pi and the tool prefix" \
            "url     : the server's MCP endpoint" \
            "example : aistackMcpAdd aidlab --url https://my.aidlab.com/mcp"
        return 2
    fi
    local name="$1" url="$3" dir backup=""
    case "$name" in
        [a-z]*) case "$name" in *[!a-z0-9-]*) fail "name must match [a-z][a-z0-9-]* — got '${name}'."; return 1 ;; esac ;;
        *) fail "name must start with a lowercase letter — got '${name}'."; return 1 ;;
    esac
    dir=$(_aiStackMcpDir "$name")

    if [ -f "$dir/server.json" ]; then
        ok "Connector '${name}' is already registered as $(_aiStackMcpField "$name" client_id)."
        warn "Re-registering asks the provider for a NEW client and deletes the stored"
        warn "tokens, so you would sign in again with: aistackMcpLogin ${name}"
        warn "To refresh only its tools and agent plugins, keeping the login, run:"
        warn "  aistackMcpBuild ${name}"
        ask_def "Remove '${name}' and register it again?" "y" || { ok "Kept as it is."; return 0; }
        # Move the old one aside rather than deleting it. Registration reaches
        # the network and can fail for reasons that have nothing to do with the
        # user; losing a working login to a timeout would be indefensible.
        _aiStackMcpActivate "$name" "" off
        backup="${dir}.replacing.$$"
        mv "$dir" "$backup" || { fail "Could not move ${dir} aside."; return 1; }
        ok "Previous registration held aside until the new one succeeds."
    fi

    mkdir -p "$dir"
    if ! _aiStackMcpRegister "$name" "$url" "$dir"; then
        rm -rf "$dir"
        if [ -n "$backup" ]; then
            mv "$backup" "$dir"
            _aiStackMcpActivate "$name" "" on
            warn "Registration failed — '${name}' has been restored exactly as it was."
        fi
        return 1
    fi
    [ -n "$backup" ] && rm -rf "$backup"
    ok "Registered — client_id $(_aiStackMcpField "$name" client_id)"
    ok "Scopes: $(_aiStackMcpField "$name" scopes)"

    # 5. which installed agents should see this connector? Agents that are not
    #    installed are not offered — a question with one answer is not a question.
    _aiStackMcpAskAgents "$name"

    # Registration on its own does nothing useful: the connector cannot list a
    # single tool until someone signs in. Offer the next step rather than
    # printing it, but only where an answer can actually be given — a script
    # must never have a browser opened underneath it.
    if _aiStackMcpInteractive && ask_def "Sign in to '${name}' now?" "y"; then
        aistackMcpLogin "$name"
    else
        warn "Next:  aistackMcpLogin ${name}"
    fi
}

# Ask, for each installed coding agent, whether this connector should be wired
# into it, and record the answers in server.json. Args: <name>.
# Claude Code is offered but flagged: it speaks MCP natively and does its own
# OAuth, so it does not share the common core the other two run through.
_aiStackMcpAskAgents() {
    local name="$1" dir any=0 pi=false oc=false cl=false
    dir=$(_aiStackMcpDir "$name")
    if command -v pi >/dev/null 2>&1; then
        any=1
        ask_def "Generate a Pi extension for '${name}'?" "y" && pi=true
    fi
    if command -v opencode >/dev/null 2>&1; then
        any=1
        ask_def "Generate OpenCode tools for '${name}'?" "y" && oc=true
    fi
    if command -v claude >/dev/null 2>&1; then
        any=1
        warn "Claude Code speaks MCP natively — it would use its own OAuth, not this connector's tokens."
        ask_def "Register '${name}' with Claude Code as well (claude mcp add)?" "n" && cl=true
    fi
    [ "$any" = "0" ] && warn "No coding agent installed — the connector still works from the shell."
    python3 - "$dir/server.json" "$pi" "$oc" "$cl" <<'PY'
import json, sys
f = sys.argv[1]; d = json.load(open(f))
d["agents"] = {"Pi": sys.argv[2] == "true", "OpenCode": sys.argv[3] == "true", "Claude": sys.argv[4] == "true"}
json.dump(d, open(f, "w"), indent=2)
PY
    [ "$cl" = "true" ] && {
        info "Registering with Claude Code..."
        claude mcp add --transport http "$name" "$(_aiStackMcpField "$name" url)" >/dev/null 2>&1 \
            && ok "Claude Code: added. Authorise it inside Claude with /mcp." \
            || warn "claude mcp add failed — run it by hand: claude mcp add --transport http ${name} $(_aiStackMcpField "$name" url)"
    }
    return 0
}

# ---------- login -------------------------------------------------------------
# Sign in to a connector and store its tokens. Args: <name>.
# Opens the provider's consent page in a browser, catches the redirect on
# 127.0.0.1:<port>/callback with a one-shot local server, and exchanges the code
# for tokens using PKCE (S256). The callback port is fixed because it is baked
# into the client registration — a different port would not be accepted.
aistackMcpLogin() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackMcpLogin <name>" \
            "example : aistackMcpLogin $(_aiStackMcpFirstName || echo aidlab)"
        return 2
    fi
    local name="$1" dir
    _aiStackMcpRequire "$name" || return 1
    dir=$(_aiStackMcpDir "$name")

    if lsof -nP -iTCP:"${MCP_CALLBACK_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
        fail "Port ${MCP_CALLBACK_PORT} is busy — the registered callback needs exactly this port:"
        lsof -nP -iTCP:"${MCP_CALLBACK_PORT}" -sTCP:LISTEN >&2
        return 1
    fi

    info "aistackMcpLogin — ${name}: opening your browser, listening on 127.0.0.1:${MCP_CALLBACK_PORT}"
    python3 - "$dir" <<'PY' || return 1
import base64, hashlib, json, os, platform, secrets, shutil, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

d = sys.argv[1]
s = json.load(open(f"{d}/server.json"))
b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
verifier = b64(secrets.token_bytes(32))
challenge = b64(hashlib.sha256(verifier.encode()).digest())
state = secrets.token_hex(16)
port = int(urllib.parse.urlparse(s["redirect_uri"]).port or 49999)

url = s["authorization_endpoint"] + "?" + urllib.parse.urlencode({
    "response_type": "code", "client_id": s["client_id"],
    "redirect_uri": s["redirect_uri"], "scope": " ".join(s["scopes"]),
    "code_challenge": challenge, "code_challenge_method": "S256",
    "state": state, "resource": s["resource"]})

got = {}
PAGE = ("<!doctype html><meta charset=utf-8><title>MyAiStack</title>"
        "<body style='font:16px system-ui;padding:3rem;max-width:34rem'>"
        "<h2>{h}</h2><p>{p}</p></body>")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        good = (u.path == "/callback" and q.get("state") == state and "code" in q
                and q.get("iss", s["issuer"]) == s["issuer"])
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8"); self.end_headers()
        if good:
            got.update(q)
            self.wfile.write(PAGE.format(h="Signed in.", p="You can close this tab and return to the terminal.").encode())
        else:
            got["error"] = q.get("error_description") or q.get("error") or "state or issuer mismatch"
            self.wfile.write(PAGE.format(h="Sign-in rejected.", p=got["error"]).encode())

try:
    srv = HTTPServer(("127.0.0.1", port), H)
except OSError as e:
    sys.exit(f"cannot listen on 127.0.0.1:{port}: {e}")

opener = "open" if platform.system() == "Darwin" else "xdg-open"
if shutil.which(opener):
    subprocess.Popen([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"    Browser opened. If nothing appeared, visit:\n    {url}", file=sys.stderr)
else:
    print(f"    Open this URL to authorise:\n    {url}", file=sys.stderr)

srv.timeout = 300
srv.handle_request()                       # exactly one request, five-minute limit
if "code" not in got:
    sys.exit(got.get("error", "no callback received within 5 minutes"))

body = urllib.parse.urlencode({
    "grant_type": "authorization_code", "code": got["code"],
    "redirect_uri": s["redirect_uri"], "client_id": s["client_id"],
    "code_verifier": verifier, "resource": s["resource"]}).encode()
req = urllib.request.Request(s["token_endpoint"], data=body, headers={
    "content-type": "application/x-www-form-urlencoded", "accept": "application/json"})
try:
    t = json.load(urllib.request.urlopen(req, timeout=25))
except urllib.error.HTTPError as e:
    sys.exit(f"token endpoint rejected the code ({e.code}): {e.read().decode()[:300]}")

t["expires_at"] = int(time.time()) + int(t.get("expires_in", 3600)) - 30
t["obtained"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
tmp = f"{d}/tokens.json.tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f: json.dump(t, f, indent=2)
os.replace(tmp, f"{d}/tokens.json")
mins = int(t.get("expires_in", 3600)) // 60
print(f"    token valid {mins} min · refresh token "
      f"{'stored' if t.get('refresh_token') else 'NOT RETURNED — you will have to sign in again'}", file=sys.stderr)
PY
    ok "Signed in to ${name}."
    aistackMcpBuild "$name"
}

# ---------- tools -------------------------------------------------------------
# Build a connector's tool surface. Args: <name>.
# Runs the MCP handshake, calls tools/list, writes tools.json (schemas, for the
# agent shims and argument checking) and tools.txt (name + summary, for tab
# completion — no JSON parsing on the completion path), then generates the
# plugin for each agent chosen at add time. Re-run it whenever the server's
# tools change: it is idempotent, and the shims always match what is cached.
aistackMcpBuild() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackMcpBuild <name>" \
            "builds  : tools.json + tools.txt, then the Pi / OpenCode plugins" \
            "example : aistackMcpBuild $(_aiStackMcpFirstName || echo aidlab)"
        return 2
    fi
    local name="$1" dir n
    _aiStackMcpRequire "$name" || return 1
    dir=$(_aiStackMcpDir "$name")

    info "aistackMcpBuild — discovering tools and building agent plugins for ${name}"
    _aiStackMcpInit "$name" || return 1
    _aiStackMcpRpc "$name" tools/list '{}' > "$dir/.tools.raw" || { rm -f "$dir/.tools.raw"; return 1; }

    n=$(python3 - "$dir" <<'PY'
import json, sys, time
d = sys.argv[1]
r = json.load(open(f"{d}/.tools.raw"))
tools = r.get("tools", [])
json.dump({"fetched": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "tools": tools},
          open(f"{d}/tools.json", "w"), indent=2)
with open(f"{d}/tools.txt", "w") as f:                     # name<TAB>summary, for completion
    for t in tools:
        summary = (t.get("description") or "").strip().splitlines()
        f.write(f"{t['name']}\t{summary[0] if summary else ''}\n")
print(len(tools))
PY
) || return 1
    rm -f "$dir/.tools.raw"
    ok "${name}: ${n} tools cached."
    [ -n "${AI_STACK_QUIET:-}" ] || cut -f1 "$dir/tools.txt" | sed 's/^/      /' >&2
    _aiStackMcpRender "$name"
}

# List a connector's tools, or one tool's parameters. Args: <name> [tool].
# With a tool name this is the parameter hint bash completion cannot show:
# type, required-ness and description per argument.
aistackMcpTools() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackMcpTools <name> [tool]" \
            "example : aistackMcpTools $(_aiStackMcpFirstName || echo aidlab)" \
            "example : aistackMcpTools $(_aiStackMcpFirstName || echo aidlab) $(_aiStackMcpFirstTool || echo aidlab_get_profile)"
        return 2
    fi
    local name="$1" tool="${2:-}" dir
    _aiStackMcpRequire "$name" || return 1
    dir=$(_aiStackMcpDir "$name")
    [ -f "$dir/tools.json" ] || { fail "No tools cached for '${name}' — run: aistackMcpBuild ${name}"; return 1; }
    python3 - "$dir/tools.json" "$tool" <<'PY'
import json, sys
tools = json.load(open(sys.argv[1]))["tools"]; want = sys.argv[2]
if not want:
    for t in tools:
        d = (t.get("description") or "").strip().splitlines()
        print(f"{t['name']:<34} {d[0] if d else ''}")
    sys.exit(0)
t = next((t for t in tools if t["name"] == want), None)
if not t:
    print(f"No tool '{want}'. Available:", file=sys.stderr)
    for x in tools: print(f"  {x['name']}", file=sys.stderr)
    sys.exit(1)
desc = (t.get("description") or "").strip()
print(f"{t['name']} — {desc}" if desc else t["name"])
s = t.get("inputSchema") or {}
props = s.get("properties") or {}; req = s.get("required") or []
if not props:
    print("  (no parameters)"); sys.exit(0)
for k in sorted(props, key=lambda k: (k not in req, k)):
    p = props[k]
    ty = p.get("type") or ("enum" if "enum" in p else "any")
    if "enum" in p: ty = "|".join(str(e) for e in p["enum"])
    print(f"  {k:<12} {ty:<22} {'required' if k in req else 'optional':<9} {(p.get('description') or '').strip()}")
PY
}

# Print the first tool of the first connector, for usage examples. Empty when
# nothing has been discovered yet.
_aiStackMcpFirstTool() {
    local n f; n=$(_aiStackMcpFirstName) || return 1
    [ -n "$n" ] || return 1
    f="$(_aiStackMcpDir "$n")/tools.txt"
    [ -f "$f" ] && cut -f1 "$f" | head -1
}

# ---------- call: the common core ---------------------------------------------
# Turn key=value arguments into a JSON object typed by the tool's own schema.
# Args: <name> <tool> [key=value ... | '{json}']. A single argument starting
# with { is taken as the object itself. Unknown keys and missing required ones
# are refused here rather than by the server, so the fix is named locally.
_aiStackMcpArgs() {
    local name="$1" tool="$2"; shift 2
    python3 - "$(_aiStackMcpDir "$name")/tools.json" "$tool" "$name" "$@" <<'PY'
import json, sys
tools = json.load(open(sys.argv[1]))["tools"]; want = sys.argv[2]; conn = sys.argv[3]; rest = sys.argv[4:]
t = next((t for t in tools if t["name"] == want), None)
if not t:
    names = ", ".join(x["name"] for x in tools)
    sys.exit(f"no tool '{want}' on '{conn}'. Available: {names}")
schema = t.get("inputSchema") or {}
props = schema.get("properties") or {}; req = schema.get("required") or []

if len(rest) == 1 and rest[0].lstrip().startswith("{"):
    try: args = json.loads(rest[0])
    except ValueError as e: sys.exit(f"argument is not valid JSON: {e}")
else:
    args = {}
    for item in rest:
        if "=" not in item:
            sys.exit(f"'{item}' is not key=value (or a single JSON object)")
        k, v = item.split("=", 1)
        if k in args:
            sys.exit(f"'{k}' given twice — a repeated key would silently take the last value")
        if k not in props:
            sys.exit(f"'{want}' has no parameter '{k}' — try: aistackMcpTools {conn} {want}")
        ty = (props[k] or {}).get("type")
        if ty in ("integer", "number"):
            try: args[k] = int(v) if ty == "integer" else float(v)
            except ValueError: sys.exit(f"'{k}' must be a {ty} — got '{v}'")
        elif ty == "boolean":
            if v.lower() not in ("true", "false"): sys.exit(f"'{k}' must be true or false — got '{v}'")
            args[k] = v.lower() == "true"
        elif ty == "array":
            args[k] = [x for x in v.split(",") if x]
        else:
            args[k] = v

missing = [k for k in req if k not in args]
if missing:
    sys.exit(f"'{want}' requires {', '.join(missing)} — see: aistackMcpTools {conn} {want}")
json.dump(args, sys.stdout)
PY
}

# Call one tool on a connector and print its text result. Args:
# <name> <tool> [key=value ... | '{json}']. Exits 1 with the server's message on
# stderr when the tool reports an error. This is the shared execution path: the
# generated Pi extension and OpenCode tools both run exactly this, so what you
# type here is what an agent runs.
aistackMcpCall() {
    if [ $# -lt 2 ]; then
        # one argument per line: aiStackUsage indents each argument it is given,
        # so a single multi-line string would align only its first line
        local -a _ex=() _l
        while IFS= read -r _l; do _ex+=("$_l"); done < <(_aiStackMcpCallExamples)
        aiStackUsage "aistackMcpCall <name> <tool> [key=value ... | '{json}']" "${_ex[@]}"
        return 2
    fi
    local name="$1" tool="$2"; shift 2
    _aiStackMcpRequire "$name" || return 1
    local dir; dir=$(_aiStackMcpDir "$name")
    [ -f "$dir/tools.json" ] || { fail "No tools cached for '${name}' — run: aistackMcpBuild ${name}"; return 1; }
    local args; args=$(_aiStackMcpArgs "$name" "$tool" "$@") || return 1
    _aiStackMcpInit "$name" || return 1
    _aiStackMcpRpc "$name" tools/call "{\"name\":\"${tool}\",\"arguments\":${args}}" | python3 -c '
import json, sys
try: r = json.load(sys.stdin)
except ValueError: sys.exit("no result from the server")
text = "\n".join(c.get("text", "") for c in r.get("content", []) if c.get("type") == "text")
if not text: text = json.dumps(r, indent=2)
print(text, file=sys.stderr if r.get("isError") else sys.stdout)
sys.exit(1 if r.get("isError") else 0)'
}

# Build the example lines for aistackMcpCall usage from what is actually
# installed: a real connector, a real tool, and that tool's required parameters.
# Falls back to the command that creates the first connector.
_aiStackMcpCallExamples() {
    local n t
    n=$(_aiStackMcpFirstName)
    if [ -z "$n" ]; then
        echo "No connectors yet. Add one, then sign in:"
        echo "  aistackMcpAdd aidlab --url https://my.aidlab.com/mcp"
        echo "  aistackMcpLogin aidlab"
        return 0
    fi
    t=$(_aiStackMcpFirstTool)
    if [ -z "$t" ]; then
        echo "'${n}' has no tools cached yet:"
        echo "  aistackMcpBuild ${n}"
        return 0
    fi
    python3 - "$(_aiStackMcpDir "$n")/tools.json" "$n" <<'PY'
import json, sys
tools = json.load(open(sys.argv[1]))["tools"]; name = sys.argv[2]
shown = 0
for t in tools:
    s = t.get("inputSchema") or {}
    req = s.get("required") or []; props = s.get("properties") or {}
    ex = []
    for k in req:
        p = props.get(k) or {}
        ty = p.get("type")
        blurb = (p.get("description", "") + " " + k).lower()
        if "date" in blurb or "time" in blurb:
            # ISO 8601 *datetime*: servers that say "ISO 8601" usually reject a
            # bare date, and an example that fails is worse than none
            ex.append(f"{k}=2026-09-01T00:00:00Z")
        elif ty in ("integer", "number"): ex.append(f"{k}=10")
        elif ty == "boolean":             ex.append(f"{k}=true")
        else:                             ex.append(f"{k}=value")
    print(f"example : aistackMcpCall {name} {t['name']}" + (" " + " ".join(ex) if ex else ""))
    shown += 1
    if shown == 3: break
print(f"tools   : aistackMcpTools {name}")
PY
}

# ---------- lifecycle ---------------------------------------------------------
# Show every connector: endpoint, token state, cached tools, and which agents
# are wired to it. Args: none. This is the status command — run it first when
# something is not behaving.
aistackMcpList() {
    local names n
    names=$(_aiStackMcpNames)
    if [ -z "$names" ]; then
        warn "No MCP connectors yet."
        echo "  Add one:  aistackMcpAdd aidlab --url https://my.aidlab.com/mcp" >&2
        return 0
    fi
    printf '\n%-12s %-34s %-22s %-7s %s\n' "CONNECTOR" "URL" "TOKEN" "TOOLS" "AGENTS" >&2
    printf '%-12s %-34s %-22s %-7s %s\n' "---------" "---" "-----" "-----" "------" >&2
    for n in $names; do
        python3 - "$(_aiStackMcpDir "$n")" "$n" "$HOME" <<'PY'
import json, os, time, sys
d, name, home = sys.argv[1], sys.argv[2], sys.argv[3]
s = json.load(open(f"{d}/server.json"))
try:
    t = json.load(open(f"{d}/tokens.json")); left = t.get("expires_at", 0) - int(time.time())
    tok = f"valid {left//60} min" if left > 0 else ("expired, will refresh" if t.get("refresh_token") else "expired, sign in")
except FileNotFoundError:
    tok = "not signed in"
try: n = len(json.load(open(f"{d}/tools.json"))["tools"])
except FileNotFoundError: n = 0
wired = []
for agent, on in (s.get("agents") or {}).items():
    if not on: continue
    if agent == "Pi":
        try: live = f"{d}/pi-extension.ts" in json.load(open(f"{home}/.pi/agent/settings.json")).get("extensions", [])
        except Exception: live = False
        wired.append("Pi*" if live else "Pi")
    elif agent == "OpenCode":
        td = f"{home}/.config/opencode/tools"
        live = os.path.isdir(td) and any(os.path.islink(f"{td}/{f}") and os.path.realpath(f"{td}/{f}").startswith(d)
                                         for f in os.listdir(td))
        wired.append("OpenCode*" if live else "OpenCode")
    else:
        wired.append(agent)
url = s["url"]
print(f"{name:<12} {url[:34]:<34} {tok:<22} {n:<7} {' '.join(wired) or '-'}")
PY
    done >&2
    echo "  * = active now (Pi: in settings.json · OpenCode: symlinked). Pi can also be attached per launch." >&2
}

# Force a token refresh without waiting for expiry. Args: <name>.
# Rarely needed — every call refreshes on demand — but useful to prove the
# refresh token still works after a long gap.
aistackMcpRefresh() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackMcpRefresh <name>" "example : aistackMcpRefresh $(_aiStackMcpFirstName || echo aidlab)"
        return 2
    fi
    _aiStackMcpRequire "$1" || return 1
    _aiStackMcpRefresh "$1" && ok "$1: token refreshed."
}

# Forget a connector's tokens, keeping its registration and tools. Args: <name>.
# The provider is not told: most MCP servers advertise no revocation endpoint,
# so the refresh token stays valid upstream until it expires on its own.
aistackMcpLogout() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackMcpLogout <name>" "example : aistackMcpLogout $(_aiStackMcpFirstName || echo aidlab)"
        return 2
    fi
    local name="$1" dir
    _aiStackMcpRequire "$name" || return 1
    dir=$(_aiStackMcpDir "$name")
    [ -f "$dir/tokens.json" ] || { ok "${name}: already signed out."; return 0; }
    rm -f "$dir/tokens.json" "$dir/.session"
    ok "${name}: tokens deleted locally."
    warn "This does not revoke access upstream — revoke it in your ${name} account if that matters."
}

# ---------- generated agent shims ---------------------------------------------
# Absolute path to this script, so a generated shim can source it regardless of
# where the agent's working directory happens to be.
_aiStackMcpSelf() {
    local s="${BASH_SOURCE[0]:-$0}"
    ( cd "$(dirname "$s")" && printf '%s/%s' "$(pwd)" "$(basename "$s")" )
}

# Regenerate every agent shim a connector asked for. Args: <name>.
# Called at the end of aistackMcpBuild, so plugins always match the tools the
# server actually offers — never a stale schema.
_aiStackMcpRender() {
    local name="$1" dir agents
    dir=$(_aiStackMcpDir "$name")
    [ -f "$dir/tools.json" ] || return 0
    agents=$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("agents",{}); print(" ".join(k for k,v in a.items() if v))' "$dir/server.json")
    case " $agents " in *" Pi "*)       _aiStackMcpRenderPi "$name" ;; esac
    case " $agents " in *" OpenCode "*) _aiStackMcpRenderOpenCode "$name" ;; esac
    return 0
}

# Write the Pi extension for a connector. Args: <name>.
# The extension holds no HTTP code: each tool's execute() shells out to
# aistackMcpCall, so Pi runs the identical path you can run by hand.
_aiStackMcpRenderPi() {
    local name="$1" dir label self
    dir=$(_aiStackMcpDir "$name")
    label=$(python3 -c 'import sys;print(sys.argv[1][:1].upper()+sys.argv[1][1:])' "$name")
    self=$(_aiStackMcpSelf)
    cat > "$dir/pi-extension.ts" <<PIEOF
// GENERATED by aistackMcpBuild — do not edit; change the template in mcp.sh.
// Connector: ${name}   Regenerated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
//
// Holds no HTTP code. Every tool call runs the same shell function you can run
// yourself:  aistackMcpCall ${name} <tool> '<json>'
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync } from "node:fs";
import { execFile } from "node:child_process";

const NAME = "${name}", LABEL = "${label}", DIR = "${dir}", MCP_SH = "${self}";
type McpTool = { name: string; description?: string; inputSchema?: Record<string, unknown> };

function call(tool: string, args: unknown, signal?: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile("bash",
      ["-c", '. "\$0" && aistackMcpCall "\$1" "\$2" "\$3"', MCP_SH, NAME, tool, JSON.stringify(args ?? {})],
      { signal, maxBuffer: 8 * 1024 * 1024, env: { ...process.env, AI_STACK_QUIET: "1" } },
      (err, stdout, stderr) => err ? reject(new Error(String(stderr).trim() || err.message)) : resolve(stdout));
  });
}

export default function (pi: ExtensionAPI) {
  const registered = new Set<string>();
  const TODAY = new Date().toISOString().slice(0, 10);

  /** True when a tool takes a date-like parameter, and so must be told the date. */
  /**
   * Strip what a model cannot use from a JSON Schema before it becomes a tool
   * definition. Aidlab attaches a 293-character leap-year regex to every date
   * field, twelve times over: 48% of the whole tool payload, in a form no model
   * can follow. The server still validates, and the required format is stated in
   * prose in the description, so nothing is lost but tokens.
   */
  /**
   * Widen a range the model collapsed to a point. Asked for "today" a model
   * will often send the same timestamp as both bounds, which is a zero-length
   * window and returns nothing — observed on every one of seven tools in a row,
   * after which the model invented a summary from the empty results.
   */
  function repairRange(args: Record<string, any>): Record<string, any> {
    const a = { ...args };
    const s = a.start_date, e = a.end_date;
    if (typeof s === "string" && typeof e === "string" && s >= e) {
      const day = s.slice(0, 10);
      a.start_date = day + "T00:00:00Z";
      a.end_date = day + "T23:59:59Z";
    }
    return a;
  }

  /**
   * Say what an empty result means. {"data":[]} reads as "you have no data",
   * which is a different claim from "nothing was recorded in the window you
   * asked about" — and the model cannot tell them apart without being told.
   */
  /**
   * Summarise a long result before the model ever sees it. One page of HRV is
   * 200 records and about 3100 tokens; five such calls fill a 32K window and the
   * session dies mid-conversation. The statistics here are computed, so the
   * model reports arithmetic it did not have to do — the same rule the rest of
   * this toolkit follows: measured, never estimated.
   */
  const KEEP = 5;
  function r1(n: number): number { return Math.round(n * 10) / 10; }
  function reduceResult(text: string): string {
    let d: any;
    try { d = JSON.parse(text); } catch { return text; }
    const arr = d && d.data;
    if (!Array.isArray(arr) || arr.length <= KEEP) return text;
    const nums: number[] = [];
    for (const x of arr) { if (x && typeof x.value === "number") nums.push(x.value); }
    const out: any = { records: arr.length };
    if (nums.length) {
      let sum = 0, lo = nums[0], hi = nums[0];
      for (const v of nums) { sum += v; if (v < lo) lo = v; if (v > hi) hi = v; }
      out.value_summary = { n: nums.length, mean: r1(sum / nums.length), min: r1(lo), max: r1(hi) };
    }
    const secs: Record<string, number> = {};
    for (const x of arr) {
      if (x && typeof x.duration_seconds === "number") {
        const k = String(x.type || "total");
        secs[k] = (secs[k] || 0) + x.duration_seconds;
      }
    }
    if (Object.keys(secs).length) {
      const mins: Record<string, number> = {};
      for (const k of Object.keys(secs)) mins[k] = Math.round(secs[k] / 60);
      out.minutes_by_type = mins;
    }
    out.first = arr.slice(0, KEEP);
    out.range = { from: arr[arr.length - 1] && (arr[arr.length - 1].date || arr[arr.length - 1].start_date),
                  to: arr[0] && (arr[0].date || arr[0].start_date) };
    if (d.has_more) out.more_pages_existed = true;
    return JSON.stringify(out) +
      "\n\nNOTE: " + arr.length + " records were summarised by MyAiStack so they fit the " +
      "context. The statistics above are computed exactly; use them as given and do not " +
      "recompute or estimate. Do not request this same range again.";
  }

  function annotate(text: string, args: Record<string, any>): string {
    if (!/"data"\s*:\s*\[\s*\]/.test(text)) return text;
    var range = "";
    if (args.start_date && args.end_date) {
      range = " for " + args.start_date + " to " + args.end_date;
    }
    return text + "\n\nNOTE: no records were returned" + range +
      ". Nothing was recorded in that window; this does NOT mean the account has no data. " +
      "Do not summarise or estimate values from an empty result. Say plainly that nothing " +
      "was recorded for that period, and stop. Do not retry the same tool.";
  }

  function slim(schema: Record<string, unknown> | undefined): Record<string, unknown> {
    const s = JSON.parse(JSON.stringify(schema ?? { type: "object", properties: {} }));
    delete s.\$schema;
    for (const v of Object.values((s.properties ?? {}) as Record<string, any>)) {
      delete v.pattern;
      delete v.\$schema;
      if (typeof v.description === "string" && v.description.length > 200) {
        v.description = v.description.slice(0, 200) + "…";
      }
    }
    return s;
  }

  function hasDates(t: McpTool): boolean {
    const props = ((t.inputSchema ?? {}) as any).properties ?? {};
    return Object.keys(props).some((k) => /date|time|start|end|since|until/i.test(k));
  }

  function register(tools: McpTool[]): number {
    let n = 0;
    for (const t of tools) {
      if (registered.has(t.name)) continue;
      registered.add(t.name); n++;
      pi.registerTool({
        name: t.name,
        label: \`\${LABEL}: \${t.name}\`,
          // The model has no clock. Left to itself it invents a plausible date —
          // observed asking for 2023-04-01 against data recorded in 2026, which
          // returns an empty set that reads as "no data" rather than "wrong year".
          // TODAY is computed when tools register, so it is always the real one.
          description: hasDates(t)
            ? \`\${t.description ?? t.name}

Today is \${TODAY}. Unless the user names a period, use a recent range ending now. start_date must be strictly BEFORE end_date — for a single day use T00:00:00Z to T23:59:59Z, never the same timestamp twice. Timestamps must be full ISO 8601 with a Z suffix, for example \${TODAY}T00:00:00Z — a bare date is rejected.\`
            : (t.description ?? t.name),
        promptSnippet: \`\${t.name} — \${LABEL} data over MCP\`,
          promptGuidelines: [
            \`Today is \${TODAY}. \${LABEL} tools need ISO 8601 timestamps with a Z suffix, never a bare date.\`,
            \`For totals or averages prefer a single summary call over several raw-sample calls.\`,
          ],
          parameters: Type.Unsafe<Record<string, unknown>>(slim(t.inputSchema)),
        executionMode: "sequential",
        async execute(_id, params, signal, _onUpdate, ctx: ExtensionContext) {
          ctx.ui.setStatus(\`mcp-\${NAME}\`, \`\${LABEL}: \${t.name}…\`);
          try {
            const fixed = repairRange(params as Record<string, any>);
            const raw = await call(t.name, fixed, signal);
            return { content: [{ type: "text", text: annotate(reduceResult(raw), fixed) }],
                     details: { server: NAME, tool: t.name } };
          } finally { ctx.ui.setStatus(\`mcp-\${NAME}\`, undefined); }
        },
      });
    }
    return n;
  }

  pi.on("session_start", async (_e, ctx) => {
    try {
      const { tools } = JSON.parse(readFileSync(\`\${DIR}/tools.json\`, "utf8")) as { tools: McpTool[] };
      ctx.ui.notify(\`\${LABEL}: \${register(tools)} MCP tools ready — /mcp-\${NAME} for status\`, "info");
    } catch (e: any) {
      ctx.ui.notify(\`\${LABEL}: \${e.message} — run: aistackMcpBuild \${NAME}\`, "warning");
    }
  });

  pi.registerCommand(\`mcp-\${NAME}\`, {
    description: \`\${LABEL} MCP connector: /mcp-\${NAME} [status|reload]\`,
    handler: async (args, ctx) => {
      if (args.trim() === "reload") {
        try {
          await new Promise<void>((res, rej) =>
            execFile("bash", ["-c", '. "\$0" && aistackMcpBuild "\$1"', MCP_SH, NAME], e => e ? rej(e) : res()));
          const { tools } = JSON.parse(readFileSync(\`\${DIR}/tools.json\`, "utf8"));
          ctx.ui.notify(\`\${LABEL}: \${register(tools)} new, \${tools.length} total\`, "info");
        } catch (e: any) { ctx.ui.notify(e.message, "error"); }
        return;
      }
      ctx.ui.notify(\`\${LABEL}: \${registered.size} tools · run "aistackMcpList" for token state\`, "info");
    },
  });
}
PIEOF
    _aiStackMcpCheckGenerated "$dir/pi-extension.ts" || return 1
    ok "Pi extension written: ${dir}/pi-extension.ts"
}

# Refuse to report a generated file as written when it cannot parse. Args: <file>.
# The extension is emitted from an unquoted heredoc so ${NAME} interpolates,
# which means an unescaped $ in the TypeScript is expanded by the shell instead:
# "delete s.$schema" became "delete s.;" and Pi failed to load the extension at
# startup, long after the build had reported success. These two checks are cheap
# and catch that whole class of damage at the moment it is written.
_aiStackMcpCheckGenerated() {
    local f="$1" bad=0
    # a backtick in the template is command substitution inside the unquoted
    # heredoc, so shell error text can land in the middle of the TypeScript
    if grep -qE 'command not found|No such file or directory' "$f"; then
        fail "Generated file contains shell error output — a backtick was executed:"
        grep -nE 'command not found|No such file or directory' "$f" | head -3 | sed 's/^/         /' >&2
        bad=1
    fi
    if grep -qE '\.[[:space:]]*;' "$f"; then
        fail "Generated file has an empty property access — a shell variable was expanded:"
        grep -nE '\.[[:space:]]*;' "$f" | head -3 | sed 's/^/         /' >&2
        bad=1
    fi
    python3 -c '
import sys
src = open(sys.argv[1]).read()
d = p = b = 0; inT = False
for i, c in enumerate(src):
    if c == chr(96) and (i == 0 or src[i-1] != chr(92)): inT = not inT
    if inT: continue
    d += c == "{"; d -= c == "}"
    p += c == "("; p -= c == ")"
    b += c == "["; b -= c == "]"
bad = [n for n, v in (("braces", d), ("parens", p), ("brackets", b)) if v]
if inT: bad.append("unclosed template literal")
if bad: sys.exit("unbalanced: " + ", ".join(bad))
' "$f" || bad=1
    [ "$bad" = "0" ] || { fail "Refusing to call ${f} written — it will not load."; return 1; }
    return 0
}

# Write one OpenCode tool file per MCP tool. Args: <name>.
# OpenCode derives the tool name from the FILENAME, so each file is named after
# its MCP tool and the model sees the original name unchanged.
_aiStackMcpRenderOpenCode() {
    local name="$1" dir self n
    dir=$(_aiStackMcpDir "$name")
    self=$(_aiStackMcpSelf)
    mkdir -p "$dir/opencode-tools"
    n=$(python3 - "$dir" "$name" "$self" <<'PY'
import json, os, sys
d, name, mcp_sh = sys.argv[1], sys.argv[2], sys.argv[3]
tools = json.load(open(f"{d}/tools.json"))["tools"]
out = f"{d}/opencode-tools"

def zod(p, required):
    """Map one JSON Schema property to a tool.schema (zod) expression."""
    t = p.get("type")
    if "enum" in p and all(isinstance(e, str) for e in p["enum"]):
        e = ", ".join(json.dumps(x) for x in p["enum"]); expr = f"tool.schema.enum([{e}])"
    elif t == "string":   expr = "tool.schema.string()"
    elif t == "integer":  expr = "tool.schema.number().int()"
    elif t == "number":   expr = "tool.schema.number()"
    elif t == "boolean":  expr = "tool.schema.boolean()"
    elif t == "array":
        it = (p.get("items") or {}).get("type")
        inner = {"string": "tool.schema.string()", "integer": "tool.schema.number().int()",
                 "number": "tool.schema.number()", "boolean": "tool.schema.boolean()"}.get(it, "tool.schema.any()")
        expr = f"tool.schema.array({inner})"
    else:                 expr = "tool.schema.any()"
    desc = (p.get("description") or "").strip()
    if desc: expr += f".describe({json.dumps(desc)})"
    if not required: expr += ".optional()"
    return expr

keep = set()
for t in tools:
    s = t.get("inputSchema") or {}
    props = s.get("properties") or {}; req = s.get("required") or []
    args = "\n".join(f"    {k}: {zod(props[k] or {}, k in req)}," for k in props) or "    // no parameters"
    body = f'''// GENERATED by aistackMcpBuild — do not edit; change the template in mcp.sh.
// Connector: {name}   Tool: {t["name"]}
import {{ tool }} from "@opencode-ai/plugin"

export default tool({{
  description: {json.dumps((t.get("description") or t["name"]).strip())},
  args: {{
{args}
  }},
  async execute(args) {{
    const r = await Bun.$`bash -c ${{'. "$0" && aistackMcpCall "$1" "$2" "$3"'}} ${{{json.dumps(mcp_sh)}}} ${{{json.dumps(name)}}} ${{{json.dumps(t["name"])}}} ${{JSON.stringify(args)}}`
      .env({{ ...process.env, AI_STACK_QUIET: "1" }}).quiet().nothrow()
    if (r.exitCode !== 0) throw new Error(r.stderr.toString().trim() || {json.dumps(t["name"] + " failed")})
    return r.stdout.toString()
  }},
}})
'''
    fn = f"{out}/{t['name']}.ts"; keep.add(os.path.basename(fn))
    open(fn, "w").write(body)

for f in os.listdir(out):                       # drop tools the server no longer offers
    if f.endswith(".ts") and f not in keep: os.remove(f"{out}/{f}")
print(len(tools))
PY
)
    ok "OpenCode tools written: ${n} files in ${dir}/opencode-tools/"
}

# ---------- activation --------------------------------------------------------
# Make a connector's tools visible to an agent for every launch. Args:
# <name> [Pi|OpenCode]. With no agent, every agent the connector was added for.
# Pi gains a path in settings.json; OpenCode gains symlinks in its tools dir,
# because it has no per-session mechanism.
aistackMcpEnable() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackMcpEnable <name> [Pi|OpenCode]" \
            "example : aistackMcpEnable $(_aiStackMcpFirstName || echo aidlab)" \
            "example : aistackMcpEnable $(_aiStackMcpFirstName || echo aidlab) OpenCode"
        return 2
    fi
    _aiStackMcpRequire "$1" || return 1
    _aiStackMcpActivate "$1" "${2:-}" on
}

# Hide a connector's tools from an agent again. Args: <name> [Pi|OpenCode].
# Removes only what this toolkit created — a hand-written file of the same name
# in OpenCode's tools directory is never touched.
aistackMcpDisable() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackMcpDisable <name> [Pi|OpenCode]" \
            "example : aistackMcpDisable $(_aiStackMcpFirstName || echo aidlab)"
        return 2
    fi
    _aiStackMcpRequire "$1" || return 1
    _aiStackMcpActivate "$1" "${2:-}" off
}

# Shared implementation of enable/disable. Args: <name> <agent|""> <on|off>.
_aiStackMcpActivate() {
    local name="$1" only="$2" mode="$3" dir agents f base t
    dir=$(_aiStackMcpDir "$name")
    agents=$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("agents",{}); print(" ".join(k for k,v in a.items() if v))' "$dir/server.json")
    [ -n "$only" ] && agents="$only"

    case " $agents " in *" Pi "*)
        if [ -f "$dir/pi-extension.ts" ]; then
            python3 - "$HOME/.pi/agent/settings.json" "$dir/pi-extension.ts" "$mode" <<'PY'
import json, os, sys
f, path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(f), exist_ok=True)
try: d = json.load(open(f))
except Exception: d = {}
ext = [e for e in d.get("extensions", []) if e != path]
if mode == "on": ext.append(path)
d["extensions"] = ext
json.dump(d, open(f, "w"), indent=2)
PY
            [ "$mode" = "on" ] && ok "Pi: enabled for every launch (~/.pi/agent/settings.json)." \
                               || ok "Pi: removed from ~/.pi/agent/settings.json."
        else
            warn "No Pi extension generated yet — run: aistackMcpBuild ${name}"
        fi ;;
    esac

    case " $agents " in *" OpenCode "*)
        base="$HOME/.config/opencode/tools"
        if [ "$mode" = "on" ]; then
            [ -d "$dir/opencode-tools" ] || { warn "No OpenCode tools generated yet — run: aistackMcpBuild ${name}"; return 0; }
            mkdir -p "$base"
            for f in "$dir/opencode-tools"/*.ts; do
                [ -e "$f" ] || continue
                t="$base/$(basename "$f")"
                if [ -e "$t" ] && [ ! -L "$t" ]; then
                    warn "Skipped $(basename "$f") — a real file of that name already exists in ${base}."
                    continue
                fi
                ln -sf "$f" "$t"
            done
            ok "OpenCode: symlinked into ${base} (active for every launch)."
        else
            for f in "$base"/*.ts; do
                [ -L "$f" ] || continue
                case "$(readlink "$f")" in "$dir"/*) rm -f "$f" ;; esac
            done
            ok "OpenCode: symlinks removed from ${base}."
        fi ;;
    esac
    return 0
}

# Delete a connector without asking. Args: <name>. Deactivates it in every
# agent first so no plugin is left pointing at a directory that has gone, then
# removes its state. The confirmation belongs to the caller — aistackMcpRemove
# asks before this, aistackMcpAdd asks its own re-registration question.
_aiStackMcpPurge() {
    local name="$1" dir; dir=$(_aiStackMcpDir "$name")
    _aiStackMcpActivate "$name" "" off
    rm -rf "$dir"
}

# Remove a connector entirely. Args: <name>. Deactivates it in every agent
# first, then deletes its state directory — registration, tokens and all.
# The provider is not told; access is revoked in your account with them.
aistackMcpRemove() {
    if [ $# -lt 1 ]; then
        aiStackUsage "aistackMcpRemove <name>" "example : aistackMcpRemove $(_aiStackMcpFirstName || echo aidlab)"
        return 2
    fi
    local name="$1" dir
    _aiStackMcpRequire "$name" || return 1
    dir=$(_aiStackMcpDir "$name")
    warn "This deletes ${dir} — registration, tokens and generated plugins."
    ask_def "Remove connector '${name}'?" "n" || { ok "Kept."; return 0; }
    _aiStackMcpPurge "$name"
    ok "${name}: removed."
    warn "Access is not revoked upstream — do that in your ${name} account if it matters."
}
