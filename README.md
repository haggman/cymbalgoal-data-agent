# CymbalGoal — AlloyDB AI: From Generated SQL to a Custom ADK Agent

Companion repository for the CymbalGoal AlloyDB workshop.

CymbalGoal is a global football fan and analytics platform, running on 13,439 players and 796 clubs
drawn from the Big 5 European leagues plus the Champions and Europa Leagues. The scouting and
analytics teams are drowning in requests, and the requests all have the same shape: a question in
plain English about data that lives in PostgreSQL. They don't want a search box, they want answers —
and they don't write SQL.

You'll build a QueryData context set so natural-language questions resolve against a real schema,
attach it to an AlloyDB data agent, then wire the AlloyDB remote MCP server into an ADK agent by
hand — choosing which tools it gets and reading every call it makes.

**You clone this repository during the lab.** Task 0 runs `setup/lab2-setup.sh` from it, which
creates the `cymbalgoal` database and loads the corpus. Everything else is provisioned for you when
you click **Start Lab** — the AlloyDB cluster, the IAM, and the database flags — so that is the only
step you run yourself.

The repo is also yours to take home: re-run the setup in your own project, inspect the infrastructure
that was built for you, and keep the agent.

```bash
git clone https://github.com/haggman/cymbalgoal-data-agent.git
```

---

## What's in here

| Folder | What it is | Do you need it during the lab? |
| :-- | :-- | :-- |
| `setup/` | The Task 0 loader — creates the database and loads the corpus | **Yes.** This is the one thing you run. |
| `agents/` | Where you build the ADK agent in Task 5 | **Yes.** This is your working directory for Task 5. |
| `agents-solution/` | A finished, heavily commented copy of that agent | Only if you get stuck, or want it afterwards. |
| `terraform/` | The infrastructure that provisions your lab cluster | No. Runs automatically at Start Lab. |
| `build/` | Internal build and verification scripts | **No. Not student-facing.** |

### `setup/`

`lab2-setup.sh` installs one client library and then backgrounds `lab2-setup.py`, which creates the
`cymbalgoal` database, enables five extensions, applies the schema, loads roughly 1.6 million rows
across eight tables plus the profile and embedding columns, builds the ScaNN indexes, and switches on
the instance's Data API. It takes about three minutes and returns your prompt immediately, so the
load runs while you read the next task. Every step is guarded by an existence check, so it is safe to
re-run.

### `agents/`

Your working directory for Task 5. You point `adk web` at this folder and build the agent inside it:

```
agents/
└── cymbalgoal_agent/         `adk create` scaffolds this in Task 5.3
    ├── __init__.py
    ├── agent.py              you replace the generated placeholder
    ├── .env
    └── .gitignore
```

ADK discovers agents by scanning a directory for Python packages, importing each one, and looking for
a variable called `root_agent`. So `agents/` is the folder you point ADK at, and `cymbalgoal_agent/`
inside it is one agent. That whole folder is gitignored, so your work never fights with `git pull`.

Task 5 has you wire `McpToolset` to `https://alloydb.googleapis.com/mcp` yourself rather than handing
you a finished agent, because the interesting part is the wiring: which tools you expose, how the
credentials get attached, and what happens when you expose too many. None of that is visible in a
finished file.

### `agents-solution/`

The same agent, finished, with the commentary left in — every decision that a completed file hides,
written next to the line it explains. It mirrors `agents/` exactly, so a stuck student can copy one
folder over their own and keep going. See `agents-solution/README.md` for the two commands.

### `terraform/`

The cluster you used was built by this Terraform before you typed a single command — a PostgreSQL 18
AlloyDB cluster with the AI extensions, the IAM the agent needs, and the database flags the AI
features rely on.

⚠️ **This is a mirror.** The authoritative copy ships with the lab in the content repo at
`labs/mkt014-building-a-data-agent/terraform/`. Keep the two in sync; a change made only here never
reaches a student.

### `build/`

Not student-facing. These are the prototype scripts that answered the "does this product actually
behave the way the docs say" questions before any lab text was written. See `build/README.md`.

---

## Rebuilding this in your own project

You'll need a Google Cloud project with billing, Terraform 1.12 or newer, and these APIs enabled:
`alloydb`, `aiplatform`, `geminidataanalytics`, `cloudaicompanion`, `dataplex`, `discoveryengine`.

Two constraints are not negotiable and will waste your afternoon if you ignore them:

- **Region must be `us-central1` or `us-east1`.** QueryData context sets exist in only four regions
  worldwide, and those are the two US ones. A cluster anywhere else completes the early tasks and
  then has no product to demonstrate.
- **PostgreSQL 18, pinned explicitly.** Never the default.

The one thing you cannot copy is the data: the staged corpus lives in a bucket owned by the course.
The source dataset is public and CC0, and the scouting profiles were generated once, offline, from it
— roughly 250 words per player and club, written by a Gemini model grounded in Google Search, then
embedded with `gemini-embedding-001` at 3072 dimensions and staged to Cloud Storage as gzipped CSV.

That "once, offline" is the part worth stealing. Nothing expensive happens at lab time, every run
gets byte-identical data, and the corpus is a pinned artifact you can point at and reproduce.

---

## Source data

Football Data from Transfermarkt — <https://github.com/dcaribou/transfermarkt-datasets> — CC0 1.0.
Pinned snapshot, never downloaded live during a lab.

Scope: `GB1`, `ES1`, `IT1`, `L1`, `FR1`, `CL`, `EL`. 13,439 players · 796 clubs · 29,740 games ·
832,193 appearances · 417,617 game events · 297,822 valuations · 65,494 transfers · 65 competitions.
