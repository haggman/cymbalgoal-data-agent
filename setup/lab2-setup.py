#!/usr/bin/env python3
"""
CymbalGoal Lab 2 (mkt014) — Task 0 provisioning loader.

Brings a freshly-provisioned mkt014 cluster from "empty PostgreSQL 18 instance"
to "13,439 players with profiles, embeddings and ScaNN indexes, Data API on."

WHERE: Cloud Shell. Launched (backgrounded) by lab2-setup.sh in Task 0 while the
       student reads Task 1. Task 1 closes with a row-count check, which is both
       the Lab 1 Task 1.7 convention AND the natural "has the load finished?"
       gate for a self-study student who jumped ahead.

WHY THIS EXISTS AT ALL. Lab 1 did this work in the student's Colab notebook,
because in Lab 1 the load WAS the lesson — CREATE INDEX ... USING scann is a
featured product and burying it in a script would have wasted it. In Lab 2 the
same work is pure scaffolding: none of it is what Google wants showcased, and
all of it stands between the student and QueryData. So it gets scripted.

⚠️ THE LOAD LOGIC BELOW IS A PORT OF LAB 1'S NOTEBOOK TASK 1, NOT A REWRITE.
Every non-obvious line here was paid for once already:

  * COPY, not INSERT — 832,193 appearances is the difference between a minute
    and an afternoon (S-34, measured 79.8 s for ~1.6M rows).
  * The file never lands on disk: `gcloud storage cat` streams it, gzip
    decompresses in flight, pg8000 pushes it into COPY FROM STDIN via stream=.
  * Header rows are DETECTED, not assumed. A header loaded as data becomes one
    corrupt row that passes every count check.
  * Column lists come from manifest.json's column_order, never from positional
    CSV order (P-40) — minus the two pass-2 columns, because column_order
    describes the TABLE and the pass-1 files do not carry them.
  * ScaNN indexes are built AFTER both loads (P-16). Building them first means
    every vector is indexed incrementally on UPDATE — the slow path.
  * The AlloyDB Python Connector with enable_iam_auth reaches the public IP with
    NO authorized networks configured. Do not "simplify" this to psql: Cloud
    Shell's egress IP is dynamic, so psql would force 0.0.0.0/0.

NEW IN LAB 2, and the only genuinely new thing in this file: the Data API PATCH.
"""

import csv
import gzip
import io
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

GCS = os.environ.get("CG_GCS", "gs://class-demo/alloydb-labs/cymbalgoal")
DB_NAME = os.environ.get("CG_DB", "cymbalgoal")

PASS2_COLS = {"profile_text", "profile_embedding"}
ORDER = ["competitions", "clubs", "players", "games",
         "appearances", "game_events", "player_valuations", "transfers"]

# Pinned expectations. These are the corpus's identity, not decoration — a
# silent zero-row load is exactly the failure that survives a happy-path check
# and then breaks Task 2 in front of a room.
EXPECT = {"players": 13439, "clubs": 796, "appearances": 832193}


def log(msg=""):
    print(msg, flush=True)


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------------------
# 0. Discover where we are
# ---------------------------------------------------------------------------
# Find the cluster rather than assuming its name. A hardcoded name is a script
# that works exactly once, in exactly one project.
def discover():
    project = sh("gcloud config get-value project")
    user = sh("gcloud config get-value account")
    if not project or project == "(unset)":
        sys.exit("FATAL: no project set. gcloud config set project YOUR_PROJECT_ID")

    clusters = json.loads(sh("gcloud alloydb clusters list --format=json") or "[]")
    if not clusters:
        sys.exit("FATAL: no AlloyDB cluster in this project. Is provisioning still running?")
    name = clusters[0]["name"]
    cluster = name.split("/")[-1]
    region = name.split("/locations/")[1].split("/")[0]

    instances = json.loads(sh(
        f"gcloud alloydb instances list --cluster={cluster} --region={region} --format=json") or "[]")
    primary = [i for i in instances if i.get("instanceType") == "PRIMARY"]
    if not primary:
        sys.exit(f"FATAL: no PRIMARY instance in cluster {cluster}.")
    instance = primary[0]["name"].split("/")[-1]

    uri = f"projects/{project}/locations/{region}/clusters/{cluster}/instances/{instance}"
    log(f"project   {project}")
    log(f"region    {region}")
    log(f"cluster   {cluster}")
    log(f"instance  {instance}")
    log(f"you       {user}")
    log(f"target    {uri}")
    log()
    return project, user, region, cluster, instance, uri


