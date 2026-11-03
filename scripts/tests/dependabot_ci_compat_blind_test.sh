#!/usr/bin/env bash
#
# Regression (blind): Dependabot must not be configured to open PRs that
# CI can never turn green.
#
# Two independent failure modes, both observed on real Dependabot PRs:
#
#   SWIFT. Dependabot's `swift` ecosystem bumps Sparkle by editing ONLY
#   `Blackbird.xcodeproj/project.pbxproj` (`minimumVersion = ...;`) and
#   `Package.resolved`. The pbxproj is generated from `project.yml`
#   (Hard Rule 1) and ci.yml's "Generate Xcode project" step re-runs
#   `xcodegen generate` and fails on `git diff --quiet`, so such a PR is
#   red by construction, and the maintainer has to hand-bump `from:` in
#   project.yml each time (Sparkle bumps can carry installer security
#   fixes, so those PRs are the ones that matter).
#
#   CARGO. Dependabot's `cargo` ecosystem is not MSRV-aware. It proposes
#   proptest 1.12.0, which needs rustc 1.88, while the workspace
#   `rust-version` and the CI toolchain are 1.85, so that PR cannot
#   compile either.
#
# Correct behaviour (what this test pins): for each ecosystem, EITHER
# Dependabot can no longer open the doomed PR (ecosystem removed, the
# dependency ignored / not allowed for the offending update, ...), OR the
# PR it opens can go green (the CI drift gate accepts / repairs a
# Dependabot-style Sparkle bump; the MSRV is raised to what proptest
# 1.12.0 needs).
#
# How it observes that WITHOUT the network and without hard-coding any
# particular fix:
#   * dependabot.yml is parsed and each candidate update is run through
#     Dependabot's documented allow / ignore / update-types semantics.
#   * The swift PR is SIMULATED: the repo's generator inputs are copied
#     into a throw-away git repo, the Sparkle pin is bumped in the
#     pbxproj + Package.resolved only (exactly what Dependabot writes),
#     and the drift-gate step(s) of .github/workflows/ci.yml - plus any
#     preceding step that touches project.yml / pbxproj / xcodegen - are
#     extracted from the workflow file and executed with the Dependabot
#     actor. Nothing in the real checkout is modified; the app is never
#     launched.
#   * Rig guards keep this from passing vacuously: an unmodified copy
#     must be drift-clean, and a hand-edited pbxproj (not a Dependabot
#     PR) must still turn the same gate red.
#
# Needs ruby (YAML + Gem::Version; the macOS system ruby is enough) and
# xcodegen (installed before this harness runs in ci.yml).

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "dependabot_ci_compat_blind_test.sh"

TMP_ROOT="$(mk_tmp bb-dependabot-ci-compat)"
trap 'rm -rf "$TMP_ROOT"' EXIT

RB="$TMP_ROOT/helper.rb"

# ---------------------------------------------------------------------------
# Ruby helper (ruby 2.6 compatible: no endless methods, no numbered params).
# Sub-commands:
#   facts                      key=value facts about the repo inputs
#   dependabot cargo|swift     safe|<why>  or  unsafe|<why>
#   gates <outdir> <actor>     writes CI drift-gate step scripts, prints
#                              PLAN/SKIP lines
#   autofix                    yes|<where>  or  no
#   edit_sparkle <pbx> <resolved> minor|<x.y.z>
#                              applies a Dependabot-style Sparkle bump
#   candidates                 patch/minor/major Sparkle bump versions
# ---------------------------------------------------------------------------
cat >"$RB" <<'RUBY'
require 'yaml'
require 'json'
require 'digest'
require 'fileutils'

ROOT = ENV['BB_REPO_ROOT'] || abort('BB_REPO_ROOT not set')

SPARKLE_NAMES = %w[sparkle sparkle-project/sparkle github.com/sparkle-project/sparkle https://github.com/sparkle-project/sparkle].freeze
PROPTEST_NAMES = %w[proptest].freeze
PROPTEST_1_12_RUSTC = '1.88'.freeze

SPARKLE_REQ_RE = %r!(repositoryURL = "[^"]*sparkle-project/Sparkle[^"]*";\s*requirement = \{)([^}]*)(\})!mi
VERSION_KEY_RE = /\b(minimumVersion|version) = (")?(\d+(?:\.\d+)*)(")?;/

