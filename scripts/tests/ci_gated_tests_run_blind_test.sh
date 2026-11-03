#!/usr/bin/env bash
#
# Regression (blind): every XCTest that hides behind a BB_RUN_* env gate
# must actually run in at least one automatic CI job (and the no-argument
# `scripts/test.sh` run must unlock the big ASan-motivated gate), otherwise
# "green CI" silently covers none of it.
#
# The bug (TSI-1). Three Swift gates turn tests into XCTSkips:
#
#   BB_RUN_STRESS_TESTS           ~36 tests (real PTY -> TerminalSession ->
#                                 snapshot path, TerminalView resize / title /
#                                 option-key wiring, Preferences repair and
#                                 SwiftUI-bridge same-value-guard assertions,
#                                 ...)
#   BB_RUN_WINDOW_LIFECYCLE_TESTS  7 real-window lifecycle tests
#   BB_RUN_SOAK                    4 multi-tab / single-session leak gates
#
# The skip messages cite "SEGV in CATransaction under cumulative ASan". But
# ci.yml's xcode job and a whole-suite `scripts/test.sh` run BOTH turn
# ASan/UBSan off already (ENABLE_ADDRESS_SANITIZER=NO ...), so the reason
# for the gate is gone while the gate itself still trips: xctest only sees
# an env var when xcodebuild is run with TEST_RUNNER_<VAR>=1, and no CI job
# that selects those classes sets it. (nightly-tsan lists
# MainWindowControllerLifetimeTests but never sets the lifecycle gate;
# nightly-soak selects other soak classes only.) Result: PR CI and local
# runs are green while 45+ tests never execute.
#
# Correct behaviour (what this test pins, deliberately fix-agnostic): for
# every test method that skips unless a BB_RUN_STRESS_TESTS /
# BB_RUN_WINDOW_LIFECYCLE_TESTS / BB_RUN_SOAK gate is set, SOME workflow that
# runs automatically (pull_request / push / schedule) must run
# `xcodebuild test` with TEST_RUNNER_<gate>=1, selecting that test (whole
# suite, or -only-testing of the class / method, minus any -skip-testing).
# Un-gating the test (removing the XCTSkip) satisfies this too. And a
# no-argument `scripts/test.sh` (documented as CI parity, ASan off) must
# export TEST_RUNNER_BB_RUN_STRESS_TESTS=1.
# Out of scope on purpose: BB_RUN_FLAKY_PTY_TESTS (real-shell rigs the CI
# image cannot run), BB_RUN_LATENCY_PROBE, BB_RUN_STARTUP_BENCH.
#
# How it observes that WITHOUT launching Xcode, the app, or the network:
#   * The Swift test sources are scanned for the skip guards and mapped to
#     (class, test method); a guard in setUp / a helper gates the whole class.
#   * Each `run:` step of every automatically-triggered workflow that invokes
#     `xcodebuild ... test` (or scripts/test.sh) is EXECUTED in a throw-away
#     sandbox with a stub `xcodebuild` first on a minimal PATH. The stub
#     records its argv and TEST_RUNNER_* environment, so inline
#     `VAR=1 xcodebuild`, `export`, step / job / workflow `env:` and wrapper
#     scripts are all resolved by the shell itself instead of by regexes.
#     The workflow YAML is only used to find triggers, env and run text.
#   * `scripts/test.sh` is run the same way with no arguments.
#   * Rig guards keep this from passing vacuously: the whole engine is first
#     run against a synthetic fixture tree whose covered / uncovered answer
#     is known (method-level, class-wide setUp, wrong gate, -skip-testing,
#     workflow-level env, non-automatic workflow, comment-only mentions), and
#     the real workflows must show the env parsing sees the gates that are
#     already wired (nightly-tsan FLAKY_PTY, nightly-soak SOAK).
#
# Needs ruby (YAML; the macOS system ruby is enough). Nothing in the real
# checkout is modified and no xcodebuild / app is launched.

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "ci_gated_tests_run_blind_test.sh"

