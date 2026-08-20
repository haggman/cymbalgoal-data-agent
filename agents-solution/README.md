# `agents-solution/` — the finished agent

The agent you build in Task 5, finished, with the commentary left in. Every decision that a
completed file hides — why the credential is a callable and not a dict, why the timeout is sixty
seconds, why `tool_filter` goes on the toolset and not on the connection params, and why the AlloyDB
region is hard-coded instead of read from `GOOGLE_CLOUD_LOCATION` — is written next to the line it
explains.

```
agents-solution/
├── .env.example              only needed if you are rebuilding outside the lab
└── cymbalgoal_agent/
    ├── __init__.py
    └── agent.py              the interesting file
```

## If you want to run this copy instead of your own

During the lab, `adk create` has already generated your `__init__.py` and a `.env` carrying your own
project. Keep both — you only need `agent.py`:

```bash
cd ~/cymbalgoal-data-agent/agents
cp ../agents-solution/cymbalgoal_agent/agent.py cymbalgoal_agent/
adk web --allow_origins="*" --host 0.0.0.0 --port 8080 .
```

That replaces only the one file, so nothing you configured is lost. Move your own `agent.py` aside
first if you want to keep it.

## Rebuilding this from scratch, outside the lab

```bash
pip install --quiet --upgrade "google-adk[mcp]==2.7.1"
export PATH="$HOME/.local/bin:$PATH"

mkdir -p agents && cd agents
adk create --model gemini-3.7-flash --region global cymbalgoal_agent
cp ../agents-solution/cymbalgoal_agent/agent.py cymbalgoal_agent/
```

The `[mcp]` extra is not optional — a plain `google-adk` installs an `mcp_tool` package that swallows
its own missing dependency and exports nothing. The version is pinned because the agent depends on
specific `McpToolset` behavior.

The `export` matters as much as the install. pip puts the `adk` script in `~/.local/bin` and warns
that the directory is not on your PATH; it is telling the truth, and without that line `adk` comes
back `command not found`, which reads like a failed install rather than a misplaced one.

At the `adk create` prompts, answer **Vertex AI** for the backend and accept the project and region
defaults. If you would rather write the `.env` by hand, `.env.example` shows what it needs — but note
that `GOOGLE_CLOUD_LOCATION` there is the **model's** endpoint, not your database's region. The two
are different, and `agent.py` keeps them apart on purpose.

## Why you type it in the lab instead of cloning it

The interesting part of this agent is the wiring: which tools you expose, how credentials get
attached, and what happens when you expose too many. All three are invisible in a finished file —
which is exactly why this copy is a reference rather than the starting point.
