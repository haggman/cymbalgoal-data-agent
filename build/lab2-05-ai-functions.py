#!/usr/bin/env python3
"""
CymbalGoal Lab 2 — Tier 2: the ai.* family and proxy models on PostgreSQL 18.

WHERE: Cloud Shell.
RUN:   python3 lab2-05-ai-functions.py 2>&1 | tee ~/lab2-ai.log
TIME:  ~3-5 min. Section 4a makes 50 real LLM calls and is the slow part.

⚠️ WHY THIS IS PYTHON AND NOT THE .sql FILE IT REPLACES.
The .sql version could not actually be run:
  * `psql` from Cloud Shell needs authorized networks on the instance, and this
    lab deliberately configures none — IAM plus the connector's mTLS is the
    access path (same reason the Task 0 loader is Python).
  * Pasting it into AlloyDB Studio fails too: Studio is a SQL editor and does
    not understand psql meta-commands (\\echo, \\timing, \\d).
So it becomes a runner over the connection the loader already proved.

⚠️ AND ONE THING ONLY PYTHON GETS RIGHT HERE. Proxy-model fallback is reported
as a PostgreSQL NOTICE/WARNING — "Reduced performance expected. Optimized AI
function is not available" — and that string is the ONLY observability the
feature has. There is no per-row indication. pg8000 queues notices on the
connection as dicts with BYTE keys, so they must be drained and decoded or the
single most important signal in this script is invisible. Section 4 lives or
dies on it.

⚠️ PREPARE/EXECUTE must run on the SAME CONNECTION. One connection is used
throughout, deliberately — do not "improve" this by reconnecting per step.
"""

import sys
import time

import google.auth  # noqa: F401  (import proves ADC resolves before we start)

DB = "cymbalgoal"

# Keep the LLM-path sample small. At one model call per row this is real money
# and real minutes; 50 is enough for a per-row rate, and the rate extrapolates.
BENCH_N = 50


def sh(cmd):
    import subprocess
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def banner(t):
    print(f"\n{'#' * 70}\n### {t}\n{'#' * 70}", flush=True)


def verdict(t):
    print(f"VERDICT: {t}", flush=True)


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
def connect():
    from google.cloud.alloydb.connector import Connector, IPTypes

    project = sh("gcloud config get-value project")
    user = sh("gcloud config get-value account")
    import json
    clusters = json.loads(sh("gcloud alloydb clusters list --format=json") or "[]")
    if not clusters:
        sys.exit("FATAL: no AlloyDB cluster found.")
    name = clusters[0]["name"]
    cluster, region = name.split("/")[-1], name.split("/locations/")[1].split("/")[0]
    instances = json.loads(sh(
        f"gcloud alloydb instances list --cluster={cluster} --region={region} --format=json") or "[]")
    primary = [i for i in instances if i.get("instanceType") == "PRIMARY"][0]["name"].split("/")[-1]
    uri = f"projects/{project}/locations/{region}/clusters/{cluster}/instances/{primary}"

    print(f"connecting to {uri} as {user}")
    c = Connector().connect(uri, "pg8000", user=user, db=DB,
                            enable_iam_auth=True, ip_type=IPTypes.PUBLIC)
    c.autocommit = True
    return c


CONN = None


def notices(show=True):
    """Drain and decode queued NOTICEs. ALWAYS drain, even when not showing.

    pg8000 accumulates notices on the connection until something clears them, so
    skipping the drain means the next step that looks dumps everything that came
    before it. Keys are bytes: {b'S': b'NOTICE', b'M': b'...'}.
    """
    queued = list(getattr(CONN, "notices", None) or [])
    try:
        CONN.notices.clear()
    except Exception:                                                # noqa: BLE001
        pass
    out = []
    for n in queued:
        if isinstance(n, dict):
            sev = n.get(b"S", b"").decode(errors="replace")
            msg = n.get(b"M", b"").decode(errors="replace")
            out.append(f"{sev}: {msg}")
        else:
            out.append(str(n))
    if show:
        for line in out:
            print(f"    !! {line}", flush=True)
    return out


# ⚠️ THE ACTUAL WARNING TEXT, MEASURED 2026-08-19 — it is NOT what the docs say.
#   docs:     "Reduced performance expected. Optimized AI function is not available"
#   reality:  "Cost Optimized AI Function is unavailable. Expect reduced performance."
# Different word order, different capitalisation. An exact-substring matcher built
# from the docs silently reports "no fallback" while the warning is right there in
# the output — which is exactly what happened on the first run. Match loosely.
def _fell_back(notice_lines):
    for n in notice_lines:
        low = n.lower()
        if "cost optimized ai function" in low and "unavailable" in low:
            return True
        if "optimized ai function" in low and ("not available" in low or "unavailable" in low):
            return True
        if "reduced performance" in low:
            return True
    return False


