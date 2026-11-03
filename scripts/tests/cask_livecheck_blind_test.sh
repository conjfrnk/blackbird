#!/usr/bin/env bash
#
# Regression (blind): the Homebrew cask in packaging/homebrew/ must be
# usable the way Homebrew 7 (and the Sparkle appcast we publish) require.
#
# Two independent defects are pinned here (bug DPC-2):
#
#   (1) The README tells contributors to run
#           brew install --cask ./packaging/homebrew/blackbird.rb
#       (and `brew audit` / `brew livecheck` against the same bare file).
#       Homebrew 7 with the default environment (HOMEBREW_DEVELOPER unset)
#       refuses any cask loaded from a file path:
#           "Homebrew requires casks to be in a tap, rejecting: ..."
#       so the documented local-test commands cannot work. The README must
#       either route through a tap or explicitly opt in via
#       HOMEBREW_DEVELOPER; it must not document a bare-path install.
#
#   (2) Once the cask lives in a tap, `brew livecheck` / the autobump bot
#       run the cask's `livecheck` block against website/appcast.xml and
#       compare the answer with the cask's `version`. Homebrew's built-in
#       Sparkle strategy reports "<shortVersionString>,<sparkle:version>"
#       ("0.9.3,54") whenever the appcast carries a bare-integer build, so a
#       cask with `version "0.9.3"` and a plain `strategy :sparkle` is
#       permanently "outdated", and an autobump to the reported version
#       would rewrite the download URL to .../v0.9.3,54/Blackbird-0.9.3,54.dmg
#       (a 404). Whatever shape the fix takes (a livecheck block that
#       returns the short version, or a comma-pair cask version whose url
#       uses version.csv.first) the following must hold:
#           - livecheck's answer == the cask's version, and
#           - the cask's download URL, re-evaluated at the version livecheck
#             reports (i.e. after an autobump), == the appcast's enclosure
#             URL.
#       Checked on the committed cask + appcast, and again on the cask as
#       rewritten by a real scripts/publish-update.sh run (the script that
#       bumps the cask on every release) against the appcast it publishes.
#
# The livecheck answer is computed by a small Ruby model of Homebrew's
# Sparkle strategy (mirrors Library/Homebrew/livecheck/strategy/sparkle.rb
# and bundle_version.rb: newest item by [pubDate, build], default answer
# BundleVersion#nice_version, `strategy :sparkle do |item| ... end` blocks
# honoured) and of the Cask DSL (`version`, `url`, `livecheck`,
# `version.csv`). No network, no brew invocation, no install.
#
# Compatible with macOS /bin/bash 3.2 and Ruby 2.6+ (CI + dev machines).

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "cask_livecheck_blind_test.sh"

CASK="$BB_REPO_ROOT/packaging/homebrew/blackbird.rb"
APPCAST="$BB_REPO_ROOT/website/appcast.xml"
README="$BB_REPO_ROOT/packaging/homebrew/README.md"
SITE_APPCAST_URL="https://blackbird-terminal.com/appcast.xml"

TMP="$(mk_tmp bb-cask-livecheck)"
trap 'rm -rf "$TMP"' EXIT

assert_file_exists "$CASK" "Homebrew cask exists"
assert_file_exists "$APPCAST" "committed Sparkle appcast exists"
assert_file_exists "$README" "packaging/homebrew/README.md exists"

# ---------------------------------------------------------------------------
# Ruby model of the Cask DSL + Homebrew's Sparkle livecheck.
# Prints `key=value` lines (one value per key, newlines flattened).
#   usage: ruby model.rb <cask.rb> <appcast.xml>
# ---------------------------------------------------------------------------

MODEL_RB="$TMP/livecheck_model.rb"
cat >"$MODEL_RB" <<'RUBY'
require "time"

# ---- Cask DSL -------------------------------------------------------------

class CsvList < Array
  def second
    self[1]
  end
end