TMP_ROOT="$(mk_tmp bb-ci-gated-tests)"
trap 'rm -rf "$TMP_ROOT"' EXIT

RB="$TMP_ROOT/engine.rb"

# ---------------------------------------------------------------------------
# Ruby engine (ruby 2.6 compatible: no endless methods, no numbered params).
#   engine.rb report <repo-root>
# prints, one record per line, '|' separated:
#   INV|workflow|job|step|gates-set-to-1|only-testing|skip-testing
#   UNIT|file|gate|class|method|yes/no|first-covering-"workflow:step"
#   TESTSH|ran/noinv/missing|gates-set-to-1|only-testing
# ---------------------------------------------------------------------------
cat >"$RB" <<'RUBY'
Encoding.default_external = Encoding::UTF_8
require 'yaml'
require 'fileutils'
require 'tmpdir'

GATES = %w[BB_RUN_STRESS_TESTS BB_RUN_WINDOW_LIFECYCLE_TESTS BB_RUN_SOAK].freeze
GATE_ALT = GATES.join('|')
SKIP_NE_RE = /environment\[\s*"(#{GATE_ALT})"\s*\]\s*(?:!=\s*"1"|==\s*nil)/
GUARD_EQ_RE = /(?:\bguard\b|XCTSkipUnless).*environment\[\s*"(#{GATE_ALT})"\s*\]\s*==\s*"1"/
MODS = '(?:(?:public|internal|private|fileprivate|final|open)\s+)*'.freeze
CLASS_RE = /^\s*(?:@\w+\s+)*#{MODS}class\s+(\w+)\s*:\s*(?:[\w.]+\s*,\s*)*XCTestCase\b/
EXT_RE = /^\s*(?:@\w+\s+)*#{MODS}extension\s+(\w+)/
FUNC_RE = /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:override|private|fileprivate|internal|public|final|static|class|open|nonisolated)\s+)*func\s+(\w+)/
TEST_FUNC_RE = /\bfunc\s+(test\w*)\s*\(\s*\)/

ALLOW_TOOLS = %w[bash sh env tee grep egrep fgrep sed awk cat mktemp date sort uniq head tail tr wc
                 dirname basename cut mkdir cp mv rm ls true false sleep uname xargs find readlink
                 touch chmod ln id whoami hostname expr test stat diff cmp printf echo pwd nl].freeze
NOOP_TOOLS = %w[sudo brew xcode-select xcodegen xcrun cargo rustup rustc gh git curl wget open codesign
                security hdiutil defaults killall pkill osascript npm node pip pip3 python3 ruby
                shellcheck fish lipo ditto].freeze
SHIM = <<'SH'.freeze
#!/bin/bash
{
  echo "BEGIN"
  for a in "$@"; do printf 'ARG\t%s\n' "$a"; done
  env | grep '^TEST_RUNNER_' | sed 's/^/ENV\t/'
  echo "END"
} >> "${BB_SHIM_LOG:?}"
echo "Test Suite 'BlackbirdTests.xctest' passed"
echo "Test Suite 'Selected tests' passed"
exit 0
SH
STEP_TIMEOUT = 120

def which(cmd)
  ENV['PATH'].to_s.split(':').each do |d|
    p = File.join(d, cmd)
    return p if File.file?(p) && File.executable?(p)
  end
  nil
end

def expand(str, os)
  str.to_s.gsub(/\$\{\{\s*matrix\.os\s*\}\}/, os).gsub(/\$\{\{.*?\}\}/m, '')
end

