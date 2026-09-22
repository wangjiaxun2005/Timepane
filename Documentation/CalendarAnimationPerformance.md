# Calendar animation maintenance

## Ownership

- `CalendarInteractionCoordinator` owns intended destination, preparation,
  generation checks, retargeting, and endpoint handoff.
- `CalendarMotionTrack` samples numeric position and velocity.
- `CalendarInteractionStage` renders the active page or zoom scene from a sparse
  presentation clock.
- `CalendarViewportHost` owns endpoint views, geometry, masks, and render commit.
- Week and month views remain steady endpoint layouts.

All navigation enters through `model.interaction.submit`. Repeated requests accumulate
from the intended date, stale generations cannot commit, and interruption starts from
the visible presentation. Week/month zoom uses a 500 ms clock; period navigation uses
480 ms. Preparation must finish before visible playback consumes its duration.

## Input rules

A physical horizontal swipe can navigate once. Momentum samples never issue another
period request. Phased input resets only on a new began phase; phase-less wheels use
idle grouping. Pinch and toolbar input share the same coordinator so they cannot
publish conflicting destinations.

## Performance rules

- Keep per-frame updates inside animatable leaves. Do not publish every frame through
  `AppModel` or rebuild the calendar hierarchy.
- Prepare layout, sorting, formatting, and geometry before playback.
- Preserve stable endpoint text and flat transient layers.
- Do not add full-calendar snapshots, new blur groups, or nested scene histories.
- A wall-clock completion is not proof that the endpoint was presented.

## Verification

Run the full scheme tests with the existing Apple Development identity. Exercise
week/month changes, fast reversal, repeated arrows, Today, pinch, event selection,
trackpad momentum, panel close/reopen, and Reduced Motion. Use Instruments or a
normal-speed capture before making frame-pacing claims.
