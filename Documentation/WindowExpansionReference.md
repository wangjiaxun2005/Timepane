# Window expansion reference

This file describes the current main-panel implementation. Historical experiments,
recording transcripts, temporary process IDs, and removed comparison builds are not
part of the maintained workspace.

## Current handoff

- Canonical application: `build/EventQA/Build/Products/Debug/Timepane.app`.
- The rightmost 8 × 8 points of each display are owned by a transparent capture
  panel while Timepane is hidden. Pointer arrival prepares the retained calendar;
  a left click opens it. The physical screen corner remains the aiming target.
- `Scripts/launch-latest.sh` stops every existing Timepane process, verifies that
  none remain, launches the canonical executable once, and confirms its exact path.
- Keep one process only. Two processes can each own a corner capture panel, allowing
  an older in-memory build to win the click even when both paths look identical.

## Opening motion

The native `PanelMorphLayerCoordinator` owns window position, mask, border, glass,
and the 640 ms shell trajectory. The surface stays anchored to the display's top
right corner. SwiftUI does not animate independent width or height progress.

Content begins revealing at 140 ms. Blur peaks at 12 points, becomes optically clear
at 290 ms, and opacity, scale, offset, toolbar, and calendar-grid transforms finish
by 320 ms. Imperceptible non-identity values keep the compositing layer installed
until the exact 640 ms endpoint so filter teardown cannot interrupt shell motion.

The visible rebound belongs to the native shell. Internal content transforms use
the same cubic expansion curve and do not carry their own spring tails into the
rebound interval. Opening shadow refresh runs at 30 Hz through 270 ms; the exact
final shadow is installed at completion. The overscanned native glass coalesces
sub-four-point frame and radius updates while mask and border geometry remain
display-linked.

## Closing motion

Closing lasts 320 ms. A single cubic contraction controls size; height leads gently,
aspect convergence and corner rounding use the shared clock, and screen departure
overlaps the final contraction. The large rectangle remains readable through the
middle of the close and the final circular retreat stays short. Content and surface
fade overlap, and reversal samples the current presentation pose and velocity.

## Invariants

- Do not reintroduce SwiftUI width/height progress for shell geometry.
- Keep one clock for each visible responsibility; avoid stacked springs on the same
  large calendar subtree.
- Prepare retained content before the first visible frame. Never substitute an old
  application copy or comparison build for startup work.
- Preserve exact top-right anchoring, endpoint mask, border, shadow, and hit testing.
- Treat display-link callback diagnostics as scheduling evidence. Visual smoothness
  still requires a normal corner-click replay without capture-induced load.

## Verification

Run `PanelMotionTests`, build with the existing Apple Development identity, verify
the app with `codesign --verify --deep --strict`, then restart through
`Scripts/launch-latest.sh`. Confirm one exact canonical process before visual review.

Current workspace verification (2026-09-22): all 166 tests pass. The build tree
contains only the canonical 43 MB `Timepane.app`; DerivedData, test results, logs,
comparison builds, and capture output have been removed. The app keeps the existing
development identity. Strict local trust evaluation reports `CSSMERR_TP_NOT_TRUSTED`
for that identity on this machine, although Xcode signing, tests, and execution work.