def rel(p)
  File.join(ROOT, p)
end

def yaml(p)
  YAML.load_file(rel(p))
end

def gv(s)
  Gem::Version.new(s.to_s.strip)
end

# ----- repo facts -----------------------------------------------------------

def lock_version(name)
  m = File.read(rel('Cargo.lock')).match(/\[\[package\]\]\nname = "#{Regexp.escape(name)}"\nversion = "([^"]+)"/)
  m && m[1]
end

def sparkle_lock_version
  j = JSON.parse(File.read(rel('Blackbird.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')))
  pins = j['pins'] || (j['object'] && j['object']['pins']) || []
  pin = pins.find { |p| (p['identity'] || p['package']).to_s.downcase == 'sparkle' }
  pin && pin['state'] && pin['state']['version']
end

def pbx_sparkle_min
  m = File.read(rel('Blackbird.xcodeproj/project.pbxproj')).match(SPARKLE_REQ_RE)
  vm = m && m[2].match(VERSION_KEY_RE)
  vm && vm[3]
end

def yml_sparkle_from
  pk = yaml('project.yml')['packages']
  s = pk && pk['Sparkle']
  s && (s['from'] || s['exactVersion'] || s['minVersion']).to_s
end

def proptest_req
  m = File.read(rel('core/Cargo.toml')).match(/^proptest\s*=\s*(?:"([^"]+)"|\{[^}]*?\bversion\s*=\s*"([^"]+)")/m)
  m && (m[1] || m[2])
end

def ws_rust_version
  m = File.read(rel('Cargo.toml')).match(/^rust-version\s*=\s*"([^"]+)"/)
  m && m[1]
end

def ci_toolchains
  out = []
  (yaml('.github/workflows/ci.yml')['jobs'] || {}).each_value do |job|
    (job['steps'] || []).each do |s|
      next unless s['uses'].to_s =~ /rust-toolchain/
      tc = s['with'] && s['with']['toolchain']
      out << tc.to_s if tc.to_s =~ /\A\d+\.\d+/
    end
  end
  out.uniq
end

def facts
  eco = (yaml('.github/dependabot.yml')['updates'] || []).map { |u| u['package-ecosystem'] }.uniq
  puts "dependabot_ecosystems=#{eco.join(',')}"
  puts "ws_rust_version=#{ws_rust_version}"
  puts "ci_toolchains=#{ci_toolchains.join(',')}"
  puts "lock_proptest=#{lock_version('proptest')}"
  puts "proptest_req=#{proptest_req}"
  puts "sparkle_lock=#{sparkle_lock_version}"
  puts "sparkle_pbx_min=#{pbx_sparkle_min}"
  puts "sparkle_yml_from=#{yml_sparkle_from}"
end

# ----- requirement / ignore matching ---------------------------------------

def caret_range(body)
  n = body.split('.').map(&:to_i)
  lo = (n + [0, 0, 0])[0, 3]
  if n[0] != 0
    hi = [n[0] + 1, 0, 0]
  elsif n.length == 1
    hi = [1, 0, 0]
  elsif n[1] != 0
    hi = [0, n[1] + 1, 0]
  elsif n.length == 2
    hi = [0, 1, 0]
  else
    hi = [0, 0, n[2] + 1]
  end
  [lo.join('.'), hi.join('.')]
end

def tilde_range(body)
  n = body.split('.').map(&:to_i)
  lo = (n + [0, 0, 0])[0, 3]
  hi = n.length == 1 ? [n[0] + 1, 0, 0] : [n[0], n[1] + 1, 0]
  [lo.join('.'), hi.join('.')]
end

