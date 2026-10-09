# infrastructure/live/global/web/wynn-cn-aasa/terragrunt.hcl
#
# https://wynn.cn/.well-known/apple-app-site-association for the iOS app
# (core-platform-infra#31 passkeys, #35 universal links /@handle + /tag, #36 /s/*):
# S3 + CloudFront (OAC) + ACM on the apex. Account-global like its zone.
#
# PREREQUISITE: global/networking/route53-wynn-cn applied AND delegated at the
# registrar; otherwise the ACM validation here waits, then times out.
# Check after apply:
#   curl -sI https://wynn.cn/.well-known/apple-app-site-association
#   (200, content-type: application/json, no redirect)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../modules/app-site-association"
}

# Ordering only (the zone is read by name).
dependency "zone" {
  config_path  = "../../networking/route53-wynn-cn"
  skip_outputs = true
}

locals {
  # <Apple team id>.<bundle id>: the project's DEVELOPMENT_TEAM and the app's
  # PRODUCT_BUNDLE_IDENTIFIER (core-platform-ios). If the domain or bundle id
  # changes, AppRoute.webHost, the entitlement and ProfileShareLink change too.
  ios_app_id = "4ZZ7J5Z8ZX.cn.wynn.core-platform-ios"
}

inputs = {
  domain_name = "wynn.cn"
  app_ids     = [local.ios_app_id]

  # Universal links: paths iOS opens in the app (the parser is
  # AppRoute.init?(deepLink:) in the iOS CoreNavigation package).
  applinks_components = [
    { path = "/@*", comment = "profiles" },
    { path = "/tag/*", comment = "hashtags" },
    { path = "/s/*", comment = "profile QR codes and share links" },
  ]

  # Passkeys bound to wynn.cn (AUTH_WEBAUTHN_RP_ID in the auth overlays).
  webcredentials = true

  tags = {
    ManagedBy = "terragrunt"
    Service   = "ios-app-site"
  }
}
