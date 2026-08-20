# `agents-solution/` — the finished agent

This mirrors the folder you build in Task 5, so you can drop it straight into place.

```
agents-solution/
├── .env.example              -> becomes agents/.env
└── cymbalgoal_agent/         -> becomes agents/cymbalgoal_agent/
    ├── __init__.py
    └── agent.py
```

The code is functionally identical to what you write during the lab. The only difference is
commentary: every decision that is invisible in a finished file — why the credential is a function,
why the timeout is sixty seconds, why `tool_filter` goes on the toolset and not on the connection
params — is written down next to the line it explains.

## If you want to run this copy instead of your own

From the repository root:

```bash
cd agents
cp -r ../agents-solution/cymbalgoal_agent .
sed "s|YOUR_PROJECT_ID|$(gcloud config get-value project)|" ../agents-solution/.env.example > .env
adk web --allow_origins="*" --host 0.0.0.0 --port 8080 .
```

That overwrites whatever is in `agents/cymbalgoal_agent/`, so move your own version aside first if
you want to keep it.

Requires `pip install "google-adk[mcp]==2.7.1"` — the `[mcp]` extra is not optional, and the version
is pinned because the agent depends on specific `McpToolset` behavior.

## Why you type it in the lab instead of cloning it

The interesting part of this agent is the wiring: which tools you expose, how credentials get
attached, and what happens when you expose too many. All three are invisible in a finished file —
which is exactly why this copy is a reference rather than the starting point.