# One requirement clause against a Gem::Version. true / false / nil (nil =
# syntax this helper does not understand). bare_caret: Cargo.toml reads a
# bare "1.2" as ^1.2; Dependabot `versions:` reads a bare "1.2.0" as exact.
def clause_match?(clause, ver, bare_caret)
  m = clause.match(/\A(>=|<=|==|=|>|<|~>|~|\^)?\s*v?([0-9A-Za-z.*+-]+)\z/)
  return nil if m.nil?
  op = m[1]
  body = m[2]
  segs = body.split('.')
  wild = segs.index { |s| s == 'x' || s == 'X' || s == '*' }
  unless wild.nil?
    nums = segs[0...wild]
    return true if nums.empty?
    lo = (nums + ['0'] * (3 - nums.length)).join('.')
    up = nums.dup
    up[-1] = (up[-1].to_i + 1).to_s
    hi = (up + ['0'] * (3 - up.length)).join('.')
    return ver >= gv(lo) && ver < gv(hi)
  end
  return nil unless body =~ /\A\d+(\.\d+)*\z/
  v = gv(body)
  case op
  when '>=' then ver >= v
  when '>' then ver > v
  when '<=' then ver <= v
  when '<' then ver < v
  when '=', '==' then ver == v
  when '~>' then Gem::Requirement.new("~> #{body}").satisfied_by?(ver)
  when '~'
    lo, hi = tilde_range(body)
    ver >= gv(lo) && ver < gv(hi)
  when '^'
    lo, hi = caret_range(body)
    ver >= gv(lo) && ver < gv(hi)
  else
    if bare_caret
      lo, hi = caret_range(body)
      ver >= gv(lo) && ver < gv(hi)
    else
      ver == v
    end
  end
end

def requirement_match?(req, ver, bare_caret)
  results = req.to_s.split(',').map { |c| clause_match?(c.strip, ver, bare_caret) }
  return nil if results.any?(&:nil?)
  results.all?
end

def name_match?(pattern, names)
  pat = pattern.to_s.downcase
  names.any? { |n| File.fnmatch(pat, n) }
end

def update_type(cur, cand)
  a = cur.segments
  b = cand.segments
  return 'major' if a[0] != b[0]
  return 'minor' if a[1] != b[1]
  'patch'
end

def covers_root?(entry)
  dirs = []
  dirs << entry['directory'] if entry['directory']
  dirs.concat(Array(entry['directories']))
  return true if dirs.empty?
  dirs.any? { |d| ['/', '/*', '/**', '*', '**'].include?(d.to_s) }
end

# Why Dependabot would NOT open a cur -> cand PR under this entry, or nil.
def blocked_reason(entry, names, dep_type, cur, cand, cargo_req)
  return 'open-pull-requests-limit: 0' if entry['open-pull-requests-limit'] == 0
  al = entry['allow']
  if al
    ok = Array(al).any? do |a|
      m = true
      m &&= name_match?(a['dependency-name'], names) if a['dependency-name']
      if a['dependency-type']
        t = a['dependency-type'].to_s
        m &&= (t == 'all' || t == 'direct' || t == dep_type)
      end
      m
    end
    return "allow list #{al.inspect} does not include it" unless ok
  end
  type = update_type(cur, cand)
  Array(entry['ignore']).each do |ign|
    next unless ign['dependency-name'] && name_match?(ign['dependency-name'], names)
    vs = ign['versions']
    ut = ign['update-types']
    return "ignore rule #{ign.inspect}" if vs.nil? && ut.nil?
    return "ignore rule #{ign.inspect} (#{cur}->#{cand} is a #{type} update)" if Array(ut).include?("version-update:semver-#{type}")
    Array(vs).each do |e|
      return "ignore rule #{ign.inspect} (matches #{cand})" if requirement_match?(e, cand, false) == true
    end
  end
  if entry['versioning-strategy'].to_s == 'lockfile-only' && cargo_req
    return "lockfile-only with Cargo.toml requirement #{cargo_req.inspect} excluding #{cand}" if requirement_match?(cargo_req, cand, true) == false
  end
  nil
end

def swift_candidates(cur)
  s = cur.segments + [0, 0, 0]
  [[s[0], s[1], s[2] + 1], [s[0], s[1] + 1, 0], [s[0] + 1, 0, 0]].map { |a| a.join('.') }
end

