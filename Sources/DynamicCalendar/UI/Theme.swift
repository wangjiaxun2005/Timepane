import AppKit
import SwiftUI

extension Color {
  init(hex: String) {
    if let cached = ColorHexCache.colors.object(forKey: hex as NSString) {
      self.init(nsColor: cached)
      return
    }

    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    var integer: UInt64 = 0
    Scanner(string: value).scanHexInt64(&integer)

    let red: Double
    let green: Double
    let blue: Double
    switch value.count {
    case 3:
      red = Double((integer >> 8) * 17) / 255
      green = Double(((integer >> 4) & 0xF) * 17) / 255
      blue = Double((integer & 0xF) * 17) / 255
    default:
      red = Double(integer >> 16 & 0xFF) / 255
      green = Double(integer >> 8 & 0xFF) / 255
      blue = Double(integer & 0xFF) / 255
    }
    let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    ColorHexCache.colors.setObject(color, forKey: hex as NSString)
    self.init(nsColor: color)
  }
}

private enum ColorHexCache {
  static let colors: NSCache<NSString, NSColor> = {
    let cache = NSCache<NSString, NSColor>()
    cache.countLimit = 64
    return cache
  }()
}

struct VisualEffectView: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .popover
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    if nsView.material != material { nsView.material = material }
    if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
    if nsView.state != .active { nsView.state = .active }
  }
}

struct IconButtonStyle: ButtonStyle {
  var isActive = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .frame(width: 28, height: 28)
      .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.74))
      .background(
        Circle()
          .fill(
            configuration.isPressed
              ? Color.primary.opacity(0.12) : Color.primary.opacity(isActive ? 0.09 : 0.035))
      )
      .contentShape(Circle())
  }
}

/// Inset controls share their surrounding capsule instead of adding separate glass rims.
struct SharedGlassToolbarButtonStyle: ButtonStyle {
  var isSelected = false
  var isActive = false
  var minimumWidth: CGFloat = 28

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(
        isSelected ? Color.white : (isActive ? Color.accentColor : Color.primary.opacity(0.78))
      )
      .frame(minWidth: minimumWidth, minHeight: 26)
      .background {
        Capsule()
          .fill(
            isSelected
              ? Color.accentColor
              : Color.primary.opacity(configuration.isPressed ? 0.12 : (isActive ? 0.065 : 0))
          )
      }
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

/// One native Liquid Glass family for toolbar controls and connected editor.
/// Let the system adapt neutral glass; do not load every merging lobe with black pigment.
enum NativeGlassAppearance {
  /// SwiftUI owns the window's semantic scheme. Bridge it once at each native
  /// root so glass, hosted controls and cached glyphs inherit the same value.
  static func apply(_ scheme: ColorScheme, to view: NSView) {
    let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
    if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
  }
}

@available(macOS 26.0, *)
final class ToolbarGlassEffectView: NSGlassEffectView {
  var prominent = false {
    didSet { if prominent != oldValue { updateTint() } }
  }
  // Animate pigment on one surface. Crossfading two live backdrop samplers at
  // the same bounds can darken their overlap during native glass fusion.
  var accentAmount: CGFloat = 0 {
    didSet { if accentAmount != oldValue { updateTint() } }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    style = .regular
    cornerRadius = 16
    updateTint()
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateTint()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateTint()
  }

