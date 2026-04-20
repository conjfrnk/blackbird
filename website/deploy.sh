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

# Static assets cached for a day.
aws s3 cp icon-512.png "s3://${BUCKET}/icon-512.png" \
  --cache-control "public,max-age=86400" \
  --content-type "image/png" \
  --profile "$PROFILE"

aws s3 cp favicon.svg "s3://${BUCKET}/favicon.svg" \
  --cache-control "public,max-age=86400" \
  --content-type "image/svg+xml" \
  --profile "$PROFILE"

aws s3 cp robots.txt "s3://${BUCKET}/robots.txt" \
  --cache-control "public,max-age=86400" \
  --content-type "text/plain; charset=utf-8" \
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
