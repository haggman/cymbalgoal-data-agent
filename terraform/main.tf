# =============================================================================
# CymbalGoal Lab 2 — Building a Data Agent. Provisioning.
# =============================================================================
# FORKED FROM mkt013, which is proven at Start Lab. Everything mkt013 got right
# is carried over verbatim and is NOT re-derived here — read the comments in
# mkt013/terraform/main.tf for the reasoning behind ZONAL, the public IP, the
# username handling and the two service-agent IAM bindings.
#
# WHAT THIS FILE PROVISIONS: the cluster, the instance, the APIs and the IAM.
# Nothing else. It cannot run SQL — the Terraform runner sits outside the VPC
# and there is no google_alloydb_database resource.
#
# WHAT IT DOES NOT DO, AND WHO DOES IT INSTEAD:
#
#   * Create the `cymbalgoal` database, extensions, schema, load 1.6M rows,
#     build the ScaNN indexes  ->  build/lab2-setup.sh, backgrounded by the
#     student in Task 0 and verified by the row-count check at the end of
#     Task 1. Lab 1 did this in a Colab notebook because the load WAS the
#     lesson; in Lab 2 it is scaffolding, so it is scripted and runs while the
#     student reads.
#
#   * PATCH dataApiAccess on the instance  ->  same script. There is no
#     Terraform attribute and no gcloud flag for it (verified 2026-08-18
#     against the google + google-beta providers, magic-modules, and both
#     `gcloud alloydb instances update` surfaces — see the block at the bottom
#     of this file). QueryData (Task 4) and the MCP server (Task 5) BOTH depend
#     on it, so if it silently fails the lab dies twice.
#
# ⚠️ DELTA FROM mkt013 — every difference is listed here so a diff is legible:
#   1. Three APIs added:  geminidataanalytics, cloudaicompanion, dataplex
#   2. Three student IAM roles added (QueryData needs them; see the note there)
#   3. One database flag added: enable_cost_optimized_ai_functions  (Task 6)
#   4. Outputs extended with the MCP instance resource path (Task 5 needs it
#      verbatim and it is tedious to hand-assemble)
#   5. Nothing removed.
# =============================================================================

locals {
  cluster_id  = "cymbalgoal-cluster"
  instance_id = "cymbalgoal-primary"
  network     = "cymbalgoal-network"

  # Append the domain ONLY if it is not already there. See mkt013 and
  # cymbalgoal-qwiklabs-runtime-facts.md — user_0.username and
  # user_0.local_username are DIFFERENT VALUES and qwiklabs.yaml decides which
  # one arrives. Tolerating both is what turns a dead room into a working one.
  student_email = can(regex("@", var.username)) ? var.username : "${var.username}@${var.student_email_domain}"

  # The fully-qualified instance path. Task 5's ADK agent passes this verbatim
  # as the `instance` argument to the MCP server's execute_sql_read_only tool,
  # and Task 4's QueryData calls want it too. Surfacing it as an output saves
  # every student from hand-assembling a five-segment resource path from four
  # separate console pages — which is exactly the kind of minute this lab has
  # no budget for.
  instance_path = "projects/${var.gcp_project_id}/locations/${var.gcp_region}/clusters/${local.cluster_id}/instances/${local.instance_id}"
}

data "google_project" "current" {
  project_id = var.gcp_project_id
}

