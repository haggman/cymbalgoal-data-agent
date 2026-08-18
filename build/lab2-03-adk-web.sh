#!/usr/bin/env bash
#
# CymbalGoal Lab 2 — Tier 1, item 1b: the ADK agent and `adk web` through Cloud
# Shell's Web Preview. This is 30 of Lab 2's ~103 minutes and the single biggest
# unverified block in the series.
#
# WHERE: Cloud Shell, after lab2-02-mcp-probe.sh returned 200s.
# RUN:   bash lab2-03-adk-web.sh 2>&1 | tee ~/lab2-adk.log
# TIME:  ~4 min to install and launch. THEN TIME THE HUMAN PART SEPARATELY —
#        the handoff asks for a measured number for Task 5 and the install is
#        not the part that varies.
#
# ⚠️ THE FINDING THAT MAKES OR BREAKS THIS TASK, established by running ADK's
# own server behind a spoofed Host header:
#
#   adk web binds 127.0.0.1:8000 by default, and its api_server carries a
#   DNS-REBINDING GUARD that activates whenever the bind host is loopback. The
#   guard rejects any request whose Host header is not loopback. Cloud Shell's
#   Web Preview sends Host: 8080-cs-<id>.cloudshell.dev.
#
#   Measured:
#     adk web --port 8081                        -> 403 Forbidden: host not allowed
#     adk web --host 0.0.0.0 --port 8082         -> 200
#     adk web --allow_origins="*" --port 8083    -> 200
#
#   So the naive invocation fails, and it fails with a message that reads like a
#   permissions problem rather than a binding problem. A student hitting this at
#   minute 70 will burn the rest of the lab on it. THE FLAGS BELOW ARE NOT
#   OPTIONAL AND THE LAB MUST NOT SIMPLIFY THEM.
#
# Two more things worth knowing before writing prose:
#   * Text chat uses POST /run_sse (Server-Sent Events). Cloud Shell proxies it.
#     The only websocket is /run_live, used for live audio, and it enforces an
#     additional Origin check. KEEP TASK 5 OUT OF LIVE/AUDIO MODE.
#   * Do NOT set --url_prefix. It exists for reverse proxies mounting at a
#     subpath; Cloud Shell serves at root and setting it breaks the dev UI.

set -uo pipefail

# ⚠️ PINNED, and the [mcp] extra is NOT optional.
# A bare `pip install google-adk` installs a google.adk.tools.mcp_tool package
# whose __init__ swallows the ImportError and exports nothing. Your import then
# fails with a confusing ImportError and the only clue is a DEBUG-level log line
# saying "MCP Tool is not installed". Verified by installing both ways.
ADK_VERSION="2.7.1"

REGION="${CG_REGION:-us-central1}"
CLUSTER="${CG_CLUSTER:-cymbalgoal-cluster}"
INSTANCE="${CG_INSTANCE:-cymbalgoal-primary}"
DB="${CG_DB:-cymbalgoal}"
PROJECT="$(gcloud config get-value project 2>/dev/null)"
PORT="${ADK_PORT:-8080}"          # inside Web Preview's default 8080-8084 band
AGENT_ROOT=~/cymbalgoal-agent

say() { echo; echo "### $* ###"; }
verdict() { echo "VERDICT: $*"; }

say "1. Install google-adk[mcp]==${ADK_VERSION}"
python3 -m pip install --quiet --upgrade "google-adk[mcp]==${ADK_VERSION}" || {
  verdict "🔴 pip install failed — everything downstream is blocked"; exit 1; }

python3 - <<'PY'
import google.adk, inspect
print("  google-adk:", google.adk.__version__)
from google.adk.tools.mcp_tool import McpToolset, StreamableHTTPConnectionParams
print("  McpToolset OK, StreamableHTTPConnectionParams OK")
print("  StreamableHTTPConnectionParams fields:", list(StreamableHTTPConnectionParams.model_fields))
sig = inspect.signature(McpToolset.__init__)
print("  McpToolset kwargs:", [p for p in sig.parameters if p not in ('self',)])
PY
verdict "imports resolved — if the fields above differ from headers/timeout/... the pin has moved"

say "2. Scaffold the agent"
mkdir -p "${AGENT_ROOT}/cymbalgoal_agent"
cat > "${AGENT_ROOT}/cymbalgoal_agent/__init__.py" <<'PY'
from . import agent
PY

cat > "${AGENT_ROOT}/cymbalgoal_agent/agent.py" <<PY
import os
import google.auth
from google.auth.transport.requests import Request
from google.adk.agents import Agent
from google.adk.tools.mcp_tool import McpToolset, StreamableHTTPConnectionParams

