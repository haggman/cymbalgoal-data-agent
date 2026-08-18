# Lab 2 — Console Checklist (Tasks 2, 3, 4)

**This is the gap the shell scripts cannot close.** `lab2-01` through `lab2-05` test everything
reachable from a terminal. **Tasks 2, 3 and 4 — 48 of Lab 2's ~103 minutes — happen in the Google
Cloud console**, and none of it is scriptable.

> **⚠️ REVISED 2026-08-18.** The first version of this file assumed the reader already knew the
> QueryData workflow and asked for checks out of order. It now explains the workflow first and is
> split into **Part A** (doable before anything else) and **Part B** (needs `lab2-04` to have run).
> Part A's results are recorded inline.

---

## First: what Task 3 is actually doing

Nothing in Part B makes sense without this, so read it once.

A **context set** is a JSON file describing your database in a way that helps an LLM write correct
SQL against it. It holds three kinds of thing:

- **templates** — representative questions paired with the SQL that answers them
- **facets** — phrasings of filters paired with the SQL predicate they mean
- **value searches** — how a user's wording maps to real values in a column

The workflow has **four steps, and the last one is a surprise**:

| | Where | What |
| :-- | :-- | :-- |
| 1 | Cloud Shell | Run `agy` with the context-engineering plugin. Talk to it in English; it inspects your schema. |
| 2 | Cloud Shell | It writes a **JSON file to local disk**, then evaluates and improves it in a loop. |
| 3 | **Console** | Create an empty, named **context set** resource in AlloyDB Studio. |
| 4 | **Console** | **Upload the JSON** into that context set. |

**Steps 3 and 4 are the surprise: there is no CLI publish command.** The agent produces a file and
stops. Getting it into AlloyDB is a manual console upload. So Task 3 *ends in the browser*, and if
that upload path is broken, Task 3 has no ending — which is why it gets checked rather than assumed.

Once uploaded, Studio's **Generate SQL** can be pointed at that context set, and Task 4 compares what
it produces against what Task 2 got without one.

**So the order is: Part A → run `lab2-04` (which does steps 1–2) → Part B (steps 3–4 and Task 4).**

---

# PART A — before anything else

## ✅ 1. Studio IAM sign-in — PASSES

Nothing in this series had ever proven a student can get into AlloyDB Studio; Lab 1 worked entirely
through a Colab notebook. Three of Lab 2's tasks assume it.

**Result: works.** Signed in with the student account, `cymbalgoal` selectable from the dropdown,
`SELECT *` returns. The two-layer grant (project IAM role from Terraform + cluster-level database
user) is sufficient. **No extra step needed in Task 0.**

## ✅ 2. The "Help me code" affordance — PRESENT, and richer than the docs suggest

**Result: present in a fresh Qwiklabs project with no manual enablement.** That also retires the open
question about `cloudaicompanion.googleapis.com` — our Terraform enables it on an *inference* (Google
never names the API string), and the panel appearing proves the inference was right.

What is actually on screen, which the docs do not describe well:

- The UI is **very close to BigQuery's**. `+` opens an "Untitled query" tab.
- A **`✦ Generate SQL`** button sits inline in an empty editor.
- Clicking it opens a panel titled **"Help me code"**, badged **`Preview`**, with the placeholder
  *"Enter a prompt to generate a query"* and a **`Generate`** button.
- Once you are typing, a **magic-pencil icon** appears beside the editor for the same thing.
- Highlighting a query reveals an **"Explain this query"** button.

**So both names in our notes are right and they are different things**: `Generate SQL` is the
*button*, `Help me code` is the *panel it opens*. Lab prose should use both, in that order, rather
than treating them as alternatives.

### 🎁 "Explain this query" is a gift to Task 2 — use it

Task 2's job is to get the student to *read* generated SQL and decide whether they would sign off on
it. "Explain this query" is a built-in step for exactly that, and — critically — its explanation will
almost certainly describe what the SQL *does* without noticing the ambiguity trap (see item 3). That
is a far sharper teaching moment than a plain code-read: the tool explains itself confidently, and
the student still has to catch the problem.

**Task 2 should include an Explain-this-query step.** Capture what it says: ________________

## 3. 🔴 THE PAULINHO RESULT — deterministic, and the trap is real

**Five runs returned byte-identical SQL. Answer: 54.**

```sql
-- How many goals has Paulinho scored?
SELECT
  COALESCE(SUM(CAST("t1"."goals" AS INTEGER)), 0) AS "total_goals"
FROM
  "appearances" AS "t1"
INNER JOIN
  "players" AS "t2"
ON
  "t1"."player_id" = "t2"."player_id"
WHERE
  "t2"."player_name" = 'Paulinho'
  AND "t1"."goals" IS NOT NULL;
```

**This is better than the plan hoped for, in two separate ways.**

**It is stable.** The handoff's central worry was that Task 2 makes a claim about nondeterministic
LLM output and a student who gets *good* SQL watches the lab's premise collapse. Five identical runs
says the variance is low enough to write around. ⚠️ **But this is one project, one day, one model
version** — P-44's lesson was that ScaNN differed *between environments*, not within one. So the lab
must still say *"you'll see something like this"* and be written to work whatever comes back. Do not
promise byte-identical SQL.

