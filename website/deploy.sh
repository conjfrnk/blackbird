#!/usr/bin/env bash
set -euo pipefail

# blackbird-terminal.com deployment
# Architecture: S3 + CloudFront + ACM + Route53
# AWS Profile: personal (account 307946647663)
#
# CloudFront "Compress objects automatically" is enabled,
# so it serves Brotli/gzip to supporting clients.

BUCKET="blackbird-terminal-website"
DISTRIBUTION_ID="E1YJB9AJI2QH8V"
PROFILE="personal"

cd "$(dirname "$0")"

echo "Uploading to S3..."

# HTML always revalidates (points to the latest icon).
aws s3 cp index.html "s3://${BUCKET}/index.html" \
  --cache-control "public,max-age=0,must-revalidate" \
  --content-type "text/html; charset=utf-8" \
  --profile "$PROFILE"

# 404 page also revalidates so a copy fix lands without TTL wait.
aws s3 cp 404.html "s3://${BUCKET}/404.html" \
  --cache-control "public,max-age=0,must-revalidate" \
  --content-type "text/html; charset=utf-8" \
  --profile "$PROFILE"

# Static assets cached for a day. Icon and stylesheet are referenced
# with ?v= query strings in HTML, so a release that needs to invalidate
# them bumps the version rather than relying on TTL expiry.
aws s3 cp icon-512.png "s3://${BUCKET}/icon-512.png" \
  --cache-control "public,max-age=86400" \
  --content-type "image/png" \
  --profile "$PROFILE"

# OpenGraph card. Referenced with ?v= in HTML; bump the query string in
# index.html when regenerating so chat previews refresh.
aws s3 cp og-image.png "s3://${BUCKET}/og-image.png" \
  --cache-control "public,max-age=86400" \
  --content-type "image/png" \
  --profile "$PROFILE"

aws s3 cp styles.css "s3://${BUCKET}/styles.css" \
  --cache-control "public,max-age=86400" \
  --content-type "text/css; charset=utf-8" \
  --profile "$PROFILE"

aws s3 cp favicon.svg "s3://${BUCKET}/favicon.svg" \
  --cache-control "public,max-age=86400" \
  --content-type "image/svg+xml" \
  --profile "$PROFILE"

aws s3 cp robots.txt "s3://${BUCKET}/robots.txt" \
  --cache-control "public,max-age=86400" \
  --content-type "text/plain; charset=utf-8" \
  --profile "$PROFILE"

# Sitemap: kept fresh so search engines pick up release-driven lastmod bumps.
aws s3 cp sitemap.xml "s3://${BUCKET}/sitemap.xml" \
  --cache-control "public,max-age=3600" \
  --content-type "application/xml; charset=utf-8" \
  --profile "$PROFILE"

# Sparkle appcast: clients poll once a day, so keep it revalidating.
aws s3 cp appcast.xml "s3://${BUCKET}/appcast.xml" \
  --cache-control "public,max-age=0,must-revalidate" \
  --content-type "application/xml; charset=utf-8" \
  --profile "$PROFILE"

echo "Invalidating CloudFront cache..."
aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --profile "$PROFILE" \
  --output text

echo "Deployed to https://blackbird-terminal.com"

# Post-deploy sanity: verify the CloudFront Response Headers Policy is
# serving security headers we asked for. Drift here (someone detaches
# the policy from the distribution, or the invalidation races ahead of
# a config change) lets the site ship without HSTS/CSP, re-opening the
# attack surface website F2 was closed against. Warning-only so deploy
# doesn't block on a flaky probe. Run scripts/apply-security-headers.sh
# once if the policy needs to be (re-)attached.
echo "Verifying security headers..."
HEADERS="$(curl -sSI --max-time 10 https://blackbird-terminal.com/ 2>/dev/null || true)"
missing=()
for h in "strict-transport-security" "content-security-policy" "x-content-type-options" "referrer-policy"; do
    if ! grep -qi "^${h}:" <<<"$HEADERS"; then
        missing+=("$h")
    fi
done
if (( ${#missing[@]} > 0 )); then
    echo "!! warning: security headers missing from live response: ${missing[*]}"
    echo "!! run ./apply-security-headers.sh to reattach the CloudFront policy (website F2)"
fi
