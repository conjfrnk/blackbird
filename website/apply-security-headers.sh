#!/usr/bin/env bash
set -euo pipefail

# CloudFront Response Headers Policy for blackbird-terminal.com.
# Idempotent — safe to re-run when the desired CSP/HSTS/etc. changes.
#
# Audit: website F2 (HSTS/CSP) + audit follow-up (drop 'unsafe-inline'
# after extracting CSS to /styles.css).
#
# Prereqs:
#   - AWS CLI with profile "personal" (or set BB_AWS_PROFILE)
#   - jq
#   - Distribution E1YJB9AJI2QH8V exists
#
# What this does:
#   1. Builds the desired Response Headers Policy ("blackbird-security-headers").
#   2. Creates the policy if it doesn't exist; updates it in place if its
#      live config differs from the desired config.
#   3. Attaches the policy to the default cache behavior of the dist if
#      not already attached.

PROFILE="${BB_AWS_PROFILE:-personal}"
DISTRIBUTION_ID="E1YJB9AJI2QH8V"
POLICY_NAME="blackbird-security-headers"

aws=(aws --profile "$PROFILE")

# Desired policy config. Note: style-src no longer includes 'unsafe-inline'
# now that all CSS lives in /styles.css served from same origin.
DESIRED_POLICY_CONFIG="$(cat <<'JSON'
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
      "ContentSecurityPolicy": "default-src 'none'; img-src 'self'; style-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
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

echo "==> Looking up policy by name: $POLICY_NAME"
POLICY_ID="$("${aws[@]}" cloudfront list-response-headers-policies \
    --query "ResponseHeadersPolicyList.Items[?ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name=='$POLICY_NAME'].ResponseHeadersPolicy.Id | [0]" \
    --output text 2>/dev/null || true)"

if [[ -z "$POLICY_ID" || "$POLICY_ID" == "None" ]]; then
    echo "==> Creating new policy"
    POLICY_ID="$(echo "$DESIRED_POLICY_CONFIG" | "${aws[@]}" cloudfront create-response-headers-policy \
        --response-headers-policy-config file:///dev/stdin \
        --query 'ResponseHeadersPolicy.Id' --output text)"
    echo "    policy id: $POLICY_ID"
else
    echo "    policy exists: $POLICY_ID"
    LIVE="$("${aws[@]}" cloudfront get-response-headers-policy --id "$POLICY_ID" --output json)"
    LIVE_CONFIG="$(echo "$LIVE" | jq -c '.ResponseHeadersPolicy.ResponseHeadersPolicyConfig')"
    DESIRED_CONFIG="$(echo "$DESIRED_POLICY_CONFIG" | jq -c '.')"
    if [[ "$LIVE_CONFIG" == "$DESIRED_CONFIG" ]]; then
        echo "==> Policy config matches desired; skipping update"
    else
        echo "==> Updating policy in place"
        ETAG="$(echo "$LIVE" | jq -r '.ETag')"
        echo "$DESIRED_POLICY_CONFIG" | "${aws[@]}" cloudfront update-response-headers-policy \
            --id "$POLICY_ID" \
            --response-headers-policy-config file:///dev/stdin \
            --if-match "$ETAG" \
            --output text > /dev/null
        echo "    policy updated"
    fi
fi

echo "==> Reading distribution config"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${aws[@]}" cloudfront get-distribution-config \
    --id "$DISTRIBUTION_ID" \
    --output json > "$TMP/dist.json"
ETAG="$(jq -r '.ETag' "$TMP/dist.json")"
CURRENT_POLICY="$(jq -r '.DistributionConfig.DefaultCacheBehavior.ResponseHeadersPolicyId // ""' "$TMP/dist.json")"

if [[ "$CURRENT_POLICY" == "$POLICY_ID" ]]; then
    echo "==> Policy already attached to distribution"
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
