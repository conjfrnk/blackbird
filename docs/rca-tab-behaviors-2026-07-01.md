# RCA — tab-behavior dogfooding bugs (2026-07-01)

**Status:** investigation complete; no fixes applied yet. This doc is the
engineering basis for the fix batch.
**Environment:** macOS 26.5.1 Tahoe (25F80), Blackbird 0.5.0, Apple Silicon.
**Location note:** gitignored (`docs/*`). Probe sources + raw outputs live in
`docs/probes/`.

Reported symptoms (dogfooding, session ~23:27–23:30 on 2026-07-01 per unified
log): bugs "surrounding tab behaviors — moving tabs between windows, clicking
below the tabs causing the tabs to be clicked, etc."

---

## TL;DR

| # | Finding | Severity | Confidence |
|---|---------|----------|------------|
| 1 | Hidden native `NSTabBar` is still **hit-testable** on Tahoe: clicks on the first ~2 rows of terminal text in any multi-tab window activate invisible native tabs | **HIGH** | CONFIRMED end-to-end (probe: synthetic click switched tabs) |
| 2 | Same mechanism: the whole 36 pt band (32–68 pt from window top) **never routes clicks to the terminal** — top ~2.2 rows are click-dead even where no invisible tab is hit | HIGH | CONFIRMED (hit-test map) |
| 3 | Invisible native tab bar also exposes **drag = native tab tear-off / reorder** and hidden per-tab close buttons → accidental "tab moved to another window", mystery closes | MED-HIGH | Mechanism CONFIRMED; individual interactions inferred |
| 4 | Custom pill order **degrades on cross-window moves**: a moved tab is re-appended at the end; a merged-in cohort loses its custom relative order | MED | CONFIRMED (probe + field log) |
| 5 | `refreshTabBar` never calls `hideNativeTabStrip` — post-move/merge re-hiding depends entirely on `windowDidBecomeKey` timing | MED (aggravates 1–3) | CONFIRMED by code |
| 6 | There is **no first-class affordance to move a tab between windows** — pills can't drag out/in, so users land on the invisible native bar or the auto-injected Window-menu items | MED (UX root cause) | CONFIRMED |
| 7 | Stale hover state after any relayout makes the pill **close-× misfire** (click switches tabs instead of closing) — P1 below | MED | CONFIRMED by code |
| 8 | Merging **standalone** windows leaves non-key members with stale strips, no tab-group KVO, and a first-responder hole (NSBeep) until first selected — X1/X2 below | MED (self-heals) | CONFIRMED by code |

Plus lower-severity items: pill-strip polish (P2–P6), cross-window edge
cases (X3–X4), and adjacent non-tab findings (A1–A5) — all below.

Cross-cutting root cause: **macOS 26 (Tahoe) broke the two assumptions the
"hide the native strip, draw our own pills" architecture rests on**:

1. `isHidden = true` no longer removes the native tab bar from hit-testing
   (the Tahoe tab bar is rebuilt on `NSGlassEffectView` +
   `_NSCoreHostingView<...>` SwiftUI hosts, and `NSTabBar` answers `hitTest`
   even while hidden).
2. AppKit still reserves the 36 pt tab-bar band in `safeAreaInsets` /
   `contentLayoutRect` (68 pt total top chrome), while Blackbird deliberately
   renders the grid starting at the pure titlebar height (32 pt on Tahoe) —
   so live UI and terminal text now *overlap*.

---

## Evidence & methodology

### A. Unified log (field data from the actual dogfooding session)

`/usr/bin/log show --last 2d --predicate 'subsystem == "dev.conjfrnk.blackbird"'`
(raw: `docs/probes/unified-log-tab-churn-2026-07-01.txt`):

- 23:27:36 — first "tab-group identity changed (new group)" (first ⌘T).
- 23:28:25 — burst of **4× "new group"** within 22 ms (a merge where every
  participating window observed a fresh group identity — the
  standalone-windows → Merge All Windows shape).
- 23:28:30 and 23:28:44 — pairs of "new group" + **"detached"** 1 ms apart
  (a 2-window group splitting; `tabGroup` went **nil** on one side — the
  drag-out/tear-off path, *not* `moveTabToNewWindow`, which produces a
  non-nil single-window group per probe B).
