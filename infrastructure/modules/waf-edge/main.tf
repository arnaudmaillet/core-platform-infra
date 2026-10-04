# infrastructure/modules/waf-edge/main.tf
#
# AWS WAF (REGIONAL) Web ACL for the CLIENT EDGE: the internet-facing ALB in front
# of the fleet's :9443 gRPC edge listeners (k8s/overlays/<env>/client-edge-ingress.yaml).
# Guest mode (core-platform-backend#675) opens reads to anonymous guest sessions, so
# the ALB gets an outer shield on top of the backend's per-IP / per-caller limits
# (the [traffic] section of infrastructure.toml).
#
# ASSOCIATION is not done here: the ALB belongs to the AWS Load Balancer Controller,
# so Terraform never knows its ARN. The ACL ARN goes to the envsubst CMP
# (WAF_EDGE_ACL_ARN, kubernetes/argocd unit) and the Ingress carries
# `alb.ingress.kubernetes.io/wafv2-acl-arn`; the controller associates it.
#
# Rules, in evaluation order:
#   1. guest-start-rate-per-ip  rate-based, scoped down to StartGuestSession (optional)
#   2. rate-per-ip              rate-based, the whole edge
#   3. ip-reputation            AWSManagedRulesAmazonIpReputationList
#   4. known-bad-inputs         AWSManagedRulesKnownBadInputsRuleSet
#   5. common                   AWSManagedRulesCommonRuleSet (count by default)
#   6. bot-control              AWSManagedRulesBotControlRuleSet (off by default)
#
# A block is an HTTP 403 from the ALB (no grpc-status): gRPC clients see
# PERMISSION_DENIED. WAF custom response headers are forced under an
# `x-amzn-waf-` prefix, so a gRPC-native RESOURCE_EXHAUSTED is not possible here;
# the backend's own limits return that.
#
# The WAF does NOT add a proxy hop (it inspects inside the ALB), so
# GRPC_TRUSTED_PROXY_HOPS stays 1. A CloudFront in front of the ALB would make it 2.
#
# Rough cost: ~$5/month per Web ACL + $1/month per rule or rule group + $0.60 per
# million requests (+ Bot Control, if enabled).

locals {
  acl_name = "${var.name}-client-edge"
}

resource "aws_wafv2_web_acl" "client_edge" {
  name        = local.acl_name
  description = "Client edge ALB (gRPC :9443): per-IP rate limits + AWS managed baseline."
  scope       = "REGIONAL"
  tags        = var.tags

  default_action {
    allow {}
  }

  # ── 1. StartGuestSession, per IP (tighter, evaluated first) ─────────────────
  dynamic "rule" {
    for_each = var.guest_start_rate_limit_per_ip > 0 ? [1] : []
    content {
      name     = "guest-start-rate-per-ip"
      priority = 10

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit                 = var.guest_start_rate_limit_per_ip
          evaluation_window_sec = 300
          aggregate_key_type    = "IP"

          scope_down_statement {
            byte_match_statement {
              search_string         = "/auth.v1.AuthService/StartGuestSession"
              positional_constraint = "EXACTLY"
              field_to_match {
                uri_path {}
              }
              text_transformation {
                priority = 0
                type     = "NONE"
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.acl_name}-guest-start-rate-per-ip"
        sampled_requests_enabled   = true
      }
    }
  }

  # ── 2. Whole edge, per IP ───────────────────────────────────────────────────
  rule {
    name     = "rate-per-ip"
    priority = 20

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit_per_ip
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.acl_name}-rate-per-ip"
      sampled_requests_enabled   = true
    }
  }

  # ── 3. Amazon IP reputation list ────────────────────────────────────────────
  rule {
    name     = "ip-reputation"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.acl_name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # ── 4. Known bad inputs (Log4j, Java deserialization, …) ────────────────────
  rule {
    name     = "known-bad-inputs"
    priority = 40

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.acl_name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ── 5. Common rule set (count until the gRPC traffic is proven clean) ───────
  rule {
    name     = "common"
    priority = 50

    dynamic "override_action" {
      for_each = var.common_rule_set_mode == "count" ? [1] : []
      content {
        count {}
      }
    }

    dynamic "override_action" {
      for_each = var.common_rule_set_mode == "block" ? [1] : []
      content {
        none {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        # In block mode, the body inspectors stay in count: binary protobuf
        # bodies false-positive, and SizeRestrictions_BODY rejects bodies > 8 KB.
        dynamic "rule_action_override" {
          for_each = var.common_rule_set_mode == "block" ? toset(var.common_rule_set_count_rules) : toset([])
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.acl_name}-common"
      sampled_requests_enabled   = true
    }
  }

  # ── 6. Bot Control (prepared, off by default) ───────────────────────────────
  dynamic "rule" {
    for_each = var.enable_bot_control ? [1] : []
    content {
      name     = "bot-control"
      priority = 60

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesBotControlRuleSet"

          managed_rule_group_configs {
            aws_managed_rules_bot_control_rule_set {
              inspection_level = "COMMON"
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.acl_name}-bot-control"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.acl_name
    sampled_requests_enabled   = true
  }
}

# ── Logging ───────────────────────────────────────────────────────────────────
# CloudWatch Logs, short retention. The name MUST start with `aws-waf-logs-`.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${local.acl_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "client_edge" {
  resource_arn            = aws_wafv2_web_acl.client_edge.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Every edge call carries a bearer edge token: never write it to the logs.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}
