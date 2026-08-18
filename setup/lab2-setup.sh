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
