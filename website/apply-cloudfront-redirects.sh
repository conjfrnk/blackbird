#!/usr/bin/env bash
set -euo pipefail

# Idempotent: create-or-update the CloudFront Function defined in
# redirect.js, publish it, and attach it to the distribution's default
# cache behavior as a viewer-request handler.
#
# What it covers:
#   - www.blackbird-terminal.com -> blackbird-terminal.com  (301)
#   - /index.html                -> /                       (301)
#
# Without this attached, the dist serves both apex and www identically
# and exposes /index.html as a duplicate of /. Audit follow-up to the
# first round of website fixes.

PROFILE="${BB_AWS_PROFILE:-personal}"
DISTRIBUTION_ID="E1YJB9AJI2QH8V"
FUNCTION_NAME="blackbird-redirects"
FUNCTION_FILE="$(cd "$(dirname "$0")" && pwd)/redirect.js"
FUNCTION_RUNTIME="cloudfront-js-2.0"
FUNCTION_COMMENT="www->apex + /index.html->/ redirects"

aws=(aws --profile "$PROFILE")

echo "==> Looking up function: $FUNCTION_NAME"
FUNCTION_ETAG=""
if EXISTING="$("${aws[@]}" cloudfront describe-function --name "$FUNCTION_NAME" --output json 2>/dev/null)"; then
    FUNCTION_ETAG="$(echo "$EXISTING" | jq -r '.ETag')"
    echo "    function exists; etag $FUNCTION_ETAG"
fi

if [[ -z "$FUNCTION_ETAG" ]]; then
    echo "==> Creating function"
    OUT="$("${aws[@]}" cloudfront create-function \
        --name "$FUNCTION_NAME" \
        --function-config "Comment=$FUNCTION_COMMENT,Runtime=$FUNCTION_RUNTIME" \
        --function-code "fileb://$FUNCTION_FILE" \
        --output json)"
    FUNCTION_ETAG="$(echo "$OUT" | jq -r '.ETag')"
else
    echo "==> Updating function code"
    OUT="$("${aws[@]}" cloudfront update-function \
        --name "$FUNCTION_NAME" \
        --function-config "Comment=$FUNCTION_COMMENT,Runtime=$FUNCTION_RUNTIME" \
        --function-code "fileb://$FUNCTION_FILE" \
        --if-match "$FUNCTION_ETAG" \
        --output json)"
    FUNCTION_ETAG="$(echo "$OUT" | jq -r '.ETag')"
fi

echo "==> Publishing function"
"${aws[@]}" cloudfront publish-function \
    --name "$FUNCTION_NAME" \
    --if-match "$FUNCTION_ETAG" \
    --output text > /dev/null

FUNCTION_ARN="$("${aws[@]}" cloudfront describe-function \
    --name "$FUNCTION_NAME" \
    --stage LIVE \
    --query 'FunctionSummary.FunctionMetadata.FunctionARN' \
    --output text)"
echo "    LIVE arn: $FUNCTION_ARN"

echo "==> Reading distribution config"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${aws[@]}" cloudfront get-distribution-config \
    --id "$DISTRIBUTION_ID" \
    --output json > "$TMP/dist.json"
ETAG="$(jq -r '.ETag' "$TMP/dist.json")"

CURRENT_ARN="$(jq -r '.DistributionConfig.DefaultCacheBehavior.FunctionAssociations.Items[0].FunctionARN // ""' "$TMP/dist.json")"
if [[ "$CURRENT_ARN" == "$FUNCTION_ARN" ]]; then
    echo "==> Function already attached"
    exit 0
fi

echo "==> Attaching function to viewer-request"
jq --arg arn "$FUNCTION_ARN" '
    .DistributionConfig.DefaultCacheBehavior.FunctionAssociations = {
        Quantity: 1,
        Items: [
            { FunctionARN: $arn, EventType: "viewer-request" }
        ]
    }
    | .DistributionConfig
' "$TMP/dist.json" > "$TMP/dist-config.json"

"${aws[@]}" cloudfront update-distribution \
    --id "$DISTRIBUTION_ID" \
    --distribution-config "file://$TMP/dist-config.json" \
    --if-match "$ETAG" \
    --output text > /dev/null

echo "==> Done. Distribution is deploying; full propagation ~15 min."
echo "    Verify with:"
echo "      curl -sSI https://www.blackbird-terminal.com/                 # expect 301 -> apex"
echo "      curl -sSI https://blackbird-terminal.com/index.html           # expect 301 -> /"
