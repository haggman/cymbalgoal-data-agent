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
# Task 3 runs `agy`. Left to itself, first launch puts the student through an
# interactive sign-in: pick an auth type, open an authorization URL in a browser
# tab, copy an auth code back into the terminal, enter the project, enter a
# location, then a colour-scheme and Terms-of-Service wizard. That is ~2-3
# minutes per person and the single most likely place for a large room to
# fragment.
#
# `selectedAuthType: cloud-shell` tells the CLI to use Cloud Shell's ambient
# credentials instead of asking. Sourced from GSP1348's resources/settings.json.
#
# ⚠️ MERGE, never overwrite. An instructor re-running this script mid-lab may
# already have authenticated by hand, and clobbering their settings would undo
# it. Written to BOTH paths because the CLI still reads the legacy ~/.gemini
# location, and GSP1348 keeps the two in sync for the same reason.
echo "Configuring the Antigravity CLI..."
python3 - <<'PYEOF'
import json, os

WANT = {
    "selectedAuthType": "cloud-shell",
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
