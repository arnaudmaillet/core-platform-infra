# infrastructure/modules/ses-identity/main.tf
#
# Amazon SES sending identity for the platform domain: auth's one-time email codes
# (guest-mode B4b, core-platform-infra#13; backend core-platform-backend#715).
#
# ACCOUNT + REGION scoped, like the Route53 zone it writes into, so this lives in
# the `live/global` tree and is shared by every env: one domain identity, one
# reputation, one sandbox/production-access state. The per-env part (an IAM user
# whose SMTP credentials auth uses, restricted to this identity and one From
# address) is in modules/app-secrets.
#
#   * Easy DKIM (RSA 2048): three CNAMEs <token>._domainkey.<domain>.
#   * Custom MAIL FROM <mail_from_subdomain>.<domain>: SES feedback MX + SPF, so
#     bounces come back to SES and SPF aligns with the From domain.
#   * DMARC at _dmarc.<domain>, p=quarantine: any OTHER sender of @<domain>
#     (Keycloak emails, a workspace mailbox…) must be DKIM/SPF-aligned first.
#   * Account-level suppression list (bounces + complaints): SES stops sending to
#     an address that hard-bounced or complained, protecting the reputation.
#
# NOT Terraform-manageable (one-time, per account + region, see
# docs/runbooks/environment-lifecycle.md): leaving the SES SANDBOX. In the sandbox
# SES only delivers to verified addresses (fine for staging tests); request
# production access with `aws sesv2 put-account-details` before real users sign up.

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

data "aws_region" "current" {}

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain_name
  tags           = var.tags

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# ── DKIM ──────────────────────────────────────────────────────────────────────
resource "aws_route53_record" "dkim" {
  count   = 3
  zone_id = data.aws_route53_zone.this.zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# ── Custom MAIL FROM + SPF ────────────────────────────────────────────────────
locals {
  mail_from_domain = "${var.mail_from_subdomain}.${var.domain_name}"
}

resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  email_identity         = aws_sesv2_email_identity.domain.email_identity
  mail_from_domain       = local.mail_from_domain
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

resource "aws_route53_record" "mail_from_mx" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.mail_from_domain
  type    = "MX"
  ttl     = 1800
  records = ["10 feedback-smtp.${data.aws_region.current.region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.mail_from_domain
  type    = "TXT"
  ttl     = 1800
  records = ["v=spf1 include:amazonses.com -all"]
}

# ── DMARC ─────────────────────────────────────────────────────────────────────
resource "aws_route53_record" "dmarc" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = "_dmarc.${var.domain_name}"
  type    = "TXT"
  ttl     = 1800
  records = [join("; ", compact([
    "v=DMARC1",
    "p=${var.dmarc_policy}",
    var.dmarc_rua == "" ? "" : "rua=mailto:${var.dmarc_rua}",
    "adkim=r",
    "aspf=r",
  ]))]
}

# ── Account-level suppression list ────────────────────────────────────────────
resource "aws_sesv2_account_suppression_attributes" "this" {
  suppressed_reasons = ["BOUNCE", "COMPLAINT"]
}
