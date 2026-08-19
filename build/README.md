# Lab 2 (mkt014) — Prototype Test Rig

**⚠️ NOT STUDENT-FACING. Internal build tooling.** Same rules as Lab 1's `build/` folder: delete it
or keep the repo private before release.

These answer the Tier 1 and Tier 2 questions in `handoff-04-lab2-prototype.md` so the Lab 2 build
session writes against measurements instead of assumptions. **Do not write lab prose from anything
here until the `VERDICT:` lines exist in a log.**

## Where to run

Cloud Shell, inside a **started mkt014 lab** (or any project with the `cymbalgoal-cluster` up).
Unlike Lab 1's rig, these do **not** provision anything — mkt014's Terraform does that, and testing
against the real provisioning is the point. Set these if your names differ:

```bash
export CG_REGION=us-central1 CG_CLUSTER=cymbalgoal-cluster CG_INSTANCE=cymbalgoal-primary CG_DB=cymbalgoal
```

## Order — and it matters

```bash
# ⚠️ START HERE, at the keyboard, BEFORE the shell scripts:
#    lab2-06-studio-checklist.md   items 1 and 4 are hard blockers

bash lab2-01-data-api.sh    2>&1 | tee ~/lab2-dataapi.log   # ~1 min
bash lab2-02-mcp-probe.sh   2>&1 | tee ~/lab2-mcp.log       # ~2 min
bash lab2-03-adk-web.sh     2>&1 | tee ~/lab2-adk.log       # ~5 min + human time
bash lab2-04-antigravity.sh 2>&1 | tee ~/lab2-agy.log       # ~3 min + human time
python3 lab2-05-ai-functions.py 2>&1 | tee ~/lab2-ai.log       # ~4 min
```

`01` before `02` because the Data API is what lets MCP execute SQL at all. `02` before `03` because
`02` proves the *server* answers us with nothing but curl — so if `03` fails afterwards, the fault
is unambiguously ADK's. That separation is the whole reason `02` exists.

`05` needs the Task 0 load to have finished. **It is Python, not SQL**, and deliberately so: `psql`
from Cloud Shell would need authorized networks this lab does not configure, and pasting into Studio
fails because Studio does not understand psql meta-commands. More importantly, proxy-model fallback
is reported only as a PostgreSQL NOTICE — pg8000 queues those as dicts with byte keys, so they have
to be drained and decoded, and that string is the single most important signal the script produces.

**`lab2-06` is a manual checklist, not a script, and it is not optional.** Tasks 2, 3 and 4 are 48 of
the lab's ~103 minutes and happen entirely in the console. Nothing in the shell scripts touches them.
Two of its items are blockers worth knowing on day one: whether AlloyDB Studio accepts an IAM
sign-in at all (**nothing in this series has ever proven that** — Lab 1 used a notebook throughout),
and whether the context-set node exists in the Explorer pane.

## What each answers

| Script | Tier | Question |
| :-- | :-- | :-- |
| `01` | 1 | Does the `dataApiAccess` PATCH work, on which API version, and is `ALLOW_DATA_API` really a docs bug? (P-08 — **never exercised in Lab 1**) |
| `02` | 1 | Does Cloud Shell ADC authenticate to the MCP server? What are the tools *actually*? Does `execute_sql_read_only` return CymbalGoal rows? |
| `03` | 1 | Does `McpToolset` + `StreamableHTTPConnectionParams` work at the pin, and **does `adk web` survive Cloud Shell Web Preview?** |
| `04` | 1 | Does the Antigravity plugin still install at `v0.7.2`, is `agy` pre-installed, are the prerequisites there? |
| `05` | 2 | **Do proxy models work on PG 18 with a learnable predicate at `VECTOR(3072)`?** A/B timing for the 100x claim, the `ai.*` inventory from `pg_proc`, and the Paulinho ambiguity arithmetic. |
| `06` | 1+2 | **Manual.** Studio IAM sign-in, "Help me code", the context-set create/upload path, Task 4's test path, the Paulinho spread, and the Task 3 / Task 5 timings. |

Every check prints a `VERDICT:` line, same convention as Lab 1's rig, so answers are greppable
rather than buried.

## The three findings that already changed the design

These came out of the docs sweep, before any of these scripts ran. They are the reason the scripts
look the way they do.

1. **`adk web` fails through Cloud Shell Web Preview with default flags.** It binds `127.0.0.1:8000`
   and its api_server carries a DNS-rebinding guard that 403s any non-loopback `Host` header — which
   is exactly what Web Preview sends. `--allow_origins="*" --host 0.0.0.0 --port 8080` is mandatory,
   and the failure message reads like an auth problem. A student would lose the rest of the lab to
   this at minute 70.

2. **`tool_filter` on `StreamableHTTPConnectionParams` is silently dropped.** The model has no
   `extra="forbid"`, so the agent quietly loads every tool the server offers — including
   `create_cluster`, `delete`, `restore_cluster`. It belongs on `McpToolset`. Google's own BigQuery
   MCP codelab carries this bug; do not copy from it.

3. **`pip install google-adk` is not enough — you need `google-adk[mcp]`.** Without the extra, the
   `mcp_tool` package swallows its own ImportError and exports nothing, and the only clue is a
   DEBUG-level log line.

## What is NOT here yet

`lab2-setup.sh` — the Task 0 loader (create database, extensions, schema, `COPY` the eight tables,
pass-2 profiles and embeddings, ScaNN indexes, and the Data API PATCH). It is deliberately last: its
load logic is a port of Lab 1's notebook Task 1, and `01`/`05` decide two things it has to encode —
which API version the PATCH goes to, and whether a second 768-dimension embedding column is needed
for proxy models.
