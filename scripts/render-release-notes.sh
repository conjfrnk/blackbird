#!/usr/bin/env bash
set -euo pipefail

# Render one CHANGELOG.md section as a standalone HTML page for the
# website, at website/releases/v<X.Y.Z>.html. The Sparkle appcast points
# <sparkle:releaseNotesLink> at this page, so the in-app update dialog
# finally shows what an update contains (through v0.8.0 it showed only a
# bare version number — the appcast item had no notes at all).
#
# Deliberately tiny Markdown subset (what CHANGELOG.md actually uses):
# `## [ver] - date`, `### Heading`, `- bullet`, `**bold**`, `` `code` ``,
# `[text](url)`, paragraphs. Anything else passes through as escaped
# text. Output is deterministic for a given CHANGELOG section, so
# re-running publish-update.sh for the same tag is still idempotent.
#
# Usage:
#   scripts/render-release-notes.sh <version> [out.html] [CHANGELOG.md]

if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "Usage: $0 <version> [out.html] [CHANGELOG.md]" >&2
    exit 2
fi

VERSION="${1#v}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${2:-$REPO_ROOT/website/releases/v${VERSION}.html}"
CHANGELOG="${3:-$REPO_ROOT/CHANGELOG.md}"

mkdir -p "$(dirname "$OUT")"

# Write via tempfiles + mv so a crash mid-render can't leave a truncated
# page where the appcast will point.
TMP="$(mktemp -t blackbird-notes.XXXXXX)"
SRC="$(mktemp -t blackbird-notes-src.XXXXXX)"
trap 'rm -f "$TMP" "$SRC"' EXIT

"$SCRIPT_DIR/changelog-section.sh" "$VERSION" "$CHANGELOG" > "$SRC"

RELEASE_VERSION="$VERSION" python3 - "$TMP" "$SRC" <<'PY'
import html, os, re, sys

version = os.environ["RELEASE_VERSION"]
out_path = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as f:
    src = f.read().splitlines()

def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    # `code` first so markup inside code spans is left alone.
    parts = re.split(r"(`[^`]*`)", text)
    for i, p in enumerate(parts):
        if p.startswith("`") and p.endswith("`") and len(p) >= 2:
            parts[i] = "<code>" + p[1:-1] + "</code>"
        else:
            p = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", p)
            p = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
                       r'<a href="\2" rel="noopener">\1</a>', p)
            parts[i] = p
    return "".join(parts)

body = []
in_list = False
para = []

def flush_para():
    global para
    if para:
        body.append("<p>" + inline(" ".join(para)) + "</p>")
        para = []

def close_list():
    global in_list
    if in_list:
        body.append("</ul>")
        in_list = False

date = ""
for line in src:
    m = re.match(r"^## \[([^\]]+)\](?: - (\S+))?", line)
    if m:
        date = m.group(2) or ""
        continue
    m = re.match(r"^### (.+)$", line)
    if m:
        flush_para(); close_list()
        body.append("<h2>" + inline(m.group(1)) + "</h2>")
        continue
    m = re.match(r"^\s*[-*] (.+)$", line)
    if m:
        flush_para()
        if not in_list:
            body.append("<ul>")
            in_list = True
        body.append("<li>" + inline(m.group(1)) + "</li>")
        continue
    if line.strip() == "":
        flush_para(); close_list()
        continue
    # Continuation of a wrapped bullet: CHANGELOG indents them by two
    # spaces. Append to the last <li> rather than opening a paragraph.
    if in_list and line.startswith("  ") and body and body[-1].startswith("<li>"):
        body[-1] = body[-1][:-len("</li>")] + " " + inline(line.strip()) + "</li>"
        continue
    para.append(line.strip())
flush_para(); close_list()

title = f"Blackbird {version}"
subtitle = f"Released {date}" if date else "Release notes"
page = f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>{html.escape(title)} — release notes</title>
    <meta name="theme-color" content="#282828" />
    <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
    <link rel="stylesheet" href="/styles.css?v=16" />
    <style>
      main.notes {{ max-width: 720px; margin: 0 auto; padding: 48px 24px; text-align: left; }}
      main.notes h1 {{ margin-bottom: 4px; }}
      main.notes .tag {{ margin-top: 0; }}
      main.notes h2 {{ font-size: 1.05rem; margin: 28px 0 8px; color: #FABD2F; }}
      main.notes ul {{ padding-left: 1.2em; }}
      main.notes li {{ margin: 6px 0; line-height: 1.5; }}
      main.notes code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; }}
      main.notes a {{ color: #83A598; }}
      main.notes .back {{ display: inline-block; margin-top: 32px; color: #A89984; }}
    </style>
  </head>
  <body>
    <main class="notes">
      <h1>{html.escape(title)}</h1>
      <p class="tag">{html.escape(subtitle)}</p>
      {chr(10).join(body)}
      <a class="back" href="/">← blackbird-terminal.com</a>
    </main>
  </body>
</html>
"""
with open(out_path, "w", encoding="utf-8") as f:
    f.write(page)
PY

mv -f "$TMP" "$OUT"
rm -f "$SRC"
trap - EXIT
echo "$OUT"