# -----------------------------------------------------------------------------
# APIs
# -----------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    # ---- carried from mkt013, unchanged --------------------------------------
    "alloydb.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "aiplatform.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",

    # Kept even though Lab 2's task list does not currently name ai.rank().
    # Task 6 walks the ai.* family and ai.rank() is in it; if a step ever calls
    # the reranker form, this API plus roles/discoveryengine.viewer below are
    # what make it work. Both are free to leave in place and cost a room-wide
    # failure at minute 90 to leave out. See mkt013 for the measured 403.
    "discoveryengine.googleapis.com",

    # ---- NEW FOR LAB 2 -------------------------------------------------------

    # QueryData / context sets. This is the API behind Task 3's context set and
    # Task 4's Generate SQL. Without it, `agy` fails at the first tool call and
    # Studio never offers the context-set affordance.
    "geminidataanalytics.googleapis.com",

    # Gemini for Google Cloud. AlloyDB Studio's "Help me code" panel — the
    # thing Task 2 and Task 4 both drive — needs cloudaicompanion.
    #
    # ⚠️ INFERRED, NOT DOCUMENTED. Google's AlloyDB pages never name this API
    # string; it is deduced from the two permissions the Studio doc DOES list
    # (cloudaicompanion.companions.generateCode and
    # cloudaicompanion.instances.generateCode). Confirm on the first Start Lab
    # run by opening Studio and clicking "Help me code" — if the panel is
    # missing or errors, this is the first thing to look at.
    "cloudaicompanion.googleapis.com",

    # "Knowledge Catalog API", named in prose in the context-set prerequisites
    # and nowhere given as a service string.
    #
    # ⚠️ ALSO INFERRED. dataplex.googleapis.com is the best candidate and the
    # context-set resource being catalog-backed is consistent with it, but this
    # is a guess with a plausible mechanism, not a verified fact. If the apply
    # fails on this line, drop it and re-test — a wrong service string here
    # halts provisioning for the whole room, which is a much worse failure than
    # a missing optional API.
    "dataplex.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Network — identical to mkt013
# -----------------------------------------------------------------------------
# AlloyDB is VPC-native and requires Private Service Access even when reached
# over its public IP. No subnet, NAT, router or firewall rules: nothing in
# Lab 2 runs inside the VPC. Cloud Shell reaches the instance the same way
# Lab 1's Colab notebook did — public IP, AlloyDB Python Connector, IAM auth,
# and NO authorized networks.
resource "google_compute_network" "main" {
  name                    = local.network
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_global_address" "psa" {
  name          = "cymbalgoal-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
  depends_on    = [google_project_service.apis]
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
  depends_on              = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
resource "random_password" "initial" {
  length           = 24
  special          = true
  override_special = "-_=+"
}

resource "google_alloydb_cluster" "main" {
  cluster_id       = local.cluster_id
  location         = var.gcp_region
  database_version = "POSTGRES_18"

  network_config {
    network = google_compute_network.main.id
  }

  initial_user {
    user     = "postgres"
    password = random_password.initial.result
  }

  depends_on = [google_service_networking_connection.psa]
}

# -----------------------------------------------------------------------------
# Primary instance
# -----------------------------------------------------------------------------
resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.main.name
  instance_id   = local.instance_id
  instance_type = "PRIMARY"

  # ⚠️ NOT the default, and do NOT add gce_zone. A PRIMARY defaults to REGIONAL,
  # which is an HA pair and doubles the capacity request — 600 nodes instead of
  # 300 at a 300-person event, in one region, at the same moment. Measured
  # failure: Error code 9, "Location us-central1 does not have enough
  # resources". Leaving the zone unset lets Google place the node where capacity
  # actually is. Full reasoning in mkt013.
  availability_type = "ZONAL"

  machine_config {
    cpu_count = var.cpu_count
  }

  network_config {
    enable_public_ip = true
  }

  # ⚠️ EVERY NAME VERIFIED against
  #   GET .../locations/{region}/supportedDatabaseFlags
  # AlloyDB rejects the ENTIRE instance create if one flag name is unknown — no
  # warning, no partial apply, every student gets a cluster with no instance.
  # Never add an unchecked name. mkt013's v1 rig lost a whole run to exactly
  # this, on a Cloud SQL flag name that does not exist on AlloyDB.
  database_flags = {
    # MANDATORY with public IP. AlloyDB refuses the request without it.
    "password.enforce_complexity" = "on"

    # Required for enable_iam_auth. google_alloydb_user creates the principal;
    # this flag is what lets it authenticate.
    "alloydb.iam_authentication" = "on"

    # Preview ai.* functions. Task 6 walks the family, and ai.summarize() /
    # ai.analyze_sentiment() are gated behind this.
    "google_ml_integration.enable_preview_ai_functions" = "on"

    # ---- NEW FOR LAB 2 -------------------------------------------------------
    # Proxy models — the whole of Task 6's second half (S-17).
    #
    # Verified present in the supportedDatabaseFlags listing, default off
    # (P-13). The two companion flags the docs also require —
    #   google_ml_integration.enable_model_support
    #   google_ml_integration.enable_ai_query_engine
    # — are NOT set here because they already default to on; setting them is
    # harmless but adds two more names that must stay correct forever.
    #
    # ⚠️ PG 18 SUPPORT IS UNVERIFIED. Google's optimized-functions page states
    # no PostgreSQL version at all, while the SIBLING feature
    # (enable_ai_function_acceleration) is documented as PG 17 ONLY. If proxy
    # models turn out to be PG 17 only as well, Task 6's second half has no
    # feature to teach and the task must be rescoped. THIS IS THE HIGHEST-VALUE
    # THING TO TEST ON THE FIRST LIVE CLUSTER.
    "google_ml_integration.enable_cost_optimized_ai_functions" = "on"

    # Task 1's columnar-engine aside, carried from mkt013.
    "google_columnar_engine.enabled" = "on"
  }

  depends_on = [google_service_networking_connection.psa]
}

