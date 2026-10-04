# infrastructure/modules/waf-edge/variables.tf

variable "name" {
  type        = string
  description = "Env-scoped prefix, e.g. core-platform-staging. The Web ACL is <name>-client-edge; its log group is aws-waf-logs-<name>-client-edge (WAF requires the aws-waf-logs- prefix)."
}

variable "rate_limit_per_ip" {
  type        = number
  description = "Requests per 5 minutes per source IP, across the whole client edge, above which an IP is blocked. Wide on purpose: mobile carriers put many users behind one IPv4 (CGNAT)."
  default     = 2000
  validation {
    condition     = var.rate_limit_per_ip >= 10
    error_message = "WAF rate-based rules need a limit of at least 10."
  }
}

variable "guest_start_rate_limit_per_ip" {
  type        = number
  description = "Requests per 5 minutes per source IP on /auth.v1.AuthService/StartGuestSession (a tighter scope-down rule, evaluated first). 0 disables the rule. The backend also limits it per IP (the `guest-start` traffic profile)."
  default     = 100
  validation {
    condition     = var.guest_start_rate_limit_per_ip == 0 || var.guest_start_rate_limit_per_ip >= 10
    error_message = "guest_start_rate_limit_per_ip must be 0 (off) or at least 10."
  }
}

variable "common_rule_set_mode" {
  type        = string
  description = "AWSManagedRulesCommonRuleSet: \"count\" (the whole group only counts) or \"block\" (the group blocks, except common_rule_set_count_rules). The edge carries gRPC (binary protobuf over HTTP/2), so start in count and switch to block once the sampled requests are clean."
  default     = "count"
  validation {
    condition     = contains(["count", "block"], var.common_rule_set_mode)
    error_message = "common_rule_set_mode must be \"count\" or \"block\"."
  }
}

variable "common_rule_set_count_rules" {
  type        = list(string)
  description = "Rules of AWSManagedRulesCommonRuleSet kept in count when common_rule_set_mode = \"block\": the body inspectors that false-positive on binary protobuf or reject bodies over 8 KB."
  default     = ["SizeRestrictions_BODY", "CrossSiteScripting_BODY", "GenericLFI_BODY"]
}

variable "enable_bot_control" {
  type        = bool
  description = "Adds AWSManagedRulesBotControlRuleSet (Common inspection level). Off by default: about $10/month plus $1 per million requests, and of limited use for a native app."
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the WAF log group, in days."
  default     = 14
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources."
  default     = {}
}
