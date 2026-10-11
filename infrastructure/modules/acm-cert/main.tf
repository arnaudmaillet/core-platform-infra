# infrastructure/modules/acm-cert/main.tf
#
# The platform's public ACM certificate (apex + wildcard), DNS-validated against
# the account-global Route53 zone. Deliberately its OWN unit, DECOUPLED from eks:
# an ACM cert can't be deleted while an ALB/NLB still references it, and LB
# deprovision lags the k8s Service deletion. When the cert lived in the eks unit,
# that ResourceInUseException failed the eks destroy, which early-exited the vpc
# destroy → the whole VPC (NAT/subnets/ENIs) leaked. As a standalone unit with no
# dependency on eks/vpc, a cert-in-use failure is isolated: eks and vpc still
# destroy cleanly, and the cert is reclaimed on a later pass once the LB is gone.

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "cert" {
  domain_name               = var.domain_name
  validation_method         = "DNS"
  subject_alternative_names = ["*.${var.domain_name}"]

  lifecycle {
    create_before_destroy = true
  }
}

# ACM's DNS validation CNAME is the SAME record for every certificate of this
# account on a given domain (and the same for the apex and its wildcard). Only
# ONE unit may own it (core-platform-infra#80): global/networking/acm-validation
# (manage_validation_records = true). Every other cert unit leaves it alone, so
# destroying one (a staging teardown) never deletes the record the others need to
# auto-renew.
resource "aws_route53_record" "cert_validation" {
  # The apex and its wildcard yield the SAME record, so only the apex's is managed
  # (managing both made two resources own one record). Keyed by domain name: it is
  # known at plan time, unlike the record name of a cert not yet requested.
  for_each = var.manage_validation_records ? {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => dvo
    if !startswith(dvo.domain_name, "*.")
  } : {}

  allow_overwrite = true
  name            = each.value.resource_record_name
  records         = [each.value.resource_record_value]
  ttl             = 60
  type            = each.value.resource_record_type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# The validation waits on the record whoever owns it: names come from the cert
# itself, so a non-owner still blocks until the owner unit has created it.
resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for dvo in aws_acm_certificate.cert.domain_validation_options : trimsuffix(dvo.resource_record_name, ".")]
}
