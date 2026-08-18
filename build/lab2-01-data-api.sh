#!/usr/bin/env bash
#
# CymbalGoal Lab 2 — Tier 1, item 2: settle the Data API PATCH. (P-08)
#
# WHERE: Cloud Shell, inside a started mkt014 lab (or any project with the
#        cymbalgoal cluster up).
# RUN:   bash lab2-01-data-api.sh 2>&1 | tee ~/lab2-dataapi.log
# TIME:  ~1 min. Run this FIRST — it is the cheapest Tier 1 item and both
#        Task 4 and Task 5 are blocked behind it.
#
# WHAT WE ALREADY KNOW, FROM THE DISCOVERY DOCUMENT (rev 20260730, identical in
# v1 / v1beta / v1alpha):
#
#   "dataApiAccess": enum [
#       "DEFAULT_DATA_API_ENABLED_FOR_GOOGLE_CLOUD_SERVICES",
#       "DISABLED",
#       "ENABLED"
#   ]
#
# So ALLOW_DATA_API — which appears in Google's PROSE, directly above a curl
# block on the same page that sends "ENABLED" — is a docs bug, not an alias.
# Our own notes repeat that bug and should be corrected once this run confirms.
#
# WHAT THIS SCRIPT ACTUALLY DECIDES, i.e. what the docs could not tell us:
#   A. Does the PATCH work on /v1/ (stable) or only /v1alpha/? Google documents
#      v1alpha; the field is present in all three discovery docs. If v1 works we
#      should use it, because an alpha endpoint can move under a shipping lab.
#   B. Does the API reject ALLOW_DATA_API with a clean 400, or silently accept
#      it? If it 400s, that is a nice defensive assertion for the setup script.
#   C. Does instances.get echo the field back before any PATCH, or omit it?
#      Decides whether "is it on?" is checkable, which the lab's troubleshooting
#      section needs.
#   D. How long does the returned long-running operation actually take?
#
# NOTHING HERE IS DESTRUCTIVE — the worst case is that the instance ends up with
# the Data API enabled, which is where we want it anyway.

set -uo pipefail

REGION="${CG_REGION:-us-central1}"
CLUSTER="${CG_CLUSTER:-cymbalgoal-cluster}"
INSTANCE="${CG_INSTANCE:-cymbalgoal-primary}"
PROJECT="$(gcloud config get-value project 2>/dev/null)"

if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  echo "FATAL: no project set. Run: gcloud config set project YOUR_PROJECT_ID"; exit 1
fi

INST="projects/${PROJECT}/locations/${REGION}/clusters/${CLUSTER}/instances/${INSTANCE}"
TOKEN="$(gcloud auth print-access-token)"

say() { echo; echo "### $* ###"; }
verdict() { echo "VERDICT: $*"; }   # greppable, same convention as Lab 1's rig

echo "=============================================="
echo " instance : $INST"
echo "=============================================="

# ---------------------------------------------------------------------------
say "C. Does instances.get report dataApiAccess BEFORE any PATCH?"
# ---------------------------------------------------------------------------
# If this comes back absent rather than as the DEFAULT_... enum, then "is the
# Data API on?" is not directly checkable and the lab's troubleshooting has to
# tell students to look at the symptom instead of the setting.
for V in v1 v1beta v1alpha; do
  RESP="$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer ${TOKEN}" \
          "https://alloydb.googleapis.com/${V}/${INST}")"
  CODE="$(tail -1 <<<"$RESP")"; BODY="$(sed '$d' <<<"$RESP")"
  FIELD="$(python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('dataApiAccess','<ABSENT>'))
except Exception as e: print('<UNPARSEABLE>')" <<<"$BODY")"
  echo "  ${V} GET -> HTTP ${CODE}, dataApiAccess = ${FIELD}"
done
verdict "pre-PATCH field state recorded above"

