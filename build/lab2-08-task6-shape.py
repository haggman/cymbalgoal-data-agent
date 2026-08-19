#!/bin/sh
# ⚠️ POLYGLOT HEADER — valid sh AND valid Python. `bash`, `sh`, `./` and
# `python3` all work. See lab2-05 for why.
''''exec python3 "$0" "$@" # '''
"""
CymbalGoal Lab 2 — lab2-08: pin down the shape of Task 6.

WHERE: Cloud Shell, after lab2-07.
RUN:   bash lab2-08-task6-shape.py 2>&1 | tee ~/lab2-task6.log
TIME:  ~6-8 min, bounded.

lab2-07 answered the existential question: PROXY MODELS WORK ON PG 18 AT
VECTOR(3072). Every table size trained. This script answers the three questions
left before Task 6 can actually be written.

WHAT lab2-07 SHOWED, and why it matters here:

    px_200      EXECUTE #1  66.8 s (warning)   EXECUTE #2  0.0 s  ✅
    px_1000     EXECUTE #1  timed out          EXECUTE #2  0.1 s  ✅
    px_5000     EXECUTE #1  timed out          EXECUTE #2  0.2 s  ✅
    players     EXECUTE #1  timed out          EXECUTE #2  0.4 s  ✅   13,439 rows

Read the middle column again. **EXECUTE #1 TIMED OUT AND THE MODEL STILL
TRAINED.** Training is asynchronous — kicked off by PREPARE, running in the
background — so cancelling the first query does not cancel the training. That is
the difference between a Task 6 a student can finish and one that needs eighty
minutes of LLM calls.

THE THREE QUESTIONS:

  Q1  Can we replace the slow throwaway EXECUTE with a WAIT? If PREPARE + sleep
      gives a fast FIRST execute, Task 6 becomes: prepare, talk for a minute,
      run once, marvel. If not, the lab has to stage a deliberately slow run and
      explain it — which is a worse but still workable story.

  Q2  Is the proxy ACCURATE, not merely fast? players returned 1,001 true against
      1,024 real goalkeepers, which is suggestive but not proof: a model can hit
      the right COUNT with the wrong ROWS. This builds the actual confusion
      matrix against main_position.

  Q3  Head-to-head on ONE table: LLM vs acceleration vs proxy. lab2-07 measured
      the three on different tables, which is not a comparison. Task 6's story is
      a trade-off between speed, cost, accuracy and setup, and it needs three
      numbers taken the same way.

⚠️ COST GUARD. The LLM leg is capped at LLM_N rows and everything runs under a
statement timeout. Do not raise LLM_N to "be thorough" — it is a bill.
"""

import sys
import time

DB = "cymbalgoal"
TABLE = "px_bench"
TABLE_N = 5000        # big enough to train reliably (200 was the observed floor)
LLM_N = 50            # the LLM leg only. 50 x ~0.36 s/row is already ~18 s.
TIMEOUT_S = 180
WAIT_S = 150          # Q1: how long to wait after PREPARE before the first EXECUTE

PROMPT = "Is this player a goalkeeper? Profile: "
CONN = None


def sh(cmd):
    import subprocess
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def banner(t):
    print(f"\n{'#' * 70}\n### {t}\n{'#' * 70}", flush=True)


def verdict(t):
    print(f"VERDICT: {t}", flush=True)


def connect():
    from google.cloud.alloydb.connector import Connector, IPTypes
    import json
    project = sh("gcloud config get-value project")
    user = sh("gcloud config get-value account")
    clusters = json.loads(sh("gcloud alloydb clusters list --format=json") or "[]")
    if not clusters:
        sys.exit("FATAL: no AlloyDB cluster found.")
    name = clusters[0]["name"]
    cluster, region = name.split("/")[-1], name.split("/locations/")[1].split("/")[0]
    inst = json.loads(sh(f"gcloud alloydb instances list --cluster={cluster} "
                         f"--region={region} --format=json") or "[]")
    primary = [i for i in inst if i.get("instanceType") == "PRIMARY"][0]["name"].split("/")[-1]
    uri = f"projects/{project}/locations/{region}/clusters/{cluster}/instances/{primary}"
    print(f"connecting to {uri} as {user}")
    c = Connector().connect(uri, "pg8000", user=user, db=DB,
                            enable_iam_auth=True, ip_type=IPTypes.PUBLIC)
    c.autocommit = True
    return c


