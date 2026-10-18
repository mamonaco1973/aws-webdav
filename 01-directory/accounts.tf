# ==============================================================================
# File: accounts.tf
# ------------------------------------------------------------------------------
# Purpose:
#   - Generates Active Directory (AD) user credentials for lab and quick-start
#     environments.
#   - Stores all credentials securely in AWS Secrets Manager.
#
# Scope:
#   - Creates a single AD Administrator account secret.
#   - Creates multiple standard AD user account secrets.
#   - Admin: a strong random password. Users: a memorable word plus a
#     random 6-digit number (e.g. "orange-481920"), easy to type at a
#     Windows sign-in or RDP prompt.
#
# Notes:
#   - Passwords are generated at apply time and never logged.
#   - Secrets are versioned automatically by AWS Secrets Manager.
#   - Usernames are constructed using the NetBIOS domain prefix.
#   - This file is intentionally explicit (non-dynamic) for clarity in
#     instructional and demo environments.
#   - The admin password is force-prefixed with "A" (see locals below).
# ==============================================================================


# ==============================================================================
# PASSWORD ASSEMBLY
# ==============================================================================
# Admin: random_password can emit a leading "-", which downstream consumers
# parse as a command-line flag instead of a value (realm join -U, net ads,
# PowerShell). Prefixing a literal "A" guarantees the first character is
# alphanumeric and also satisfies the AD complexity rule for an uppercase
# character. The random half is 23 chars so the assembled password stays 24.
#
# Users: "<word>-<6 digits>". Lowercase, digits and "-" are three character
# classes, which meets AD complexity.
# ==============================================================================

locals {
  word_users = toset(["jsmith", "edavis", "rpatel", "akumar"])

  memorable_words = [
    "bright", "simple", "orange", "window", "little", "people", "friend",
    "yellow", "animal", "family", "circle", "moment", "summer", "button",
    "planet", "rocket", "silver", "forest", "stream", "butter", "castle",
    "wonder", "gentle", "driver", "coffee"
  ]
}

# One random memorable word per user.
resource "random_shuffle" "word" {
  for_each     = local.word_users
  input        = local.memorable_words
  result_count = 1
}

# One random 6-digit number per user.
resource "random_integer" "num" {
  for_each = local.word_users
  min      = 100000
  max      = 999999
}

locals {
  user_passwords = {
    for user in local.word_users :
    user => format("%s-%d", random_shuffle.word[user].result[0], random_integer.num[user].result)
  }

  admin_password  = "A${random_password.admin_password.result}"
  jsmith_password = local.user_passwords["jsmith"]
  edavis_password = local.user_passwords["edavis"]
  rpatel_password = local.user_passwords["rpatel"]
  akumar_password = local.user_passwords["akumar"]
}


# ==============================================================================
# AD ADMINISTRATOR ACCOUNT
# ==============================================================================

# ------------------------------------------------------------------------------
# Generate a random password for the AD Administrator account
# ------------------------------------------------------------------------------
resource "random_password" "admin_password" {
  length           = 23   # 23 + the "A" prefix = 24 total
  special          = true # Include special characters
  override_special = "_-" # Restrict special characters to safe set
}

# ------------------------------------------------------------------------------
# Secrets Manager secret for AD Administrator credentials
# ------------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "admin_secret" {
  name        = "admin_ad_credentials_webdav"
  description = "AD Administrator Credentials (WebDAV)"

  lifecycle {
    prevent_destroy = false
  }
}

# ------------------------------------------------------------------------------
# Store AD Administrator credentials as a versioned secret
# ------------------------------------------------------------------------------
resource "aws_secretsmanager_secret_version" "admin_secret_version" {
  secret_id = aws_secretsmanager_secret.admin_secret.id

  secret_string = jsonencode({
    username = "${var.netbios}\\Admin"
    password = local.admin_password
  })
}


# ==============================================================================
# STANDARD AD USER ACCOUNTS
# ==============================================================================

# ------------------------------------------------------------------------------
# User: John Smith (jsmith)
# ------------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "jsmith_secret" {
  name        = "jsmith_ad_credentials_webdav"
  description = "John Smith AD Credentials (WebDAV)"

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_secretsmanager_secret_version" "jsmith_secret_version" {
  secret_id = aws_secretsmanager_secret.jsmith_secret.id

  secret_string = jsonencode({
    username = "${var.netbios}\\jsmith"
    password = local.jsmith_password
  })
}


# ------------------------------------------------------------------------------
# User: Emily Davis (edavis)
# ------------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "edavis_secret" {
  name        = "edavis_ad_credentials_webdav"
  description = "Emily Davis AD Credentials (WebDAV)"

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_secretsmanager_secret_version" "edavis_secret_version" {
  secret_id = aws_secretsmanager_secret.edavis_secret.id

  secret_string = jsonencode({
    username = "${var.netbios}\\edavis"
    password = local.edavis_password
  })
}


# ------------------------------------------------------------------------------
# User: Raj Patel (rpatel)
# ------------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "rpatel_secret" {
  name        = "rpatel_ad_credentials_webdav"
  description = "Raj Patel AD Credentials (WebDAV)"

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_secretsmanager_secret_version" "rpatel_secret_version" {
  secret_id = aws_secretsmanager_secret.rpatel_secret.id

  secret_string = jsonencode({
    username = "${var.netbios}\\rpatel"
    password = local.rpatel_password
  })
}


# ------------------------------------------------------------------------------
# User: Amit Kumar (akumar)
# ------------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "akumar_secret" {
  name        = "akumar_ad_credentials_webdav"
  description = "Amit Kumar AD Credentials (WebDAV)"

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_secretsmanager_secret_version" "akumar_secret_version" {
  secret_id = aws_secretsmanager_secret.akumar_secret.id

  secret_string = jsonencode({
    username = "${var.netbios}\\akumar"
    password = local.akumar_password
  })
}
