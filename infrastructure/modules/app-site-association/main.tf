# infrastructure/modules/app-site-association/main.tf
#
# Serves the iOS app's apple-app-site-association (AASA) file on its web domain
# (core-platform-infra#31/#35/#36):
#   * applinks — universal links (/@handle, /tag/<tag>, /s/<token>) open the app;
#   * webcredentials — passkeys bound to this domain (auth AUTH_WEBAUTHN_RP_ID).
#
# Apple's requirements: https on the apex, HTTP 200, NO redirect,
# `content-type: application/json`, no file extension. Apple fetches it through
# its own CDN (app-site-association.cdn-apple.com), which caches it; the 5-minute
# TTL here only bounds our edge.
#
# A private S3 bucket (Block Public Access on) behind CloudFront with Origin
# Access Control, an ACM cert (us-east-1, DNS-validated in the domain's Route53
# zone) and A/AAAA aliases on the apex. Every other path answers 403 (no web
# fallback pages yet).

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

data "aws_caller_identity" "current" {}

locals {
  slug = replace(var.domain_name, ".", "-")
  aasa = jsonencode(merge(
    {
      applinks = {
        details = [{
          appIDs     = var.app_ids
          components = [for c in var.applinks_components : { "/" = c.path, comment = c.comment }]
        }]
      }
    },
    var.webcredentials ? { webcredentials = { apps = var.app_ids } } : {},
  ))
}

# ── Content ───────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "site" {
  bucket        = "core-platform-${local.slug}-site-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # only generated content; Terraform rewrites it
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The canonical path, plus the legacy root path older iOS versions also try.
resource "aws_s3_object" "aasa" {
  for_each     = toset([".well-known/apple-app-site-association", "apple-app-site-association"])
  bucket       = aws_s3_bucket.site.id
  key          = each.value
  content      = local.aasa
  content_type = "application/json"
  etag         = md5(local.aasa)
}

# ── TLS (CloudFront needs the cert in us-east-1, the provider's region here) ──
resource "aws_acm_certificate" "site" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

# Blocks until the zone is delegated at the registrar (NS) and DNS resolves.
resource "aws_acm_certificate_validation" "site" {
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ── CloudFront ────────────────────────────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${local.slug}-site"
  description                       = "${var.domain_name} site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_cache_policy" "short" {
  name        = "${local.slug}-site-5min"
  comment     = "AASA: short TTL, Apple's CDN caches on its side."
  default_ttl = 300
  max_ttl     = 300
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_distribution" "site" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.domain_name}: apple-app-site-association"
  aliases         = [var.domain_name]
  price_class     = "PriceClass_All"
  http_version    = "http2and3"
  tags            = var.tags

  origin {
    origin_id                = "site-s3"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id = "site-s3"
    # Apple requires no redirect on the AASA URL: it is fetched over https
    # directly, so the http->https redirect here never sits on its path.
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.short.id
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

data "aws_iam_policy_document" "site" {
  statement {
    sid       = "CdnRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}

# ── DNS: the apex ─────────────────────────────────────────────────────────────
resource "aws_route53_record" "apex" {
  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.this.zone_id
  name     = var.domain_name
  type     = each.value

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}