def notices(show=True):
    queued = list(getattr(CONN, "notices", None) or [])
    try:
        CONN.notices.clear()
    except Exception:                                                # noqa: BLE001
        pass
    out = []
    for n in queued:
        if isinstance(n, dict):
            out.append(f"{n.get(b'S', b'').decode(errors='replace')}: "
                       f"{n.get(b'M', b'').decode(errors='replace')}")
        else:
            out.append(str(n))
    if show:
        for line in out:
            print(f"    !! {line}", flush=True)
    return out


def fell_back(ns):
    for n in ns:
        low = n.lower()
        if "optimized ai function" in low and ("unavailable" in low or "not available" in low):
            return True
        if "reduced performance" in low:
            return True
    return False


def run(sql):
    cur = CONN.cursor()
    cur.execute(sql)
    cur.close()
    return notices(show=False)


def timed(sql, label, show=True):
    cur = CONN.cursor()
    t0 = time.time()
    try:
        cur.execute(sql)
        rows = cur.fetchall()
        dt = time.time() - t0
        cur.close()
        ns = notices(show=show)
        print(f"--- {label}: {dt:.2f}s", flush=True)
        return rows, dt, ns, False
    except Exception as e:                                           # noqa: BLE001
        dt = time.time() - t0
        try:
            cur.close()
        except Exception:                                            # noqa: BLE001
            pass
        ns = notices(show=show)
        msg = str(e)
        to = "timeout" in msg.lower() or "canceling statement" in msg.lower()
        print(f"--- {label}: {'TIMED OUT' if to else 'ERROR'} after {dt:.2f}s", flush=True)
        if not to:
            print(f"    {type(e).__name__}: {msg[:300]}", flush=True)
        return None, dt, ns, to


