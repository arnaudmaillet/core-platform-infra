# infrastructure/modules/ses-identity/variables.tf

variable "domain_name" {
  type        = string
  description = "Sending domain (SES domain identity). Must be the name of a public Route53 zone in this account: the DKIM, MAIL FROM and DMARC records are written there."
  default     = "core-platform.click"
}

variable "mail_from_subdomain" {
  type        = string
  description = "Custom MAIL FROM (bounce) subdomain label: <label>.<domain_name> gets the SES feedback MX and the SPF record, so SPF aligns with the From domain (relaxed alignment)."
  default     = "mail"
}

variable "dmarc_policy" {
  type        = string
  description = "DMARC policy published at _dmarc.<domain_name>. Only SES sends as this domain, DKIM-aligned, so quarantine is safe from day one."
  default     = "quarantine"
  validation {
    condition     = contains(["none", "quarantine", "reject"], var.dmarc_policy)
    error_message = "dmarc_policy must be none, quarantine or reject."
  }
}

variable "dmarc_rua" {
  type        = string
  description = "Optional mailbox for DMARC aggregate reports (e.g. dmarc@example.com, without mailto:). Empty = no reports requested."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources."
  default     = {}
}