# ---------------------------------------------------------------- sandbox --
class Sandbox
  attr_reader :dir, :bash

  def initialize(root)
    @dir = Dir.mktmpdir('bb-gated-sandbox')
    @bin = File.join(@dir, 'bin')
    @tmp = File.join(@dir, 'tmp')
    @home = File.join(@dir, 'home')
    @logs = File.join(@dir, 'logs')
    [@bin, @tmp, @home, @logs, File.join(@dir, 'steps')].each { |d| FileUtils.mkdir_p(d) }
    src = File.join(root, 'scripts')
    FileUtils.cp_r(src, File.join(@dir, 'scripts')) if File.directory?(src)
    @bash = which('bash') || '/bin/bash'
    ALLOW_TOOLS.each do |t|
      p = which(t)
      File.symlink(p, File.join(@bin, t)) if p && !File.exist?(File.join(@bin, t))
    end
    NOOP_TOOLS.each { |t| write_exec(File.join(@bin, t), "#!/bin/sh\nexit 0\n") }
    write_exec(File.join(@bin, 'xcodebuild'), SHIM)
    @n = 0
  end

  def write_exec(path, text)
    File.open(path, 'w') { |f| f.write(text) }
    File.chmod(0o755, path)
  end

  def write_step(run)
    @n += 1
    path = File.join(@dir, 'steps', "step_#{@n}.sh")
    text = run.gsub(%r{(?<![\w.~/-])/tmp/}, @tmp + '/')
    File.open(path, 'w') { |f| f.write(text + "\n") }
    path
  end

  def cleanup
    FileUtils.rm_rf(@dir)
  end

  def run_script(path, extra_env)
    @n += 1
    log = File.join(@logs, "shim#{@n}.log")
    out = File.join(@logs, "out#{@n}.txt")
    env = {
      'PATH' => @bin, 'HOME' => @home, 'TMPDIR' => @tmp + '/', 'LANG' => 'en_US.UTF-8',
      'CI' => 'true', 'BB_SHIM_LOG' => log, 'GITHUB_WORKSPACE' => @dir, 'RUNNER_TEMP' => @tmp,
      'GITHUB_ENV' => File.join(@logs, 'github_env'), 'GITHUB_OUTPUT' => File.join(@logs, 'github_output'),
      'GITHUB_STEP_SUMMARY' => File.join(@logs, 'github_summary'), 'GIT_DIR' => '/dev/null'
    }.merge(extra_env)
    pid = Process.spawn(env, @bash, '--noprofile', '--norc', '-eo', 'pipefail', path,
                        chdir: @dir, unsetenv_others: true, pgroup: true,
                        in: File::NULL, out: out, err: [:child, :out])
    deadline = Time.now + STEP_TIMEOUT
    loop do
      r = Process.wait2(pid, Process::WNOHANG)
      break if r
      if Time.now > deadline
        (Process.kill('KILL', -pid) rescue nil)
        (Process.wait(pid) rescue nil)
        break
      end
      sleep 0.02
    end
    parse_shim_log(log)
  end

  def parse_shim_log(path)
    invs = []
    cur = nil
    return invs unless File.exist?(path)
    File.read(path, encoding: 'UTF-8').scrub.each_line do |l|
      l = l.chomp
      if l == 'BEGIN'
        cur = { args: [], env: {} }
      elsif l == 'END'
        invs << cur if cur
        cur = nil
      elsif cur && l =~ /\AARG\t(.*)\z/
        cur[:args] << Regexp.last_match(1)
      elsif cur && l =~ /\AENV\t([^=]+)=(.*)\z/
        cur[:env][Regexp.last_match(1)] = Regexp.last_match(2)
      end
    end
    invs.select { |r| !(r[:args] & %w[test test-without-building]).empty? }
  end
end

# ------------------------------------------------------------- workflows --
def load_yaml(path)
  txt = File.read(path, encoding: 'UTF-8').scrub
  begin
    YAML.safe_load(txt, aliases: true)
  rescue ArgumentError
    YAML.safe_load(txt, [], [], true)
  rescue Psych::DisallowedClass
    YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(txt) : YAML.load(txt)
  end
end