def dependabot_verdict(eco)
  cfg = yaml('.github/dependabot.yml')
  entries = (cfg['updates'] || []).select { |u| u['package-ecosystem'].to_s == eco && covers_root?(u) }
  if eco == 'cargo'
    names = PROPTEST_NAMES
    dep_type = 'development'
    cur = lock_version('proptest')
    cands = ['1.12.0']
    req = proptest_req
  else
    names = SPARKLE_NAMES
    dep_type = 'production'
    cur = sparkle_lock_version || pbx_sparkle_min
    cands = cur ? swift_candidates(gv(cur)) : []
    req = nil
  end
  if cur.nil?
    puts "unsafe|cannot determine the currently pinned #{eco} version (lockfile unreadable)"
    return
  end
  if entries.empty?
    puts "safe|dependabot.yml has no #{eco} ecosystem entry covering / (Dependabot opens no #{eco} PRs)"
    return
  end
  if eco == 'cargo' && gv(cur) >= gv(cands[0])
    puts "safe|Cargo.lock already pins proptest #{cur} (>= #{cands[0]}); nothing to bump"
    return
  end
  open = []
  why = []
  cands.each do |cand|
    reasons = entries.map { |e| blocked_reason(e, names, dep_type, gv(cur), gv(cand), req) }
    if reasons.any?(&:nil?)
      open << cand
    else
      why << "#{cand}: #{reasons.uniq.join('; ')}"
    end
  end
  if open.empty?
    puts "safe|every #{eco} bump from #{cur} is suppressed by dependabot.yml (#{why.join(' | ')})"
    return
  end
  if eco == 'cargo'
    ws = ws_rust_version
    tcs = ci_toolchains
    floor = gv(PROPTEST_1_12_RUSTC)
    if ws && !tcs.empty? && gv(ws) >= floor && tcs.all? { |t| gv(t) >= floor }
      puts "safe|workspace rust-version #{ws} and CI toolchain(s) #{tcs.join(',')} all satisfy proptest 1.12.0 (rustc #{PROPTEST_1_12_RUSTC})"
      return
    end
    puts "unsafe|Dependabot can open proptest #{cur} -> #{cands[0]} (needs rustc #{PROPTEST_1_12_RUSTC}) while workspace rust-version is #{ws.inspect} and CI toolchain(s) #{tcs.join(',').inspect}; cargo entries: #{entries.length}, none ignores/denies it"
  else
    puts "unsafe|Dependabot can open Sparkle #{cur} -> #{open.join(' / ')} PRs (swift entries: #{entries.length}, ignore rules cover only: #{why.empty? ? 'nothing' : why.join(' | ')})"
  end
end

# ----- CI drift-gate extraction --------------------------------------------

def expand(text, actor, head_ref)
  text.to_s.gsub(/\$\{\{\s*(.*?)\s*\}\}/m) do
    expr = Regexp.last_match(1)
    case expr
    when /github\.actor|pull_request\.user\.login|github\.triggering_actor/ then actor
    when /github\.event_name/ then 'pull_request'
    when /github\.head_ref|pull_request\.head\.ref/ then head_ref
    when /matrix\.os/ then 'macos-26'
    else ''
    end
  end
end