# -----------------------------------------------------------------------------
# Service-agent bindings — carried from mkt013, both load-bearing
# -----------------------------------------------------------------------------
# The AlloyDB service agent does not exist until the cluster does, so binding
# earlier fails. These depends_on are not decoration.
#
# ⚠️ PROJECT NUMBER, NOT PROJECT ID. One Google doc page writes the placeholder
# as service-PROJECT_ID@... and then shows a project number in its own worked
# example. The number is correct.

# Without this, google_ml.embedding() and every ai.generate()/ai.summarize()
# call fail. In Lab 2 that is Task 6 in its entirety, plus any embedding the
# proxy-model path needs to compute.
resource "google_project_iam_member" "alloydb_vertex" {
  project    = var.gcp_project_id
  role       = "roles/aiplatform.user"
  member     = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-alloydb.iam.gserviceaccount.com"
  depends_on = [google_alloydb_cluster.main]
}

# ⚠️ THE ROLE NAME IS COUNTERINTUITIVE AND WAS VERIFIED, NOT GUESSED:
#   roles/discoveryengine.viewer   HAS rankingConfigs.rank   <- narrowest
#   roles/discoveryengine.user     does NOT
# "user" is the obvious guess and it is wrong. Enabling the API is not the same
# as being allowed to call it — that mistake cost mkt013 a room-wide 403 at the
# final step of the lab.
resource "google_project_iam_member" "alloydb_discoveryengine" {
  project    = var.gcp_project_id
  role       = "roles/discoveryengine.viewer"
  member     = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-alloydb.iam.gserviceaccount.com"
  depends_on = [google_alloydb_cluster.main]
}

# -----------------------------------------------------------------------------
# Student database user
# -----------------------------------------------------------------------------
# Lab 2 needs alloydbsuperuser for the same reason Lab 1 did: the setup script
# creates extensions, and CREATE EXTENSION for pg_textsearch / alloydb_scann
# requires it.
resource "google_alloydb_user" "student" {
  cluster   = google_alloydb_cluster.main.id
  user_id   = local.student_email
  user_type = "ALLOYDB_IAM_USER"

  # ⚠️ TWO traps, both of which only appear on the SECOND apply:
  #   1. alloydbiamuser is NOT optional — database_roles declares the COMPLETE
  #      set, so omitting it reads as "revoke alloydbiamuser" and errors.
  #   2. ORDER MATTERS. It is a LIST and AlloyDB returns the roles sorted, so
  #      any other order is a permanent diff. Keep this ALPHABETICAL.
  database_roles = ["alloydbiamuser", "alloydbsuperuser"]

  depends_on = [google_alloydb_instance.primary]
}