# ---------------------------------------------------------------------------
# 1. The Data API PATCH — the one thing here that is new in Lab 2
# ---------------------------------------------------------------------------
def enable_data_api(uri, project):
    """Turn on dataApiAccess so Task 5's ADK agent can execute SQL through MCP.

    ⚠️ NO TERRAFORM ATTRIBUTE AND NO GCLOUD FLAG EXISTS. Verified against the
    google and google-beta providers, magic-modules, and both gcloud surfaces.
    Nothing is queued either, so a provider bump will not remove this function.

    ⚠️ THE ENUM IS "ENABLED". Google's prose says ALLOW_DATA_API directly above
    a curl block on the same page that sends ENABLED; the discovery document
    (rev 20260730, identical across v1/v1beta/v1alpha) lists exactly:
        DEFAULT_DATA_API_ENABLED_FOR_GOOGLE_CLOUD_SERVICES | DISABLED | ENABLED

    ⚠️ THE SUBTLETY THAT WILL CONFUSE A LIVE DEBUG. The implicit default already
    grants Data API access to Google-INTERNAL services, which is why AlloyDB
    Studio works with no PATCH at all. This PATCH is what opens executeSql to
    OUR callers. So Task 4 may work without it and Task 5 will not.

    Version order is deliberate: v1 first. Google documents v1alpha, but a
    shipping lab pinned to an alpha endpoint has an expiry date on it, and the
    field is present in the v1 discovery document.
    """
    token = sh("gcloud auth print-access-token")
    body = json.dumps({"dataApiAccess": "ENABLED"}).encode()

    for ver in ("v1", "v1beta", "v1alpha"):
        url = f"https://alloydb.googleapis.com/{ver}/{uri}?updateMask=dataApiAccess"
        req = urllib.request.Request(url, data=body, method="PATCH", headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "X-Goog-User-Project": project,
        })
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                op = json.loads(r.read() or b"{}").get("name", "")
            log(f"  Data API PATCH accepted on /{ver}/")
            if op:
                # instances.patch returns a long-running operation. Poll it, but
                # do NOT make the whole load fail if polling times out — the
                # setting almost certainly landed and Task 5 is 70 minutes away.
                start = time.time()
                for _ in range(60):
                    g = urllib.request.Request(
                        f"https://alloydb.googleapis.com/{ver}/{op}",
                        headers={"Authorization": f"Bearer {token}"})
                    with urllib.request.urlopen(g, timeout=30) as r:
                        d = json.loads(r.read() or b"{}")
                    if d.get("done"):
                        if d.get("error"):
                            log(f"  ⚠️ operation finished WITH ERROR: {d['error']}")
                        else:
                            log(f"  Data API enabled in {time.time()-start:.0f}s")
                        return ver
                    time.sleep(5)
                log("  ⚠️ operation still running after 5 min — continuing anyway")
            return ver
        except urllib.error.HTTPError as e:
            log(f"  /{ver}/ -> HTTP {e.code}: {e.read()[:200].decode(errors='replace')}")
        except Exception as e:                                    # noqa: BLE001
            log(f"  /{ver}/ -> {type(e).__name__}: {e}")

    # Not fatal to the LOAD, but fatal to Task 5. Say so loudly rather than
    # letting a student discover it at minute 70.
    log("  🔴 Data API PATCH FAILED ON ALL VERSIONS.")
    log("     The data will still load and Tasks 1-4 will work.")
    log("     TASK 5 (MCP) WILL NOT. Needs alloydb.instances.update.")
    return None


