# infrastructure/live/global/networking/route53-wynn-cn/terragrunt.hcl
#
# Authoritative public hosted zone for wynn.cn, the iOS app's web domain
# (universal links + passkeys, core-platform-infra#31/#35/#36). Same module as
# core-platform.click's zone. Apply it ALONE first, then delegate the domain at
# the .cn registrar to the `name_servers` output; global/web/wynn-cn-aasa (its
# ACM DNS validation) only succeeds once that delegation resolves.
#   terragrunt output name_servers

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../modules/networking/route53"
}

inputs = {
  domain_name = "wynn.cn"
}
