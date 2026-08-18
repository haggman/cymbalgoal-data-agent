#!/usr/bin/env bash
#
# CymbalGoal Lab 2 — Tier 1, item 3: pin the Antigravity context-engineering
# plugin and confirm it still installs. The whole of Task 3 (25 min) rests on it.
#
# WHERE: Cloud Shell.
# RUN:   bash lab2-04-antigravity.sh 2>&1 | tee ~/lab2-agy.log
# TIME:  ~3 min for the checks. Task 3's REAL duration is the agentic loop that
#        follows, and that is the number the handoff actually wants.
#
# WHAT THE DOCS GIVE YOU, VERBATIM, PLACEHOLDER AND ALL:
#   agy plugin install https://github.com/GoogleCloudPlatform/db-context-enrichment/tree/*VERSION*
#
# *VERSION* is a git tag on that repo, format vX.Y.Z. Google names none.
#
# ⚠️ THE PIN, as of 2026-08-18:  v0.7.2  (released 2026-08-06)
#   Resolution probed directly: v0.7.2, v0.7.1, v0.8.0-rc.3 and v0.6.0 all
#   resolve; v0.8.0, v0.7.3 and v1.0.0 all 404. So 0.8.0 has NOT shipped stable
#   and the rc tags must not go in a lab.
#   ⚠️ This repo shipped three releases in six weeks. RE-CHECK THE TAG ON EVENT
#   WEEK, and prefer a pin that has been smoke-tested over "whatever is latest".
#
# ⚠️ AND THE THING THAT CHANGES TASK 3'S SHAPE: there is NO CLI publish command.
# The agent produces a context-set JSON on local disk. Publishing it means
# AlloyDB Studio -> Explorer -> Context sets -> View actions -> Create context
# set, then Edit context set -> Upload. Task 3 therefore ends in the console,
# not in the terminal, and the lab must say so or students will hunt for an
# `agy publish` that does not exist.
#
# Related: Gemini CLI is now DEPRECATED for this workflow in Google's own docs,
# which retroactively justifies the Antigravity choice in the outline.

set -uo pipefail

PLUGIN_REPO="https://github.com/GoogleCloudPlatform/db-context-enrichment"
PLUGIN_TAG="${AGY_PLUGIN_TAG:-v0.7.2}"
PLUGIN_NAME="google-cloud-db-context-engineering"

say() { echo; echo "### $* ###"; }
verdict() { echo "VERDICT: $*"; }

say "1. Is agy really pre-installed in Cloud Shell?"
# The pre-install claim rests on ONE sentence in a Dataplex doc and appears in no
# Cloud Shell release note. If it is false, Task 3 gains an install step and
# several minutes, so this is a real scheduling question and not trivia.
if command -v agy >/dev/null 2>&1; then
  echo "  agy at: $(command -v agy)"
  agy --version 2>&1 | head -3
  verdict "agy pre-installed — Task 3 needs no install step"
else
  verdict "🔴 agy NOT pre-installed — Task 3 needs: curl -fsSL https://antigravity.google/cli/install.sh | bash"
  echo "  Installing now so the rest of this script can run..."
  curl -fsSL https://antigravity.google/cli/install.sh | bash || exit 1
  export PATH="$HOME/.antigravity/bin:$PATH"
fi

say "2. Confirm the pinned tag still resolves before trying to install it"
# Cheaper than a failed install and gives a clean answer if the tag moved.
for T in "$PLUGIN_TAG" v0.8.0 v0.7.3; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' \
    "https://raw.githubusercontent.com/GoogleCloudPlatform/db-context-enrichment/${T}/README.md")"
  printf '  %-12s -> HTTP %s\n' "$T" "$CODE"
done
echo "  (the two after the pin are probes: if either is now 200, a newer stable exists)"

say "3. Install the plugin at the pin"
# ⚠️ The /tree/<tag> URL form is used by Google's OWN AlloyDB docs, but the
# Antigravity CLI's plugin reference documents only a local path. It is very
# likely supported — a Dataplex doc uses a bare GitHub URL too — but this line
# is precisely why we smoke-test rather than write prose around it.
agy plugin uninstall "$PLUGIN_NAME" >/dev/null 2>&1 || true
if agy plugin install "${PLUGIN_REPO}/tree/${PLUGIN_TAG}"; then
  verdict "plugin installed at ${PLUGIN_TAG} via the /tree/<tag> URL form"
else
  verdict "🔴 install FAILED at ${PLUGIN_TAG} — try the marketplace form before concluding the tag is bad:"
  echo "     /plugin marketplace add ${PLUGIN_REPO}.git"
  echo "     /plugin install db-context-engineering@db-context-enrichment-marketplace"
  exit 1
fi

say "4. Is it actually enabled?"
agy plugin list 2>&1 | sed 's/^/  /'

say "5. Prerequisites the plugin will hit the moment it runs"
echo "  --- APIs (Terraform should have enabled all three) ---"
gcloud services list --enabled \
  --filter="config.name:(geminidataanalytics.googleapis.com OR cloudaicompanion.googleapis.com OR dataplex.googleapis.com)" \
  --format="value(config.name)" | sed 's/^/    ✅ /'
echo "  (anything missing above is a Terraform bug, not a student problem —"
echo "   the dataplex/'Knowledge Catalog' entry in particular is an INFERENCE)"

echo
echo "  --- uv, which the eval loop needs (uvx google-evalbench) ---"
if command -v uv >/dev/null 2>&1; then uv --version | sed 's/^/    /'
else echo "    ⚠️ uv NOT present — Task 3's evaluate/gap-analysis phases need it. Add an install step."; fi

echo
echo "  --- IAM: verify the role names rather than trusting them ---"
# Every one of these is a name that, if wrong in Terraform, fails the apply for
# the entire room at once. Cheap to check, expensive to guess.
for R in roles/geminidataanalytics.queryDataUser \
         roles/alloydb.databaseUser \
         roles/serviceusage.serviceUsageConsumer \
         roles/aiplatform.user \
         roles/discoveryengine.viewer; do
  if gcloud iam roles describe "$R" --format="value(name)" >/dev/null 2>&1; then
    echo "    ✅ $R"
  else
    echo "    🔴 $R  DOES NOT EXIST — remove it from main.tf before any Start Lab run"
  fi
done

say "6. Hand over to the agentic part — and START A TIMER"
cat <<'EOF'
  Run `agy` and drive it with these prompts, in order. This is Task 3's real
  content and its real duration:

    1. "Help me set up the database connection"
         -> writes autoctx/tools.yaml, then run /mcp and reconnect `toolbox`
    2. "Generate an evaluation dataset from my schema"      -> autoctx/golden.json
    3. "Generate a context set from my schema"              -> experiment folder
    4. "Evaluate my context against golden.json"            -> eval_reports/*.csv
    5. "Run gap analysis on my last evaluation and propose fixes"

  Then fold in the two CymbalGoal-specific assets the plan already identified:
    - value search: from_club_name = 'Without Club'
    - facet:        the three-way NULL club FK

  ⚠️ RECORD THESE, they are prototype deliverables:
    - wall-clock for each phase, and how many gap-analysis rounds you allowed
    - the exact filename of the JSON the agent emits (docs never name it)
    - whether the Studio Explorer node reads "Context sets" or "QueryData
      Context" — the docs and the Next '26 codelab disagree, and Task 3's final
      steps are console clicks that have to match what students actually see
EOF
