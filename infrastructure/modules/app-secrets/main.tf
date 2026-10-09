# infrastructure/modules/app-secrets/main.tf
#
# Seeds the application secrets that the workload overlay's ExternalSecrets pull
# from AWS Secrets Manager but that NO other Terraform unit creates (previously
# "create out-of-band" — the gap that left media/audit/auth pods in
# CreateContainerConfigError). Generates everything so a from-scratch env needs
# zero manual steps:
#   * <name>-media-s3     {access_key, secret_key}                 (rusty-s3 static keys)
#   * <name>-scylla-s3    {access_key, secret_key}                 (scylla-manager-agent backups)
#   * <name>-audit-crypto {object/witness S3 keys, kek_base64, signing_key_base64}
#   * <name>-auth-secrets {ES256 signing PEM pair, keycloak_client_secret,
#                          keycloak_admin_client_secret}
#   * <name>-auth-smtp    {username, password}                     (SES SMTP, one-time email codes)
#   * <name>-auth-sns     {access_key_id, secret_access_key}       (SNS SMS, one-time SMS codes)
#   * <name>-auth-mfa     {seed_key, seed_key_id}                  (TOTP seed encryption key)
#   * <name>-account-exports {access_key_id, secret_access_key}    (GDPR export bucket)
#   * <name>-notification-apns {key_id, key_p8}                    (APNs, OWNER-filled; no TF value)
#
# STAGING v1 PATH: static IAM keys (rusty-s3 cannot use IRSA web-identity) and the
# env-KEK / signing key are GENERATED HERE and live in Terraform state. Prod's
# tamper-evidence story (real KMS/HSM custody, cross-account WORM witness) is the
# documented external deferral — see the audit blueprint; do NOT use this path for
# prod. The ESO read policy already covers <name>-* (modules/security/irsa-roles).
#
# NB: the tls (auth_signing) and random (KEK/signing/keycloak) providers are
# resolved implicitly by Terraform from the resource prefixes. They are NOT
# declared in a required_providers block here on purpose: Terragrunt generates the
# module's only versions.tf (aws + time, overwrite_terragrunt) and a module may
# have just one required_providers block.

# ── media: static S3 keys ─────────────────────────────────────────────────────
resource "aws_iam_user" "media" {
  name = "${var.name}-media-s3"
  tags = var.tags
}

resource "aws_iam_user_policy" "media" {
  name = "media-s3-rw"
  user = aws_iam_user.media.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [var.media_bucket_arn]
      },
      {
        Sid      = "ObjectRW"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = ["${var.media_bucket_arn}/*"]
      },
    ]
  })
}

resource "aws_iam_access_key" "media" {
  user = aws_iam_user.media.name
}

resource "aws_secretsmanager_secret" "media_s3" {
  name                    = "${var.name}-media-s3"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "media_s3" {
  secret_id = aws_secretsmanager_secret.media_s3.id
  secret_string = jsonencode({
    access_key = aws_iam_access_key.media.id
    secret_key = aws_iam_access_key.media.secret
  })
}

# ── scylla: static S3 keys for the Scylla Manager agent (backups) ─────────────
# Unlike audit's append-only users, the agent PURGES snapshots past the backup
# task's retention, so it needs delete on the backup bucket. Keys reach the
# `scylla` namespace as scylla-agent-config-secret via an ExternalSecret
# (k8s/base/infra/scylla-cluster).
resource "aws_iam_user" "scylla" {
  name = "${var.name}-scylla-s3"
  tags = var.tags
}

resource "aws_iam_user_policy" "scylla" {
  name = "scylla-backups-rw"
  user = aws_iam_user.scylla.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [var.scylla_backups_bucket_arn]
      },
      {
        Sid      = "SnapshotRW"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = ["${var.scylla_backups_bucket_arn}/*"]
      },
    ]
  })
}

resource "aws_iam_access_key" "scylla" {
  user = aws_iam_user.scylla.name
}

