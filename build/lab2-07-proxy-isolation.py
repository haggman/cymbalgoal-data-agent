#!/usr/bin/env python3
"""
CymbalGoal Lab 2 — lab2-07: WHY did the proxy model refuse, and can Task 6 be saved?

WHERE: Cloud Shell, after lab2-05.
RUN:   python3 lab2-07-proxy-isolation.py 2>&1 | tee ~/lab2-proxy.log
TIME:  ~10-15 min worst case, hard-bounded (see the cost guard below).

WHAT HAPPENED IN lab2-05. Every EXECUTE produced:

    WARNING: Cost Optimized AI Function is unavailable. Expect reduced performance.

and the proxy path was 18.5 s against the LLM path's 17.9 s — a speedup of 1.0x.
The feature is enabled, the extension is 1.6, the flag reads `on`, and it still
declined. So the question is not "does PG 18 support it" but "what did we do
that it would not accept."

FOUR CANDIDATE CAUSES, and this script isolates them.

  H1  TOO FEW ROWS, and/or a TEMP TABLE.  ← the leading hypothesis, and it is
      lab2-05's fault, not the product's. A proxy model is a logistic regression
      trained on a SAMPLE of the table, and the sampling knobs are visible:
          google_ml_integration.sampling_percentage = 5
          google_ml_integration.max_sampling_count  = 1000
      Five percent of a 50-row temp table is two or three rows. You cannot train
      anything on that. lab2-05 kept N small to control LLM cost — correct for
      the baseline, fatal for the proxy. Google's own troubleshooting page hints
      at the same thing: "accuracy is generally less than 95% for proxy models on
      smaller tables."

  H2  VECTOR(3072) vs real[].  pg_proc gives the proxy overload as
          ai.if(prompt text, embedding real[]) -> boolean
      NOT `vector`. Our column is VECTOR(3072). PREPARE succeeded, so a cast
      happened — but a 3072-wide feature vector on a small sample may simply not
      converge. Every published example is 768.

  H3  runtime_accuracy_check is OFF here (default), though the docs describe it
      as on. Worth one run with it forced on.

  H4  Nothing works and Task 6 pivots to enable_ai_function_acceleration, which
      lab2-05 proved EXISTS on PG 18 and is currently off. Docs call it PG 17
      only; they are wrong. It needs no embeddings.

⚠️ COST GUARD — READ BEFORE EDITING.
If the proxy declines, every row becomes a real LLM call at ~0.36 s/row measured.
Over the full 13,439-row players table that is roughly 80 minutes and a real
bill. EVERY test here runs under a server-side statement_timeout, so a fallback
is capped at a couple of hundred rows instead of running away. A TIMEOUT IS A
RESULT — it means "fell back" — not a failure of the script. Do not remove the
timeout to "let it finish."
"""

import sys
import time

DB = "cymbalgoal"
TIMEOUT_S = 120           # hard cap per test. A fallback hits this and stops.
SIZES = [200, 1000, 5000]  # persistent tables, climbing until it trains

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
    """⚠️ Match loosely. The REAL warning text is
       'Cost Optimized AI Function is unavailable. Expect reduced performance.'
       The DOCS say 'Reduced performance expected. Optimized AI function is not
       available'. Different word order and capitalisation — an exact matcher
       built from the docs reports a clean run while the warning sits in the
       output. That is exactly what lab2-05 did on its first pass.
    """
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


def timed(sql, label):
    """Run under the statement timeout. Returns (value, seconds, notices, timed_out)."""
    cur = CONN.cursor()
    t0 = time.time()
    try:
        cur.execute(sql)
        val = cur.fetchone()[0]
        dt = time.time() - t0
        cur.close()
        ns = notices(show=True)
        print(f"--- {label}: {val} true in {dt:.1f}s", flush=True)
        return val, dt, ns, False
    except Exception as e:                                           # noqa: BLE001
        dt = time.time() - t0
        try:
            cur.close()
        except Exception:                                            # noqa: BLE001
            pass
        ns = notices(show=True)
        msg = str(e)
        to = "timeout" in msg.lower() or "canceling statement" in msg.lower()
        print(f"--- {label}: {'TIMED OUT' if to else 'ERROR'} after {dt:.1f}s", flush=True)
        if not to:
            print(f"    {type(e).__name__}: {msg[:300]}", flush=True)
        return None, dt, ns, to


