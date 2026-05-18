# blackbird-terminal.com

Splash page for [blackbird-terminal.com](https://blackbird-terminal.com).

Plain static HTML — no build step. Gruvbox dark colors, app icon + wordmark, that's it.

## Deploy

```sh
./deploy.sh
```

Uploads the splash assets (`index.html`, `404.html`, `styles.css`,
`favicon.svg`, `icon-512.png`, `og-image.png`, `robots.txt`,
`sitemap.xml`, `appcast.xml`) to S3 with appropriate cache headers,
then invalidates CloudFront. The `appcast.xml` upload overlaps with
`scripts/publish-update.sh`, which is the canonical release-side
deployer; keeping it in `deploy.sh` lets the splash-page workflow stay
self-contained when only the splash is being updated.

Requires the `personal` AWS CLI profile.

## Infrastructure

All resources live in AWS account `307946647663`, region `us-east-1`.

| Resource | Identifier |
|---|---|
| Route53 hosted zone | `Z01616732WA9WYVYAAKAG` (`blackbird-terminal.com.`) |
| ACM certificate | `arn:aws:acm:us-east-1:307946647663:certificate/f5c92791-f833-4cf7-ad30-33f48f335050` |
| S3 bucket | `blackbird-terminal-website` (private, CloudFront OAC only) |
| CloudFront OAC | `E3N9QUQFQQ8VPS` |
| CloudFront distribution | `E1YJB9AJI2QH8V` (domain `ds64l7faovo47.cloudfront.net`) |

Route53 A/AAAA ALIAS records for the apex and `www` point at the CloudFront distribution.

## Editing

Edit `index.html` directly. Re-run `./deploy.sh`.