def auto_triggered?(wf)
  on = wf.key?('on') ? wf['on'] : wf[true]
  names = case on
          when Hash then on.keys.map(&:to_s)
          when Array then on.map(&:to_s)
          when String then [on]
          else []
          end
  !(names & %w[push pull_request pull_request_target schedule]).empty?
end

def first_os(job)
  m = job['strategy'].is_a?(Hash) ? job['strategy']['matrix'] : nil
  os = m.is_a?(Hash) ? m['os'] : nil
  os = os.first if os.is_a?(Array)
  os.is_a?(String) && !os.include?('${{') ? os : 'macos-26'
end

def test_step?(run)
  run.gsub(/\\\n/, ' ').each_line.any? do |line|
    s = line.strip
    next false if s.start_with?('#')
    !(s =~ /\bxcodebuild\b[^\n]*?\s(?:test|test-without-building)(?:\s|\z)/).nil? ||
      !(s =~ %r{(?:\A|[\s;&|(])(?:\./)?scripts/test\.sh(?:\s|\z)}).nil?
  end
end

def candidate_steps(root)
  out = []
  Dir.glob(File.join(root, '.github', 'workflows', '*.{yml,yaml}')).sort.each do |path|
    wf = load_yaml(path)
    next unless wf.is_a?(Hash) && auto_triggered?(wf)
    wf_env = wf['env'].is_a?(Hash) ? wf['env'] : {}
    (wf['jobs'] || {}).each do |job_id, job|
      next unless job.is_a?(Hash) && job['steps'].is_a?(Array)
      job_env = job['env'].is_a?(Hash) ? job['env'] : {}
      os = first_os(job)
      job['steps'].each_with_index do |step, i|
        next unless step.is_a?(Hash) && step['run'].is_a?(String)
        step_env = step['env'].is_a?(Hash) ? step['env'] : {}
        next if step['run'] =~ /secrets\./ || step_env.values.any? { |v| v.to_s =~ /secrets\./ }
        run = expand(step['run'], os)
        next unless test_step?(run)
        env = {}
        [wf_env, job_env, step_env].each { |h| h.each { |k, v| env[k.to_s] = expand(v.to_s, os) } }
        out << { wf: File.basename(path), job: job_id.to_s,
                 step: (step['name'] || "step#{i}").to_s.tr('|', '/'), run: run, env: env }
      end
    end
  end
  out
end

# ------------------------------------------------------------ swift scan --
def scan_swift(root)
  gated = []
  tests = Hash.new { |h, k| h[k] = [] }
  calls = Hash.new { |h, k| h[k] = [] }
  Dir.glob(File.join(root, 'Tests', '**', '*.swift')).sort.each do |path|
    rel = path.sub(root + '/', '')
    klass = nil
    func = nil
    File.read(path, encoding: 'UTF-8').scrub.each_line do |line|
      next if line.lstrip.start_with?('//')
      if (m = CLASS_RE.match(line))
        klass = m[1]
        func = nil
      elsif (m = EXT_RE.match(line))
        klass = m[1]
        func = nil
      end
      if (m = FUNC_RE.match(line))
        func = m[1]
        tm = TEST_FUNC_RE.match(line)
        tests[[rel, klass]] << tm[1] if tm
      end
      if func && func.start_with?('test')
        line.scan(/\b([A-Za-z_]\w*)\s*\(/).each { |c| calls[[rel, klass, func]] << c[0] }
      end
      m = SKIP_NE_RE.match(line) || GUARD_EQ_RE.match(line)
      gated << [m[1], rel, klass, func] if m
    end
  end
  units = []
  gated.uniq.each do |gate, rel, klass, func|
    all_tests = tests[[rel, klass]].uniq
    # A guard inside a private helper (e.g. skipUnlessStressEnabled()) gates
    # only the tests that call it; a guard in setUp / outside any function
    # gates the whole class.
    callers = []
    if func && !func.start_with?('test', 'setUp', 'tearDown')
      callers = all_tests.select { |t| calls[[rel, klass, t]].include?(func) }
    end
    if func && func.start_with?('test')
      units << [rel, gate, klass.to_s, func]
    elsif !callers.empty?
      callers.each { |t| units << [rel, gate, klass.to_s, t] }
    elsif all_tests.empty?
      units << [rel, gate, klass.to_s, nil]
    else
      all_tests.each { |t| units << [rel, gate, klass.to_s, t] }
    end
  end
  units.uniq.sort_by { |u| [u[0], u[1], u[2], u[3].to_s] }
end

# ------------------------------------------------------------- selection --
def selectors(args, flag)
  out = []
  args.each_with_index do |a, i|
    if a.start_with?(flag + ':')
      out << a.sub(flag + ':', '')
    elsif a == flag && args[i + 1]
      out << args[i + 1]
    end
  end
  out.map { |s| s.sub(/\(\)\z/, '').split('/') }
end

def sel_includes?(sel, klass, meth)
  return sel[0] == 'BlackbirdTests' if sel.length == 1
  return false unless sel[1] == klass
  return true if sel.length == 2
  meth.nil? || sel[2] == meth
end

def sel_excludes?(sel, klass, meth)
  return sel[0] == 'BlackbirdTests' if sel.length == 1
  return false unless sel[1] == klass
  return true if sel.length == 2
  !meth.nil? && sel[2] == meth
end

def covers?(inv, gate, klass, meth)
  return false unless inv[:env]["TEST_RUNNER_#{gate}"] == '1'
  included = inv[:only].empty? || inv[:only].any? { |s| sel_includes?(s, klass, meth) }
  excluded = inv[:skip].any? { |s| sel_excludes?(s, klass, meth) }
  included && !excluded
end

def gates_set(env)
  env.select { |k, v| k.start_with?('TEST_RUNNER_BB_RUN_') && v == '1' }
     .keys.map { |k| k.sub('TEST_RUNNER_', '') }.sort
end

def join_sel(list)
  list.map { |s| s.join('/') }.join(',')
end

def report(root)
  sb = Sandbox.new(root)
  invs = []
  testsh = nil
  begin
    candidate_steps(root).each do |st|
      sb.run_script(sb.write_step(st[:run]), st[:env]).each do |r|
        invs << { wf: st[:wf], job: st[:job], step: st[:step], env: r[:env],
                  only: selectors(r[:args], '-only-testing'), skip: selectors(r[:args], '-skip-testing') }
      end
    end
    script = File.join(sb.dir, 'scripts', 'test.sh')
    if File.exist?(script)
      recs = sb.run_script(script, {})
      if recs.empty?
        testsh = 'TESTSH|noinv||'
      else
        g = recs.map { |r| gates_set(r[:env]) }.flatten.uniq.sort
        o = recs.map { |r| join_sel(selectors(r[:args], '-only-testing')) }.reject(&:empty?).join(',')
        testsh = "TESTSH|ran|#{g.join(',')}|#{o}"
      end
    else
      testsh = 'TESTSH|missing||'
    end
  ensure
    sb.cleanup
  end
  invs.each do |i|
    puts ['INV', i[:wf], i[:job], i[:step], gates_set(i[:env]).join(','), join_sel(i[:only]), join_sel(i[:skip])].join('|')
  end
  scan_swift(root).each do |rel, gate, klass, meth|
    by = invs.find { |i| covers?(i, gate, klass, meth) }
    puts ['UNIT', rel, gate, klass, meth.to_s, by ? 'yes' : 'no', by ? "#{by[:wf]}:#{by[:step]}" : ''].join('|')
  end
  puts testsh
end

case ARGV[0]
when 'report' then report(File.expand_path(ARGV[1]))
else abort "usage: engine.rb report <root>"
end
RUBY

engine() {
    ruby "$RB" report "$1"
}

# ---------------------------------------------------------------------------
# 0. Preconditions.
# ---------------------------------------------------------------------------

if command -v ruby >/dev/null 2>&1; then
    pass "ruby is available for YAML evaluation ($(ruby -e 'print RUBY_VERSION'))"
else
    fail "ruby not on PATH - cannot evaluate the workflows"
    test_end
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Rig self-test on a synthetic tree with a KNOWN answer. If the engine
#    always said "covered" (or always "uncovered", or could not see env /
#    selection / triggers), the real-repo assertions below would be
#    vacuous - so this must pass first.
# ---------------------------------------------------------------------------

FX="$TMP_ROOT/fixture"
mkdir -p "$FX/.github/workflows" "$FX/Tests/BlackbirdTests" "$FX/scripts"

cat >"$FX/.github/workflows/fx.yml" <<'YML'
name: fx
on:
  schedule:
    - cron: "0 1 * * *"
env:
  TEST_RUNNER_BB_RUN_WINDOW_LIFECYCLE_TESTS: "1"
jobs:
  a:
    runs-on: macos-26
    steps:
      - name: prefixed env, class selected
        run: |
          set +e
          TEST_RUNNER_BB_RUN_STRESS_TESTS=1 \
          xcodebuild test \
            -scheme Fx \
            -only-testing:BlackbirdTests/CoveredByPrefix \
            -only-testing:BlackbirdTests/HelperGated/test_h1 \
            2>&1 | tee /tmp/fx.log
      - name: step env, method + class selected
        env:
          TEST_RUNNER_BB_RUN_SOAK: "1"
        run: |
          xcodebuild test -scheme Fx \
            -only-testing:BlackbirdTests/MethodLevel/test_b \
            -only-testing:BlackbirdTests/GuardForm
      - name: exported env, wrong gate for its class
        run: |
          export TEST_RUNNER_BB_RUN_STRESS_TESTS=1
          xcodebuild test -scheme Fx -only-testing:BlackbirdTests/WrongGate
      - name: whole suite, one class skipped (workflow-level env)
        run: |
          xcodebuild test -scheme Fx -skip-testing:BlackbirdTests/SkippedByFlag
      - name: not a test step
        run: xcodebuild build -scheme Fx
YML

# A manual-only workflow must NOT count as CI coverage.
cat >"$FX/.github/workflows/manual.yml" <<'YML'
name: manual
on:
  workflow_dispatch:
jobs:
  m:
    runs-on: macos-26
    steps:
      - name: manual stress run
        run: |
          TEST_RUNNER_BB_RUN_STRESS_TESTS=1 xcodebuild test -scheme Fx -only-testing:BlackbirdTests/ClassWideSetUp
YML

cat >"$FX/Tests/BlackbirdTests/FxTests.swift" <<'SWIFT'
import XCTest

final class CoveredByPrefix: XCTestCase {
    func test_one() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1", "x")
    }
    func test_two() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
            "x")
    }
    func test_ungated() {}
}

