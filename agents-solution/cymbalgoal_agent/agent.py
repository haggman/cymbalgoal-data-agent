"""CymbalGoal ADK agent — finished reference copy.

This is the agent built by hand in Task 5 of the CymbalGoal AlloyDB workshop,
with the commentary left in. It is functionally identical to what you end up
with in the lab; nothing here is a shortcut you were not shown.

Layout ADK expects:

    agents/                      <- the directory you point `adk web` at
      .env                       <- read from HERE, beside the package
      cymbalgoal_agent/          <- one agent
        __init__.py              <- must contain: from . import agent
        agent.py                 <- must define: root_agent

ADK discovers agents by scanning the parent directory for Python packages,
importing each one, and looking for a module-level variable named `root_agent`.
Miss the __init__.py and your agent appears in the dropdown, then does nothing.

Run it from the parent directory:

    adk web --allow_origins="*" --host 0.0.0.0 --port 8080 ~/cymbalgoal-data-agent/agents

Those two flags are Cloud Shell's problem, not ADK's. `--host 0.0.0.0` turns off
the DNS-rebinding guard that rejects Web Preview's cloudshell.dev Host header,
and `--allow_origins="*"` lets the proxied page talk to its own backend. On a
laptop, plain `adk web` is fine.
"""

import os

import google.auth
from google.auth.transport.requests import Request

from google.adk.agents import Agent
from google.adk.tools.mcp_tool import McpToolset, StreamableHTTPConnectionParams

# --- credentials -------------------------------------------------------------
# Application Default Credentials. In Cloud Shell these are already the identity
# you signed in with, so there is no key file anywhere in this project — and
# there should never be one.
_credentials, _default_project = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"]
)
_request = Request()


# --- where the database is ----------------------------------------------------
PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT") or _default_project
REGION = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
DATABASE = "cymbalgoal"

# The MCP tools address the instance by its full resource path, not by a
# connection string. Nothing about this is a secret; it is a name.
INSTANCE_PATH = (
    f"projects/{PROJECT_ID}/locations/{REGION}"
    f"/clusters/cymbalgoal-cluster/instances/cymbalgoal-primary"
)


def adc_headers(context=None) -> dict:
    """Return fresh auth headers. Called per MCP session, not once at import.

    This is a function rather than a dict on purpose. Access tokens live about
    an hour, and an agent scaffolded at minute 70 is still expected to answer
    questions at minute 130. Capture the header once at import time and it goes
    stale mid-session, producing 401s with nothing in the agent's own logs to
    explain them.
    """
    if not _credentials.valid:
        _credentials.refresh(_request)
    return {
        "Authorization": f"Bearer {_credentials.token}",
        "x-goog-user-project": PROJECT_ID,
    }


_credentials.refresh(_request)


# --- the toolset --------------------------------------------------------------
# AlloyDB runs a hosted MCP server. There is nothing to deploy and no endpoint
# to stand up; you authenticate to it with the identity you already have.
#
# The server publishes seventeen tools. Fifteen of them manage cluster
# lifecycle — including deletion. The default when you wire an agent to a tool
# server is *everything*, and nothing warns you.
alloydb_tools = McpToolset(
    connection_params=StreamableHTTPConnectionParams(
        url="https://alloydb.googleapis.com/mcp",
        # A static header for the paths that list tools with no session
        # attached, where the provider below is skipped.
        headers=adc_headers(),
        # Sixty seconds, not the five-second default. Five is fine for a
        # metadata call and hopeless for a GROUP BY over 832,193 appearances.
        timeout=60.0,
    ),
    # The per-session refresh described above.
    header_provider=adc_headers,
    # ------------------------------------------------------------------------
    # THE LINE THAT MATTERS.
    #
    # Seventeen tools go in, one comes out. The sixteen that are gone include
    # every way this agent had of changing or destroying anything. There is no
    # instruction telling it not to delete the cluster, and there does not need
    # to be: the capability is absent. A tool the agent does not have is not a
    # tool it can be talked into using.
    #
    # `tool_filter` belongs HERE, on McpToolset. It looks equally at home on
    # StreamableHTTPConnectionParams above — and that object accepts the keyword
    # without complaint and discards it, because it does not reject unknown
    # fields. Your agent then loads all seventeen tools while your source code
    # says otherwise. It fails open, it fails silently, and it reads correctly
    # in code review. Verify it; do not trust it:
    #
    #   tools = await alloydb_tools.get_tools()
    # ------------------------------------------------------------------------
    tool_filter=["execute_sql_read_only"],
)


# --- the agent ----------------------------------------------------------------
# Note what the instruction is doing. Part of it is behavior ("ground every
# claim"), and part of it is *domain knowledge* — the duplicate-name paragraph
# is the same fact the context set encodes for AlloyDB Studio and for the
# console data agent, stated a third time in a third form. Different surface,
# same idea: somebody has to write down what the data means.
#
# That third statement is a choice, not a limitation. The context set is
# reachable from here too, via a Toolbox tool that wraps the same QueryData
# service and takes a contextSetId. This agent deliberately does not use it,
# because that tool returns a finished natural-language answer and the whole
# point of this rung is being able to see the rows the answer was built from.
root_agent = Agent(
    model="gemini-2.5-flash",
    name="cymbalgoal_agent",
    instruction=f"""You answer questions about CymbalGoal's football database.

Use the execute_sql_read_only tool with:
  instance = "{INSTANCE_PATH}"
  database = "{DATABASE}"

Write standard PostgreSQL. Put a LIMIT on exploratory queries.
Ground every claim in a query result. If you did not read it from this
database, do not say it.

Player names in this database are NOT unique: 134 names are shared by more
than one player, across 289 rows. If a name is ambiguous, say so and show
the candidates rather than picking one or summing across them.

Answer in business terms, not raw rows.""",
    tools=[alloydb_tools],
)
