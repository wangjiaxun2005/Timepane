import AppKit
import SwiftUI

struct PanelMotionHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotionModel
    let onCollapse: () -> Void
    let onTogglePin: () -> Void
    let onQuit: () -> Void

    @Namespace private var surfaceNamespace

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if motion.phase.keepsExpandedContentAlive || model.eventCreation.isSuspended {
                ZStack(alignment: .topLeading) {
                  PanelRootView(
                    model: model,
                    motion: motion,
                    surfaceNamespace: surfaceNamespace,
                    onCollapse: onCollapse,
                    onTogglePin: onTogglePin,
                    onQuit: onQuit
                  )
                  EventParentPresentationHost(creation: model.eventCreation, isPinned: model.isPinned,
                    onTogglePin: onTogglePin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .modifier(PanelExpansionContentEffect(
                    time: reduceMotion ? PanelExpansionTrajectory.duration : motion.expansionTime
                ))
                .allowsHitTesting(motion.phase == .expanded)
                .transition(.identity)
            }

            if motion.phase.showsCompactSurface {
                CompactPanelGlyph(namespace: surfaceNamespace)
                    .padding(.top, 2)
                    .padding(.trailing, 2)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(PanelSurfacePose.canvasInset)
    }

}

/// The retained editor joins the calendar's actual content hierarchy during
/// group motion, sharing its blur, opacity, transform and outer shell mask.
private struct EventParentPresentationHost: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var creation: EventCreationModel
    // Keep the retained native glyphs in sync even when editor state is unchanged.
    let isPinned: Bool
    let onTogglePin: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = EventParentPresentationView()
        view.wantsLayer = true
        view.creation = creation
        NativeGlassAppearance.apply(colorScheme, to: view)
        creation.toolbarPinAction = onTogglePin
        creation.parentPresentationView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        NativeGlassAppearance.apply(colorScheme, to: nsView)
        creation.toolbarPinAction = onTogglePin
        creation.presentationLayoutDriver?()
    }
}

private final class EventParentPresentationView: NSView {
    weak var creation: EventCreationModel?
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); creation?.presentationLayoutDriver?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard creation?.isSuspended == false else { return nil }
        if #unavailable(macOS 26.0) {
            guard creation?.isMounted == true else { return nil }
        }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

struct PanelGlassBackground: View {
    let motion: PanelMotionModel

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                NativeGlassMotionSurface(motion: motion)
            } else {
                LegacyGlassMotionSurface()
            }
        }
        .padding(PanelSurfacePose.canvasInset)
    }
}

private struct PanelExpansionContentEffect: AnimatableModifier {
    var time: TimeInterval

    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    func body(content: Content) -> some View {
        let sample = PanelExpansionTrajectory.content(at: time)
        content
            .scaleEffect(sample.scale, anchor: .topTrailing)
            .offset(y: sample.offset)
            .blur(radius: sample.blur)
            .opacity(sample.opacity)
    }
}

private struct CompactPanelGlyph: View {
    let namespace: Namespace.ID

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.72))
            .frame(width: 52, height: 28)
            .matchedGeometryEffect(
                id: PanelMotionIDs.collapseGlyph,
                in: namespace,
                properties: .position,
                anchor: .center
            )
    }
}

@available(macOS 26.0, *)
private struct NativeGlassMotionSurface: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let motion: PanelMotionModel

    func makeNSView(context: Context) -> CroppedPanelGlassView {
        let view = CroppedPanelGlassView()
        NativeGlassAppearance.apply(colorScheme, to: view)
        motion.surfaceRenderer = view
        return view
    }

    func updateNSView(_ nsView: CroppedPanelGlassView, context: Context) {
        NativeGlassAppearance.apply(colorScheme, to: nsView)
    }
}

@available(macOS 26.0, *)
private final class CroppedPanelGlassView: NSView, PanelSurfaceRendering {
    private let glass = NSGlassEffectView()
    private let rimInset: CGFloat = 12
    private let materialGeometryThreshold: CGFloat = 4
    private let border = CAShapeLayer()
    private var pose: PanelSurfacePose?
    private var appliedBounds: CGRect?
    private var appliedBackingScale: CGFloat?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        // The panel's animated mask owns the visible corner geometry.
        glass.style = .regular
        glass.cornerRadius = 22 + rimInset
        addSubview(glass)
        border.fillColor = nil
        layer?.addSublayer(border)
        updateMaterialAppearance()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        applySurface(pose ?? .expanded(size: bounds.size))
    }

    func applySurface(_ pose: PanelSurfacePose) {
        let backingScale = window?.backingScaleFactor ?? 2
        // AppKit layout may revisit the pose already submitted by the display
        // link. Reuse its glass geometry and border path until an input changes.
        guard self.pose != pose || appliedBounds != bounds || appliedBackingScale != backingScale else { return }
        self.pose = pose
        appliedBounds = bounds
        appliedBackingScale = backingScale
        let glassFrame = pose.visibleFrame.insetBy(dx: -rimInset, dy: -rimInset)
        let expandedSize = CGSize(
            width: max(0, bounds.width - 2 * PanelSurfacePose.canvasInset),
            height: max(0, bounds.height - 2 * PanelSurfacePose.canvasInset)
        )
        let isExactExpandedEndpoint = pose == .expanded(size: expandedSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The exact mask and border still move every display tick. The glass is
        // deliberately 12 pt larger, so coalesce tiny late geometry changes
        // instead of asking AppKit to rerasterize the full material every frame.
        // The stable endpoint always receives its exact frame and radius.
        let frameDelta = [
            abs(glass.frame.minX - glassFrame.minX),
            abs(glass.frame.minY - glassFrame.minY),
            abs(glass.frame.width - glassFrame.width),
            abs(glass.frame.height - glassFrame.height)
        ].max() ?? 0
        if isExactExpandedEndpoint || frameDelta >= materialGeometryThreshold {
            glass.frame = glassFrame
        }
        let glassRadius = pose.cornerRadius + rimInset
        if isExactExpandedEndpoint || abs(glass.cornerRadius - glassRadius) >= materialGeometryThreshold {
            glass.cornerRadius = glassRadius
        }
        let width = 1 / max(1, backingScale)
        border.frame = bounds
        border.contentsScale = backingScale
        border.lineWidth = width
        border.path = CGPath(roundedRect: pose.visibleFrame.insetBy(dx: width / 2, dy: width / 2),
          cornerWidth: max(0, pose.cornerRadius - width / 2),
          cornerHeight: max(0, pose.cornerRadius - width / 2), transform: nil)
        // Let AppKit coalesce glass layout in its normal drawing pass.
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterialAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMaterialAppearance()
    }

    private func updateMaterialAppearance() {
        // Calendar foreground lives in a separate animation host, outside the
        // glass's adaptive contentView. Keep material and foreground on the same
        // semantic appearance instead of letting backdrop adaptation darken only
        // the glass while the calendar retains light-mode black text.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glass.tintColor = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        border.strokeColor = (dark ? NSColor.white.withAlphaComponent(0.22)
          : NSColor.black.withAlphaComponent(0.16)).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct LegacyGlassMotionSurface: View {
    var body: some View {
        LegacyGlassBackground(cornerRadius: 22)
    }
}

private struct LegacyGlassBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover)
            Color(nsColor: .windowBackgroundColor).opacity(0.22)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

enum PanelMotionIDs {
    static let collapseGlyph = "panel.collapse.glyph"
}