final class HelperGated: XCTestCase {
    private func skipUnlessStressEnabled() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1", "x")
    }
    func test_h1() throws { try skipUnlessStressEnabled() }
    func test_h2() throws { try skipUnlessStressEnabled() }
    func test_free() {}
}

final class ClassWideSetUp: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1", "x")
    }
    func test_x() {}
    func test_y() {}
}

final class MethodLevel: XCTestCase {
    func test_a() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1", "x")
    }
    func test_b() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1", "x")
    }
}

final class WrongGate: XCTestCase {
    func test_w() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1", "x")
    }
}

final class GuardForm: XCTestCase {
    func test_g() throws {
        guard ProcessInfo.processInfo.environment["BB_RUN_SOAK"] == "1" else {
            throw XCTSkip("x")
        }
    }
}

final class SkippedByFlag: XCTestCase {
    func test_s() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1", "x")
    }
}

final class WholeSuiteLifecycle: XCTestCase {
    func test_l() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1", "x")
    }
}

final class NotGated: XCTestCase {
    // try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1", "commented out")
    func test_theme() {
        if ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] == "1" {
            // behaviour switch, not a skip
        }
    }
}
SWIFT

cat >"$FX/scripts/test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${TEST_RUNNER_BB_RUN_STRESS_TESTS:=1}"
export TEST_RUNNER_BB_RUN_STRESS_TESTS
exec env TEST_RUNNER_BB_SUPPRESS_BELL=1 xcodebuild test -scheme Fx "$@"
SH
chmod +x "$FX/scripts/test.sh"