# ---------------------------------------------------------------------------
# 2. Connect
# ---------------------------------------------------------------------------
def make_session(uri, user):
    from google.cloud.alloydb.connector import Connector, IPTypes

    connector = Connector()
    state = {"conn": None}

    def connect(db=DB_NAME):
        c = connector.connect(
            uri, "pg8000",
            user=user, db=db,
            enable_iam_auth=True,      # no password anywhere
            ip_type=IPTypes.PUBLIC,    # IAM gates access; the connector carries mTLS
        )
        c.autocommit = True
        return c

    def session():
        """Live connection, reconnected if the previous one died.

        The load runs for minutes on a connection that AlloyDB may recycle, so
        a bare `conn` that worked at pass 1 is not guaranteed at pass 2.
        """
        if state["conn"] is None:
            state["conn"] = connect()
            return state["conn"]
        try:
            cur = state["conn"].cursor()
            cur.execute("SELECT 1")
            cur.close()
        except Exception:                                          # noqa: BLE001
            state["conn"] = connect()
        return state["conn"]

    return connect, session


def run(session, sql):
    cur = session().cursor()
    cur.execute(sql)
    cur.close()


def scalar(session, sql):
    cur = session().cursor()
    cur.execute(sql)
    v = cur.fetchone()[0]
    cur.close()
    return v


# ---------------------------------------------------------------------------
# 3. The bulk loader
# ---------------------------------------------------------------------------
def copy_table(session, table, cols, gcs_uri):
    """Stream a gzipped CSV from Cloud Storage straight into `table`."""
    # Peek at row one so a header row is DETECTED rather than assumed.
    peek = subprocess.Popen(["gcloud", "storage", "cat", gcs_uri], stdout=subprocess.PIPE)
    with gzip.GzipFile(fileobj=peek.stdout, mode="rb") as gz:
        first = next(csv.reader(io.TextIOWrapper(gz, encoding="utf-8")))
    peek.stdout.close()
    peek.wait()
    has_header = [c.strip().lower() for c in first] == [c.strip().lower() for c in cols]

    conn = session()
    cur = conn.cursor()
    proc = subprocess.Popen(["gcloud", "storage", "cat", gcs_uri], stdout=subprocess.PIPE)
    try:
        with gzip.GzipFile(fileobj=proc.stdout, mode="rb") as gz:
            cur.execute(
                f'COPY {table} ({", ".join(cols)}) FROM STDIN '
                f'WITH (FORMAT csv, HEADER {"true" if has_header else "false"})',
                stream=gz,
            )
        conn.commit()
    finally:
        cur.close()
        proc.stdout.close()
        proc.wait()


def column_lists():
    manifest = json.loads(sh(f"gcloud storage cat {GCS}/manifest.json"))
    staged = manifest.get("staged_files")
    items = staged.items() if isinstance(staged, dict) else [(f.get("name"), f) for f in staged]
    cols = {}
    for key, meta in items:
        if isinstance(meta, dict) and meta.get("column_order"):
            table = str(key).split("/")[-1].replace(".csv.gz", "").replace(".csv", "")
            # column_order is DDL-derived and lists profile_text /
            # profile_embedding for players and clubs, which the pass-1 files do
            # NOT contain. Authoritative for ORDER; subtract the pass-2 columns.
            cols[table] = [c for c in meta["column_order"] if c not in PASS2_COLS]
    return cols


def preflight(cols):
    """Refuse to load if any file's field count disagrees with its column list.

    Loading anyway would either error out or, far worse, silently shift values
    into the wrong columns — which passes every row-count check there is.
    """
    for t in ORDER:
        if t not in cols:
            sys.exit(f"FATAL: {t} has no column_order in the manifest. Never guess at this.")
        proc = subprocess.Popen(["gcloud", "storage", "cat", f"{GCS}/{t}.csv.gz"],
                                stdout=subprocess.PIPE)
        with gzip.GzipFile(fileobj=proc.stdout, mode="rb") as gz:
            first = next(csv.reader(io.TextIOWrapper(gz, encoding="utf-8")))
        proc.stdout.close()
        proc.wait()
        if len(first) != len(cols[t]):
            sys.exit(f"FATAL: {t} file has {len(first)} fields, column list has "
                     f"{len(cols[t])}. Refusing to load.")
        log(f"  {t:22s} {len(first):>3} fields  OK")