def proxy_test(table, embed_expr, label):
    """PREPARE + two EXECUTEs on one connection. Second run is the real signal."""
    run("DEALLOCATE ALL")
    stmt = (f"PREPARE p AS SELECT count(*) FROM {table} t "
            f"WHERE ai.if('{PROMPT}' || t.profile_text, {embed_expr})")
    try:
        ns = run(stmt)
        if ns:
            for n in ns:
                print(f"    !! {n}", flush=True)
    except Exception as e:                                           # noqa: BLE001
        verdict(f"🔴 {label}: PREPARE failed — {type(e).__name__}: {str(e)[:200]}")
        return None
    results = []
    for i in (1, 2):
        val, dt, ns, to = timed("EXECUTE p", f"{label} EXECUTE #{i}")
        results.append((val, dt, fell_back(ns) or to, to))
    _, dt2, fb2, to2 = results[-1]
    if to2:
        verdict(f"🔴 {label}: TIMED OUT at {TIMEOUT_S}s on the second run — "
                "that is a fallback running at LLM speed. NOT trained.")
    elif fb2:
        verdict(f"🔴 {label}: warning still fired on the second run. NOT trained.")
    else:
        verdict(f"✅ {label}: NO fallback warning on run 2, {dt2:.1f}s. TRAINED.")
    return results