  private func updateTint() {
    let amount = prominent ? 1 : min(1, max(0, accentAmount))
    effectiveAppearance.performAsCurrentDrawingAppearance {
      tintColor = amount <= 0 ? nil : NSColor.controlAccentColor.withAlphaComponent(0.72 * amount)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26.0, *)
struct ToolbarGlassBackground: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  var prominent = false
  func makeNSView(context: Context) -> ToolbarGlassBackdropView {
    let view = ToolbarGlassBackdropView(frame: .zero)
    NativeGlassAppearance.apply(colorScheme, to: view)
    view.glass.prominent = prominent
    return view
  }
  func updateNSView(_ view: ToolbarGlassBackdropView, context: Context) {
    NativeGlassAppearance.apply(colorScheme, to: view)
    view.glass.prominent = prominent
  }
}

/// Keep standalone navigation and mode controls in the same native composition
/// hierarchy as the action capsule. A matching tint alone is not sufficient.
@available(macOS 26.0, *)
final class ToolbarGlassBackdropView: NSView {
  let glass = ToolbarGlassEffectView(frame: .zero)
  private let container = NSGlassEffectContainerView()
  private let content = NSView()
  override init(frame: NSRect) {
    super.init(frame: frame)
    clipsToBounds = false
    container.spacing = 0
    container.contentView = content
    container.clipsToBounds = false
    content.clipsToBounds = false
    content.addSubview(glass)
    addSubview(container)
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    container.frame = bounds
    content.frame = container.bounds
    glass.frame = content.bounds
    glass.cornerRadius = bounds.height / 2
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct AdaptiveGlassControlGroup<Content: View>: View {
  let clearGlass: Bool
  @ViewBuilder let content: () -> Content

  init(clearGlass: Bool = false, @ViewBuilder content: @escaping () -> Content) {
    self.clearGlass = clearGlass
    self.content = content
  }

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      if clearGlass {
        content().padding(3).background(ToolbarGlassBackground())
      } else {
        content().padding(3).glassEffect(.regular, in: Capsule())
      }
    } else {
      content()
        .padding(3)
        .background(Color.black.opacity(0.10), in: Capsule())
        .overlay {
          Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        }
    }
  }
}

struct CalendarModeSelectionLens: View {
  var body: some View {
    Capsule()
      .fill(Color.accentColor)
  }
}

enum AdaptiveGlassButtonFallback {
  case icon(isActive: Bool = false)
  case bordered
  case plain
}

struct AdaptiveGlassButton<Label: View>: View {
  let action: () -> Void
  let isProminent: Bool
  let fallback: AdaptiveGlassButtonFallback
  var controlSize: ControlSize = .small
  @ViewBuilder let label: () -> Label

  init(
    isProminent: Bool = false,
    fallback: AdaptiveGlassButtonFallback = .bordered,
    controlSize: ControlSize = .small,
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.action = action
    self.isProminent = isProminent
    self.fallback = fallback
    self.controlSize = controlSize
    self.label = label
  }

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      if isProminent {
        button
          .buttonStyle(.glassProminent)
          .buttonBorderShape(borderShape)
          .controlSize(controlSize)
      } else {
        button
          .buttonStyle(.glass)
          .buttonBorderShape(borderShape)
          .controlSize(controlSize)
      }
    } else {
      switch fallback {
      case .icon(let isActive):
        button.buttonStyle(IconButtonStyle(isActive: isActive))
      case .bordered:
        button
          .buttonStyle(.bordered)
          .controlSize(controlSize)
      case .plain:
        button.buttonStyle(.plain)
      }
    }
  }

  private var button: some View {
    Button(action: action, label: label)
  }

  private var borderShape: ButtonBorderShape {
    if case .icon = fallback { return .circle }
    return .capsule
  }
}

struct AdaptiveGlassLink<Label: View>: View {
  let destination: URL
  @ViewBuilder let label: () -> Label

  init(destination: URL, @ViewBuilder label: @escaping () -> Label) {
    self.destination = destination
    self.label = label
  }

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      Link(destination: destination, label: label)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    } else {
      Link(destination: destination, label: label)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
  }
}

struct AdaptiveGlassEffectContainer<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: () -> Content

  init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) {
    self.spacing = spacing
    self.content = content
  }

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing, content: content)
    } else {
      content()
    }
  }
}

struct PanelSurface: ViewModifier {
  var cornerRadius: CGFloat = 22

  func body(content: Content) -> some View {
    content.background { BorderlessGlassBackground(cornerRadius: cornerRadius) }
  }
}

struct BorderlessGlassBackground: View {
  var cornerRadius: CGFloat = 22
  var rimInset: CGFloat = 2

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      Color.clear
        .glassEffect(
          .regular,
          in: RoundedRectangle(
            cornerRadius: cornerRadius + rimInset,
            style: .continuous
          )
        )
        // Keep the native refractive material while clipping its perimeter rim.
        .padding(-rimInset)
        .clipShape(
          RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
          )
        )
    } else {
      ZStack {
        VisualEffectView(material: .popover)
        Color(nsColor: .windowBackgroundColor).opacity(0.22)
      }
        .clipShape(
          RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
          )
        )
    }
  }
}

extension View {
  func panelSurface(cornerRadius: CGFloat = 22) -> some View {
    modifier(PanelSurface(cornerRadius: cornerRadius))
  }
}
