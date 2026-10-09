# infrastructure/live/global/networking/route53-wynn-cn/terragrunt.hcl
#
# Authoritative public hosted zone for wynn.cn, the iOS app's web domain
# (universal links + passkeys, core-platform-infra#31/#35/#36). Same module as
# core-platform.click's zone. Apply it ALONE first, then delegate the domain at
# the .cn registrar to the `name_servers` output; global/web/wynn-cn-aasa (its
# ACM DNS validation) only succeeds once that delegation resolves.
#   terragrunt output name_servers
# If a wynn.cn hosted zone ALREADY exists in this account, import it instead of
# creating a second one (two zones make `data "aws_route53_zone"` in
# global/web/wynn-cn-aasa fail on two matches, and split the delegation):
#   terragrunt import aws_route53_zone.main <ZONE_ID>

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../modules/networking/route53"
}

inputs = {
  domain_name = "wynn.cn"
}
