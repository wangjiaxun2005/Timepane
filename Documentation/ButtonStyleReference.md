# Button material reference

Timepane uses native Liquid Glass on supported macOS versions and a restrained
fallback on earlier systems. Root-native appearance follows SwiftUI's color scheme.

## Rules

- Navigation, Week/Month, Add/Pin/Settings, cancel, and save use one material family.
- Joined controls keep six-point fusion spacing and continuous geometry.
- The editor toolbar is one permanent native scene; do not swap clear, dark, and
  regular hosts during an animation.
- Save becomes blue after it separates. Neutral controls remain untinted.
- Glyph color, hit target, and surface pose move together.
- Do not add duplicate optical borders, proxy glyphs, blurred copies, or extra
  shadows to hide a handoff.
- Pin selection must update immediately in both the model and native glyph.

Resting controls should be readable in light and dark appearance without black
material flashes. Motion may soften content briefly, but settled text and symbols
must use their original colors and exact endpoint positions.