resource "aws_secretsmanager_secret" "scylla_s3" {
  name                    = "${var.name}-scylla-s3"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "scylla_s3" {
  secret_id = aws_secretsmanager_secret.scylla_s3.id
  secret_string = jsonencode({
    access_key = aws_iam_access_key.scylla.id
    secret_key = aws_iam_access_key.scylla.secret
  })
}

# ── audit: static S3 keys (object store + witness) + crypto custody (v1) ───────
# Two independent users so object-store and witness credentials rotate separately.
# Both scoped to the WORM bucket, append-only (Object-Lock blocks deletes anyway),
# plus KMS to write/read the SSE-KMS objects under the audit KEK.
resource "aws_iam_user" "audit_object" {
  name = "${var.name}-audit-object"
  tags = var.tags
}

resource "aws_iam_user" "audit_witness" {
  name = "${var.name}-audit-witness"
  tags = var.tags
}

resource "aws_iam_user_policy" "audit_object" {
  name   = "audit-worm-append"
  user   = aws_iam_user.audit_object.name
  policy = local.audit_worm_policy
}

resource "aws_iam_user_policy" "audit_witness" {
  name   = "audit-worm-append"
  user   = aws_iam_user.audit_witness.name
  policy = local.audit_worm_policy
}

locals {
  # Append-only write + read to the WORM bucket; GenerateDataKey/Decrypt on the
  # audit KEK for SSE-KMS. No s3:DeleteObject (the ledger never deletes).
  audit_worm_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ListBucket", Effect = "Allow", Action = ["s3:ListBucket"], Resource = [var.audit_worm_bucket_arn] },
      { Sid = "ObjectAppend", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = ["${var.audit_worm_bucket_arn}/*"] },
      { Sid = "KmsForSse", Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = [var.audit_kms_key_arn] },
    ]
  })
}

resource "aws_iam_access_key" "audit_object" {
  user = aws_iam_user.audit_object.name
}

resource "aws_iam_access_key" "audit_witness" {
  user = aws_iam_user.audit_witness.name
}

# App-level env KEK (wraps per-subject DEKs for crypto-shred) + checkpoint signing
# key. 32 random bytes each, base64. v1 only — prod custody = real KMS/HSM.
resource "random_bytes" "audit_kek" {
  length = 32
}

resource "random_bytes" "audit_signing_key" {
  length = 32
}

resource "aws_secretsmanager_secret" "audit_crypto" {
  name                    = "${var.name}-audit-crypto"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "audit_crypto" {
  secret_id = aws_secretsmanager_secret.audit_crypto.id
  secret_string = jsonencode({
    object_access_key  = aws_iam_access_key.audit_object.id
    object_secret_key  = aws_iam_access_key.audit_object.secret
    witness_access_key = aws_iam_access_key.audit_witness.id
    witness_secret_key = aws_iam_access_key.audit_witness.secret
    kek_base64         = random_bytes.audit_kek.base64
    signing_key_base64 = random_bytes.audit_signing_key.base64
  })
}

# ── auth: ES256 signing keypair + Keycloak client secret (placeholder) ────────
# Keycloak is not yet provisioned (auth prerequisite), so the client secret is a
# generated placeholder until it lands.
resource "tls_private_key" "auth_signing" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "random_password" "keycloak_client_secret" {
  length  = 40
  special = false
}

# Second confidential client (core-platform-auth-admin): a service account auth
# uses via client_credentials to set/verify passwords through the Keycloak Admin
# API (auth.v1.ChangePassword / VerifyCredentials). A SEPARATE resource so adding
# it never regenerates keycloak_client_secret — same one-value/two-consumers
# contract: auth sends it, the imported realm expects it.
resource "random_password" "keycloak_admin_client_secret" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "auth_secrets" {
  name                    = "${var.name}-auth-secrets"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

# ── keycloak: bootstrap admin credential ─────────────────────────────────────
# Consumed by the keycloak platform app's ExternalSecret (ns keycloak) as
# KC_BOOTSTRAP_ADMIN_PASSWORD. The client secret Keycloak's imported realm
# expects is the SAME keycloak_client_secret published in <name>-auth-secrets
# below — one generated value, two consumers, zero drift (likewise
# keycloak_admin_client_secret for the core-platform-auth-admin client).
resource "random_password" "keycloak_admin_password" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "keycloak" {
  name                    = "${var.name}-keycloak"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "keycloak" {
  secret_id = aws_secretsmanager_secret.keycloak.id
  secret_string = jsonencode({
    admin_password = random_password.keycloak_admin_password.result
  })
}

resource "aws_secretsmanager_secret_version" "auth_secrets" {
  secret_id = aws_secretsmanager_secret.auth_secrets.id
  secret_string = jsonencode({
    # PKCS#8, not the default SEC1 ("EC PRIVATE KEY") PEM: auth's jsonwebtoken/
    # ring EC path only accepts PKCS#8 — with SEC1 the key never loads and the
    # service fail-closes with "no signing key is currently available" (found
    # live on the staging bring-up).
    signing_private_pem          = tls_private_key.auth_signing.private_key_pem_pkcs8
    signing_public_pem           = tls_private_key.auth_signing.public_key_pem
    keycloak_client_secret       = random_password.keycloak_client_secret.result
    keycloak_admin_client_secret = random_password.keycloak_admin_client_secret.result
  })
}

# ── auth: SES SMTP credentials (one-time email codes, guest-mode B4b) ─────────
# auth sends its StartVerification codes through the SES SMTP interface
# (email-smtp.<region>.amazonaws.com:587, STARTTLS). SMTP credentials are an IAM
# user's access key: the username is the key id, the password is derived from the
# secret (aws_iam_access_key.ses_smtp_password_v4, region-specific). The user may
# only send as ses_from_address (ses:FromAddress), an address of the account-global
# domain identity (global/messaging/ses-identity).
#
# Resource is identity/* on purpose: while the account is in the SES SANDBOX, SES
# also authorizes the send against the RECIPIENT's verified identity, so a policy
# limited to the domain identity gets AccessDenied on every staging test send.
# The From condition is what scopes the user.
#
# ROTATION (long-lived key, also in Terraform state): `terragrunt apply
# -replace=aws_iam_access_key.auth_smtp` in data/app-secrets, then ESO refreshes
# auth-smtp within 1h (or annotate the ExternalSecret `force-sync`), then restart
# auth-server: envFrom is only read at pod start.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_user" "auth_smtp" {
  name = "${var.name}-auth-smtp"
  tags = var.tags
}

resource "aws_iam_user_policy" "auth_smtp" {
  name = "ses-send-codes"
  user = aws_iam_user.auth_smtp.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SendAsNoReplyOnly"
        Effect   = "Allow"
        Action   = ["ses:SendRawEmail"]
        Resource = ["arn:aws:ses:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:identity/*"]
        Condition = {
          StringEquals = { "ses:FromAddress" = var.ses_from_address }
        }
      },
    ]
  })
}