def main():
    global CONN
    CONN = connect()
    run(f"SET statement_timeout = '{TIMEOUT_S}s'")

    print(f"building {TABLE} ({TABLE_N} rows)...")
    run(f"DROP TABLE IF EXISTS {TABLE}")
    run(f"""CREATE TABLE {TABLE} AS
              SELECT player_id, player_name, main_position,
                     profile_text, profile_embedding
              FROM players
              WHERE profile_text IS NOT NULL AND profile_embedding IS NOT NULL
              ORDER BY player_id LIMIT {TABLE_N}""")
    truth = run(f"SELECT 1")  # noqa: F841
    cur = CONN.cursor()
    cur.execute(f"SELECT count(*) FROM {TABLE} WHERE main_position = 'Goalkeeper'")
    gk_actual = cur.fetchone()[0]
    cur.close()
    notices(show=False)
    print(f"  ground truth: {gk_actual} goalkeepers in {TABLE_N} rows")

    # -----------------------------------------------------------------------
    banner("Q1 — can a WAIT replace the slow throwaway run?")
    # -----------------------------------------------------------------------
    # If yes, Task 6 is: PREPARE, explain what is happening for a minute or two,
    # then run ONCE and it is instant. If no, the lab must stage a slow run and
    # explain the warning, which is a worse story but still teachable.
    run("DEALLOCATE ALL")
    run(f"""PREPARE gk AS SELECT count(*) FROM {TABLE} t
              WHERE ai.if('{PROMPT}' || t.profile_text, t.profile_embedding)""")
    print(f"PREPARE issued. Training is ASYNCHRONOUS — waiting {WAIT_S}s without "
          f"executing anything.")
    for remaining in range(WAIT_S, 0, -30):
        print(f"    {remaining}s...", flush=True)
        time.sleep(min(30, remaining))

    rows, dt_first, ns, to = timed("EXECUTE gk", "first EXECUTE after the wait")
    if to:
        verdict(f"🔴 Q1: still slow after {WAIT_S}s — training needs longer, or needs "
                "a query to drive it. Task 6 must stage a slow run.")
    elif fell_back(ns):
        verdict(f"🔴 Q1: warning still fired after {WAIT_S}s. Not trained by waiting alone.")
    else:
        verdict(f"✅ Q1: FIRST execute took {dt_first:.2f}s with no warning after a "
                f"{WAIT_S}s wait. Task 6 can be: PREPARE -> talk -> run once -> instant.")

    # -----------------------------------------------------------------------
    banner("Q2 — accuracy, not just speed")
    # -----------------------------------------------------------------------
    # ⚠️ A model can hit the right COUNT with the wrong ROWS. players returned
    # 1,001 against 1,024 actual goalkeepers, which proves nothing on its own.
    # Build the real confusion matrix.
    rows, dt, ns, to = timed(f"""
        SELECT
          count(*) FILTER (WHERE pred AND main_position = 'Goalkeeper')       AS true_pos,
          count(*) FILTER (WHERE pred AND main_position <> 'Goalkeeper')      AS false_pos,
          count(*) FILTER (WHERE NOT pred AND main_position = 'Goalkeeper')   AS false_neg,
          count(*) FILTER (WHERE NOT pred AND main_position <> 'Goalkeeper')  AS true_neg
        FROM (
          SELECT t.main_position,
                 ai.if('{PROMPT}' || t.profile_text, t.profile_embedding) AS pred
          FROM {TABLE} t
        ) s""", "confusion matrix")
    if rows:
        tp, fp, fn, tn = rows[0]
        total = tp + fp + fn + tn
        prec = tp / (tp + fp) if (tp + fp) else 0
        rec = tp / (tp + fn) if (tp + fn) else 0
        print(f"    true positives  {tp}\n    false positives {fp}")
        print(f"    false negatives {fn}\n    true negatives  {tn}")
        verdict(f"accuracy {(tp+tn)/total:.4f} · precision {prec:.4f} · recall {rec:.4f} "
                f"over {total} rows")
        print("    >>> Google's troubleshooting page says proxy accuracy is 'generally")
        print("    >>> less than 95%'. Ours is measured above — quote OURS (S-37).")
        print("    >>> The false positives and negatives ARE the lesson: this is a")
        print("    >>> cheap approximation of an LLM, and Task 6 should say so plainly.")

    # -----------------------------------------------------------------------
    banner("Q3 — head to head, ONE table, three ways")
    # -----------------------------------------------------------------------
    # lab2-07 measured the three approaches on three different tables, which is
    # not a comparison. Task 6's story is a trade-off between speed, cost,
    # accuracy and setup — it needs numbers taken the same way.
    run(f"DROP TABLE IF EXISTS {TABLE}_llm")
    run(f"CREATE TABLE {TABLE}_llm AS SELECT * FROM {TABLE} LIMIT {LLM_N}")

    print(f"\n1. PLAIN LLM — {LLM_N} rows, no acceleration, no embedding")
    run("SET google_ml_integration.enable_ai_function_acceleration = off")
    _, dt_llm, _, _ = timed(
        f"SELECT count(*) FROM {TABLE}_llm t WHERE ai.if('{PROMPT}' || t.profile_text)",
        "plain LLM")

    print(f"\n2. ACCELERATION — same {LLM_N} rows, no embedding, no training")
    run("SET google_ml_integration.enable_ai_function_acceleration = on")
    _, dt_acc, _, _ = timed(
        f"SELECT count(*) FROM {TABLE}_llm t WHERE ai.if('{PROMPT}' || t.profile_text)",
        "accelerated")
    run("SET google_ml_integration.enable_ai_function_acceleration = off")

    print(f"\n3. PROXY — the SAME {LLM_N} rows, already-trained model")
    run("DEALLOCATE ALL")
    run(f"""PREPARE gk_small AS SELECT count(*) FROM {TABLE}_llm t
              WHERE ai.if('{PROMPT}' || t.profile_text, t.profile_embedding)""")
    timed("EXECUTE gk_small", "proxy warm-up (may train)", show=False)
    _, dt_proxy, ns, _ = timed("EXECUTE gk_small", "proxy")

    print()
    if dt_llm and dt_acc:
        verdict(f"acceleration vs plain LLM: {dt_llm/max(dt_acc,0.001):.0f}x "
                f"({dt_llm:.2f}s -> {dt_acc:.2f}s), NO embeddings, NO training step")
    if dt_llm and dt_proxy:
        verdict(f"proxy vs plain LLM: {dt_llm/max(dt_proxy,0.001):.0f}x "
                f"({dt_llm:.2f}s -> {dt_proxy:.2f}s), after a one-time training cost")
    print("\n    >>> These three numbers are Task 6. Speed is not the only axis —")
    print("    >>> acceleration needs no embeddings and no training but still calls")
    print("    >>> the LLM for every row; the proxy replaces the calls outright but")
    print("    >>> needs an embedding column and pays training once, and it only")
    print("    >>> APPROXIMATES the LLM. Q2 is what that approximation costs you.")

    banner("Cleanup")
    run(f"DROP TABLE IF EXISTS {TABLE}")
    run(f"DROP TABLE IF EXISTS {TABLE}_llm")
    print("done")


if __name__ == "__main__":
    main()