class CaskVersion < String
  def csv
    CsvList.new(split(","))
  end

  def before_comma
    split(",", 2).first
  end

  def after_comma
    split(",", 2)[1]
  end

  def major
    split(/[.,-]/)[0]
  end

  def minor
    split(/[.,-]/)[1]
  end

  def patch
    split(/[.,-]/)[2]
  end

  def no_dots
    delete(".")
  end

  def dots_to_hyphens
    tr(".", "-")
  end

  def dots_to_underscores
    tr(".", "_")
  end
end

class LivecheckSpec
  attr_reader :url_arg, :strategy_name, :strategy_block, :regex_arg, :skipped

  def initialize
    @skipped = false
  end

  def url(arg = nil, *_rest)
    @url_arg = arg unless arg.nil?
    @url_arg
  end

  def strategy(name = nil, &block)
    @strategy_name = name
    @strategy_block = block
  end

  def regex(arg = nil)
    @regex_arg = arg unless arg.nil?
    @regex_arg
  end

  def skip(*_args)
    @skipped = true
  end

  def method_missing(_name, *_args, &_block)
    nil
  end

  def respond_to_missing?(*_args)
    true
  end
end

class CaskDSL
  attr_reader :livecheck_spec

  def initialize(version_override)
    @version_override = version_override
    @version = nil
    @url = nil
    @livecheck_spec = nil
  end

  # `version "x"` sets, bare `version` reads (as in Homebrew's Cask::DSL).
  def version(arg = nil)
    unless arg.nil?
      @version = CaskVersion.new(@version_override.nil? ? arg.to_s : @version_override.to_s)
    end
    @version
  end

  def url(*args)
    @url = args.first.to_s unless args.empty?
    @url
  end

  def livecheck(&block)
    @livecheck_spec = LivecheckSpec.new
    @livecheck_spec.instance_eval(&block) if block
    @livecheck_spec
  end

  # name / desc / homepage / sha256 / app / zap / depends_on / auto_updates ...
  def method_missing(_name, *_args, &_block)
    nil
  end

  def respond_to_missing?(*_args)
    true
  end
end

def eval_cask(path, version_override)
  dsl = CaskDSL.new(version_override)
  holder = Object.new
  holder.define_singleton_method(:cask) { |_token, &blk| dsl.instance_eval(&blk) }
  holder.instance_eval(File.read(path), path)
  dsl
end

# ---- Homebrew Sparkle strategy model --------------------------------------

