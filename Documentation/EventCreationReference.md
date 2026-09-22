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
direction once and returns on the same trajectory family. Opening completes at
540 ms.

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
