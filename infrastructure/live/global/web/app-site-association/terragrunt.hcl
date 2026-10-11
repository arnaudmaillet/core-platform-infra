# infrastructure/live/global/web/app-site-association/terragrunt.hcl
#
# https://core-platform.click/.well-known/apple-app-site-association for the iOS
# app (core-platform-infra#31 passkeys, #35 universal links /@handle + /tag, #36
# /s/*): S3 + CloudFront (OAC) + ACM on the APEX of the account-global zone
# (global/networking/route53, already delegated, so the ACM validation is
# immediate). Account-global like its zone.
#
# PROVISIONAL DOMAIN: core-platform is a prototyping name. Universal links can
# move to the final domain later (app update + this unit's domain_name).
# Passkeys can't: they are bound to AUTH_WEBAUTHN_RP_ID forever, so don't open
# passkeys to real users before the final domain is in place.
#
# The apex A/AAAA records point at this distribution. A future website on
# https://core-platform.click must join it (an extra origin / behaviours), not
# take the apex over, or the AASA disappears.
#
# The apex cert's DNS validation CNAME is owned by global/networking/acm-validation
# (core-platform-infra#80), applied first.
#
# Check after apply:
#   curl -sI https://core-platform.click/.well-known/apple-app-site-association
#   (200, content-type: application/json, no redirect)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../modules/app-site-association"
}

# Ordering only (the zone is read by name; the validation record is owned by
# acm-validation).
dependency "zone" {
  config_path  = "../../networking/route53"
  skip_outputs = true
}

dependency "acm_validation" {
  config_path  = "../../networking/acm-validation"
  skip_outputs = true
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  # <Apple team id>.<bundle id>: the project's DEVELOPMENT_TEAM and the app's
  # PRODUCT_BUNDLE_IDENTIFIER (core-platform-ios). If the domain or bundle id
  # changes, AppRoute.webHost, the entitlement and ProfileShareLink change too.
  ios_app_id = "4ZZ7J5Z8ZX.cn.wynn.core-platform-ios"
}

inputs = {
  # The platform apex (global/env.hcl), single source of truth for the domain.
  domain_name = local.env_vars.locals.domain_name
  app_ids     = [local.ios_app_id]

  # Universal links: paths iOS opens in the app (the parser is
  # AppRoute.init?(deepLink:) in the iOS CoreNavigation package).
  applinks_components = [
    { path = "/@*", comment = "profiles" },
    { path = "/tag/*", comment = "hashtags" },
    { path = "/s/*", comment = "profile QR codes and share links" },
  ]

  # Passkeys bound to the apex (AUTH_WEBAUTHN_RP_ID in the auth overlays).
  webcredentials = true

  tags = {
    ManagedBy = "terragrunt"
    Service   = "ios-app-site"
  }
}
