import AppKit
import QuartzCore
import SwiftUI

struct ZoomEventEndpointTypography: View, Equatable {
  let event: ScheduleEvent
  let timeText: String
  let appearance: CalendarZoomEventAppearance
  let size: CGSize

  @ViewBuilder
  var body: some View {
    switch appearance {
    case .weekTimed:
      HStack(spacing: 0) {
        Color.clear.frame(width: CalendarEventStyle.colorBarWidth)
        CalendarWeekEventText(title: event.title, timeText: timeText,
          location: event.location, height: size.height)
          .equatable()
      }

    case let .weekAllDay(_, _, itemCount, allDayHeight):
      let spacing: CGFloat = itemCount > 5 ? 0.5 : 2
      let available = max(1, allDayHeight - 4 - CGFloat(max(0, itemCount - 1)) * spacing)
      let chipHeight = itemCount == 0 ? size.height : available / CGFloat(itemCount)
      HStack(spacing: 4) {
        Color.clear.frame(width: CalendarEventStyle.colorBarWidth)
        Text(event.title)
          .font(.system(size: max(8, min(10, chipHeight - 5)), weight: .medium))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)

    case .monthTimed:
      HStack(spacing: 0) {
        Color.clear.frame(width: CalendarEventStyle.colorBarWidth)
        Text("\(timeText) \(event.title)")
          .font(.system(size: CalendarEventStyle.compactFontSize(height: size.height), weight: .medium))
          .lineLimit(1)
          .padding(.leading, 3)
        Spacer(minLength: 0)
      }
      .padding(.trailing, 3)

    case .monthSpan:
      HStack(spacing: 0) {
        Color.clear.frame(width: CalendarEventStyle.colorBarWidth)
        Text(event.title)
          .font(.system(size: CalendarEventStyle.compactFontSize(height: size.height), weight: .medium))
          .lineLimit(1)
          .padding(.leading, 3)
        Spacer(minLength: 0)
      }
      .padding(.trailing, 3)

    case .monthDot, .monthAllDayOverflow, .monthOverflow:
      Color.clear
    }
  }
}

struct ZoomEventTypographyClip: Shape {
  enum Role {
    case source
    case target
  }

  var progress: CGFloat
  let role: Role

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let progress = min(1, max(0, progress))
    switch role {
    case .source:
      return Path(CGRect(
        x: rect.minX,
        y: rect.minY,
        width: rect.width * (1 - progress),
        height: rect.height
      ))
    case .target:
      let width = rect.width * progress
      return Path(CGRect(
        x: rect.maxX - width,
        y: rect.minY,
        width: width,
        height: rect.height
      ))
    }
  }
}


/// Shared endpoint typography; only stable content and endpoint height enter
/// this view. Animated geometry and transfer masks remain in the outer card.
struct CalendarWeekEventText: View, Equatable {
  let title: String
  let timeText: String
  let location: String?
  let height: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: height > 43 ? 2 : 0) {
      Text(title)
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(height > 36 ? 2 : 1)
      if height >= 28 {
        Text(timeText)
          .font(.system(size: 8, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if height >= 48, let location {
        Text(location)
          .font(.system(size: 8))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, min(4, max(1, height / 8)))
  }
}

enum CalendarEventStyle {
  static let colorBarWidth: CGFloat = 3
  static let weekCornerRadius: CGFloat = 6
  static let monthCornerRadius: CGFloat = 4
  static let weekFillOpacity = 0.14
  static let weekBorderOpacity = 0.18
  static func compactFontSize(height: CGFloat) -> CGFloat { max(8, min(10, height - 3)) }
}
