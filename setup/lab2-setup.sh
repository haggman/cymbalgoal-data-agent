#!/usr/bin/env bash
#
# CymbalGoal Lab 2 (mkt014) — Task 0 setup launcher.
#
# WHERE: Cloud Shell.
# RUN:   bash lab2-setup.sh
#
# Installs the client libraries, then BACKGROUNDS lab2-setup.py and returns you
# to the prompt immediately. The load takes roughly 3-5 minutes and none of it
# is Lab 2's subject matter, so the student reads Task 1 while it runs and
# Task 1's closing row-count check tells them when it is done.
#
# Safe to re-run: every step in lab2-setup.py is guarded by an existence check.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${HOME}/cymbalgoal-setup.log"

echo "Installing client libraries..."
# --quiet keeps a wall of pip output off the projector. pandas is NOT needed —
# this is the load, not the analysis, and dropping it saves ~20s of install.
python3 -m pip install --quiet --upgrade \
  "google-cloud-alloydb-connector[pg8000]" 2>&1 | tail -2


# ---------------------------------------------------------------------------
# Antigravity CLI first-run settings.
#
# 🔴 MEASURED 2026-08-19: this does NOT skip the sign-in flow. Seeding
# `selectedAuthType: "cloud-shell"` — lifted from GSP1348's resources/settings.json,
# where it is present but never actually written by that lab — had no effect. `agy`
# still ran its full interactive sequence: login method, sign-in method, browser
# OAuth round-trip, project ID, location, licence. Task 3 documents that sequence
# rather than pretending it away.
#
# So the wrong value is no longer written. Only the nudge suppressor stays, which
# is harmless either way.
#
# ⚠️ TO FINISH THIS: after signing in successfully once, run
#     cat ~/.antigravity/settings.json
# The CLI writes its own auth type, project and location there, in whatever enum it
# actually uses. Seed THOSE exact values here and re-test on a clean project —
# `rm -f ~/.antigravity/settings.json ~/.gemini/settings.json` first, or the merge
# below will preserve what is already there and prove nothing.
#
# MERGE, never overwrite: an instructor re-running this mid-lab may already have
# authenticated by hand. Both paths are written because the CLI still reads the
# legacy ~/.gemini location.
echo "Configuring the Antigravity CLI..."
python3 - <<'PYEOF'
import json, os

WANT = {
    "hasSeenIdeIntegrationNudge": True,
}

for d in ("~/.antigravity", "~/.gemini"):
    d = os.path.expanduser(d)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "settings.json")
    current = {}
    if os.path.exists(path):
        try:
            with open(path) as fh:
                current = json.load(fh)
        except (ValueError, OSError):
            current = {}          # unreadable or not JSON: start clean
    merged = dict(current)
    merged.update({k: v for k, v in WANT.items() if k not in current})
    with open(path, "w") as fh:
        json.dump(merged, fh, indent=2)
        fh.write("\n")
    print(f"  {path}")
PYEOF

echo
echo "Starting the CymbalGoal load in the background."
echo "  log: ${LOG}"
echo

nohup python3 "${HERE}/lab2-setup.py" > "${LOG}" 2>&1 &
PID=$!
echo "  pid: ${PID}"

cat <<EOF

  This takes about 3-5 minutes. You do not need to wait for it — carry on with
  Task 1 and it will be finished by the time you need the data.

  Watch it:        tail -f ${LOG}
  Check it's alive: ps -p ${PID}

  ⚠️ If you close this Cloud Shell tab the process keeps running (nohup), but a
  Cloud Shell session that TIMES OUT entirely will kill it. Re-run this script
  if that happens — it picks up where it left off.

EOF
