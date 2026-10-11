# infrastructure/modules/acm-cert/variables.tf

variable "domain_name" {
  type        = string
  description = "Apex domain for the cert; the wildcard SAN *.<domain> is added. Must match the account-global Route53 zone name."
  default     = "core-platform.click"
}

variable "manage_validation_records" {
  type        = bool
  description = "Create (and own) the DNS validation CNAMEs. ONLY global/networking/acm-validation sets true: the record is shared by every cert of the account on this domain, and its owner's destroy deletes it (core-platform-infra#80)."
  default     = false
}