class BundleVersion
  attr_reader :short_version, :version

  def initialize(short_version, version)
    short_version = short_version.sub(/\s*\(#{Regexp.escape(version)}\)\Z/, "") if short_version && version
    @short_version = (short_version.nil? || short_version.empty?) ? nil : short_version
    @version = (version.nil? || version.empty?) ? nil : version
  end

  def nice_version
    nice_parts.join(",")
  end

  def nice_parts
    sv = @short_version
    v = @version
    return [sv] if sv && sv == v

    if sv && v
      return [v] if v.match?(/\A\d+(\.\d+)+\Z/) && v.start_with?("#{sv}.")
      return [sv] if sv.match?(/\A\d+(\.\d+)+\Z/) && sv.start_with?("#{v}.")

      if sv.match?(/\A\d+(\.\d+)*\Z/) && v.match?(/\A\d+\Z/)
        return [sv] if sv.start_with?("#{v}.") || sv.end_with?(".#{v}")

        return [sv, v]
      end
    end

    [sv, v].compact
  end
end

SparkleItem = Struct.new(:title, :url, :pub_date, :bundle_version) do
  def short_version
    bundle_version.short_version
  end

  def version
    bundle_version.version
  end

  def nice_version
    bundle_version.nice_version
  end
end

def xml_text(block, tag)
  m = block.match(%r{<(?:sparkle:)?#{tag}>\s*(.*?)\s*</(?:sparkle:)?#{tag}>}m)
  m && !m[1].empty? ? m[1] : nil
end

def xml_enclosure_attr(block, attr)
  m = block.match(/<enclosure\b[^>]*?\b(?:sparkle:)?#{attr}="([^"]*)"/m)
  m && !m[1].empty? ? m[1] : nil
end

def parse_sparkle_items(content)
  content.scan(%r{<item>.*?</item>}m).map do |blk|
    short = xml_enclosure_attr(blk, "shortVersionString") || xml_text(blk, "shortVersionString")
    build = xml_enclosure_attr(blk, "version") || xml_text(blk, "version")
    pub = begin
      Time.parse(xml_text(blk, "pubDate").to_s)
    rescue ArgumentError
      Time.at(0)
    end
    enclosure = blk.match(/<enclosure\b[^>]*?\burl="([^"]*)"/m)
    SparkleItem.new(xml_text(blk, "title"), enclosure && enclosure[1], pub, BundleVersion.new(short, build))
  end
end

def latest_item(items)
  items.max_by { |i| [i.pub_date, i.version.to_i] }
end

def handle_block_return(value)
  case value
  when nil then []
  when Array then value.flatten.compact.map(&:to_s)
  else [value.to_s]
  end
end

# Returns the list of versions `brew livecheck` would report.
def run_livecheck(spec, items)
  raise "cask has no livecheck block" if spec.nil?
  raise "livecheck is skipped (livecheck do skip ...); nothing would track releases" if spec.skipped

  item = latest_item(items)
  raise "appcast has no items" if item.nil?

  case spec.strategy_name
  when :sparkle
    block = spec.strategy_block
    if block
      ret = case block.parameters[0]
            when [:opt, :item], [:req, :item], [:rest], [:req]
              spec.regex ? block.call(item, spec.regex) : block.call(item)
            when [:opt, :items], [:req, :items]
              spec.regex ? block.call(items, spec.regex) : block.call(items)
            else
              raise ArgumentError, "First argument of Sparkle `strategy` block must be `item` or `items`"
            end
      return handle_block_return(ret)
    end
    v = item.bundle_version.nice_version
    v.empty? ? [] : [v]
  when :github_latest
    # The newest GitHub release is the one publish-update.sh just announced,
    # tagged v<shortVersionString>.
    tag = "v#{item.short_version}"
    json = { "tag_name" => tag, "name" => "Version #{item.short_version}", "prerelease" => false, "draft" => false }
    default_regex = /v?(\d+(?:\.\d+)+)/i
    if spec.strategy_block
      rx = spec.regex || default_regex
      handle_block_return(spec.strategy_block.call(json, rx))
    else
      m = tag.match(default_regex)
      m ? [m[1]] : []
    end
  else
    raise "livecheck strategy #{spec.strategy_name.inspect} is not modelled by this test; extend livecheck_model.rb"
  end
end

# ---- main -------------------------------------------------------------------

out = {}
begin
  cask_path, appcast_path = ARGV
  items = parse_sparkle_items(File.read(appcast_path))
  latest = latest_item(items)
  raise "no <item> in #{appcast_path}" if latest.nil?

  out["appcast_items"] = items.length
  out["appcast_short"] = latest.short_version
  out["appcast_build"] = latest.version
  out["appcast_enclosure"] = latest.url

  dsl = eval_cask(cask_path, nil)
  out["cask_version"] = dsl.version
  out["cask_url"] = dsl.url

  spec = dsl.livecheck_spec
  out["livecheck_url"] = spec && spec.url
  out["livecheck_strategy"] = spec && spec.strategy_name
  out["livecheck_has_block"] = spec && !spec.strategy_block.nil?

  # Model sanity: whatever the version stanza looks like, a bare short
  # version must yield the real download URL.
  out["url_for_short"] = eval_cask(cask_path, latest.short_version).url

  reported = run_livecheck(spec, items)
  out["livecheck_result"] = reported.first || "<none>"
  if reported.first
    # An autobump rewrites `version` to what livecheck reported.
    out["bumped_url"] = eval_cask(cask_path, reported.first).url
  end
rescue Exception => e # rubocop:disable Lint/RescueException
  out["error"] = "#{e.class}: #{e.message}"
end

out.each { |k, v| puts "#{k}=#{v.to_s.gsub(/\s+/, ' ')}" }
RUBY

RUBY_BIN=""
if command -v ruby >/dev/null 2>&1; then
    RUBY_BIN="$(command -v ruby)"
elif [[ -x /usr/bin/ruby ]]; then
    RUBY_BIN="/usr/bin/ruby"
fi

if [[ -z "$RUBY_BIN" ]]; then
    # Every macOS runner ships Ruby; a missing one must be loud, not a
    # silent pass.
    fail "no ruby on PATH or at /usr/bin/ruby - cannot model Homebrew's cask/livecheck evaluation"
    test_end
    exit 1
fi

# field <outfile> <key> : value of key=... line (empty when absent)
field() {
    sed -n "s/^$2=//p" "$1" | head -1
}

# check_cask_vs_appcast <label> <cask.rb> <appcast.xml>
#
# Runs the model and asserts the livecheck/autobump contract. Preconditions
# (model sanity) are asserted first so a harness fault cannot masquerade as,
# or hide, the bug.
check_cask_vs_appcast() {
    local label="$1" cask="$2" appcast="$3"
    local out="$TMP/${label}.model.out" err="$TMP/${label}.model.err" rc=0
    "$RUBY_BIN" "$MODEL_RB" "$cask" "$appcast" >"$out" 2>"$err" || rc=$?

    assert_exit_code "$rc" "0" "$label: livecheck model ran"
    if [[ -s "$err" ]]; then
        sed 's/^/        | /' "$err" >&2
    fi

    local error short build enclosure cask_version cask_url lc_url lc_result
    local url_for_short bumped_url
    error="$(field "$out" error)"
    short="$(field "$out" appcast_short)"
    build="$(field "$out" appcast_build)"
    enclosure="$(field "$out" appcast_enclosure)"
    cask_version="$(field "$out" cask_version)"
    cask_url="$(field "$out" cask_url)"
    lc_url="$(field "$out" livecheck_url)"
    lc_result="$(field "$out" livecheck_result)"
    url_for_short="$(field "$out" url_for_short)"
    bumped_url="$(field "$out" bumped_url)"

    echo "    $label: appcast short='$short' build='$build' enclosure='$enclosure'"
    echo "    $label: cask version='$cask_version' url='$cask_url'"
    echo "    $label: livecheck strategy='$(field "$out" livecheck_strategy)' block='$(field "$out" livecheck_has_block)' reports='$lc_result'"

    # --- preconditions (must hold before AND after the fix) -----------------
    assert_eq "$error" "" "$label: cask + livecheck evaluate without error"
    assert_ne "$short" "" "$label: appcast carries a shortVersionString"
    assert_eq "$([[ "$build" =~ ^[0-9]+$ ]] && echo bare-integer || echo "not-an-integer:$build")" \
        "bare-integer" "$label: appcast sparkle:version is the bare-integer CFBundleVersion"
    assert_eq "$enclosure" \
        "https://github.com/conjfrnk/blackbird/releases/download/v${short}/Blackbird-${short}.dmg" \
        "$label: appcast enclosure is the GitHub release DMG for v${short}"
    assert_eq "$url_for_short" "$enclosure" \
        "$label: cask url template, at the bare short version, is the appcast enclosure URL"
    # A Sparkle livecheck must watch the published appcast. (A fix that moves
    # livecheck to another source, e.g. GitHub releases, has no appcast URL to
    # check; the version/URL assertions below still bind it.)
    if [[ "$(field "$out" livecheck_strategy)" == "sparkle" ]]; then
        assert_eq "$lc_url" "$SITE_APPCAST_URL" \
            "$label: Sparkle livecheck watches the published appcast URL"
    fi

    # --- the bug ---------------------------------------------------------------
    # brew livecheck must agree with the cask's own version, else the cask is
    # permanently outdated / `brew audit --online` fails.
    assert_eq "$lc_result" "$cask_version" \
        "$label: brew livecheck's reported version must equal the cask version (appcast short='$short', build='$build')"

    # An autobump rewrites the cask to the livecheck-reported version; the
    # resulting download URL must still be the real release asset.
    assert_eq "$bumped_url" "$enclosure" \
        "$label: cask url after autobumping to livecheck's '$lc_result' must be the appcast enclosure URL"
}

# ---------------------------------------------------------------------------
# 1. The committed cask against the committed appcast.
# ---------------------------------------------------------------------------

check_cask_vs_appcast "repo" "$CASK" "$APPCAST"

# ---------------------------------------------------------------------------
# 2. README: the documented local-test commands must be ones Homebrew 7 accepts.
# ---------------------------------------------------------------------------

# Offending lines: inside fenced code blocks, a `brew install|audit|livecheck|...`
# command that hands brew a bare *.rb path (outside a Casks/ tap checkout), in a
# block that does not opt in via HOMEBREW_DEVELOPER. Comments are ignored.
readme_path_commands() {
    awk '
        function flush(   i, l) {
            if (blocktext ~ /HOMEBREW_DEVELOPER/) return
            for (i = 1; i <= n; i++) {
                l = buf[i]
                if (l ~ /^[[:space:]]*#/) continue
                if (l ~ /(^|[^[:alnum:]_])brew[[:space:]]+(install|reinstall|upgrade|audit|livecheck|fetch|info)([[:space:]]|$)/ \
                    && l ~ /[^[:space:]]*\.rb([[:space:]]|$)/ \
                    && l !~ /(^|[[:space:]\/])Casks\//) {
                    print lineno[i] ": " l
                }
            }
        }
        /^[[:space:]]*```/ {
            if (inblock) { flush(); inblock = 0 } else { inblock = 1; n = 0; blocktext = "" }
            next
        }
        inblock { n++; buf[n] = $0; lineno[n] = NR; blocktext = blocktext "\n" $0 }
        END { if (inblock) flush() }
    ' "$README"
}

# Precondition: the parser really sees the README's fenced brew commands.
README_FENCED_BREW="$(awk '/^[[:space:]]*```/ { f = !f; next } f && /brew/ { print }' "$README")"
assert_contains "$README_FENCED_BREW" "brew " \
    "README parser sees fenced brew commands (not vacuous)"

README_BAD="$(readme_path_commands)"
assert_eq "$README_BAD" "" \
    "README must not document brew install/audit/livecheck on a bare cask file path (Homebrew 7: 'Homebrew requires casks to be in a tap, rejecting')"

README_HAS_ROUTE="no"
if grep -qiE '(^|[^[:alnum:]_])tap([^[:alnum:]_]|$)|Library/Taps|HOMEBREW_DEVELOPER' "$README"; then
    README_HAS_ROUTE="yes"
fi
assert_eq "$README_HAS_ROUTE" "yes" \
    "README documents a route Homebrew 7 accepts for local cask testing (a tap, or HOMEBREW_DEVELOPER)"

# ---------------------------------------------------------------------------
# 3. The cask as rewritten by a real publish-update.sh run must still agree
#    with the appcast that same run publishes.
# ---------------------------------------------------------------------------

FX="$TMP/fixture"
mkdir -p "$FX/scripts" "$FX/website" "$FX/dist" "$FX/stub-bin" "$FX/packaging/homebrew"

# Real scripts under test (+ the two helpers it shells out to).
cp "$BB_REPO_ROOT/scripts/publish-update.sh" "$FX/scripts/publish-update.sh"
cp "$BB_REPO_ROOT/scripts/changelog-section.sh" "$FX/scripts/changelog-section.sh"
cp "$BB_REPO_ROOT/scripts/render-release-notes.sh" "$FX/scripts/render-release-notes.sh"
chmod +x "$FX/scripts/"*.sh

# The REAL committed cask, as the starting point of the bump.
cp "$CASK" "$FX/packaging/homebrew/blackbird.rb"

cat >"$FX/CHANGELOG.md" <<'MD'
# Changelog

## [0.2.0] - 2026-01-01

### Added
- fixture release
MD

cat >"$FX/project.yml" <<'YAML'
name: Blackbird
settings:
  CFBundleShortVersionString: "0.2.0"
  CFBundleVersion: "42"
YAML

cat >"$FX/website/appcast.xml" <<'XML'
<?xml version="1.0" standalone="yes"?>
<rss version="2.0">
  <channel>
    <title>Blackbird</title>
    <description>Pre-existing fixture appcast.</description>
  </channel>
</rss>
XML

cat >"$FX/website/index.html" <<'HTML'
<!doctype html>
<html><head>
<script type="application/ld+json">
{"softwareVersion": "0.1.15"}
</script>
</head>
<body>
<div class="reqs">Apple Silicon and Intel · v0.1.15</div>
<div class="row dim">Compiling blackbird_core v0.1.15</div>
</body></html>
HTML

cat >"$FX/website/deploy.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub deploy.sh ran"
exit 0
STUB
chmod +x "$FX/website/deploy.sh"

# External-command stubs: every signing / network step passes.
cat >"$FX/stub-bin/codesign" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "--display" ]]; then
        printf 'Executable=/path/to/Blackbird.dmg\nTeamIdentifier=F2B95Q4CT8\n'
    fi
done
exit 0
STUB
cat >"$FX/stub-bin/spctl" <<'STUB'
#!/usr/bin/env bash
cat <<'EOF'
/path/to/Blackbird.dmg: accepted
source=Notarized Developer ID
origin=Developer ID Application: Connor Frank (F2B95Q4CT8)
EOF
exit 0
STUB
cat >"$FX/stub-bin/xcrun" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$FX/stub-bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}${2:-}" in
    "release""view")
        if [[ "${4:-}" == "--json" ]]; then
            printf '%s\n' "Blackbird-${TAG_VERSION:-MISSING}.dmg"
        fi
        exit 0
        ;;
esac
exit 0
STUB
cat >"$FX/stub-bin/curl" <<'STUB'
#!/usr/bin/env bash
DEST=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then DEST="$arg"; fi
    prev="$arg"
done
[[ -n "$DEST" ]] || { echo "stub curl: no -o destination" >&2; exit 1; }
printf 'fake dmg bytes for tests\n' >"$DEST"
exit 0
STUB
chmod +x "$FX/stub-bin/"*

# make-appcast stub: same contract as the real one for what publish-update.sh
# cross-checks (enclosure URL + shortVersionString come from the pinned DMG,
# sparkle:version is the bare-integer CFBundleVersion from project.yml).
cat >"$FX/scripts/make-appcast.sh" <<'STUB'
#!/usr/bin/env bash
if [[ -z "${APPCAST_DMG:-}" ]]; then
    echo "stub make-appcast.sh: APPCAST_DMG not set" >&2
    exit 1
fi
DMG_NAME="$(basename "$APPCAST_DMG")"
VERSION="$(echo "$DMG_NAME" | sed -E 's/^Blackbird-(.*)\.dmg$/\1/')"
cat <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Blackbird</title>
    <description>fixture full appcast</description>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>42</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <enclosure url="${APPCAST_BASE_URL%/}/${DMG_NAME}"
                 type="application/x-apple-diskimage" />
    </item>
  </channel>
</rss>
XML
exit 0
STUB
chmod +x "$FX/scripts/make-appcast.sh"

mk_git_fixture "$FX"
(
    cd "$FX"
    git add website/appcast.xml website/index.html project.yml packaging/homebrew/blackbird.rb
    git -c commit.gpgsign=false commit -q -m "seed fixture"
    git tag v0.2.0
)

PUB_LOG="$TMP/publish.log"
PUB_RC=0
(
    cd "$FX"
    export PATH="$FX/stub-bin:$PATH"
    export TAG_VERSION="0.2.0"
    bash "$FX/scripts/publish-update.sh" 0.2.0
) >"$PUB_LOG" 2>&1 || PUB_RC=$?

assert_exit_code "$PUB_RC" "0" "fixture: publish-update.sh 0.2.0 succeeds with the real cask in the tree"
if [[ "$PUB_RC" != "0" ]]; then
    tail -30 "$PUB_LOG" | sed 's/^/        | /' >&2
    test_end
    exit 1
fi

check_cask_vs_appcast "published" "$FX/packaging/homebrew/blackbird.rb" "$FX/website/appcast.xml"

test_end