FX_REPORT="$TMP_ROOT/fixture.report"
engine "$FX" >"$FX_REPORT" 2>"$TMP_ROOT/fixture.err" || {
    fail "engine crashed on the synthetic fixture: $(head -5 "$TMP_ROOT/fixture.err")"
}

FX_UNITS="$(grep '^UNIT|' "$FX_REPORT" | cut -d'|' -f2-6 | LC_ALL=C sort || true)"
FX_EXPECTED="$(LC_ALL=C sort <<'EXP'
Tests/BlackbirdTests/FxTests.swift|BB_RUN_SOAK|GuardForm|test_g|yes
Tests/BlackbirdTests/FxTests.swift|BB_RUN_SOAK|MethodLevel|test_a|no
Tests/BlackbirdTests/FxTests.swift|BB_RUN_SOAK|MethodLevel|test_b|yes
Tests/BlackbirdTests/FxTests.swift|BB_RUN_SOAK|WrongGate|test_w|no
Tests/BlackbirdTests/FxTests.swift|BB_RUN_STRESS_TESTS|ClassWideSetUp|test_x|no
Tests/BlackbirdTests/FxTests.swift|BB_RUN_STRESS_TESTS|ClassWideSetUp|test_y|no
Tests/BlackbirdTests/FxTests.swift|BB_RUN_STRESS_TESTS|HelperGated|test_h1|yes
Tests/BlackbirdTests/FxTests.swift|BB_RUN_STRESS_TESTS|HelperGated|test_h2|no
Tests/BlackbirdTests/FxTests.swift|BB_RUN_STRESS_TESTS|CoveredByPrefix|test_one|yes
Tests/BlackbirdTests/FxTests.swift|BB_RUN_STRESS_TESTS|CoveredByPrefix|test_two|yes
Tests/BlackbirdTests/FxTests.swift|BB_RUN_WINDOW_LIFECYCLE_TESTS|SkippedByFlag|test_s|no
Tests/BlackbirdTests/FxTests.swift|BB_RUN_WINDOW_LIFECYCLE_TESTS|WholeSuiteLifecycle|test_l|yes
EXP
)"
assert_eq "$FX_UNITS" "$FX_EXPECTED" "rig self-test: engine classifies the synthetic gated tests exactly (method / setUp / helper / guard forms, env prefix/export/step/workflow env, -only/-skip-testing, manual-only workflow ignored, comment + behaviour-switch mentions ignored)"