# -----------------------------------------------------------------------------
# ⚠️ NEW FOR LAB 2 — student project-level IAM for QueryData and MCP
# -----------------------------------------------------------------------------
# qwiklabs.yaml already grants the student roles/owner, so the obvious reaction
# is that these are redundant. Grant them anyway, for one specific reason:
#
#   Google has been carving newly-minted permissions OUT of the basic roles.
#   A permission that postdates the basic-role definitions is not automatically
#   in roles/owner, and geminidataanalytics.locations.queryData is exactly that
#   shape — a permission on a service that reached Preview in April 2026.
#
# An explicit grant costs one API call at provision time. Discovering at Task 3
# that owner was not enough costs the room 25 minutes. The asymmetry decides it.
#
# ⚠️ VERIFY THESE THREE NAMES AT THE KEYBOARD before the first event:
#   gcloud iam roles describe roles/geminidataanalytics.queryDataUser
#   gcloud iam roles describe roles/alloydb.databaseUser
#   gcloud iam roles describe roles/serviceusage.serviceUsageConsumer
# A role name that does not exist fails the apply for every student at once,
# which is the single most expensive way to be wrong in this file.
#
# Provenance: Google's own AlloyDB QueryData prerequisites list exactly these
# three, project-level, for the human user. Do NOT substitute any of the
# geminidataanalytics.dataAgent* roles — those govern the Conversational
# Analytics API's data-agent resource model, which is a different axis from
# QueryData-for-AlloyDB and will not grant queryData.
resource "google_project_iam_member" "student_querydata" {
  for_each = toset([
    # The permission behind Task 3's context-set build and Task 4's
    # Generate SQL: geminidataanalytics.locations.queryData
    "roles/geminidataanalytics.queryDataUser",

    # alloydb.instances.executeSql — how Studio, the Data API and the MCP
    # server all actually run a statement. Also required for the two-layer
    # grant: IAM here, plus the cluster-level database user above.
    "roles/alloydb.databaseUser",

    # Named in the same prerequisite list. Consuming a service on behalf of a
    # project is what the context-engineering agent does when it calls
    # geminidataanalytics from Cloud Shell.
    "roles/serviceusage.serviceUsageConsumer",
  ])
  project = var.gcp_project_id
  role    = each.value
  member  = "user:${local.student_email}"

  # Not strictly ordered against anything, but keeping it behind the cluster
  # means a failed cluster create surfaces as a cluster error rather than as a
  # confusing IAM error on a principal nothing has used yet.
  depends_on = [google_alloydb_cluster.main]
}

# =============================================================================
# ⚠️ THE THING THIS FILE DELIBERATELY DOES NOT DO: dataApiAccess
# =============================================================================
# Both Task 4 (QueryData) and Task 5 (MCP execute_sql) require the Data API to
# be ENABLED on the instance. There is no Terraform attribute and no gcloud
# flag. Verified 2026-08-18 against:
#
#   hashicorp/google + google-beta  website docs and resource_alloydb_instance.go
#   GoogleCloudPlatform/magic-modules  mmv1/products/alloydb/Instance.yaml
#   gcloud alloydb instances update  (GA and alpha surfaces)
#
# — nothing in any of them, and nothing queued in magic-modules either, so this
# will not be fixed by a provider bump.
#
# THE ENUM IS SETTLED. Read the AlloyDB Admin API discovery document
# (revision 20260730, identical in v1 / v1beta / v1alpha) and the field is:
#
#   "dataApiAccess": enum [
#       "DEFAULT_DATA_API_ENABLED_FOR_GOOGLE_CLOUD_SERVICES",   <- implicit default
#       "DISABLED",
#       "ENABLED"                                               <- what we want
#   ]
#
# ALLOW_DATA_API IS NOT A VALID VALUE. It appears in Google's PROSE, directly
# above a curl block in the same page that sends "ENABLED". It is a docs bug.
# Anything in our own notes that says ALLOW_DATA_API is repeating that bug and
# should be corrected.
#
# Also worth knowing, because it changes what Task 5 is actually demonstrating:
# the implicit default already grants Data API access to Google-internal
# services, which is why AlloyDB Studio works with no PATCH at all. The PATCH
# to ENABLED is what opens executeSql to OUR OWN callers — the ADK agent in
# Task 5. So Task 4 may well work without it and Task 5 will not, which is a
# genuinely confusing failure mode to debug live. Do the PATCH in Task 0.
#
# The PATCH lives in build/lab2-setup.sh. It needs alloydb.instances.update,
# which the student has via roles/owner.
# =============================================================================

# -----------------------------------------------------------------------------
# D-32 — read pool: DELIBERATELY ABSENT, same as mkt013
# -----------------------------------------------------------------------------
# No task in any of the three labs requires one, and it costs provisioning
# wall-clock on every student cluster. If one is ever added, remember that
# database_flags are INSTANCE-level: every flag above must be repeated on it
# verbatim or the pool silently behaves differently.
