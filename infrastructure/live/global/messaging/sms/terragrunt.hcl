# infrastructure/live/global/messaging/sms/terragrunt.hcl
#
# Account-level guardrails for SMS sent through Amazon SNS (auth's one-time codes
# for phone-only accounts, guest-mode B4c, core-platform-infra#14): spend limit,
# spend alarms, country allow-list (protect configuration, account default) and
# delivery-status logs. Account + region scoped like the SNS settings themselves,
# hence `global/`. The per-env sender IAM users are in data/app-secrets.
#
# Applier prerequisites: the AWS CLI v2 (the country allow-list runs through
# scripts/sms-protect.sh, the provider has no resource for it).
#
# One-time manual steps, NOT in Terraform (docs/runbooks/environment-lifecycle.md):
#   * the alarm email lives in SSM, out of this PUBLIC repo:
#       aws ssm put-parameter --name /core-platform/ops/alert-email --type String --value <email>
#     (then re-apply, and confirm the subscription from the inbox);
#   * leave the SNS SMS sandbox, and raise the SMS spending quota (1 USD by default)
#     before raising monthly_spend_limit_usd below.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  # 4 levels up reaches infrastructure/ (live/global/messaging/sms).
  source = "../../../../modules/sms-guardrails"
}

inputs = {
  name = "core-platform"

  # 1 USD = the SMS spending quota every account starts with; AWS rejects a higher
  # limit until a quota increase is granted. Owner's target: 20 USD/month, set it
  # here once the increase (requested with the sandbox exit) lands.
  monthly_spend_limit_usd = 1

  # Launch markets for SMS codes. Email and Sign in with Apple stay available
  # everywhere; SMS (the only per-message cost and the toll-fraud vector) is
  # opened market by market. MUST equal AUTH_SMS_COUNTRIES in
  # k8s/overlays/<env>/auth.env (auth's own allow-list, core-platform-backend#732).
  #   * EU / EEA, the UK and Switzerland: alphanumeric sender ids or shared
  #     routes work without a dedicated number, at moderate per-SMS prices;
  #   * the French overseas departments (GP, GF, MQ, RE, YT) have their own ISO
  #     codes and +59x/+262 prefixes;
  #   * NOT the US / Canada yet: US SMS needs a registered toll-free or 10DLC
  #     number (weeks of registration). Add them with that origination identity.
  allowed_countries = [
    # EU 27
    "AT", "BE", "BG", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HR", "HU",
    "IE", "IT", "LT", "LU", "LV", "MT", "NL", "PL", "PT", "RO", "SE", "SI", "SK",
    # EEA (non-EU), UK, Switzerland
    "IS", "LI", "NO", "GB", "CH",
    # French overseas departments
    "GP", "GF", "MQ", "RE", "YT",
  ]

  tags = {
    ManagedBy = "terragrunt"
  }
}