PROJECT_ID  = os.environ.get("GOOGLE_CLOUD_PROJECT", "${PROJECT}")
INSTANCE    = "projects/${PROJECT}/locations/${REGION}/clusters/${CLUSTER}/instances/${INSTANCE}"
DATABASE    = "${DB}"

# ⚠️ google.auth.default(scopes=...) is a NO-OP for user credentials
# (requires_scopes is False) — you get whatever gcloud already granted. It is
# left in because it IS meaningful if this ever runs as a service account.
_creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
_request = Request()


def _adc_headers(context=None) -> dict:
    """Fresh bearer token per MCP session.

    ⚠️ Why a provider and not just a static header: access tokens live about an
    hour and this lab runs longer than that. A student who scaffolds the agent
    at minute 60 and is still chatting at minute 130 would otherwise watch it
    start 401ing for no visible reason.
    """
    if not _creds.valid:
        _creds.refresh(_request)
    return {
        "Authorization": f"Bearer {_creds.token}",
        "x-goog-user-project": PROJECT_ID,
    }


_creds.refresh(_request)

alloydb_tools = McpToolset(
    connection_params=StreamableHTTPConnectionParams(
        url="https://alloydb.googleapis.com/mcp",
        # ⚠️ BOTH the static headers AND the provider, deliberately.
        # ADK's _build_headers guards with \`if self._header_provider and
        # readonly_context:\` — so on any code path that lists tools with a null
        # context, the provider is SKIPPED and the request goes out
        # unauthenticated. Verified against a request-logging MCP server.
        headers=_adc_headers(),
        timeout=60.0,          # the 5.0 default is far too tight for real SQL
    ),
    header_provider=_adc_headers,

    # ⚠️ tool_filter BELONGS ON McpToolset, NOT on the connection params.
    # StreamableHTTPConnectionParams has no extra="forbid", so passing
    # tool_filter there is SILENTLY DROPPED and the agent loads every tool the
    # server offers — including create/delete/restore. Google's own BigQuery MCP
    # codelab has this bug in its snippet. Verified by model_dump().
    tool_filter=["execute_sql_read_only"],
)

root_agent = Agent(
    model="gemini-2.5-flash",
    name="cymbalgoal_agent",
    instruction=f"""You answer questions about CymbalGoal's football database.

Use execute_sql_read_only with:
  instance = "{INSTANCE}"
  database = "{DATABASE}"

Write standard PostgreSQL. LIMIT exploratory queries.
Answer in business terms, not raw rows.

If a player name is ambiguous, SAY SO and show the candidates rather than
picking one — this database has 937 duplicate player names.""",
    tools=[alloydb_tools],
)
PY
echo "  wrote ${AGENT_ROOT}/cymbalgoal_agent/agent.py"

say "3. Smoke-test the toolset OUTSIDE the web UI"
# If this fails, the problem is the agent or MCP — not Web Preview. Separating
# the two is the whole reason this step exists.
python3 - <<PY
import asyncio, sys
sys.path.insert(0, "${AGENT_ROOT}")
from cymbalgoal_agent.agent import alloydb_tools
async def main():
    try:
        tools = await alloydb_tools.get_tools()
        print("  tools visible to the agent:", [t.name for t in tools])
        print("  VERDICT: toolset resolved")
    except Exception as e:
        print("  VERDICT: 🔴 toolset FAILED —", type(e).__name__, e)
asyncio.run(main())
PY

say "4. Launch adk web with the flags Cloud Shell requires"
echo
echo "  ⚠️ Do NOT simplify this command. Dropping --host 0.0.0.0 gives a 403"
echo "     'Forbidden: host not allowed' through Web Preview, which reads like"
echo "     an auth failure and is not."
echo
CMD="adk web --allow_origins=\"*\" --host 0.0.0.0 --port ${PORT} ${AGENT_ROOT}"
echo "  ${CMD}"
echo
echo "  Then: Web Preview (top right of Cloud Shell) -> Preview on port ${PORT}"
echo
echo "  ---- TIME THIS PART. The handoff wants a measured number for Task 5 and"
echo "       it is the students' hands-on minutes that matter, not the install."
echo
read -r -p "  Launch it now? [Y/n] " GO
[[ "${GO:-Y}" =~ ^[Nn] ]] && { echo "  skipped."; exit 0; }
exec adk web --allow_origins="*" --host 0.0.0.0 --port "${PORT}" "${AGENT_ROOT}"