def run(sql, show_notices=False):
    cur = CONN.cursor()
    cur.execute(sql)
    cur.close()
    if show_notices:
        return notices()
    notices(show=False)
    return []


def q(sql, label=None, show_notices=False, timeit=False):
    """Execute and print rows. Returns (rows, seconds, notice_lines)."""
    cur = CONN.cursor()
    t0 = time.time()
    cur.execute(sql)
    try:
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description] if cur.description else []
    except Exception:                                                # noqa: BLE001
        rows, cols = [], []
    dt = time.time() - t0
    cur.close()
    ns = notices(show=show_notices)

    if label:
        print(f"\n--- {label}" + (f"   [{dt:.2f}s]" if timeit else ""), flush=True)
    if cols:
        print("    " + " | ".join(str(c) for c in cols), flush=True)
    for r in rows[:40]:
        print("    " + " | ".join("NULL" if v is None else str(v)[:70] for v in r), flush=True)
    if len(rows) > 40:
        print(f"    ... {len(rows)-40} more rows", flush=True)
    return rows, dt, ns


# ---------------------------------------------------------------------------
def main():
    global CONN
    CONN = connect()

    # -----------------------------------------------------------------------
    banner("1. Versions and flags — the floor everything else depends on")
    # -----------------------------------------------------------------------
    q("SELECT version()", "PostgreSQL")
    rows, _, _ = q("""SELECT extname, extversion FROM pg_extension
                      WHERE extname IN ('google_ml_integration','vector',
                                        'alloydb_scann','pg_textsearch')
                      ORDER BY extname""", "Extensions")
    mlver = dict(rows).get("google_ml_integration")
    print()
    if mlver:
        parts = tuple(int(x) for x in str(mlver).split("."))
        if parts >= (1, 5, 8):
            verdict(f"google_ml_integration {mlver} — clears the 1.5.8 proxy-model floor")
        else:
            verdict(f"🔴 google_ml_integration {mlver} is BELOW 1.5.8 — proxy models "
                    "unavailable regardless of the flag. Task 6's second half needs rescoping.")

    rows, _, _ = q("""SELECT name, setting, source FROM pg_settings
                      WHERE name LIKE 'google_ml_integration%' ORDER BY name""",
                   "google_ml_integration settings")
    flags = {r[0]: r[1] for r in rows}
    cost_opt = flags.get("google_ml_integration.enable_cost_optimized_ai_functions")
    if cost_opt == "on":
        verdict("enable_cost_optimized_ai_functions = on")
    else:
        verdict(f"🔴 enable_cost_optimized_ai_functions reads '{cost_opt}' — Terraform set it "
                "as an instance flag; if it is not on, the flag name changed or the instance "
                "did not take it. STOP and fix Terraform.")

    # The sibling feature. Documented PG 17 only — if it is absent here, say so
    # rather than implying students have a choice on PG 18.
    if "google_ml_integration.enable_ai_function_acceleration" in flags:
        verdict("enable_ai_function_acceleration EXISTS on PG 18 — the contrast sentence "
                "in Task 6 can present it as a real alternative")
    else:
        verdict("enable_ai_function_acceleration is ABSENT on PG 18 — Task 6's contrast "
                "sentence must say so, not imply a choice")

    # -----------------------------------------------------------------------
    banner("2. The real ai.* inventory, from pg_proc (S-37)")
    # -----------------------------------------------------------------------
    # Note ai.if in particular: it has BOTH a (prompt, model_id) overload and a
    # (prompt, embedding) proxy overload. Passing all three gives
    #   ERROR: function ai.if(text, vector, unknown) does not exist
    # which is a confusing message for "you mixed the two forms".
    q("""SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
                pg_get_function_result(p.oid) AS returns
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ai' ORDER BY p.proname, args""", "ai.* functions")

    # -----------------------------------------------------------------------
    banner("3. Registered models")
    # -----------------------------------------------------------------------
    # model_request_url is the tell for the backing service: semantic-ranker-*
    # point at discoveryengine, which is WHY roles/aiplatform.user is not enough
    # for ai.rank() and why roles/discoveryengine.viewer is in the Terraform.
    q("""SELECT model_id, model_type, model_provider, model_request_url
         FROM google_ml.model_info_view ORDER BY model_type, model_id""", "model_info_view")

    # -----------------------------------------------------------------------
    banner("4. 🔴 PROXY MODELS ON PG 18 — the decisive test")
    # -----------------------------------------------------------------------
    # The story is a >100x cost claim, and it only holds if the predicate is
    # LEARNABLE from profile text: a proxy model is a logistic regression over
    # the embedding, so it can only learn a boundary the embedding separates.
    #   "is this player a goalkeeper?" -> should converge
    #   "is this player underrated?"   -> should not
    #
    # ⚠️ Our embedding is VECTOR(3072). Every published example is VECTOR(768).
    # 3072 is 4x the feature width on the same training sample, which could push
    # the accuracy check into permanent LLM fallback. If it does, Task 6 needs a
    # second 768-dim column — a Terraform AND Task-0 change.
    print("\nBuilding a 50-row bench slice...")
    run(f"""CREATE TEMP TABLE _bench AS
              SELECT player_id, player_name, profile_text, profile_embedding
              FROM players
              WHERE profile_text IS NOT NULL AND profile_embedding IS NOT NULL
              ORDER BY player_id LIMIT {BENCH_N}""")

    print(f"\n4a. LLM PATH — ai.if() with NO embedding, {BENCH_N} rows. This makes "
          f"{BENCH_N} real model calls and is the slow step.")
    try:
        rows, llm_dt, _ = q(
            "SELECT count(*) AS llm_true FROM _bench b "
            "WHERE ai.if('Is this player a goalkeeper? Profile: ' || b.profile_text)",
            "LLM path", show_notices=True, timeit=True)
        llm_true = rows[0][0] if rows else None
        verdict(f"LLM path: {llm_dt:.1f}s for {BENCH_N} rows "
                f"= {llm_dt/BENCH_N:.2f}s/row, {llm_true} true")
    except Exception as e:                                           # noqa: BLE001
        llm_dt, llm_true = None, None
        verdict(f"🔴 LLM path FAILED: {type(e).__name__}: {e}")
        notices()

    print("\n4b. PROXY PATH — same predicate, same rows, embedding as arg 2.")
    print("    PREPARE triggers ASYNCHRONOUS training; the verdict is what EXECUTE does.")
    proxy_ok = True
    try:
        run("DEALLOCATE ALL")
        run(f"""PREPARE gk_proxy AS
                  SELECT count(*) FROM _bench b
                  WHERE ai.if('Is this player a goalkeeper? Profile: ' || b.profile_text,
                              b.profile_embedding)""", show_notices=True)
    except Exception as e:                                           # noqa: BLE001
        proxy_ok = False
        verdict(f"🔴 PREPARE FAILED: {type(e).__name__}: {e}")
        print("    If this says ai.if(text, vector) does not exist, proxy models are NOT "
              "available on PG 18 and Task 6's second half must be rescoped.")

    if proxy_ok:
        for i in (1, 2):
            # The SECOND run is the one that matters: a working proxy model gets
            # dramatically faster once trained. One that silently fell back to
            # the LLM does not. That difference IS the demonstration.
            try:
                rows, dt, ns = q("EXECUTE gk_proxy", f"EXECUTE #{i}",
                                 show_notices=True, timeit=True)
                val = rows[0][0] if rows else None
                fell_back = _fell_back(ns)
                verdict(f"EXECUTE #{i}: {dt:.1f}s, {val} true"
                        + ("  🔴 FELL BACK TO LLM" if fell_back else ""))
                if i == 2 and llm_dt and not fell_back:
                    verdict(f"SPEEDUP vs LLM path: {llm_dt/max(dt, 0.001):.1f}x "
                            f"({llm_dt:.1f}s -> {dt:.1f}s). THIS IS OUR NUMBER, "
                            "not Google's 100x. Quote this one (S-37).")
            except Exception as e:                                   # noqa: BLE001
                verdict(f"🔴 EXECUTE #{i} FAILED: {type(e).__name__}: {e}")

    print("\n4c. ACCURACY — a proxy that says yes to everything is fast and wrong.")
    # ⚠️ DISCOVER the ground-truth column, do not guess it. Notes disagree
    # between `position` and `main_position`, and a wrong guess here does not
    # error loudly — it just means the accuracy check silently tests nothing,
    # which is worse than failing. S-37 applies to our own tooling too.
    posrows, _, _ = q("""SELECT column_name FROM information_schema.columns
                         WHERE table_name = 'players' AND table_schema = 'public'
                           AND column_name ILIKE '%position%'
                         ORDER BY ordinal_position""", "position-ish columns on players")
    poscol = posrows[0][0] if posrows else None
    if not poscol:
        verdict("🔴 no position column found on players — cannot score the proxy model. "
                "Run \\d players and tell Claude what the column is actually called.")
    else:
        verdict(f"scoring against players.{poscol}")
        q(f"""SELECT {poscol}, count(*) AS n FROM players
              WHERE profile_text IS NOT NULL GROUP BY {poscol} ORDER BY n DESC""",
          "actual distribution (whole corpus)")
        q(f"""SELECT {poscol}, count(*) AS n FROM players
              WHERE player_id IN (SELECT player_id FROM _bench)
              GROUP BY {poscol} ORDER BY n DESC""",
          f"actual distribution (the {BENCH_N}-row bench)")
    print("\n    >>> Compare the Goalkeeper count above with what 4a/4b returned.")
    print("    >>> If the proxy says most of the bench are goalkeepers, the feature")
    print("    >>> 'worked' and the answer is garbage — which is a BETTER teaching")
    print("    >>> moment than a clean success. Record it either way.")

    print("\n4d. The UNLEARNABLE predicate, as a deliberate contrast.")
    try:
        run("DEALLOCATE ALL")
        run("""PREPARE underrated AS
                 SELECT count(*) FROM _bench b
                 WHERE ai.if('Is this player underrated relative to their market value? '
                             'Profile: ' || b.profile_text, b.profile_embedding)""",
            show_notices=True)
        rows, dt, ns = q("EXECUTE underrated", "underrated", show_notices=True, timeit=True)
        fell_back = _fell_back(ns)
        verdict(f"underrated: {dt:.1f}s, {rows[0][0] if rows else '?'} true"
                + ("  <- fell back, AS EXPECTED and as designed" if fell_back else
                   "  <- did NOT fall back; the contrast is weaker than hoped"))
    except Exception as e:                                           # noqa: BLE001
        verdict(f"underrated predicate failed: {type(e).__name__}: {e}")

    # -----------------------------------------------------------------------
    banner("5. The rest of the ai.* family Task 6 walks — one row each")
    # -----------------------------------------------------------------------
    # Breadth, not volume. A family walk over 13,439 rows is a bill, not a lesson.
    for label, sql in [
        ("ai.generate", "SELECT ai.generate('In one sentence, what kind of player is this? ' "
                        "|| profile_text) FROM players WHERE profile_text IS NOT NULL LIMIT 1"),
        ("ai.summarize", "SELECT ai.summarize(prompt => profile_text) FROM players "
                         "WHERE profile_text IS NOT NULL LIMIT 1"),
        ("ai.analyze_sentiment", "SELECT ai.analyze_sentiment(prompt => profile_text) FROM players "
                                 "WHERE profile_text IS NOT NULL LIMIT 1"),
    ]:
        try:
            q(sql, label, timeit=True)
        except Exception as e:                                       # noqa: BLE001
            verdict(f"🔴 {label} FAILED: {type(e).__name__}: {e}")
            print("    'function does not exist' => extension below floor, or "
                  "enable_preview_ai_functions is off. Both are Terraform-side.")

    # -----------------------------------------------------------------------
    banner("6. Task 2 ammunition — prove the ambiguity is structural")
    # -----------------------------------------------------------------------
    # These are deterministic corpus facts, so unlike anything model-derived they
    # are safe to print verbatim in lab prose (S-37).
    q("SELECT count(*) AS paulinho_rows FROM players WHERE player_name = 'Paulinho'",
      "rows named exactly 'Paulinho'")
    q("""SELECT player_id, player_name, last_season FROM players
         WHERE player_name = 'Paulinho' ORDER BY player_id""", "the Paulinhos")
    q("""SELECT count(*) AS duplicated_names, sum(c) AS rows_involved FROM (
           SELECT player_name, count(*) AS c FROM players
           GROUP BY player_name HAVING count(*) > 1) d""", "corpus-wide duplicate names")
    print("\n    >>> Expect 937 duplicated names across 2,261 rows (P-30).")
    print("    >>> If these differ, the corpus moved and Task 2's numbers need re-deriving.")

    print("\nDone. Record every VERDICT line and the exact text of any !! notice.")


if __name__ == "__main__":
    main()