def main():
    global CONN
    CONN = connect()
    run(f"SET statement_timeout = '{TIMEOUT_S}s'")
    print(f"statement_timeout = {TIMEOUT_S}s (cost guard — a timeout IS a result)")

    # -----------------------------------------------------------------------
    banner("H1 — row count and real-vs-temp table")
    # -----------------------------------------------------------------------
    # Persistent tables, not TEMP. Climbing sizes. If the warning disappears at
    # some size, H1 is confirmed and Task 6 simply has to run against a real
    # table of realistic size — which is also the honest way to demo a feature
    # whose whole pitch is million-row queries.
    for n in SIZES:
        t = f"px_{n}"
        run(f"DROP TABLE IF EXISTS {t}")
        run(f"""CREATE TABLE {t} AS
                  SELECT player_id, player_name, main_position,
                         profile_text, profile_embedding
                  FROM players
                  WHERE profile_text IS NOT NULL AND profile_embedding IS NOT NULL
                  ORDER BY player_id LIMIT {n}""")
        print(f"\n>>> {t}: {n} rows, persistent, VECTOR(3072)")
        proxy_test(t, "t.profile_embedding", f"{t}/vector")

    # -----------------------------------------------------------------------
    banner("H1b — the real players table, 13,439 rows")
    # -----------------------------------------------------------------------
    # The size the feature is actually meant for. Bounded by the timeout: if it
    # declines, this stops at ~330 rows of LLM calls rather than 13,439.
    print(">>> players, 13,439 rows. If this trains, Task 6 runs against the")
    print(">>> real table and the LLM baseline stays a small sample.")
    proxy_test("players", "t.profile_embedding",
               "players/vector")

    # -----------------------------------------------------------------------
    banner("H2 — dimensionality: 3072 vs 768")
    # -----------------------------------------------------------------------
    # pg_proc says the proxy overload takes real[], and every published example
    # is 768-wide. ai.text_embedding() takes an out_dimensions argument — which
    # incidentally CORRECTS P-25's claim that in-SQL embedding cannot be
    # dimension-reduced. So a narrow column is computable in-database.
    #
    # Built on the largest size that did NOT train above, so the only variable
    # changing is width.
    t = f"px_{SIZES[-1]}"
    print(f">>> adding a 768-dim column to {t} via ai.text_embedding(out_dimensions => 768)")
    try:
        run(f"ALTER TABLE {t} ADD COLUMN IF NOT EXISTS emb768 real[]")
        run("SET statement_timeout = '600s'")   # embedding N rows is not an LLM-per-row cost
        t0 = time.time()
        run(f"""UPDATE {t}
                   SET emb768 = ai.text_embedding('gemini-embedding-001', profile_text, 768)""")
        print(f"    embedded in {time.time()-t0:.1f}s")
        run(f"SET statement_timeout = '{TIMEOUT_S}s'")
        proxy_test(t, "t.emb768", f"{t}/768")
    except Exception as e:                                           # noqa: BLE001
        run(f"SET statement_timeout = '{TIMEOUT_S}s'")
        verdict(f"H2 could not be tested — {type(e).__name__}: {str(e)[:250]}")
        print("    If ai.text_embedding rejected out_dimensions, record the exact error:")
        print("    it would mean the 768 fallback for Task 6 is not available in SQL.")

    # -----------------------------------------------------------------------
    banner("H3 — runtime_accuracy_check")
    # -----------------------------------------------------------------------
    # Reads `off` on this instance though the docs describe it as on by default.
    # Forcing it on is one line and rules the knob in or out.
    try:
        run("SET google_ml_integration.runtime_accuracy_check = on")
        print(">>> runtime_accuracy_check forced on")
        proxy_test(f"px_{SIZES[-1]}", "t.profile_embedding",
                   f"px_{SIZES[-1]}/accuracy-check-on")
        run("SET google_ml_integration.runtime_accuracy_check = off")
    except Exception as e:                                           # noqa: BLE001
        verdict(f"H3 not testable at session level — {type(e).__name__}: {str(e)[:200]}")
        print("    If this is 'permission denied to set parameter', it is an")
        print("    instance-level database_flag and belongs in Terraform.")

    # -----------------------------------------------------------------------
    banner("H4 — the fallback feature: enable_ai_function_acceleration")
    # -----------------------------------------------------------------------
    # lab2-05 proved this EXISTS on PG 18 and is off, which corrects the docs'
    # "PostgreSQL 17 only". It batches LLM calls rather than replacing them, it
    # covers ai.if in WHERE and ai.rank in ORDER BY, and it needs NO embeddings.
    #
    # If H1-H3 all fail, THIS becomes Task 6's second half and S-17 gets
    # re-decided a second time — on measured grounds rather than a blog post.
    try:
        run("SET google_ml_integration.enable_ai_function_acceleration = on")
        print(">>> acceleration on. ai.if in WHERE, no embedding argument.")
        val, dt, ns, to = timed(
            f"SELECT count(*) FROM px_{SIZES[0]} t "
            f"WHERE ai.if('{PROMPT}' || t.profile_text)",
            f"accelerated/{SIZES[0]}")
        if to:
            verdict("acceleration: timed out — no better than the plain LLM path")
        else:
            verdict(f"acceleration: {SIZES[0]} rows in {dt:.1f}s = {dt/SIZES[0]:.3f}s/row. "
                    f"Compare with the 0.36 s/row plain LLM rate from lab2-05.")
        run("SET google_ml_integration.enable_ai_function_acceleration = off")
    except Exception as e:                                           # noqa: BLE001
        verdict(f"H4 not testable at session level — {type(e).__name__}: {str(e)[:200]}")
        print("    Likely an instance-level flag. Add it to Terraform and re-run.")

    # -----------------------------------------------------------------------
    banner("Cleanup")
    # -----------------------------------------------------------------------
    for n in SIZES:
        run(f"DROP TABLE IF EXISTS px_{n}")
    print("dropped px_* tables")
    print("\nDone. The decisive lines are the ✅/🔴 VERDICTs in H1 and H1b.")


if __name__ == "__main__":
    main()
