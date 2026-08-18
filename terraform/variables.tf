# Variables the Qwiklabs runtime injects at Start Lab time.
#
# ⚠️ RULE: every variable here must be one the platform actually supplies, under
# the exact name the platform uses. Nothing is present to answer a prompt, and a
# required variable the runtime does not know about fails the apply — for every
# student in the room, at once, with no partial success.
#
# MEASURED, from a live Start Lab log (2026-08-18), the ENTIRE command line is:
#   terraform apply -var gcp_project_id=... -var gcp_zone=... -var gcp_region=... -auto-approve
# Three variables. Everything else arrives only because qwiklabs.yaml declares
# it under startup_script.custom_properties.

variable "gcp_project_id" {
  description = "Project the lab platform provisions for the student."
  type        = string
}

variable "gcp_region" {
  description = <<-EOT
    Deployment region. Constrained to us-central1 or us-east1 for THREE independent
    reasons in this lab — one more than Lab 1 had:
      1. QueryData context sets exist in only four regions (us-central1, us-east1,
         europe-west4, asia-southeast1); these are the two US ones. Confirmed verbatim
         in the context-sets overview, 2026-08-18.
      2. google_ml.embedding() calls Vertex from the cluster's own region, so the region
         must serve gemini-embedding-001.
      3. ai.rank()'s reranker form resolves to Discovery Engine's locations/global, which
         offers global/us/eu only.
    qwiklabs.yaml narrows allowed_locations to match. Both gates, deliberately.
  EOT
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-central1", "us-east1"], var.gcp_region)
    error_message = "Region must be us-central1 or us-east1 (QueryData context sets + embedding model availability)."
  }
}

variable "gcp_zone" {
  description = <<-EOT
    Zone within gcp_region. Nothing consumes it — there is no startup VM in this lab
    either — but Qwiklabs injects it and it costs nothing to declare, so it stays.
    ⚠️ Do NOT wire it into the AlloyDB instance as gce_zone. See the availability_type
    note in main.tf: pinning a zone re-creates the capacity failure ZONAL just fixed.
  EOT
  type        = string
  default     = "us-central1-a"
}

# -----------------------------------------------------------------------------
# ⚠️ THE VARIABLE MOST LIKELY TO KILL START LAB
# -----------------------------------------------------------------------------
# `username` carries the LOCAL PART ONLY — "student-03-abc123", no domain — when
# qwiklabs.yaml passes user_0.local_username, and the FULL ADDRESS when it passes
# user_0.username. Measured on a live run; the two references are different values:
#
#   user_0.username        -> "student-03-5f4bdd24d19c@qwiklabs.net"   FULL EMAIL
#   user_0.local_username  -> "student-03-5f4bdd24d19c"                LOCAL PART
#
# main.tf appends the domain only when it is absent, so either reference works.
#
# Two ways the standalone dev version of Lab 1's file got this wrong, both of which
# applied cleanly at a desk and failed at Start Lab:
#   1. Named `gcp_username`. The platform does not inject that name, and the variable
#      had no default -> "No value for required variable", room dead.
#   2. Validated that the value CONTAINED an "@". The platform's real value never does.
#
# Both were invisible to testing, because testing supplied a hand-written
# terraform.tfvars with a full email in it. A tfvars you wrote yourself proves your
# config parses; it proves nothing about what the platform hands you.
#
# In LAB 2 this is even more load-bearing than in Lab 1: it is not only the
# alloydbsuperuser grant, it is also the `member` on the three project-level QueryData
# roles. Get it wrong and the grants land on a principal nobody owns, the apply
# succeeds, the outputs look right, and Task 3 dies 25 minutes in.
# -----------------------------------------------------------------------------
variable "username" {
  description = <<-EOT
    The student's lab username. EITHER "student-03-abc123" (local part, what
    user_0.local_username gives) OR "student-03-abc123@qwiklabs.net" (full address,
    what user_0.username gives). main.tf appends the domain only when it is absent.

    ⚠️ NOT injected automatically. Qwiklabs passes only gcp_project_id, gcp_region
    and gcp_zone on its own. This arrives ONLY because qwiklabs.yaml declares it under
    startup_script.custom_properties. Delete that block and this apply halts on
    "No value for required variable" for every student simultaneously.

    Do NOT use data.google_client_openid_userinfo — that returns the Terraform
    runner's identity, not the student's.
  EOT
  type        = string

  validation {
    condition     = length(regexall("@", var.username)) <= 1
    error_message = "username must be either the local part (student-03-abc123) or one full address (student-03-abc123@qwiklabs.net)."
  }

  validation {
    condition     = length(trimspace(var.username)) > 0
    error_message = "username is empty. Without it the student gets neither alloydbsuperuser nor the QueryData roles, and Tasks 3-5 all fail."
  }
}

# ---------------------------------------------------------------------------
# Tunables — not injected by the platform, defaults are the shipped values.
# ---------------------------------------------------------------------------

variable "cpu_count" {
  description = <<-EOT
    Primary instance vCPUs. Measured on Lab 1: cluster + instance creation is ~9 min at
    8 vCPU and dominates provisioning wall-clock, so this is the only real lever on how
    far ahead an instructor must pre-warm.

    Left at 8 deliberately. Lab 2 asks MORE of the instance than Lab 1 did, not less:
    the Task 0 load is the same 1.6M rows, and Task 6's proxy-model training runs a
    logistic regression over 3072-dimension embeddings on top of it. Shrinking this
    would invalidate every timing we carry forward and would slow the one task whose
    story is a speed claim.
  EOT
  type        = number
  default     = 8
}

variable "student_email_domain" {
  description = <<-EOT
    Domain appended to var.username. Qwiklabs issues qwiklabs.net addresses; this is a
    variable only so the same config can be applied by hand in a personal project, where
    your identity is your own Google account domain.
  EOT
  type        = string
  default     = "qwiklabs.net"
}
