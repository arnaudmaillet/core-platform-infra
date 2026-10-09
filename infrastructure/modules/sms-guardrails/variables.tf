# infrastructure/modules/sms-guardrails/variables.tf

variable "name" {
  type        = string
  description = "Prefix for the created resources, e.g. core-platform."
  default     = "core-platform"
}

variable "monthly_spend_limit_usd" {
  type        = number
  description = "SNS account-level MonthlySpendLimit (USD). SNS stops sending SMS for the rest of the month once reached. AWS caps it at the account's SMS spending quota (1 USD by default): raising it above that needs a quota increase (support case) first, or the apply fails."
  default     = 1
}

variable "spend_alarm_thresholds_pct" {
  type        = list(number)
  description = "Alarm when the month-to-date SMS spend reaches these percentages of monthly_spend_limit_usd."
  default     = [50, 90]
}

variable "spend_spike_usd_per_hour" {
  type        = number
  description = "Alarm when the SMS spend grows by more than this many USD within one hour (an SMS-pumping burst), whatever the monthly total."
  default     = 2
}

variable "allowed_countries" {
  type        = list(string)
  description = "ISO 3166-1 alpha-2 codes SMS may be sent to. Every other country is BLOCKed by the account-default protect configuration (it applies to SNS). Keep in sync with auth's own SMS country allow-list."
  validation {
    condition     = length(var.allowed_countries) > 0 && alltrue([for c in var.allowed_countries : can(regex("^[A-Z]{2}$", c))])
    error_message = "allowed_countries must be a non-empty list of upper-case ISO alpha-2 codes."
  }
}

variable "alert_email_ssm_parameter" {
  type        = string
  description = "SSM parameter (String) holding the email address the alarms are sent to. Kept out of git on purpose (public repo): create it once with `aws ssm put-parameter`. Absent = the alarm topic exists with no subscriber."
  default     = "/core-platform/ops/alert-email"
}

variable "enable_delivery_status_logs" {
  type        = bool
  description = "Log SMS delivery statuses to CloudWatch Logs (an IAM role SNS assumes). Off by default: setting it on SNS needs iam:PassRole on that role for whoever applies, and the spend limit / Transactional default must never wait on it."
  default     = false
}

variable "delivery_status_success_sampling_pct" {
  type        = number
  description = "Percentage of SUCCESSFUL SMS deliveries logged to CloudWatch Logs (failures are always logged)."
  default     = 100
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the SNS SMS delivery-status log groups, in days."
  default     = 30
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources."
  default     = {}
}
