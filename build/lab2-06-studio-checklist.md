# Lab 2 — Console Checklist (Tasks 2, 3, 4)

**This is the gap the shell scripts cannot close.** `lab2-01` through `lab2-05` test everything
reachable from a terminal. **Tasks 2, 3 and 4 — 48 of Lab 2's ~103 minutes — happen in the Google
Cloud console**, and not one click of that is scripted or scriptable.

Work through this at the keyboard and **write the answers in**. Per S-37, the Lab 2 build session may
not assert any of it until there is a recorded answer here.

⚠️ **Do this EARLY, not after the shell scripts.** Items 1 and 4 are hard blockers: if AlloyDB Studio
won't take an IAM sign-in, or the Context sets node isn't in the Explorer pane, then Tasks 2, 3 and 4
have no delivery mechanism and the lab's shape changes. That is a finding worth having on day one,
not day three.

---

## 1. 🔴 BLOCKER — Studio IAM sign-in

Lab 1 never used AlloyDB Studio; it worked entirely through a Colab notebook and the Python
Connector. **So nothing in this series has ever proven a student can get into Studio at all.** Three
of Lab 2's tasks assume it.

Console → **AlloyDB** → `cymbalgoal-cluster` → **AlloyDB Studio**.

- [ ] Does the sign-in offer **IAM authentication** as an option (not just user/password)?
- [ ] Does signing in as the student account succeed?
- [ ] Database `cymbalgoal` visible in the dropdown? _(if the load hasn't run, it won't exist yet)_
- [ ] Does a trivial `SELECT count(*) FROM players;` return?

**Result:** ______________________________________________

**If IAM sign-in fails:** the likely cause is the two-layer grant — the project IAM role
(`roles/alloydb.databaseUser`, from Terraform) AND the cluster-level database user (the
`google_alloydb_user` resource). Check both exist before concluding anything about Studio.

---

## 2. Task 2's affordance — "Help me code"

The docs call it **"Help me code"**, a ✨ / `pen_spark` icon **next to the query editor** — not
"Generate SQL", and not in the Explorer pane. It requires **Gemini Cloud Assist** set up for the
account and project.

- [ ] Is the icon present in a **fresh Qwiklabs project**?
- [ ] Does it work without any manual enablement step, or does it prompt to turn something on?
- [ ] If it prompts: what exactly, and can Terraform pre-empt it?

**Result:** ______________________________________________

⚠️ **This is Task 2's entire delivery mechanism.** Our Terraform enables `cloudaicompanion.googleapis.com`
on an **inference** — Google's AlloyDB pages never name the API string, we deduced it from the two
`cloudaicompanion.*` permissions the Studio doc lists. If the panel is missing, that inference is
where to look first.

---

## 3. 🔴 DELIVERABLE — the Paulinho spread

Handoff deliverable #4, and **the one thing neither of us can script**.

Task 2's premise is that Generate SQL gets an ambiguous question wrong. We may not assert what the
model produces (P-44's lesson applied to a higher-variance system), so the task has to be written
around the *range*. That means knowing the range.

Ask **"How many goals has Paulinho scored?"** five times, in a fresh tab each time.

| # | SQL it generated | Picked one Paulinho / summed several / asked back / other |
| :-- | :-- | :-- |
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |

**Did any run produce SQL you would actually sign off on?** ______

That last line is the one that matters. If Generate SQL reliably *handles* the ambiguity — asks a
clarifying question, or returns per-player rows — then Task 2's framing ("read this and decide
whether you'd sign off") still works, but the *reason* changes and the task has to be rewritten
around it. Better to find out now than in the build session.

`lab2-05` §6 gives you the corpus arithmetic that makes the question ambiguous by construction
(expect 937 duplicated names across 2,261 rows). Those numbers are deterministic and safe to print in
lab prose; nothing in the table above is.

---

## 4. 🔴 BLOCKER — Task 3's publish path

**There is no CLI publish command.** The Antigravity agent writes a context-set JSON to local disk;
getting it into AlloyDB is a console upload. So Task 3 ends in the browser, and if this path is
broken Task 3 has no ending.

In the Studio **Explorer pane**:

- [ ] Is there a top-level node for context sets? **What is it labelled?**
      Docs say **"Context sets"**; the Next '26 codelab shows **"QueryData Context"**.
      → seen: ______________________
- [ ] **View actions** → is there a **Create context set** (or **Create Context**) item?
- [ ] Does creating one succeed? _(docs warn the first one in a project "can take several minutes")_
      → time taken: ______
- [ ] **Edit context set** → **Upload context set file** → does the JSON upload take?

**Result:** ______________________________________________

⚠️ **Record the exact filename** the `agy` agent emitted. Google's docs say only "a JSON file in an
experiment folder" and never name it, so the lab's Task 3 steps cannot reference it until we've seen
it: ______________________

---

## 5. Task 4's test path

Docs give this verbatim, and `lab2-04` cannot reach any of it:

Explorer pane → **View actions** next to the context set → **Test context set** → in the query editor
click **Generate SQL** (which opens the **Help me code** panel, now bound to that context set) → enter
the question → **Generate**.

- [ ] Does **Test context set** exist under View actions?
- [ ] Does it open a query editor tab **bound to that context set** — is the binding visible in the
      panel header?
- [ ] Which four fields come back: `generated_query`, `intent_explanation`, `query_result`,
      `natural_language_answer`?
- [ ] **Is there any confidence score?** Docs document none. If a draft ever claims one, cut it.
      → seen: ______

**Label drift to check** (docs vs. the codelab's live console):

| Docs say | Codelab shows | You saw |
| :-- | :-- | :-- |
| Context sets | QueryData Context | |
| Create context set | Create Context | |
| Test context set | Test context | |
| **Generate** button | **Insert** button | |

Write Task 4's steps hedged around whichever you actually see, and take screenshots while you're
there.

---

## 6. Then re-run Paulinho, WITH the context set

Same question, same five runs, now through **Test context set**. This is Task 4's whole payload.

| # | SQL it generated | Better? How? |
| :-- | :-- | :-- |
| 1 | | |
| 2 | | |
| 3 | | |

⚠️ **Task 4 must be framed as "compare what the context set changed," not "now it's right."** If the
context set happens to produce something wrong on the day, a task written around "now it's right"
collapses in front of the room — the same failure mode Task 2 is being protected from.

---

## 7. Timings — handoff deliverable #3

Fifty-five of Lab 2's 103 minutes sit in Tasks 3 and 5, both open-ended AI-tool work whose variance
is set by the tooling rather than by us. A measured number here is worth more than re-arithmetic on
the other five tasks.

| Segment | Estimated | Measured |
| :-- | --: | --: |
| `terraform apply`, cold project | ~9 min (Lab 1) | |
| `lab2-setup.sh` load | ~4.5 min (Lab 1) | |
| **Task 3** — `agy` connection + golden set + context + evaluate + gap analysis | 25 min | |
| — of which: how many gap-analysis rounds did you allow? | — | |
| **Task 5** — ADK install → agent → first successful tool call | 30 min | |
| Task 4 — context-set test loop | 15 min | |

For the Terraform number, run it as `time terraform apply -auto-approve` — the handoff asks for Lab
2's provisioning wall-clock **as a delta against Lab 1's**, and Lab 1's is 542 s in a virgin project.
