#!/usr/bin/env bash
#
# CymbalGoal Lab 2 — Tier 1, item 1a: does the AlloyDB remote MCP server answer
# Cloud Shell's ADC, and which of its tools are worth 30 minutes of Task 5?
#
# WHERE: Cloud Shell, after lab2-01-data-api.sh has succeeded.
# RUN:   bash lab2-02-mcp-probe.sh 2>&1 | tee ~/lab2-mcp.log
# TIME:  ~2 min.
#
# WHY THIS RUNS BEFORE ANY ADK CODE. Task 5 has two independent ways to fail:
# the MCP server might not accept us, or ADK might not talk to it properly. If
# we go straight to `adk web` and get nothing, we cannot tell which one broke.
# This script removes the first variable using nothing but curl, so that when
# lab2-03 runs, any failure is unambiguously ADK's.
#
# THE FOUR QUESTIONS:
#   1. Does a plain cloud-platform-scoped ADC token authenticate? Google's docs
#      name the scope https://www.googleapis.com/auth/alloydb. cloud-platform is
#      a superset and is what Cloud Shell hands out, but "superset should work"
#      is exactly the class of assumption that cost us the Discovery Engine role.
#   2. What are the tools, from tools/list rather than from a docs page? Two
#      independent fetches of Google's reference enumerated 17 while one summary
#      said 18. Ask the server.
#   3. Does execute_sql_read_only actually return CymbalGoal rows?
#   4. Is mcp.tools.call carried by a role the student has? The docs list the
#      permission and never name a role containing it. This is the likeliest
#      silent blocker in the whole lab.

set -uo pipefail

REGION="${CG_REGION:-us-central1}"
CLUSTER="${CG_CLUSTER:-cymbalgoal-cluster}"
INSTANCE="${CG_INSTANCE:-cymbalgoal-primary}"
DB="${CG_DB:-cymbalgoal}"
PROJECT="$(gcloud config get-value project 2>/dev/null)"
MCP_URL="https://alloydb.googleapis.com/mcp"

INST="projects/${PROJECT}/locations/${REGION}/clusters/${CLUSTER}/instances/${INSTANCE}"
TOKEN="$(gcloud auth print-access-token)"

say() { echo; echo "### $* ###"; }
verdict() { echo "VERDICT: $*"; }

# Streamable HTTP MCP wants BOTH content types in Accept or some servers 406.
# Sending them unconditionally costs nothing and removes a whole failure mode.
mcp() {
  curl -sS -w '\n%{http_code}' -X POST "$MCP_URL" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "x-goog-user-project: ${PROJECT}" \
    -d "$1"
}

# The server may reply as SSE ("data: {...}") rather than bare JSON. Normalise
# both shapes so the rest of the script does not care which it got.
unwrap() {
  python3 -c "
import json,sys
raw=sys.stdin.read()
for line in raw.splitlines():
    line=line.strip()
    if line.startswith('data:'): line=line[5:].strip()
    if line.startswith('{'):
        try:
            print(json.dumps(json.loads(line), indent=2)); sys.exit(0)
        except Exception: pass
print(raw)"
}

echo "=============================================="
echo " MCP      : $MCP_URL"
echo " instance : $INST"
echo " database : $DB"
echo "=============================================="

# ---------------------------------------------------------------------------
say "1. initialize — does ADC get in at all?"
# ---------------------------------------------------------------------------
RESP="$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cymbalgoal-probe","version":"1.0"}}}')"
CODE="$(tail -1 <<<"$RESP")"; BODY="$(sed '$d' <<<"$RESP")"
echo "HTTP ${CODE}"; unwrap <<<"$BODY" | head -40
case "$CODE" in
  200) verdict "cloud-platform ADC ACCEPTED — no alloydb-scoped token needed" ;;
  401) verdict "🔴 401 — cloud-platform scope is NOT sufficient. Task 5 needs a re-scoped token; try: gcloud auth application-default login --scopes=https://www.googleapis.com/auth/alloydb,https://www.googleapis.com/auth/cloud-platform" ;;
  403) verdict "🔴 403 — authenticated but not authorized. This is the mcp.tools.call permission question. Check which role carries it." ;;
  *)   verdict "unexpected HTTP ${CODE} — read the body above" ;;
esac
[[ "$CODE" == "200" ]] || exit 1

# ---------------------------------------------------------------------------
say "2. tools/list — the real inventory, not the docs page"
# ---------------------------------------------------------------------------
RESP="$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')"
BODY="$(sed '$d' <<<"$RESP")"
unwrap <<<"$BODY" > /tmp/mcp-tools.json
python3 -c "
import json
d=json.load(open('/tmp/mcp-tools.json'))
tools=d.get('result',{}).get('tools',[])
print(f'  COUNT: {len(tools)}')
for t in tools:
    desc=(t.get('description') or '').split('.')[0][:78]
    req=t.get('inputSchema',{}).get('required',[])
    print(f\"  - {t['name']:26s} req={','.join(req) or '-':40s} {desc}\")
" || cat /tmp/mcp-tools.json
verdict "tool inventory above — record the count and the names in the prototype findings"

# ---------------------------------------------------------------------------
say "3. execute_sql_read_only against the CymbalGoal schema"
# ---------------------------------------------------------------------------
# ⚠️ execute_sql_read_only is documented as PostgreSQL 17+. We are on 18, so it
# should be available — but "should" is what this whole session exists to
# replace. If only the read-write execute_sql works, Task 5's tool_filter has to
# change and the lab has to explain why the agent can write.
probe_sql() {
  local TOOL="$1" SQL="$2"
  local P
  P="$(python3 -c "
import json,sys
print(json.dumps({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{
 'name': sys.argv[1],
 'arguments': {'instance': sys.argv[2], 'database': sys.argv[3], 'sqlStatement': sys.argv[4]}}}))
" "$TOOL" "$INST" "$DB" "$SQL")"
  local R; R="$(mcp "$P")"
  echo "  --- ${TOOL} -> HTTP $(tail -1 <<<"$R")"
  sed '$d' <<<"$R" | unwrap | head -30
}

probe_sql "execute_sql_read_only" "SELECT count(*) AS players FROM players;"
probe_sql "execute_sql"           "SELECT count(*) AS clubs FROM clubs;"

echo
echo ">>> Expect 13439 players / 796 clubs IF the Task 0 load has finished."
echo ">>> A clean connection returning 0 rows means the load is still running —"
echo ">>> that is the same signal Task 1's row-count check gives students."

# ---------------------------------------------------------------------------
say "4. Which tools are actually useful against this schema?"
# ---------------------------------------------------------------------------
# The answer that matters for Task 5 is not "17 tools exist", it is "these N are
# worth wiring". Most of the inventory is cluster lifecycle — create_cluster,
# create_backup, restore_cluster — which a student in a two-hour lab must never
# call and which would let an agent delete its own database. Task 5's tool_filter
# is therefore a teaching moment, not boilerplate.
python3 -c "
import json
d=json.load(open('/tmp/mcp-tools.json'))
tools=[t['name'] for t in d.get('result',{}).get('tools',[])]
useful=[t for t in tools if 'execute_sql' in t or t in ('list_instances','get_instance','list_users','get_operation')]
danger=[t for t in tools if any(k in t for k in ('create','delete','restore','import','export','update'))]
print('  CANDIDATES for tool_filter :', useful)
print('  MUST NOT EXPOSE to students:', danger)
"
verdict "tool_filter candidates listed above — Task 5 should filter explicitly and say why"

echo
echo "Next: bash lab2-03-adk-web.sh"