# ---------------------------------------------------------------------------
def main():
    t_start = time.time()
    project, user, region, cluster, instance, uri = discover()

    log("### Data API ###")
    enable_data_api(uri, project)
    log()

    connect, session = make_session(uri, user)

    # --- database -----------------------------------------------------------
    # Owner check, not a blind CREATE: a database owned by someone else is one
    # the student cannot manage, and the failure surfaces much later.
    log("### Database ###")
    c = connect("postgres")
    cur = c.cursor()
    cur.execute("SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = %s",
                (DB_NAME,))
    row = cur.fetchone()
    if row is None:
        cur.execute(f'CREATE DATABASE "{DB_NAME}"')
        log(f"  created {DB_NAME}, owned by {user}")
    elif row[0] == user:
        log(f"  {DB_NAME} already exists and you own it")
    else:
        sys.exit(f"FATAL: {DB_NAME} exists but is owned by '{row[0]}', not {user}.")
    cur.close()
    c.close()

    # --- extensions ---------------------------------------------------------
    # Needs alloydbsuperuser, which Terraform grants the student's IAM user.
    log("\n### Extensions ###")
    for ext in ("vector", "alloydb_scann", "google_ml_integration", "pg_textsearch"):
        run(session, f"CREATE EXTENSION IF NOT EXISTS {ext}")
    ver = scalar(session,
                 "SELECT extversion FROM pg_extension WHERE extname='google_ml_integration'")
    log(f"  google_ml_integration {ver}")
    # ⚠️ FAIL LOUDLY, NOT SILENTLY. Task 6's proxy models need 1.5.8. If the
    # instance ships something older, Task 6's second half has no feature — and
    # the right time to know is now, not at minute 85.
    if ver and tuple(int(x) for x in ver.split(".")) < (1, 5, 8):
        log(f"  ⚠️ WARNING: {ver} is below the 1.5.8 floor for proxy models (Task 6).")
        log("     Trying ALTER EXTENSION ... UPDATE")
        try:
            run(session, "ALTER EXTENSION google_ml_integration UPDATE")
            log("     now " + str(scalar(session, "SELECT extversion FROM pg_extension "
                                                  "WHERE extname='google_ml_integration'")))
        except Exception as e:                                     # noqa: BLE001
            log(f"     update failed: {e}")

    # --- schema -------------------------------------------------------------
    log("\n### Schema ###")
    schema_sql = sh(f"gcloud storage cat {GCS}/schema.sql")
    if not schema_sql.strip():
        sys.exit("FATAL: could not read schema.sql from Cloud Storage")
    present = scalar(session, f"""
        SELECT count(*) FROM information_schema.tables
        WHERE table_schema='public' AND table_type='BASE TABLE'
          AND table_name IN ({','.join("'" + t + "'" for t in ORDER)})""")
    if present == len(ORDER):
        log("  all 8 tables already exist — skipping (schema.sql is not re-runnable)")
    elif present == 0:
        t0 = time.time()
        run(session, schema_sql)
        log(f"  applied in {time.time()-t0:.1f}s")
    else:
        sys.exit(f"FATAL: {present} of {len(ORDER)} tables exist — a half-built schema. "
                 "Drop the database and re-run.")

    # --- pass 1 -------------------------------------------------------------
    log("\n### Pass 1 — eight relational tables ###")
    cols = column_lists()
    preflight(cols)
    t0 = time.time()
    for t in ORDER:
        n = scalar(session, f"SELECT count(*) FROM {t}")
        if n:
            log(f"  {t:22s} already loaded, {n:>9,} rows")
            continue
        s = time.time()
        copy_table(session, t, cols[t], f"{GCS}/{t}.csv.gz")
        n = scalar(session, f"SELECT count(*) FROM {t}")
        log(f"  {t:22s} {n:>9,} rows  {time.time()-s:>6.1f}s")
    log(f"  pass 1 complete in {time.time()-t0:.1f}s")

    # --- pass 2 -------------------------------------------------------------
    # Touches ONLY profile_text and profile_embedding. The eight relational
    # tables are left alone.
    log("\n### Pass 2 — profiles and embeddings ###")
    t0 = time.time()
    for t, key in (("players", "player_id"), ("clubs", "club_id")):
        run(session, f"""CREATE TABLE IF NOT EXISTS _{t}_profiles (
                             {key} INTEGER, profile_text TEXT,
                             profile_embedding VECTOR(3072))""")
        if scalar(session, f"SELECT count(*) FROM _{t}_profiles") == 0:
            copy_table(session, f"_{t}_profiles",
                       [key, "profile_text", "profile_embedding"],
                       f"{GCS}/{t}_profiles.csv.gz")
        run(session, f"""UPDATE {t} tgt
                            SET profile_text = src.profile_text,
                                profile_embedding = src.profile_embedding
                           FROM _{t}_profiles src
                          WHERE tgt.{key} = src.{key}""")
    n_p = scalar(session, "SELECT count(*) FROM players WHERE profile_embedding IS NOT NULL")
    n_c = scalar(session, "SELECT count(*) FROM clubs   WHERE profile_embedding IS NOT NULL")
    assert n_p == EXPECT["players"], f"expected {EXPECT['players']:,} player profiles, got {n_p:,}"
    assert n_c == EXPECT["clubs"], f"expected {EXPECT['clubs']:,} club profiles, got {n_c:,}"
    log(f"  {n_p:,} player and {n_c:,} club profiles  {time.time()-t0:.1f}s")

    # --- indexes ------------------------------------------------------------
    # ⚠️ AFTER both loads, never before (P-16). schema.sql was re-emitted by
    # Stage 3 with zero CREATE INDEX statements precisely so this order is
    # enforced by the artifacts rather than by whoever is reading the script.
    log("\n### ScaNN indexes ###")
    if scalar(session, "SELECT count(*) FROM pg_indexes WHERE schemaname='public' "
                       "AND indexname LIKE '%scann%'") >= 2:
        log("  already built — skipping")
    else:
        indexes_sql = sh(f"gcloud storage cat {GCS}/indexes.sql")
        if not indexes_sql.strip():
            sys.exit("FATAL: could not read indexes.sql from Cloud Storage")
        t0 = time.time()
        run(session, "SET maintenance_work_mem = '2GB'")
        run(session, indexes_sql)
        log(f"  built in {time.time()-t0:.1f}s")

    # --- the gate Task 1 reads ---------------------------------------------
    # Same convention as Lab 1 Task 1.7: a self-study student who jumped ahead
    # sees 0 instead of 13,439 and knows to wait.
    log("\n### provisioning_status ###")
    run(session, """CREATE TABLE IF NOT EXISTS provisioning_status (
                        players INTEGER, clubs INTEGER, appearances INTEGER,
                        completed_at TIMESTAMPTZ DEFAULT now())""")
    run(session, """INSERT INTO provisioning_status (players, clubs, appearances)
                    SELECT (SELECT count(*) FROM players),
                           (SELECT count(*) FROM clubs),
                           (SELECT count(*) FROM appearances)""")

    log("\n" + "=" * 62)
    log(f" SETUP COMPLETE in {time.time()-t_start:.0f}s")
    log(f" players {scalar(session, 'SELECT count(*) FROM players'):,}  "
        f"clubs {scalar(session, 'SELECT count(*) FROM clubs'):,}  "
        f"appearances {scalar(session, 'SELECT count(*) FROM appearances'):,}")
    log("=" * 62)


if __name__ == "__main__":
    main()