- 23:29:45 — another 4× "new group" burst.
- **No** "0 'TabBar' views found" canary → `NativeTabStripHider`'s class-name
  match still works on Tahoe; the strip *is* visually hidden.
- No `tabDrag` / `tabFocus` canaries fired.

### B. Probe A — titlebar geometry + hit-test map (two-tab window)

Source: `docs/probes/TabGeometryProbeTests.swift.txt` (drop back into
`Tests/BlackbirdTests/`, `xcodegen generate`, run with
`TEST_RUNNER_BB_RUN_GEOMETRY_PROBE=1` + `TEST_RUNNER_BB_PROBE_OUT=<file>`
via the usual `xcodebuild test -only-testing:BlackbirdTests/TabGeometryProbeTests`
flags from `scripts/test.sh`; remember to delete + regenerate after).
Raw output: `docs/probes/tab-geometry-probe-output-2026-07-01.txt`.

Uses `MainWindowController.makeForTesting(stubSession:)` ×2 (headless, no
PTY — the real production window/accessory/KVO path) + `addTabbedWindow`.

Measured on a 800×480 window, macOS 26.5.1, y measured from the window TOP:

```
0–32   titlebar row      (titlebarOnlyTopInset = 32 on Tahoe, NOT 28)
         0–2    NSThemeFrame (resize edge)
         4–28   TabStripView — the pills (strip inWindow y-top 0–28, x 77–800)
         28–32  NSTitlebarAccessoryClipView (3–4 pt dead sliver)
32–68  the phantom band  (NSTitlebarContainerView spans 0–68 total)
         32–60  hidden native NSTabBar — HIT-TESTABLE (x ≤ ~760)
         60–68  plain NSView (band container) — swallows clicks, dead
68+    TerminalView finally reachable
```

But the terminal grid **renders text starting at y-top = 32**
(`TerminalView.titlebarOnlyTopInset`, by design — see
`TerminalView.swift:1341-1360`): the first ~2.2 rows (36 pt / ~16 pt cells)
of *visible text* live inside the band.

