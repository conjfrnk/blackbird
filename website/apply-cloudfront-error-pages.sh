#!/usr/bin/env bash
set -euo pipefail

# Idempotent: configure CloudFront to render /404.html (with HTTP 404)
# for both 403 (S3-OAC denial — what S3 returns for missing keys) and
# 404 (true not-found from S3). Without this the dist serves S3's raw
# AccessDenied XML to anyone hitting an unknown path.
#
# 5-minute ErrorCachingMinTTL so a deploy-time blip doesn't poison the
# CDN edge for hours.

PROFILE="${BB_AWS_PROFILE:-personal}"
DISTRIBUTION_ID="E1YJB9AJI2QH8V"

aws=(aws --profile "$PROFILE")

DESIRED_ERRORS="$(cat <<'JSON'
{
  "Quantity": 2,
  "Items": [
    {
      "ErrorCode": 403,
      "ResponsePagePath": "/404.html",
      "ResponseCode": "404",
      "ErrorCachingMinTTL": 300
    },
    {
      "ErrorCode": 404,
      "ResponsePagePath": "/404.html",
      "ResponseCode": "404",
      "ErrorCachingMinTTL": 300
    }
  ]
}
JSON
)"

echo "==> Reading distribution config"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${aws[@]}" cloudfront get-distribution-config \
    --id "$DISTRIBUTION_ID" \
    --output json > "$TMP/dist.json"
ETAG="$(jq -r '.ETag' "$TMP/dist.json")"

CURRENT="$(jq -c '.DistributionConfig.CustomErrorResponses' "$TMP/dist.json")"
DESIRED="$(echo "$DESIRED_ERRORS" | jq -c '.')"

if [[ "$CURRENT" == "$DESIRED" ]]; then
    echo "==> Custom error responses already match desired"
    exit 0
fi

echo "==> Updating custom error responses"
jq --argjson errs "$DESIRED_ERRORS" \
   '.DistributionConfig.CustomErrorResponses = $errs | .DistributionConfig' \
   "$TMP/dist.json" > "$TMP/dist-config.json"

"${aws[@]}" cloudfront update-distribution \
    --id "$DISTRIBUTION_ID" \
    --distribution-config "file://$TMP/dist-config.json" \
    --if-match "$ETAG" \
    --output text > /dev/null

echo "==> Done. Distribution is deploying; full propagation ~15 min."
echo "    Verify with:"
echo "      curl -sSI https://blackbird-terminal.com/does-not-exist       # expect 404 + text/html"
