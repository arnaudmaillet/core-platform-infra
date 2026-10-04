#!/usr/bin/env bash
# infrastructure/modules/sms-guardrails/scripts/sms-protect.sh
#
# Country allow-list for every SMS the account sends, Amazon SNS included: an AWS
# End User Messaging SMS *protect configuration* set as the ACCOUNT DEFAULT (the
# only way it applies to sns:Publish). Destinations outside the allow-list are
# BLOCKed, so an SMS-pumping attack can't spray premium-rate numbers abroad.
#
# Run by terraform_data.sms_protect (local-exec) because the AWS provider has no
# protect-configuration resource. Idempotent: reuses the current account default
# protect configuration (or creates one), then rewrites the whole SMS country rule
# set (ALLOW the listed ISO codes, BLOCK every other country AWS supports).
#
# Usage: sms-protect.sh <region> <name> <CC> [<CC> ...]
set -euo pipefail

region="$1"; name="$2"; shift 2
[ "$#" -gt 0 ] || { echo "sms-protect: empty allow-list" >&2; exit 1; }
allow=" $* "

aws_sms() { aws pinpoint-sms-voice-v2 --region "$region" --output text "$@"; }

id="$(aws_sms describe-protect-configurations \
  --filters Name=account-default,Values=true \
  --query 'ProtectConfigurations[0].ProtectConfigurationId')"
if [ -z "$id" ] || [ "$id" = "None" ]; then
  id="$(aws_sms create-protect-configuration \
    --deletion-protection-enabled \
    --tags "Key=Name,Value=$name" \
    --query 'ProtectConfigurationId')"
  # Default right away (a new configuration ALLOWs everything, so this changes
  # nothing yet): a failed run below then reuses it instead of orphaning it.
  aws_sms set-account-default-protect-configuration --protect-configuration-id "$id" >/dev/null
  echo "sms-protect: created protect configuration $id"
fi

# Every country AWS can send SMS to, then one ALLOW/BLOCK entry each. `--output
# text` separates the keys with TABs (and may wrap lines): normalise to single
# spaces, or the " $cc " membership checks below never match.
countries="$(aws_sms get-protect-configuration-country-rule-set \
  --protect-configuration-id "$id" --number-capability SMS \
  --query 'keys(CountryRuleSet)' | tr -s '\t\n' '  ')"

for cc in $*; do
  case " $countries " in
    *" $cc "*) ;;
    *) echo "sms-protect: '$cc' is not an SMS country code AWS supports" >&2; exit 1 ;;
  esac
done

# Batches of 50 countries per call.
batch=""; n=0; allowed=0; blocked=0
flush() {
  [ -n "$batch" ] || return 0
  aws_sms update-protect-configuration-country-rule-set \
    --protect-configuration-id "$id" --number-capability SMS \
    --country-rule-set-updates "{${batch%,}}" >/dev/null
  batch=""; n=0
}
for cc in $countries; do
  case "$allow" in
    *" $cc "*) status=ALLOW; allowed=$((allowed + 1)) ;;
    *)         status=BLOCK; blocked=$((blocked + 1)) ;;
  esac
  batch="$batch\"$cc\":{\"ProtectStatus\":\"$status\"},"
  n=$((n + 1))
  [ "$n" -lt 50 ] || flush
done
flush

aws_sms set-account-default-protect-configuration --protect-configuration-id "$id" >/dev/null
echo "sms-protect: $id is the account default (SMS: $allowed allowed, $blocked blocked)"