resource "aws_iam_access_key" "auth_smtp" {
  user = aws_iam_user.auth_smtp.name
}

resource "aws_secretsmanager_secret" "auth_smtp" {
  name                    = "${var.name}-auth-smtp"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "auth_smtp" {
  secret_id = aws_secretsmanager_secret.auth_smtp.id
  secret_string = jsonencode({
    username = aws_iam_access_key.auth_smtp.id
    password = aws_iam_access_key.auth_smtp.ses_smtp_password_v4
  })
}

# ── auth: SNS static keys (one-time SMS codes, guest-mode B4c) ────────────────
# auth signs its own SNS Publish calls (SigV4, static keys, like media/audit), so
# it needs an IAM user. It may publish to PHONE NUMBERS ONLY: SMS publishes have
# no resource ARN (Resource "*"), so the explicit Deny on every topic/endpoint ARN
# keeps the key from reaching any SNS topic or app endpoint. Account-wide brakes
# (spend limit, country allow-list, alarms) are in global/messaging/sms.
# Rotation: same as auth_smtp above (-replace=aws_iam_access_key.auth_sns).
resource "aws_iam_user" "auth_sns" {
  name = "${var.name}-auth-sns"
  tags = var.tags
}

resource "aws_iam_user_policy" "auth_sns" {
  name = "sns-sms-codes"
  user = aws_iam_user.auth_sns.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishSms"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = ["*"]
      },
      {
        Sid      = "NoTopicsOrEndpoints"
        Effect   = "Deny"
        Action   = ["sns:Publish"]
        Resource = ["arn:aws:sns:*:*:*"]
      },
    ]
  })
}

resource "aws_iam_access_key" "auth_sns" {
  user = aws_iam_user.auth_sns.name
}

