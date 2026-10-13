# infrastructure/modules/media-cdn/main.tf
#
# CloudFront in front of the media bucket (guest-mode B6, core-platform-infra#25):
# ResolveDelivery's PUBLIC URLs are MEDIA_CDN_BASE_URL/<storage key>. The bucket
# keeps S3 Block Public Access on; the distribution reads it through Origin
# Access Control (OAC), the only principal the bucket policy lets in.
#
#   * Keys are content-addressed and immutable (a new upload is a new hash and a
#     new URL): cache for a year, no cookies / query strings / headers in the key.
#   * GET/HEAD only, HTTPS only (HTTP redirects), compression on. HLS (.m3u8,
#     .m4s) is served as-is.
#   * NEVER served, whatever the key: quarantine/ (takedowns,
#     core-platform-backend#758), uploads/ (originals) and private/ (verification
#     documents, #777): an explicit Deny for the distribution in the bucket
#     policy. Those are read only through short-lived S3 presigned URLs signed
#     with media's own keys, which this policy does not affect.
#   * SIGNED ONLY: restricted/ (non-public renditions, per asset,
#     core-platform-infra#56/#90). Its own cache behavior trusts this module's
#     key group, so CloudFront answers 403 without valid signed cookies. Media
#     signs a custom policy over the asset's whole tree (an HLS master, its rung
#     playlists and segments: a presigned master URL can't authorize the
#     relative URIs a player resolves). A viewer-request function on the default
#     behavior refuses an encoded path that S3 would decode into restricted/.
#     Inert until media writes there (MEDIA_RESTRICTED_PREFIX_ENABLED).
#   * Takedown purge: the media IAM user gets cloudfront:CreateInvalidation on
#     this distribution (MEDIA_CLOUDFRONT_DISTRIBUTION_ID).
#
# The bucket policy is owned HERE (one policy per bucket): nothing else may set
# one on the media bucket.

data "aws_route53_zone" "this" {
  name         = var.zone_name
  private_zone = false
}

resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${var.name}-media"
  description                       = "Media bucket read access for the media CDN."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Immutable, content-addressed objects: one year, nothing varies the key.
resource "aws_cloudfront_cache_policy" "immutable" {
  name        = "${var.name}-media-immutable"
  comment     = "Content-addressed media: cache a year, no cookies/query/headers."
  default_ttl = 31536000
  max_ttl     = 31536000
  min_ttl     = 86400

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
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

locals {
  origin_id = "media-s3"
}

# ── Signed cookies for restricted/ (core-platform-infra#90) ───────────────────
# The signing key is generated HERE, so no one handles it. The private key
# therefore sits in this unit's Terraform state (S3, encrypted, like the other
# generated credentials) and in Secrets Manager, which media reads through ESO
# (media-cdn-cookie: MEDIA_CDN_COOKIE_KEY_PAIR_ID / MEDIA_CDN_COOKIE_PRIVATE_KEY).
# Cookies live 1 h (MEDIA_CDN_COOKIE_TTL_SECS), so rotating means `-replace` on
# tls_private_key.cookie, then restarting media-server: cookies issued under the
# old key fail at once and players fetch fresh ones on the next resolve.
resource "tls_private_key" "cookie" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_cloudfront_public_key" "cookie" {
  name        = "${var.name}-media-cookie"
  comment     = "Verifies media's signed cookies on ${var.signed_prefix}*."
  encoded_key = tls_private_key.cookie.public_key_pem
}

resource "aws_cloudfront_key_group" "cookie" {
  name    = "${var.name}-media-cookie"
  comment = "Signers of ${var.signed_prefix}* (media-server)."
  items   = [aws_cloudfront_public_key.cookie.id]
}

resource "aws_secretsmanager_secret" "cookie" {
  name                    = "${var.name}-media-cdn-cookie"
  description             = "media-server's CloudFront signed-cookie key (key pair id + RSA private key, PKCS#1 PEM)."
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "cookie" {
  secret_id = aws_secretsmanager_secret.cookie.id
  secret_string = jsonencode({
    key_pair_id = aws_cloudfront_public_key.cookie.id
    private_key = tls_private_key.cookie.private_key_pem
  })
}

# A request that reaches the DEFAULT behavior never matched "restricted/*"
# literally, but S3 decodes the key (restricted%2F… is restricted/…). Refuse
# any path that decodes into the signed prefix, so only the signed behavior
# serves it.
resource "aws_cloudfront_function" "guard_signed_prefix" {
  name    = "${var.name}-media-guard-signed"
  runtime = "cloudfront-js-2.0"
  comment = "403 for encoded paths into ${var.signed_prefix} on the default behavior."
  publish = true
  code    = <<-JS
    function handler(event) {
      var uri = event.request.uri;
      var decoded;
      try {
        decoded = decodeURIComponent(uri);
      } catch (e) {
        return { statusCode: 400, statusDescription: "Bad Request" };
      }
      if (decoded.replace(/^\/+/, "").indexOf("${var.signed_prefix}") === 0) {
        return { statusCode: 403, statusDescription: "Forbidden" };
      }
      return event.request;
    }
  JS
}

# ⚠️ The bucket policy can't tell this distribution's behaviors apart, so
# restricted/ is guarded by CloudFront alone: the restricted/* behavior
# (trusted_key_groups) and the guard function on the default behavior. Any
# ordered_cache_behavior added later (e.g. "*.m3u8") MUST also carry the
# guard_signed_prefix function_association, or an encoded path
# (restricted%2F…) matching it would reach restricted/ unsigned.
resource "aws_cloudfront_distribution" "media" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name} media CDN"
  aliases         = [var.domain_name]
  price_class     = var.price_class
  http_version    = "http2and3"
  tags            = var.tags

  origin {
    origin_id                = local.origin_id
    domain_name              = var.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.media.id
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.immutable.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.guard_signed_prefix.arn
    }
  }

  # Non-public renditions: signed cookies only. Same immutable cache (the
  # cookies are validated at the edge, before the cache, and never forwarded
  # or keyed on).
  ordered_cache_behavior {
    path_pattern           = "${var.signed_prefix}*"
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.immutable.id
    trusted_key_groups     = [aws_cloudfront_key_group.cookie.id]
  }

  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# ── Bucket policy: the distribution reads, except the private prefixes ────────
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "CdnRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.media.arn]
    }
  }

  statement {
    sid       = "CdnNeverServesPrivatePrefixes"
    effect    = "Deny"
    actions   = ["s3:GetObject"]
    resources = [for p in var.private_prefixes : "${var.bucket_arn}/${p}*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.media.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "media" {
  bucket = var.bucket_name
  policy = data.aws_iam_policy_document.bucket.json
}

# ── Takedown purge rights for media's static-key IAM user ─────────────────────
# Granted BEFORE MEDIA_CLOUDFRONT_DISTRIBUTION_ID is set (the CMP value comes
# from this unit's output): once set, a failed purge fails the takedown.
resource "aws_iam_user_policy" "media_invalidation" {
  name = "cloudfront-invalidate-media"
  user = var.media_iam_user_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "TakedownPurge"
      Effect   = "Allow"
      Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
      Resource = [aws_cloudfront_distribution.media.arn]
    }]
  })
}

# ── DNS ───────────────────────────────────────────────────────────────────────
resource "aws_route53_record" "alias" {
  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.this.zone_id
  name     = var.domain_name
  type     = each.value

  alias {
    name                   = aws_cloudfront_distribution.media.domain_name
    zone_id                = aws_cloudfront_distribution.media.hosted_zone_id
    evaluate_target_health = false
  }
}
