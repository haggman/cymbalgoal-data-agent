# What the lab platform surfaces, and what an instructor needs to verify a
# pre-warmed cluster before students arrive.
#
# ⚠️ These are Terraform outputs, NOT student_visible_outputs. The four things
# students actually see are declared in qwiklabs.yaml. Everything here is for
# whoever is looking at a provisioning log.

output "alloydb_cluster" {
  description = "Cluster ID."
  value       = google_alloydb_cluster.main.cluster_id
}

output "alloydb_instance" {
  description = "Primary instance ID."
  value       = google_alloydb_instance.primary.instance_id
}

output "alloydb_public_ip" {
  description = "Reached by the AlloyDB Python Connector with IAM auth — no password, no authorized networks."
  value       = google_alloydb_instance.primary.public_ip_address
}

output "student_db_user" {
  description = "IAM database user holding alloydbsuperuser. Needed for CREATE EXTENSION in the Task 0 setup script."
  value       = google_alloydb_user.student.user_id
}

# ---------------------------------------------------------------------------
# NEW FOR LAB 2
# ---------------------------------------------------------------------------

# Task 5's ADK agent passes this string verbatim as the `instance` argument to
# the MCP server's execute_sql_read_only tool. Task 4's QueryData calls want it
# too. Assembling it by hand means reading a project ID, a region, a cluster ID
# and an instance ID off four different console surfaces and getting the
# five-segment path exactly right — a pure-tax minute in a lab that has none to
# spare, and a silent 404 when it goes wrong.
output "mcp_instance_path" {
  description = "Fully-qualified instance path for the AlloyDB MCP server and QueryData."
  value       = local.instance_path
}

# The PATCH that has no Terraform surface. Emitted here so that if the Task 0
# script is ever skipped, the exact command is one `terraform output` away
# rather than reconstructed from memory — and so the correct enum is recorded
# in the provisioning log itself.
#
# ⚠️ BOTH DETAILS BELOW ARE MEASURED, 2026-08-18, not copied from the docs:
#
#   /v1/ WORKS. Google documents v1alpha; we do not need it, and a shipping lab
#   pinned to an alpha endpoint has an expiry date on it. Verified HTTP 200.
#
#   "ENABLED" is the only accepted spelling. ALLOW_DATA_API — which Google's
#   prose names, directly above a curl block that sends ENABLED — returns:
#     HTTP 400 INVALID_ARGUMENT
#     "Invalid value at 'instance.data_api_access' (...Instance.DataApiAccess),
#      \"ALLOW_DATA_API\""
#
# ⚠️ It returns a long-running operation that takes ~134 SECONDS. Anyone running
# this by hand needs to be told that, or they will conclude it hung.
output "data_api_patch_command" {
  description = "Manual fallback if the Task 0 setup script did not run. Requires alloydb.instances.update. Takes ~134s to settle."
  value       = <<-EOT
    curl -sS -X PATCH \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://alloydb.googleapis.com/v1/${local.instance_path}?updateMask=dataApiAccess" \
      -d '{"dataApiAccess":"ENABLED"}'
  EOT
}

output "instructor_preflight" {
  description = "Run after the Task 0 setup script. Expect 13439 players / 796 clubs / 832193 appearances."
  value       = "SELECT * FROM provisioning_status;"
}