**It walks straight into the trap.** The SQL sums goals across **every** player named Paulinho and
reports one number. It looks impeccable — quoted identifiers, `COALESCE`, an explicit `CAST`, a
`NULL` guard. There is nothing a reviewer would flag on style. And the answer is meaningless, because
"Paulinho" is not one player. **That is exactly the task Lab 2 wanted**: not "the AI got it wrong"
but "the AI produced professional SQL that answers a question nobody asked."

`lab2-05` §6 supplies the arithmetic that makes this airtight and is deterministic, so it is safe to
print in lab prose: the number of `Paulinho` rows, and the corpus-wide duplicate-name counts.

**Also confirmed from this SQL** — the column is **`players.player_name`**, not `name`. `lab2-05` has
been corrected.

---

# PART B — after `lab2-04` has produced a context-set JSON

Do not attempt these until `bash build/lab2-04-antigravity.sh` has run and `agy` has written a JSON.
Items 5 and 6 are impossible without one; item 4 is half-doable before (you can create an empty
context set), but there is nothing to upload.

## 4. The publish path — steps 3 and 4 of the workflow above

In Studio's **Explorer pane** (the tree on the left, where the database and tables are listed):

- [ ] Is there a top-level node for context sets? **What is it labelled?**
      Docs say **"Context sets"**; the Next '26 codelab shows **"QueryData Context"**; you have also
      now seen an **"Agents"** entry in the left nav that may or may not be the same thing.
      → seen: ______________________
- [ ] Hover it → **View actions** (a ⋮ or similar) → is there **Create context set** / **Create
      Context**? Create one with any name.
- [ ] How long did creation take? Docs warn the *first* one in a project "can take several minutes."
      → ______
- [ ] Then **View actions → Edit context set → Upload context set file → Browse**, and upload the
      JSON `agy` wrote. Does it accept it?
- [ ] **Record the exact filename `agy` produced.** Google's docs say only "a JSON file in an
      experiment folder" and never name it, so Task 3's steps cannot reference it until we have seen
      it. → ______________________

**Result:** ______________________________________________

## 5. Task 4's test path

The documented click path, which nothing in the shell scripts can reach:

Explorer pane → **View actions** next to your context set → **Test context set** → in the query
editor click **Generate SQL** (which opens the same **Help me code** panel, now bound to that context
set) → enter a question → **Generate**.

- [ ] Does **Test context set** exist under View actions?
- [ ] Does the panel header name the context set — i.e. is the binding *visible*? Task 4 depends on
      the student being able to tell the two modes apart.
      → header reads: ______________________
- [ ] Which fields come back? Docs promise four: `generated_query`, `intent_explanation`,
      `query_result`, `natural_language_answer`.
- [ ] **Is there a confidence score?** Docs document none. If a draft ever claims one, cut it. → ____

**Label drift** — docs vs. the codelab's live console. You have already found the docs right on
"Help me code", so these may well be right too:

| Docs say | Codelab shows | You saw |
| :-- | :-- | :-- |
| Context sets | QueryData Context | |
| Create context set | Create Context | |
| Test context set | Test context | |
| **Generate** button | **Insert** button | |

## 6. Paulinho, round two — WITH the context set

The whole payload of Task 4. Same question, through **Test context set**.

| # | SQL it generated | What changed vs. the 54-goal version? |
| :-- | :-- | :-- |
| 1 | | |
| 2 | | |
| 3 | | |

The interesting outcomes, in order of usefulness to the lab:

1. It returns **per-Paulinho rows** — the context set taught it the name is not unique. Ideal.
2. It **asks a clarifying question** instead of guessing. Also excellent, different lesson.
3. It produces the **same 54** — then the honest lesson is that context sets fix schema and
   vocabulary problems, not ambiguity in the *question*, and Task 4 should say so rather than
   pretending otherwise.

⚠️ **Task 4 must be framed as "compare what the context set changed," not "now it's right."** All
three outcomes above are writable. Only a task that promised correctness would break.

## 7. Timings — handoff deliverable

Fifty-five of the lab's ~103 minutes sit in Tasks 3 and 5, both open-ended AI-tool work whose
variance is set by the tooling rather than by us.

| Segment | Estimate | Measured |
| :-- | --: | --: |
| `terraform apply`, cold project | ~9 min | |
| `lab2-setup.sh` load | — | **213 s** (344 s measured, less the 131 s PATCH now made async) |
| **Task 3** — `agy` connect → golden set → context → evaluate → gap analysis | 25 min | |
| — how many gap-analysis rounds did you allow? | — | |
| — plus the console create + upload (items 4) | — | |
| **Task 5** — ADK install → agent → first successful tool call | 30 min | |
| Task 4 — context-set test loop | 15 min | |

For the Terraform number use `time terraform apply` — the deliverable is Lab 2's provisioning
wall-clock **as a delta against Lab 1's 542 s** in a virgin project.

---

## Noted for later, not now: the "Agents" nav entry

An **Agents** link has appeared in AlloyDB's left nav, BigQuery-style — presumably a console-native
way to chat with your data.

**Agreed it does not replace Task 5.** Task 5's teaching payload is *wiring MCP tools yourself*: what
you expose, how credentials attach, and what goes wrong when you expose too much. A console chat box
teaches none of that, and the lab's audience are practitioners who will build agents, not use one.

But it is worth **one sentence in the Lab Summary or an optional task** — a student who spots it in
the nav will wonder why they hand-built an agent, and the answer ("that one you cannot deploy,
version, or put a tool filter on") is a good one. Capture what it does if you get a spare minute:

______________________________________________
