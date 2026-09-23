# Event creation reference

This file records the current event-editor architecture and motion contract.

## Ownership

`EventCreationModel` owns the draft, validation, calendar selection, recurrence,
alerts, and presentation state. EventKit writes stay on the existing provider queue.
The editor is retained in the calendar hierarchy so panel expansion and collapse do
not create, destroy, or reparent a second input window during motion.

Save is explicit. Existing events are never edited or deleted by this flow. Cancelling
a changed draft asks before discarding it. Demo mode keeps saves in memory.

## Toolbar fission

The Add/Pin/Settings group is one native glass scene. Opening swells the joined
container, separates cancel and save leaves, and releases the editor without an
empty handoff frame. The opening recoil travels right to left: save, cancel, then
the adjacent Week/Month picker peak at 310, 350, and 390 ms. Each component changes
direction once and returns on the same trajectory family. The editor still reaches
its 12 pt downward peak at 350 ms, then uses one soft return through 580 ms: after
a brief turn, its speed continuously decreases and its final speed and acceleration
reach zero. Button timing stays unchanged. Opening completes at 580 ms.

Closing keeps the 230 ms inflation peak and resolves at 380 ms. The slower recovery
applies after the peak; the lead-in, editor contraction, blur, and opening recoil
remain independent. Interruption samples the visible pose and velocity rather than
restarting from an endpoint.

## Material and layout

The action group and editor use native `NSGlassEffectView` material on supported
macOS versions. One permanent parent-host scene owns glass and cached glyphs at rest
and during fission. Save receives blue tint only after physical separation. Glyphs,
hit targets, and glass surfaces share the same pose; no duplicate blurred glyph or
shadow layer is permitted.

The parent calendar retains input ownership. Pin state is reflected in the native
toolbar and determines panel level and automatic dismissal. Window expansion may
prepare the idle toolbar before the first visible frame, but must not save a draft.

## Verification

Run `EventCreationTests` and the toolbar motion tests, then exercise Add, Cancel,
Save validation, pinning, interrupted open/close, and parent panel collapse. Visual
checks must use a real interaction; held frames alone do not establish pacing.

## Current handoff (2026-09-23)

The editor-return curve and its motion-invariant test were updated. The targeted
`EventDraftTests` suite passed (24 tests), and the canonical debug app was built
with the existing signing team. After the user authorized replacement, the
canonical app was restarted and exactly one expected process was verified. The
user saw the new effect and accepted it. A window-only capture was saved locally,
but its intended interaction and frames were not independently reviewed because
the user asked to stop the inspection. The temporary pin was restored to its
original off state. No further visual work is requested for this change.