# ---------------------------------------------------------------------------
say "B. Does the API REJECT the documented-in-prose value ALLOW_DATA_API?"
# ---------------------------------------------------------------------------
# Expect a 400. If this returns 200, the two spellings are interchangeable and
# our notes are merely untidy rather than wrong — a materially different
# conclusion, so it is worth the ten seconds.
RESP="$(curl -sS -w '\n%{http_code}' -X PATCH \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  "https://alloydb.googleapis.com/v1alpha/${INST}?updateMask=dataApiAccess" \
  -d '{"dataApiAccess":"ALLOW_DATA_API"}')"
CODE="$(tail -1 <<<"$RESP")"
echo "  HTTP ${CODE}"
sed '$d' <<<"$RESP" | head -20
if [[ "$CODE" == "400" ]]; then
  verdict "ALLOW_DATA_API rejected with 400 — docs prose is a bug, ENABLED is the only spelling"
elif [[ "$CODE" == "200" ]]; then
  verdict "⚠️ ALLOW_DATA_API ACCEPTED — both spellings work, revise the note in main.tf"
else
  verdict "ALLOW_DATA_API returned HTTP ${CODE} — read the body above before concluding"
fi

# ---------------------------------------------------------------------------
say "A. The real PATCH — try STABLE v1 first"
# ---------------------------------------------------------------------------
# Preference order is deliberate: v1 > v1beta > v1alpha. Google documents
# v1alpha, but a shipping lab pinned to an alpha endpoint is a lab with an
# expiry date on it. The field is in the v1 discovery document, so v1 has a
# real chance of working; we just have to ask.
PATCH_VERSION=""
for V in v1 v1beta v1alpha; do
  RESP="$(curl -sS -w '\n%{http_code}' -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "https://alloydb.googleapis.com/${V}/${INST}?updateMask=dataApiAccess" \
    -d '{"dataApiAccess":"ENABLED"}')"
  CODE="$(tail -1 <<<"$RESP")"; BODY="$(sed '$d' <<<"$RESP")"
  echo "  ${V} PATCH -> HTTP ${CODE}"
  if [[ "$CODE" == "200" ]]; then
    PATCH_VERSION="$V"
    OP="$(python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('name',''))
except Exception: print('')" <<<"$BODY")"
    echo "  operation: ${OP:-<none returned>}"
    break
  else
    head -10 <<<"$BODY"
  fi
done

if [[ -z "$PATCH_VERSION" ]]; then
  verdict "🔴 PATCH FAILED ON ALL THREE VERSIONS — Tasks 4 and 5 are both blocked. Stop and read the bodies above."
  exit 1
fi
verdict "PATCH succeeded on /${PATCH_VERSION}/ — pin this version in lab2-setup.sh"

# ---------------------------------------------------------------------------
say "D. Poll the operation and time it"
# ---------------------------------------------------------------------------
# Matters because the setup script backgrounds this. If it is seconds, the
# script can just wait. If it is minutes, Task 0 needs to say so, and Task 5
# needs a "if the agent 401s, the PATCH may still be settling" note.
START=$SECONDS
if [[ -n "${OP:-}" ]]; then
  for i in $(seq 1 60); do
    R="$(curl -sS -H "Authorization: Bearer ${TOKEN}" "https://alloydb.googleapis.com/${PATCH_VERSION}/${OP}")"
    if grep -q '"done"[[:space:]]*:[[:space:]]*true' <<<"$R"; then
      echo "  done after $((SECONDS-START))s"
      grep -q '"error"' <<<"$R" && { echo "$R" | head -20; verdict "🔴 operation completed WITH AN ERROR"; exit 1; }
      break
    fi
    sleep 5
  done
fi
verdict "operation settled in $((SECONDS-START))s"

# ---------------------------------------------------------------------------
say "Confirm the field now reads ENABLED"
# ---------------------------------------------------------------------------
curl -sS -H "Authorization: Bearer ${TOKEN}" "https://alloydb.googleapis.com/${PATCH_VERSION}/${INST}" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  dataApiAccess =', d.get('dataApiAccess','<ABSENT>'))
print('  state         =', d.get('state','?'))"

echo
echo "Next: bash lab2-02-mcp-probe.sh"