FX_TESTSH="$(grep '^TESTSH|' "$FX_REPORT" || true)"
assert_eq "$FX_TESTSH" "TESTSH|ran|BB_RUN_STRESS_TESTS|" "rig self-test: engine reports the gates a no-argument scripts/test.sh exports (synthetic script exports STRESS only)"

# ---------------------------------------------------------------------------
# 2. The real repository.
# ---------------------------------------------------------------------------

REPORT="$TMP_ROOT/real.report"
if ! engine "$BB_REPO_ROOT" >"$REPORT" 2>"$TMP_ROOT/real.err"; then
    fail "engine crashed on the real repo: $(head -5 "$TMP_ROOT/real.err")"
    test_end
    exit 1
fi

echo "    automatic xcodebuild-test invocations seen (workflow | step | TEST_RUNNER gates=1 | -only-testing | -skip-testing):"
grep '^INV|' "$REPORT" | cut -d'|' -f2,4-7 | sed 's/^/      /' || true

# 2a. Rig guards on the real workflows: the parser sees what is already wired.
n_ci="$(grep -c '^INV|ci.yml|' "$REPORT" || true)"
assert_ne "$n_ci" "0" "rig: ci.yml's xcode job produced at least one observed 'xcodebuild test' invocation"

tsan_gates="$(grep '^INV|nightly-tsan.yml|' "$REPORT" | cut -d'|' -f5 | tr '\n' ',' || true)"
assert_contains "$tsan_gates" "BB_RUN_FLAKY_PTY_TESTS" "rig: nightly-tsan's already-wired TEST_RUNNER_BB_RUN_FLAKY_PTY_TESTS=1 is visible to the engine (observed: $tsan_gates)"