View-tree facts (multi-tab window, selected tab's theme frame):

- `NSTabBar` subtree exists only in the **selected** tab's window; it is
  re-hosted/re-created when selection changes (probe B).
- `NativeTabStripHider` hid all 6 `*TabBar*`-classed views
  (`NSTabBar`, `NSTabBarTrackView`, `NSTabBarScrollView`, `NSTabBarClipView`,
  `NSTabBarDocumentView`, `NSTabBarNewTabButton`) — but the Tahoe tab bar's
  actual interactive innards are **not** TabBar-classed:
  `NSGlassEffectView → ContentHolderView → NSTabButton →
  _NSCoreHostingView<AppKitButton>` etc., all `hidden=false`.
- Despite `NSTabBar.isHidden == true`, `themeFrame.hitTest(...)` returns
  `NSTabBar` throughout the 32–60 band — i.e. on Tahoe a hidden `NSTabBar`
  is **not** skipped by hit-testing (its SwiftUI-hosted internals appear to
  answer hit-tests regardless of the AppKit hidden flag).

End-to-end confirmation: the probe synthesized a `leftMouseDown`/`Up` at
`(x=200, y-top=40)` — visually terminal text, below the pills — via
`NSWindow.sendEvent`:

```
selected before: PROBE-TWO (arrival=[PROBE-ONE, PROBE-TWO])
clicked at (x=200, top=40) → selected after: PROBE-ONE
TAB SWITCHED BY BAND CLICK: true
```

Single-tab control: the same click point resolves to `TerminalView`
(no band exists; bug is multi-tab-only). Matches the user's phrasing
"clicking below the tabs causes the tabs to be clicked".

### C. Probe B — real cross-window move actions

Source: `docs/probes/TabMoveProbeTests.swift.txt`; raw output:
`docs/probes/tab-move-probe-output-2026-07-01.txt`. Three headless
controllers; drives the actual `NSWindow.moveTabToNewWindow(_:)` and
`NSWindow.mergeAllWindows(_:)` selectors (what the auto-injected Window-menu
items fire), with a `TabOrderCoordinator` reorder first.

Key results:

- 3-tab group G1, coordinator order set to `[T3, T1, T2]` (AppKit arrival
  `[T1, T3, T2]` — orders diverge as designed).
- `moveTabToNewWindow(T2)`: **G1's identity survives**; T2 gets a fresh
  non-nil single-window group G2. G1's visual order `[T3, T1]` preserved.
- `mergeAllWindows` back: T2 rejoins **the same G1**; visual order
  `[T3, T1, T2]` — the moved tab is **re-appended at the end** (reconcile
  dropped it while away, appended on return). Here it coincidentally matched
  its old slot; in general the moved tab always loses its slot.
- In every multi-tab snapshot, the selected window's theme frame:
  `TabBar-classed views total=6 hidden=6`, and
  `hitTest(x=200, top=40) = NSTabBar` — the click-hijack band exists in
  every multi-tab state, before AND after moves/merges/refresh sweeps.
- `isTabBarVisible` stays `true` for the group throughout (AppKit
  bookkeeping) — so the `visObs` KVO (which fires only on a `→ true`
  *change*) is not a reliable re-hide trigger.

---

## Bug 1 — clicks below the pills activate invisible native tabs

**Symptom.** In any multi-tab window, clicking in the top ~2 rows of the
terminal (anything within 32–60 pt from the window top, x up to ~760)
switches tabs "randomly". This is the reported "clicking below the tabs
causing the tabs to be clicked".

**Mechanism.**
1. `NSWindowTabGroup` reserves a 36 pt tab-bar band under the 32 pt titlebar
   (total 68 pt, per `safeAreaInsets.top` / `contentLayoutRect`).
2. `NativeTabStripHider.hide(in:)`
   (`Sources/Blackbird/Window/NativeTabStripHider.swift:33-48`) sets
   `isHidden = true` on `*TabBar*`-classed views only. On ≤ macOS 15 this
   made the strip invisible **and** removed it from hit-testing. On Tahoe it
   only removes rendering: `NSTabBar` still answers `hitTest`, and its
   interactive `NSTabButton`/SwiftUI-host internals are not hidden at all
   (their class names don't contain "TabBar").
3. `TerminalView` renders the grid starting at `titlebarOnlyTopInset`
   (= pure titlebar height, 32 pt on Tahoe; see
   `TerminalView.swift:629-644` and the deliberate decision at
   `TerminalView.swift:1341-1360` to ignore the phantom band so the prompt
   doesn't drop ~2 rows).
4. Result: visible terminal text overlaps a live, invisible tab bar. Clicks
   route to the invisible `NSTabButton` at that x — tabs are laid out in
   **AppKit arrival order**, which diverges from the pill order after any
   reorder, so which tab activates looks arbitrary to the user.

**Why it's new.** Tahoe rebuilt the tab bar on Liquid-Glass SwiftUI hosting
(`NSGlassEffectView`, `_NSCoreHostingView`), which (a) renamed the
interactive subviews out of the `"TabBar"` string-match and (b) changed
hidden-view hit-test semantics for the `NSTabBar` subtree. The
`hideNativeTabStrip` zero-matches canary (`TabGroupObserver.swift:149-152`)
did NOT fire because `NSTabBar` itself still matches — the hiding "worked"
visually while silently losing its event-blocking property.

**Scope.** Multi-tab windows only; every multi-tab state (probe B: present
before/after moves, merges, refreshes). Single-tab windows are clean.

**Fix directions** (to be designed properly in the fix batch):

- (a) *Neutralize the band's hit-testing.* `isHidden` is proven
  insufficient. Options, in rough order of preference:
  - Hide/neutralize the band's **host container** rather than the TabBar
    subtree: the band is hosted in its own `NSTitlebarAccessoryClipView →
    NSView(800×36)` chain (probe A tree, lines 27-29 of the output). It is
    plausibly one of AppKit's internal titlebar accessory VCs
    (`window.titlebarAccessoryViewControllers` may expose it) — hiding at
    that level, or removing the accessory, may both collapse the band and
    kill hit-testing. Needs an experiment; the probe harness makes this a
    ~10-minute check per candidate.
  - Give the strip's suppression a hit-test kill switch: e.g. also set
    `view.frame = .zero` or move it out of the hit path. This was
    deliberately rejected in audit L12 (fragile against AppKit reading
    frames for inset math) — Tahoe breaking `isHidden` semantics is new
    information that justifies re-testing that trade-off.
  - Install an event-forwarding shim view above the band that claims the
    band's hit-tests and re-dispatches mouse events to the `TerminalView`
    (converts band clicks into terminal clicks — also fixes Bug 2). More
    moving parts, but doesn't fight AppKit's private layout.
- (b) *Stop overlapping:* start the grid at `contentLayoutRect` (68 pt) for
  multi-tab windows. Robust and simple but re-introduces the ~2-row prompt
  drop + a visually dead band — previously rejected on UX grounds
  (KNOWN_ISSUES "tab-merge titlebar flash" analysis).
- (c) *Structural:* custom tabs without `NSWindowTabGroup` (KNOWN_ISSUES
  option 2, WezTerm route). Eliminates Bugs 1/2/3/4/5 and the 36 pt flash
  band wholesale. ~A day plus IME/responder-chain risk; Tahoe breaking two
  private-behavior assumptions in one release materially strengthens the
  case. Worth an explicit scope conversation before v1.0 (target 2026-07-01…
  already slipped past freeze — decide consciously).

**Regression pin for the fix:** probe A's synthetic band click asserting
`selectedWindow` does NOT change (plus hit-test map rows 32–68 resolving to
`TerminalView` or inert chrome).

---

## Bug 2 — top ~2.2 terminal rows are click-dead in multi-tab windows

Same mechanism as Bug 1, different consequence: even where the invisible
tab bar does NOT claim the click (x > ~760, or the 60–68 pt sliver, or the
28–32 pt accessory-clip sliver), the click is swallowed by titlebar-container
chrome and **never reaches the terminal**. Selecting text in the first two
rows, clicking a URL there, or focusing the window by clicking that region
misbehaves (drag-selections that *start* lower work, because `mouseDragged`
keeps routing to the initiating view).

Also note `MainWindowController.wireTerminalView`
(`MainWindowController.swift:305-311`) computes `contentMinSize` with a
hard-coded `+ 28` titlebar — actual Tahoe titlebar is 32 pt (probe:
`titlebarOnlyTopInset=32`), so the 4-row minimum is short by 4 pt. Cosmetic,
but fix alongside.

---

## Bug 3 — invisible native tab bar: drags tear tabs off, hidden close buttons

The band doesn't just accept clicks:

- **Drag** on an invisible native tab = native tab **drag/reorder/tear-off**.
  A drag starting on terminal text in the band can rip the tab into its own
  window or reorder AppKit's arrival order. This is almost certainly a chunk
  of the "moving tabs between windows" weirdness: tabs seem to detach/move
  when the user never asked. (Field log's "detached — resubscribing" nil-group
  events at 23:28:30/23:28:44 match the tear-off path — code comment at
  `TitlebarTabBar.swift:1578-1584` documents drag-out as the way `tabGroup`
  goes nil.)
- Each hidden `NSTabButton` contains a live close button
  (`_NSCoreHostingView<AppKitButton>` at its leading edge, probe A tree) —
  a click at just the wrong spot can **close a session** with no visible
  affordance. (Inferred from the view tree; not separately driven
  end-to-end.)
- AppKit reordering its internal `windows` array via invisible-tab drags is
  mostly harmless downstream (everything positional reads
  `TabOrderCoordinator`), but it shifts which native tab sits at which x —
  making Bug 1's "which tab did my click activate" even less predictable.

Any Bug-1 fix that kills band hit-testing fixes this class too. Fix must be
verified against *drag* events, not just clicks.

---

## Bug 4 — pill order lost when tabs move between windows

**Symptom.** After moving a tab out to another window and back (or merging
windows), the pill order no longer matches what the user arranged.

**Mechanism.** `TabOrderCoordinator` stores the visual permutation keyed by
`ObjectIdentifier(tabGroup)` (`TabOrderCoordinator.swift:54,64-68`).
Reconcile (`:138-163`) drops stored windows no longer live in the group and
appends unknown ones in AppKit arrival order. Consequences, all confirmed:

- A tab moved away and back is re-appended **at the end** regardless of its
  old slot (probe B; identity survived, so this is the *best* case).
- When a merge brings a cohort of windows INTO another group (or into a
  brand-new group — the field log's nil→group bursts), the incoming cohort
  arrives via reconcile's append rule in **AppKit arrival order**: any
  custom relative order the incoming cohort had in its previous group
  (keyed to that dead/foreign identity) is not consulted and is lost. The
  destination cohort's order is preserved.
- A group whose windows all leave (or close) is purged; re-forming "the
  same" group starts from scratch — by design, but now user-visible because
  cross-window moves are common.

**Fix direction.** Re-key or migrate the stored order on identity change:
`TabGroupObserver.refreshTabBar` already detects identity transitions
(`TabGroupObserver.swift:344-360`) — on transition, look up the old entry by
window-set overlap and graft the surviving relative order into the new key
(then append genuinely-new windows). Alternatively key order per-window
(a monotonically assigned sort key on each `MainWindowController`) so order
is group-independent. Either is testable headless via probe-B-style tests.

---

## Bug 5 — native-strip re-hiding has no hook on several transition paths

`hideNativeTabStrip` is only called from:
1. `installTitlebarTabBar` (once, async post-init) — `TabGroupObserver.swift:125-128`
2. the group's `windows` KVO — `:202` — token bound to the group instance at subscribe time
3. the group's `isTabBarVisible` KVO — `:235-239` — fires only on `false→true` *changes* (probe B: it just stays `true`)
4. `windowDidBecomeKey` — `MainWindowController.swift:534`

`refreshTabBar()` itself — the thing that reliably runs on every transition
(including the identity-change resubscribe path) — **never re-hides**. After
a merge/move where all KVO tokens are dead, hiding depends solely on the
destination window becoming key at the right moment relative to AppKit
(re)installing the tab bar in that window's theme frame (probe B shows the
bar is re-hosted into the newly-selected window per selection change). In
the common path this works (tab switch → new window becomes key → hide);
the gap is real for e.g. "Merge All Windows" while the destination is
already key, where nothing forces a hide until the next key transition.

Cheap hardening regardless of the Bug-1 fix: call `hideNativeTabStrip()`
inside `refreshTabBar()` (idempotent, walk is cheap), so every transition
that repaints pills also re-asserts suppression. Note this hardening is
**insufficient by itself on Tahoe** (hidden ≠ non-interactive — Bug 1).

---

## Bug 6 — no legitimate way to move a tab between windows (UX root cause)

The pill strip supports: click-select, drag-reorder (within its own strip),
modifier-drag = move the whole window (`TitlebarTabBar.swift:152-158,
1491-1504` — `performDrag` moves the *window/group*, it cannot extract a
tab). Cross-window tab movement exists only through:

- AppKit's auto-injected Window-menu items ("Move Tab to New Window",
  "Merge All Windows", "Show All Tabs") — none built/validated by us
  (`AppDelegate+Menu.swift:299-383` constructs the menu;
  `NSApplication.windowsMenu` assignment invites the auto-items), and
- the invisible native tab bar (Bug 3's accidental drags).

So the *intended* gesture (drag a pill to another window / out to the
desktop) does nothing, while the *unintended* gesture (drag slightly below
the pills) tears tabs off invisibly. Recommend treating "explicit drag a
pill out / into another window's strip" as a feature requirement of the fix
batch — or at minimum decide consciously to keep the menu-only affordance
and kill the invisible one. ("Show All Tabs"'s overview interaction with a
hidden strip is untested — flag for a quick manual pass after the fix.)

---

## Related pre-existing context

- KNOWN_ISSUES "Tab-merge titlebar flash on ⌘T" (won't-fix 2026-04-24):
  documents the 36 pt band's existence and why collapsing it was abandoned;
  the two options listed there (ghost tab / custom tabs) are the same
  structural options that Bug 1 revives.
- GitHub issue #12 "Can't move window" (0.2.11, macOS Tahoe.5, open):
  external user can't drag the window by trackpad. Multi-tab windows since
  v0.3.3 have no bare titlebar (pills fill it; documented trade-off:
  modifier-drag on a pill). Issue predates that but is Tahoe — worth
  re-testing after this batch: if the user's drag attempts landed in the
  band, they were being eaten by the hidden tab bar (Bug 2/3), which would
  make issue #12 another face of the same root cause.

## Non-tab findings noted along the way

- `contentMinSize` titlebar constant is 28 pt but Tahoe's real titlebar is
  32 pt (`MainWindowController.swift:305-311`, `TerminalView.swift:612-615`) —
  4-row minimum window is 4 pt short. Cosmetic.

### Adjacent window-management sweep (agent pass, read-only)

Verdict: the layer is heavily hardened (F-S6 fixes, June refactor); no
severe standalone bug. Edge-case findings, ranked:

- **A1 (PLAUSIBLE, med) — shell-start-failure recovery sheet can present
  against a not-yet-visible window.** `MainWindowController.init` runs
  `startSession` (`MainWindowController.swift:150`); on spawn failure
  `SessionLifecycle.presentShellStartFailureAlert` calls
  `alert.beginSheetModal(for: window)` (`SessionLifecycle.swift:108`) —
  but the window is only ordered in after init returns (`App.swift:326`,
  `:471`, `:522`). If AppKit doesn't defer the sheet, the Retry/Close
  affordance never appears and the user is stranded with a diagnostic
  title and ⌘W. Repro: `SHELL=/nonexistent open Blackbird.app`. Needs a
  runtime check before fixing (modern AppKit sometimes queues the sheet).
- **A2 (PLAUSIBLE, low-med, tab-adjacent) — "Hide Tab Bar" (⇧⌘T /
  auto-injected menu item) desyncs band and pills.**
  `MainWindowController.toggleTabBar` (`MainWindowController.swift:668`)
  forwards to `window.toggleTabBar` on ≥2 tabs → AppKit collapses the 36 pt
  band, but the pill accessory is only hidden on the ≤1-tab transition, and
  the `isTabBarVisible` KVO (`TabGroupObserver.swift:235`) only re-hides on
  `→ true`. Likely leaves pills in a shrunk titlebar / overlapping traffic
  lights. Overlaps the KNOWN_ISSUES toggleTabBar notes — decide whether to
  guard the action off entirely for multi-tab windows too.
  (Post-Bug-1 note: with the band's hit-test hijack confirmed, an
  *intentional* band collapse via `toggleTabBar` is also a candidate FIX
  ingredient — worth a probe experiment: does `isTabBarVisible=false`
  remove both the band's height AND its hit-testing while `selectedWindow`
  switching still works? KNOWN_ISSUES documents past beachballs when
  toggling inside the ⌘T merge transaction; toggling OUTSIDE that
  transaction was not what failed.)
- **A3 (PLAUSIBLE, low) — fullscreen-enter can persist a screen-sized
  windowed frame.** `WindowFramePersistence.saveCurrentFrame` gates on the
  final `.fullScreen` styleMask (`WindowFramePersistence.swift:65`); a
  `windowDidResize` during the enter animation before the flag lands saves
  a near-screen-sized frame → next launch opens screen-sized, traffic
  lights under the menu bar. Needs a `windowWillEnterFullScreen` guard.
- **A4 (PLAUSIBLE, low) — 2.0 s screen-reconfig settle window
  (`WindowFramePersistence.swift:31,64`) can be outrun** by slow
  wake-from-sleep display relocation, clobbering the saved multi-display
  frame (S5-006 heuristic tuning).
- **A5 (CONFIRMED, cosmetic) — ⌘N reapplies the theme twice**: `showWindow`
  (`MainWindowController.swift:320-342`) — `windowDidBecomeKey` fires the
  refresh while `didReapplyThemeAfterOrderIn` is still false, then
  `showWindow` schedules a second. Duplicate work only.

Checked-and-not-a-bug (verified refutations, for the fix batch's reference):
unowned collaborator back-refs (all detached closures capture the
collaborator weakly; controller-deinit invalidates the two risky tokens
inline); windowShouldClose modal vs shell-exit race (mutually exclusive —
alert requires a live foreground child); ⌘⇧W bypass static races (defer
reset + runModal blocks key equivalents); deferred-auto-close re-queue storm
(bounded 20 Hz backoff, isClosing-gated); title-broadcast fan-out (scoped +
torn down); ⌘1-9/⌘⇧W gating (validator and action agree via
ownedKeyWindow + coordinator); off-screen nudge (per-screen reachability +
size clamp, test-pinned).

---

## Pill-strip event-handling findings (agent pass, read-only)

Verdict: the strip's gesture state machine is robust and well test-pinned;
one confirmed defect degrades a primary affordance. File refs are
`Sources/Blackbird/Window/TitlebarTabBar.swift` unless noted.

- **P1 (CONFIRMED, MED) — stale hover state after any relayout: the
  close-× misfires.** `update()` (:296-335) / `layoutPills()` (:379-411)
  recompute `pillFrames` but never recompute `hoveredPill` /
  `hoveredClose` / `hoveredAdd` — those are written only by `mouseMoved`
  (:1145-1174) and consumed by the close-click gate (:832) and the × paint
  (:523, :598). Relayout under a stationary cursor happens constantly
  (live resize refreshes every tick; tab add/close; reorder commit). Repro:
  hover a pill's × , add a tab (⌘T) or nudge-resize without moving the
  mouse, then click where the × is painted → the guard `hoveredPill == i`
  fails against the pill actually under the cursor and the click **switches
  tabs instead of closing** (fails safe — never closes the wrong tab — but
  the affordance visibly misfires; after a reorder the × can paint on a
  different tab's pill until the mouse moves). Fix: recompute hover from
  the last cursor location at the end of `layoutPills()` (or clear it).
  This compounds with Bug 1: both make clicks in/near the strip feel
  unreliable.
- **P2 (CONFIRMED, LOW) — `+` double-click opens two tabs.** `mouseDown`
  (:767-770) fires `onAddTab` with no `clickCount` guard (the pill path
  gates on `clickCount == 1`, :837).
- **P3 (CONFIRMED, LOW) — no cancel path for an in-flight reorder drag**
  (no Escape/`cancelOperation`; `rightMouseDown` :938-941 doesn't cancel).
- **P4 (CONFIRMED, LOW/cosmetic) — window-move hand-off seeds
  `performDrag` with the mouseDragged sample instead of the mouseDown
  event** (:1504, :152-158) — window can jump slightly at move start.
- **P5 (PLAUSIBLE, LOW) — VoiceOver pill frames possibly mirrored ~4 pt**:
  `setAccessibilityFrameInParentSpace` (:1958, :1990) is fed frames in the
  strip's flipped space; needs a VO runtime check.
- **P6 (CONFIRMED, LOW) — `moveLeft` can leave `focusedPill` transiently
  out of range after a shrink** (:1077-1082; guarded consumers, no crash).

Checked-and-not-a-bug (verified refutations): armed-release location
(≤5 pt threshold keeps it on the armed pill; test-pinned); hitTest vs
mouseDown share the same frames; inter-pill/top-band gaps intentionally
pass through; commit-on-outside-click cannot synchronously relayout
mid-mouseDown (title refresh is async-KVO-gated); `insertText` fallthrough
is a single beep; `deleteBackward` snapshots before the synchronous close
(test-pinned); in-flight drags are cancelled on list-shape change
(test-pinned); mid-drag modifier changes can't reclassify the gesture
(pinned by design); double-click can't arm a drag.

---

## Cross-window flow findings (agent pass, read-only)

The agent's original "order scrambles on every merge" hypothesis was
**refuted** by probe B (identity survives `moveTabToNewWindow` /
`mergeAllWindows`; those flows' KVO stays live) and downgraded — see Bug 4.
Its confirmed residual findings:

- **X1 (MED) — merging standalone windows leaves non-key members with a
  hidden strip and NO tab-group KVO until first selected.** Standalone
  windows (⌘N) have `tabGroup == nil`, so `observeTabGroup` bails
  (`TabGroupObserver.swift:163`) and they carry no observers. There is no
  app-level hook for `mergeAllWindows:`/`moveTabToNewWindow:`
  (`refreshAllTabBars` callers are only `orderDidChange` `App.swift:316`,
  `onClose` `:424`, ⌘T `:480`). After Window → Merge All Windows over
  standalone windows (the field log's 4×"new group" nil→group bursts), the
  key member heals via `windowDidBecomeKey → refreshTabBarIfStateChanged`
  (`MainWindowController.swift:524`), but the other members show a stale
  (hidden) strip and have no KVO until each is first selected. Self-heals
  on first selection; visible as "merged windows' tabs look wrong until I
  click them".
  Repro: ⌘N ×3 → Window → Merge All Windows → look at (don't click) the
  non-frontmost tabs' strips.
- **X2 (MED) — first-responder loss (NSBeep / typing goes nowhere) for a
  not-yet-selected merged standalone member.** The `selectedWindow` KVO —
  the unified focus-restore net for tab-internal swaps that DON'T fire
  `windowDidBecomeKey` (`TabGroupObserver.swift:205-231`) — doesn't exist
  on X1's un-subscribed members. A tab-internal swap into such a member
  restores nothing → keystrokes beep until the user clicks the terminal
  body. Same scope and self-heal as X1.
- **X3 (LOW) — ABA identity gap in `TabGroupObserver`.**
  Resubscription gates purely on `ObjectIdentifier` equality
  (`TabGroupObserver.swift:344-371, 415-424`); a recycled group address
  with an unchanged tab count early-returns AND skips the
  `tabGroupObservers.isEmpty` retry (dead tokens keep the array
  non-empty) → permanently dead observers. Rare. `TabOrderCoordinator` is
  immune (reconciles against live `group.windows`).
- **X4 (LOW, unverified) — "Show All Tabs" overview** is a separate AppKit
  UI never touched by the hider (`NativeTabStripHider.hide` walks only the
  window's theme frame) — plausible visual oddities; needs a manual
  eyeball after the Bug-1 fix.

Cheap consolidated fix for X1/X2 (per agent, endorsed): an app-level
key/main-window observer (or an explicit hook on the auto-injected menu
actions) that runs `refreshAllTabBars()`, plus `hideNativeTabStrip()` inside
`refreshTabBar()` (Bug 5). X3: make the `isEmpty` retry also validate token
liveness (or resubscribe unconditionally on every refresh — the KVO install
is cheap).

Checked-and-not-a-bug (verified refutations): order loss on
Move-Tab-to-New-Window / merge-into-existing-group (identity survives —
probe B); `ObjectIdentifier` recycling corrupting the coordinator's stored
order (reconcile filters by live membership; worst case arrival order);
⌘1-9 / ⌘⇧] / ⌘⇧[ against stale groups (both reconcile live and guard nil);
tab close within a group (survivors' KVO valid + `onClose` refresh sweep).

---

## Suggested fix-batch shape (for the follow-up session)

1. **Kill the band's interactivity** (Bugs 1/2/3) — run the probe harness
   over the candidate mechanisms (hide/remove the band's host accessory;
   `frame = .zero` on `NSTabBar` despite L12 — Tahoe voided that
   trade-off's premise; event-forwarding shim; `toggleTabBar`-off
   experiment per A2). Pick whichever kills hit-testing without breaking
   selection, then pin with the synthetic-click regression test.
2. **Re-assert suppression everywhere** (Bug 5 + X1/X2): `hideNativeTabStrip`
   inside `refreshTabBar`; app-level refresh hook covering merges;
   unconditional (or liveness-checked) KVO resubscribe (X3).
3. **Order continuity** (Bug 4): graft/migrate coordinator order across
   group-identity changes and on re-join, instead of append-at-end.
4. **Pill polish** (P1, P2, P4, P6): hover recompute after `layoutPills`;
   `clickCount` guard on `+`; seed `performDrag` with the down event; clamp
   `moveLeft`.
5. **Product decision**: first-class pill drag-out/drag-in (Bug 6) vs
   menu-only cross-window moves; and whether Tahoe's breakage justifies the
   custom-tab-bar rewrite (KNOWN_ISSUES option 2) before more band
   whack-a-mole.
6. **Non-tab follow-ups**: A1 runtime-check the spawn-failure sheet; A3/A4
   frame-persistence guards; A5 double theme apply; 28→32 titlebar constant.