resource "aws_secretsmanager_secret" "auth_sns" {
  name                    = "${var.name}-auth-sns"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "auth_sns" {
  secret_id = aws_secretsmanager_secret.auth_sns.id
  secret_string = jsonencode({
    access_key_id     = aws_iam_access_key.auth_sns.id
    secret_access_key = aws_iam_access_key.auth_sns.secret
  })
}

# ── auth: MFA seed key (two-step sign-in, core-platform-infra#27) ─────────────
# auth encrypts each holder's TOTP seed (AES-256-GCM) with this key before
# account stores it. NEVER regenerate or delete it once anyone has enrolled:
# every account with 2FA on would be locked out of sign-in (TIER-0, fail-closed).
# Rotation = a NEW key with a new id, the old one kept in
# AUTH_MFA_SEED_KEYS_PREVIOUS (backend side).
#
# `protect_mfa_seed_key` (prod) puts prevent_destroy on the key material and the
# secret. It is two resource variants because prevent_destroy can't take a
# variable; staging keeps the unprotected one so its disposable teardown works
# (its accounts are destroyed with it).
#
# !! FLIPPING false -> true ON AN ENV WHOSE KEY EXISTS: the variants are different
# addresses, so a plain apply destroys the unprotected key (no prevent_destroy on
# it) and generates a new one = every 2FA account locked out. Move the state
# FIRST, in that env's data/app-secrets, then flip the variable and apply (the
# plan must show no change to the key or the secret):
#   terragrunt state mv 'random_bytes.auth_mfa_seed[0]' 'random_bytes.auth_mfa_seed_protected[0]'
#   terragrunt state mv 'aws_secretsmanager_secret.auth_mfa[0]' 'aws_secretsmanager_secret.auth_mfa_protected[0]'
# (true -> false is blocked by prevent_destroy: plan fails, nothing is lost; move
# the state the other way to do it on purpose.)
resource "random_bytes" "auth_mfa_seed" {
  count  = var.protect_mfa_seed_key ? 0 : 1
  length = 32
}

resource "random_bytes" "auth_mfa_seed_protected" {
  count  = var.protect_mfa_seed_key ? 1 : 0
  length = 32
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "auth_mfa" {
  count                   = var.protect_mfa_seed_key ? 0 : 1
  name                    = "${var.name}-auth-mfa"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret" "auth_mfa_protected" {
  count                   = var.protect_mfa_seed_key ? 1 : 0
  name                    = "${var.name}-auth-mfa"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
  lifecycle {
    prevent_destroy = true
  }
}

locals {
  auth_mfa_secret_id = one(concat(aws_secretsmanager_secret.auth_mfa[*].id, aws_secretsmanager_secret.auth_mfa_protected[*].id))
  auth_mfa_seed_b64  = one(concat(random_bytes.auth_mfa_seed[*].base64, random_bytes.auth_mfa_seed_protected[*].base64))
}

resource "aws_secretsmanager_secret_version" "auth_mfa" {
  secret_id = local.auth_mfa_secret_id
  secret_string = jsonencode({
    seed_key    = local.auth_mfa_seed_b64 # 32 bytes, standard base64 (44 chars)
    seed_key_id = var.mfa_seed_key_id
  })
}

# ── account: GDPR export bucket keys (core-platform-infra#28) ─────────────────
# account-server's export pass writes the archive with rusty-s3 and signs a
# 7-day download link: SigV4 presigning that long needs non-STS credentials, so
# static keys, like media. Scoped to the bucket's exports/ prefix.
# Rotation: same as auth_smtp above (-replace=aws_iam_access_key.account_exports);
# links already sent stop working with the old key.
resource "aws_iam_user" "account_exports" {
  name = "${var.name}-account-exports"
  tags = var.tags
}

resource "aws_iam_user_policy" "account_exports" {
  name = "gdpr-exports-rw"
  user = aws_iam_user.account_exports.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ExportObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = ["${var.gdpr_exports_bucket_arn}/exports/*"]
      },
    ]
  })
}

resource "aws_iam_access_key" "account_exports" {
  user = aws_iam_user.account_exports.name
}

resource "aws_secretsmanager_secret" "account_exports" {
  name                    = "${var.name}-account-exports"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "account_exports" {
  secret_id = aws_secretsmanager_secret.account_exports.id
  secret_string = jsonencode({
    access_key_id     = aws_iam_access_key.account_exports.id
    secret_access_key = aws_iam_access_key.account_exports.secret
  })
}

# ── notification: APNs auth key (iOS push, core-platform-infra#39) ────────────
# The key (AuthKey_<KEYID>.p8, Apple Developer → Keys) is the OWNER's. Terraform
# creates the secret CONTAINER only and never writes a value: the owner puts it
#   aws secretsmanager put-secret-value --secret-id <name>-notification-apns \
#     --secret-string "$(jq -n --arg id <KEYID> --rawfile p8 AuthKey_<KEYID>.p8 '{key_id:$id,key_p8:$p8}')"
# No aws_secretsmanager_secret_version on purpose: a TF-managed placeholder
# version, even with ignore_changes, is re-created empty once Secrets Manager
# deprecates it after a few owner puts (dropped from state), which would turn
# push off silently at the next restart.
# Until the owner puts a value, the notification-apns ExternalSecret reports
# SecretSyncedError (cosmetic: the volume and env are optional, push stays off,
# the pod boots). A staging teardown deletes the secret (recovery window 0):
# put the key again after a rebuild.
resource "aws_secretsmanager_secret" "notification_apns" {
  name                    = "${var.name}-notification-apns"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}