def term_true?(term, actor, head_ref)
  t = term.strip
  neg = false
  if t.start_with?('!')
    neg = true
    t = t[1..-1].strip
  end
  t = t[1..-2].strip if t.start_with?('(') && t.end_with?(')')
  val = nil
  if (m = t.match(/\A(?:github\.actor|github\.triggering_actor|github\.event\.pull_request\.user\.login)\s*(==|!=)\s*'([^']*)'\z/))
    val = (m[1] == '==') == (actor == m[2])
  elsif (m = t.match(/\Agithub\.event_name\s*(==|!=)\s*'([^']*)'\z/))
    val = (m[1] == '==') == ('pull_request' == m[2])
  elsif (m = t.match(/\Acontains\(\s*(github\.actor|github\.event\.pull_request\.user\.login|github\.head_ref)\s*,\s*'([^']*)'\s*\)\z/))
    subject = m[1] == 'github.head_ref' ? head_ref : actor
    val = subject.include?(m[2])
  elsif (m = t.match(/\AstartsWith\(\s*(github\.actor|github\.head_ref)\s*,\s*'([^']*)'\s*\)\z/))
    subject = m[1] == 'github.head_ref' ? head_ref : actor
    val = subject.start_with?(m[2])
  end
  return true if val.nil?
  neg ? !val : val
end

def cond_true?(cond, actor, head_ref)
  return true if cond.nil?
  c = cond.to_s.strip.sub(/\A\$\{\{\s*/, '').sub(/\s*\}\}\z/, '')
  return true if c.empty? || c.include?('||')
  c.split('&&').all? { |t| term_true?(t, actor, head_ref) }
end

def gate_step?(step)
  r = step['run'].to_s
  r =~ /xcodegen\s+generate/ && r =~ /git\s+(--no-pager\s+)?diff/ && r =~ /pbxproj/ ? true : false
end

def shell_quote(s)
  "'" + s.to_s.gsub("'") { "'\\''" } + "'"
end

def write_plans(outdir, actor)
  head_ref = 'dependabot/swift/sparkle'
  (yaml('.github/workflows/ci.yml')['jobs'] || {}).each do |jid, job|
    steps = job['steps'] || []
    gi = steps.index { |s| gate_step?(s) }
    next if gi.nil?
    unless cond_true?(job['if'], actor, head_ref)
      puts "SKIP\t#{jid}\tjob condition is false for actor #{actor}"
      next
    end
    dir = File.join(outdir, "job-#{jid}")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    texts = []
    names = []
    steps.each_with_index do |s, i|
      break if i > gi
      r = s['run']
      next if r.nil?
      next unless cond_true?(s['if'], actor, head_ref)
      relevant = (i == gi) || (r =~ /project\.yml|pbxproj|xcodegen|dependabot|Package\.resolved/i && r !~ /brew install|sudo /)
      next unless relevant
      env_lines = (s['env'] || {}).map { |k, v| "export #{k}=#{shell_quote(expand(v, actor, head_ref))}" }
      script = "#!/usr/bin/env bash\n" + env_lines.join("\n") + "\n" + expand(r, actor, head_ref) + "\n"
      File.write(File.join(dir, format('%02d.sh', i)), script)
      texts << script
      names << (s['name'] || "step #{i}").to_s
    end
    puts ['PLAN', jid, Digest::MD5.hexdigest(texts.join("\0")), dir, names.empty? ? '(gate step skipped)' : names.join(' + ')].join("\t")
  end
end

# A workflow job that reacts to Dependabot by regenerating the project and
# committing the result back to the PR branch.
def autofix
  hits = []
  Dir.glob(rel('.github/workflows/*.yml')).sort.each do |f|
    wf = begin
      YAML.load_file(f)
    rescue StandardError
      nil
    end
    next unless wf.is_a?(Hash)
    (wf['jobs'] || {}).each do |jid, job|
      next unless job.to_yaml =~ /dependabot/i
      steps = job['steps'] || []
      runs = steps.map { |s| s['run'].to_s }.join("\n")
      uses = steps.map { |s| s['uses'].to_s }.join("\n")
      regen = runs =~ /xcodegen\s+generate/
      pushes = runs =~ /git\s+(-C\s+\S+\s+)?(commit|push)/ || uses =~ /auto-commit|add-and-commit|git-push/i
      hits << "#{File.basename(f)}:#{jid}" if regen && pushes
    end
  end
  puts(hits.empty? ? 'no' : "yes|#{hits.join(',')}")
end

# Apply a Dependabot-style Sparkle bump: pbxproj requirement + Package.resolved only.
def edit_sparkle(pbx, resolved, target)
  txt = File.read(pbx)
  m = txt.match(SPARKLE_REQ_RE)
  if m.nil?
    puts 'noedit|no Sparkle XCRemoteSwiftPackageReference in the pbxproj'
    return
  end
  vm = m[2].match(VERSION_KEY_RE)
  if vm.nil?
    puts "noedit|Sparkle requirement pins no semver in the pbxproj (#{m[2].strip.gsub(/\s+/, ' ')}); Dependabot would only touch Package.resolved"
    return
  end
  old = vm[3]
  ver = target
  if target == 'minor'
    s = gv(old).segments + [0, 0, 0]
    ver = [s[0], s[1] + 1, 0].join('.')
  end
  new_block = m[2].sub(VERSION_KEY_RE) { "#{vm[1]} = #{vm[2]}#{ver}#{vm[4]};" }
  File.write(pbx, txt.sub(SPARKLE_REQ_RE) { m[1] + new_block + m[3] })
  if File.exist?(resolved)
    r = File.read(resolved)
    File.write(resolved, r.sub(/("version" : ")#{Regexp.escape(old)}(")/) { "#{Regexp.last_match(1)}#{ver}#{Regexp.last_match(2)}" })
  end
  puts "edited|#{old}->#{ver}"
end

case ARGV[0]
when 'facts' then facts
when 'dependabot' then dependabot_verdict(ARGV[1])
when 'gates' then write_plans(ARGV[1], ARGV[2])
when 'autofix' then autofix
when 'edit_sparkle' then edit_sparkle(ARGV[1], ARGV[2], ARGV[3])
when 'candidates'
  cur = sparkle_lock_version || pbx_sparkle_min
  puts swift_candidates(gv(cur)).join(' ') if cur
else
  abort "unknown sub-command: #{ARGV.inspect}"
end
RUBY

rb() {
    ruby "$RB" "$@"
}

# ---------------------------------------------------------------------------
# 0. Preconditions: tools and parseable inputs (so nothing below is vacuous).
# ---------------------------------------------------------------------------

HAVE_RUBY=0
if command -v ruby >/dev/null 2>&1; then
    HAVE_RUBY=1
    pass "ruby is available for YAML / version-requirement evaluation ($(ruby -e 'print RUBY_VERSION'))"
else
    fail "ruby not on PATH - cannot evaluate .github/dependabot.yml"
fi
if (( HAVE_RUBY == 0 )); then
    test_end
    exit 1
fi

FACTS="$(rb facts)"
fact() {
    printf '%s\n' "$FACTS" | sed -n "s/^$1=//p" | head -1
}

echo "    facts:"
printf '%s\n' "$FACTS" | sed 's/^/      /'

assert_contains "$(fact dependabot_ecosystems)" "github-actions" \
    "parser sees dependabot.yml (long-standing github-actions ecosystem present)"
assert_ne "$(fact lock_proptest)" "" \
    "Cargo.lock pins proptest (premise: a newer proptest would be a Dependabot bump)"
assert_ne "$(fact ws_rust_version)" "" \
    "workspace Cargo.toml declares rust-version (MSRV under test)"
assert_ne "$(fact ci_toolchains)" "" \
    "ci.yml installs a pinned Rust toolchain (compile floor under test)"
assert_ne "$(fact sparkle_lock)" "" \
    "Package.resolved pins Sparkle (premise: a newer Sparkle would be a Dependabot bump)"

# ---------------------------------------------------------------------------
# 1. CARGO: proptest 1.12.0 needs rustc 1.88; the workspace is on 1.85.
# ---------------------------------------------------------------------------

CARGO_VERDICT="$(rb dependabot cargo)"
CARGO_STATE="${CARGO_VERDICT%%|*}"
CARGO_WHY="${CARGO_VERDICT#*|}"
echo "    cargo verdict: $CARGO_VERDICT"

# ---------------------------------------------------------------------------
# 2. SWIFT: simulate Dependabot's Sparkle bump against ci.yml's drift gate.
# ---------------------------------------------------------------------------

SWIFT_VERDICT="$(rb dependabot swift)"
SWIFT_CFG_STATE="${SWIFT_VERDICT%%|*}"
SWIFT_CFG_WHY="${SWIFT_VERDICT#*|}"
echo "    swift (dependabot.yml) verdict: $SWIFT_VERDICT"

RIG="$TMP_ROOT/rig"
BASE_SHA=""
RIG_STATE="not-built"

# Copy only what `xcodegen generate` reads (project.yml's sources, including the
# bundled LICENSE / THIRD_PARTY_NOTICES.txt resources), into a git repo of its own.
setup_rig() {
    mkdir -p "$RIG"
    local item
    for item in .gitignore project.yml LICENSE THIRD_PARTY_NOTICES.txt Blackbird.xcodeproj Sources Tests scripts .github; do
        [[ -e "$BB_REPO_ROOT/$item" ]] || continue
        cp -R "$BB_REPO_ROOT/$item" "$RIG/$item"
    done
    find "$RIG" -name .DS_Store -delete
    (
        cd "$RIG"
        git init -q -b main
        git config user.name "Blackbird Blind Test"
        git config user.email "blind-test@example.invalid"
        git config commit.gpgsign false
        git add -A
        git commit -q -m baseline
    )
    BASE_SHA="$(git -C "$RIG" rev-parse HEAD)"
}

rig_reset() {
    git -C "$RIG" reset -q --hard "${1:-HEAD}"
    git -C "$RIG" clean -fdq
}

# Echo "ok", "failed" for the unmodified-copy sanity run of the real generator.
rig_baseline() {
    local rc=0
    (cd "$RIG" && xcodegen generate) >"$TMP_ROOT/xcodegen-baseline.log" 2>&1 || rc=$?
    if (( rc != 0 )); then
        # Surface why (stderr is not captured by the caller's $(...)): the rig
        # is a partial copy of the repo, so a missing input shows up here.
        tail -25 "$TMP_ROOT/xcodegen-baseline.log" | sed 's/^/        xcodegen: /' >&2
        echo "xcodegen-failed(rc=$rc)"
    elif git -C "$RIG" diff --quiet -- Blackbird.xcodeproj/project.pbxproj Sources/Blackbird/Info.plist; then
        echo "clean"
    else
        echo "drifted"
    fi
    rig_reset "$BASE_SHA"
}

# Run every distinct ci.yml drift-gate plan for ACTOR against the rig's
# current HEAD. Sets PLAN_JOBS, PLAN_FAILED_JOBS, PLAN_LOG_EXCERPT.
run_gate_plans() {
    local actor="$1" label="$2"
    local outdir="$TMP_ROOT/plans-$label"
    mkdir -p "$outdir"
    PLAN_JOBS=""
    PLAN_FAILED_JOBS=""
    PLAN_LOG_EXCERPT=""
    local lines tag jid digest dir names rc f
    lines="$(rb gates "$outdir" "$actor")"
    while IFS=$'\t' read -r tag jid digest dir names; do
        [[ "$tag" == "PLAN" ]] || continue
        PLAN_JOBS="$PLAN_JOBS $jid"
        if [[ ! -f "$outdir/result-$digest" ]]; then
            rc=0
            : >"$dir.log"
            for f in "$dir"/*.sh; do
                [[ -e "$f" ]] || break
                if ! (cd "$RIG" && bash --noprofile --norc -e -o pipefail "$f") >>"$dir.log" 2>&1; then
                    rc=1
                    echo "[step $(basename "$f") failed]" >>"$dir.log"
                    break
                fi
            done
            echo "$rc" >"$outdir/result-$digest"
            cp "$dir.log" "$outdir/log-$digest" 2>/dev/null || true
            rig_reset "HEAD"
        fi
        if [[ "$(cat "$outdir/result-$digest")" != "0" ]]; then
            PLAN_FAILED_JOBS="$PLAN_FAILED_JOBS $jid($names)"
            if [[ -z "$PLAN_LOG_EXCERPT" ]]; then
                PLAN_LOG_EXCERPT="$(grep -v '^\s*$' "$outdir/log-$digest" | head -14 | sed 's/^/        | /')"
            fi
        fi
    done <<<"$lines"
}

HAVE_XCODEGEN=0
if command -v xcodegen >/dev/null 2>&1; then
    HAVE_XCODEGEN=1
    pass "xcodegen is available ($(xcodegen --version 2>&1 | head -1))"
else
    fail "xcodegen not on PATH - cannot simulate ci.yml's pbxproj drift gate (ci.yml installs it before this harness)"
fi

SIM_STATE="not-run"       # green | red | n/a
SIM_DETAIL=""
EDIT_RESULT=""

if (( HAVE_XCODEGEN == 1 )); then
    setup_rig
    RIG_STATE="$(rig_baseline)"
    assert_eq "$RIG_STATE" "clean" \
        "rig sanity: an unmodified copy + 'xcodegen generate' leaves pbxproj/Info.plist drift-free (else the simulation proves nothing)"

    if [[ "$RIG_STATE" == "clean" ]]; then
        # Guard: a hand-edited pbxproj (NOT a Dependabot PR) must still fail
        # every distinct gate, so a "fix" cannot just delete the drift gate.
        perl -0pi -e 's/PRODUCT_BUNDLE_IDENTIFIER = dev\.conjfrnk\.blackbird;/PRODUCT_BUNDLE_IDENTIFIER = dev.conjfrnk.blackbird.handdrift;/g' \
            "$RIG/Blackbird.xcodeproj/project.pbxproj"
        if git -C "$RIG" diff --quiet -- Blackbird.xcodeproj/project.pbxproj; then
            fail "rig guard setup: hand edit did not change the pbxproj (PRODUCT_BUNDLE_IDENTIFIER pattern gone?)"
        else
            git -C "$RIG" commit -q -am "human hand-edits pbxproj"
            run_gate_plans "octocat" "human"
            assert_ne "${PLAN_JOBS# }" "" "rig guard: ci.yml has at least one pbxproj drift-gate step to exercise"
            human_green=""
            for j in $PLAN_JOBS; do
                case "$PLAN_FAILED_JOBS" in
                    *" $j("*) ;;
                    *) human_green="$human_green $j" ;;
                esac
            done
            assert_eq "${human_green# }" "" \
                "rig guard: a hand-edited pbxproj (human PR, not Dependabot) still turns the drift gate red in every job (jobs where it stayed green: ${human_green:-none})"
        fi
        rig_reset "$BASE_SHA"

        # The simulated Dependabot PR: bump Sparkle in pbxproj + Package.resolved only.
        EDIT_RESULT="$(rb edit_sparkle "$RIG/Blackbird.xcodeproj/project.pbxproj" \
            "$RIG/Blackbird.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" minor)"
        echo "    simulated Dependabot edit: $EDIT_RESULT"
        if [[ "${EDIT_RESULT%%|*}" == "edited" ]]; then
            git -C "$RIG" commit -q -am "chore(deps): bump Sparkle (dependabot)"
            run_gate_plans "dependabot[bot]" "dependabot"
            if [[ -z "${PLAN_FAILED_JOBS// /}" ]]; then
                SIM_STATE="green"
                SIM_DETAIL="the ci.yml drift gate(s)${PLAN_JOBS:-none} accept a Dependabot-style Sparkle bump (${EDIT_RESULT#*|})"
            else
                SIM_STATE="red"
                SIM_DETAIL="ci.yml drift gate red for Dependabot-style Sparkle bump (${EDIT_RESULT#*|}) in:${PLAN_FAILED_JOBS}"
                echo "      first failing gate output:" >&2
                printf '%s\n' "$PLAN_LOG_EXCERPT" >&2
            fi
        else
            SIM_STATE="n/a"
            SIM_DETAIL="Dependabot would not touch the pbxproj (${EDIT_RESULT#*|})"
        fi
    fi
fi

AUTOFIX="$(rb autofix)"
echo "    auto-regenerate workflow for Dependabot PRs: $AUTOFIX"

# ---------------------------------------------------------------------------
# Verdicts.
# ---------------------------------------------------------------------------

SWIFT_FINAL="unsafe"
SWIFT_WHY=""
if [[ "$SWIFT_CFG_STATE" == "safe" ]]; then
    SWIFT_FINAL="safe"
    SWIFT_WHY="$SWIFT_CFG_WHY"
elif [[ "$SIM_STATE" == "green" || "$SIM_STATE" == "n/a" ]]; then
    SWIFT_FINAL="safe"
    SWIFT_WHY="$SIM_DETAIL"
elif [[ "${AUTOFIX%%|*}" == "yes" ]]; then
    SWIFT_FINAL="safe"
    SWIFT_WHY="a workflow regenerates the project on Dependabot PRs (${AUTOFIX#*|}) although ci.yml's gate alone would be red"
else
    case "$SIM_STATE" in
        red) SWIFT_WHY="$SWIFT_CFG_WHY; $SIM_DETAIL; no workflow regenerates the pbxproj for Dependabot PRs" ;;
        *)   SWIFT_WHY="$SWIFT_CFG_WHY; the CI gate could not be simulated (rig state: $RIG_STATE)" ;;
    esac
fi

assert_eq "$SWIFT_FINAL" "safe" \
    "SWIFT: a Dependabot Sparkle bump (pbxproj minimumVersion + Package.resolved only) must never leave PR CI red - $SWIFT_WHY"

assert_eq "$CARGO_STATE" "safe" \
    "CARGO: Dependabot must not propose proptest 1.12.0 (rustc 1.88) against the 1.85 MSRV - $CARGO_WHY"

test_end