soak_gates="$(grep '^INV|nightly-soak.yml|' "$REPORT" | cut -d'|' -f5 | tr '\n' ',' || true)"
assert_contains "$soak_gates" "BB_RUN_SOAK" "rig: nightly-soak's already-wired TEST_RUNNER_BB_RUN_SOAK=1 is visible to the engine (observed: $soak_gates)"

# 2b. Every gated test runs in some automatic CI job, grouped per
#     (test file, gate) so a failure names the file and the tests.
GROUPS_FILE="$TMP_ROOT/groups.txt"
grep '^UNIT|' "$REPORT" | cut -d'|' -f2,3 | LC_ALL=C sort -u >"$GROUPS_FILE" || true

total_units="$(awk -F'|' '$1=="UNIT" {n++} END {print n+0}' "$REPORT")"
uncovered_units="$(awk -F'|' '$1=="UNIT" && $6=="no" {n++} END {print n+0}' "$REPORT")"

while IFS='|' read -r gfile ggate; do
    [[ -z "$gfile" ]] && continue
    n_total="$(awk -F'|' -v f="$gfile" -v g="$ggate" '$1=="UNIT" && $2==f && $3==g {n++} END {print n+0}' "$REPORT")"
    n_unc="$(awk -F'|' -v f="$gfile" -v g="$ggate" '$1=="UNIT" && $2==f && $3==g && $6=="no" {n++} END {print n+0}' "$REPORT")"
    names="$(awk -F'|' -v f="$gfile" -v g="$ggate" '$1=="UNIT" && $2==f && $3==g && $6=="no" {printf "%s.%s ", $4, $5}' "$REPORT")"
    expected="0 of $n_total tests skipped on $ggate run in no automatic CI job"
    actual="$n_unc of $n_total tests skipped on $ggate run in no automatic CI job"
    if (( n_unc > 0 )); then
        actual="$actual: $names"
    fi
    assert_eq "$actual" "$expected" "$(basename "$gfile"): tests gated on $ggate run in some automatic CI job with TEST_RUNNER_$ggate=1"
done <"$GROUPS_FILE"

assert_eq "$uncovered_units of $total_units" "0 of $total_units" "overall: gated tests (STRESS / WINDOW_LIFECYCLE / SOAK) that skip in every automatic CI job"

# 2c. A whole-suite local run (scripts/test.sh, no arguments; ASan already
#     off) unlocks the ASan-motivated STRESS gate.
ts_line="$(grep '^TESTSH|' "$REPORT" || true)"
ts_status="$(printf '%s' "$ts_line" | cut -d'|' -f2)"
ts_gates="$(printf '%s' "$ts_line" | cut -d'|' -f3)"
assert_eq "$ts_status" "ran" "rig: a no-argument scripts/test.sh run reaches xcodebuild test (line: '$ts_line')"
assert_contains ",$ts_gates," ",BB_RUN_STRESS_TESTS," "scripts/test.sh (no args, ASan/UBSan off) exports TEST_RUNNER_BB_RUN_STRESS_TESTS=1 to the xctest host (observed gates set: '$ts_gates')"

test_end
