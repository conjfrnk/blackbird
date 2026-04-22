#!/usr/bin/env bash
set -euo pipefail

# One-shot CloudFront Response Headers Policy setup for
# blackbird-terminal.com. Run this once, after which every response from
# the distribution carries HSTS, CSP, and friends — without per-object
# overhead or S3 metadata mutation.
#
# Audit: website F2.
#
# Prereqs:
#   - AWS CLI with profile "personal" (or set BB_AWS_PROFILE)
#   - Distribution E1YJB9AJI2QH8V exists
#
# What this does:
#   1. Creates a Response Headers Policy named "blackbird-security-headers"
#      if it doesn't already exist.
#   2. Attaches it to the default cache behaviour of the distribution.
#
# Safe to re-run: the script checks existence of the policy by name
# before creating, and only touches the distribution config if its
# attachment differs from what we expect.

PROFILE="${BB_AWS_PROFILE:-personal}"
DISTRIBUTION_ID="E1YJB9AJI2QH8V"
POLICY_NAME="blackbird-security-headers"

aws=(aws --profile "$PROFILE")

echo "==> Looking up existing response-headers policy: $POLICY_NAME"
POLICY_ID="$("${aws[@]}" cloudfront list-response-headers-policies \
    --query "ResponseHeadersPolicyList.Items[?ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name=='$POLICY_NAME'].ResponseHeadersPolicy.Id | [0]" \
    --output text 2>/dev/null || true)"

if [[ -z "$POLICY_ID" || "$POLICY_ID" == "None" ]]; then
    echo "==> Creating new policy"
    POLICY_CONFIG="$(cat <<'JSON'
{
  "Name": "blackbird-security-headers",
  "Comment": "HSTS + CSP + no-sniff + Referrer-Policy + Permissions-Policy for blackbird-terminal.com. website F2.",
  "SecurityHeadersConfig": {
    "StrictTransportSecurity": {
      "Override": true,
      "AccessControlMaxAgeSec": 63072000,
      "IncludeSubdomains": true,
      "Preload": true
    },
    "ContentTypeOptions": {
      "Override": true
    },
    "ReferrerPolicy": {
      "Override": true,
      "ReferrerPolicy": "strict-origin-when-cross-origin"
    },
    "ContentSecurityPolicy": {
      "Override": true,
      "ContentSecurityPolicy": "default-src 'none'; img-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    },
    "FrameOptions": {
      "Override": true,
      "FrameOption": "DENY"
    }
  },
  "CustomHeadersConfig": {
    "Quantity": 1,
    "Items": [
      {
        "Header": "Permissions-Policy",
        "Value": "interest-cohort=()",
        "Override": true
      }
    ]
  }
}
JSON
)"
    POLICY_ID="$(echo "$POLICY_CONFIG" | "${aws[@]}" cloudfront create-response-headers-policy \
        --response-headers-policy-config file:///dev/stdin \
        --query 'ResponseHeadersPolicy.Id' --output text)"
    echo "    policy id: $POLICY_ID"
else
    echo "    policy already exists: $POLICY_ID"
fi

echo "==> Reading current distribution config"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${aws[@]}" cloudfront get-distribution-config \
    --id "$DISTRIBUTION_ID" \
    --output json > "$TMP/dist.json"
ETAG="$(jq -r '.ETag' "$TMP/dist.json")"
CURRENT_POLICY="$(jq -r '.DistributionConfig.DefaultCacheBehavior.ResponseHeadersPolicyId // ""' "$TMP/dist.json")"

if [[ "$CURRENT_POLICY" == "$POLICY_ID" ]]; then
    echo "==> Policy already attached; nothing to do."
    exit 0
fi

echo "==> Attaching policy $POLICY_ID to distribution $DISTRIBUTION_ID"
jq --arg pid "$POLICY_ID" \
   '.DistributionConfig.DefaultCacheBehavior.ResponseHeadersPolicyId = $pid | .DistributionConfig' \
   "$TMP/dist.json" > "$TMP/dist-config.json"

"${aws[@]}" cloudfront update-distribution \
    --id "$DISTRIBUTION_ID" \
    --distribution-config "file://$TMP/dist-config.json" \
    --if-match "$ETAG" \
    --output text > /dev/null

echo "==> Done. Distribution is deploying; full propagation takes ~15 min."
echo "    Verify with:"
echo "      curl -sSI https://blackbird-terminal.com/ | grep -iE '^(strict-transport|content-security|referrer|x-content|permissions)'"
