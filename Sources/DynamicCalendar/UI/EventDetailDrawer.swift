import SwiftUI

struct EventDetailDrawer: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var presentation: EventDetailPresentationModel

  var body: some View {
    ZStack(alignment: .bottom) {
      if let event = presentation.event,
         let content = presentation.displayContent {
        EventDetailCard(event: event, content: content)
          .id(event.id)
          .transition(
            EventDetailMotionTiming.cardSwitchTransition(
              direction: presentation.switchDirection,
              reduceMotion: reduceMotion
            )
          )
      }
    }
    .frame(maxWidth: .infinity, minHeight: 202, maxHeight: 202, alignment: .bottom)
    .modifier(EventDetailImpactMotionModifier(impulse: presentation.drawerImpact))
  }
}

private struct EventDetailCard: View {
  @Environment(\.eventDetailCornerRadius) private var cornerRadius
  let event: ScheduleEvent
  let content: EventDetailDisplayContent

  var body: some View {
    AdaptiveGlassEffectContainer(spacing: 12) {
      VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color(hex: event.colorHex))
          .frame(width: 4, height: 34)

        VStack(alignment: .leading, spacing: 4) {
          Text(event.title)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(2)
          Text(event.calendarTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(hex: event.colorHex))
        }

        Spacer()
      }

      HStack(spacing: 20) {
        DetailLabel(icon: "clock", text: content.formattedTime)
        if let location = event.location {
          DetailLabel(icon: "mappin.and.ellipse", text: location)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        if let attributedNotes = content.attributedNotes {
          Text(attributedNotes)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let url = event.url {
          AdaptiveGlassLink(destination: url) {
            Label("打开会议链接", systemImage: "video")
              .font(.system(size: 12, weight: .medium))
          }
        }
      }
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, minHeight: 182, maxHeight: 182, alignment: .topLeading)
    .panelSurface(cornerRadius: cornerRadius)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .shadow(color: .black.opacity(0.18), radius: 24, y: -4)
    .padding(10)
  }

}

struct EventDetailDisplayContent {
  let formattedTime: String
  let attributedNotes: AttributedString?

  init(event: ScheduleEvent) {
    if event.isAllDay {
      formattedTime = "全天"
    } else {
      let start = DateFormatting.dayAndTime.string(from: event.startDate)
      let end: String
      if Calendar.autoupdatingCurrent.isDate(event.startDate, inSameDayAs: event.endDate) {
        end = DateFormatting.time.string(from: event.endDate)
      } else {
        end = DateFormatting.dayAndTime.string(from: event.endDate)
      }
      formattedTime = "\(start) – \(end)"
    }
    attributedNotes = event.notes.map(EventDescriptionLinkifier.attributedString(for:))
  }
}

enum EventDescriptionLinkifier {
  private static let detector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )

  static func attributedString(for text: String) -> AttributedString {
    let result = NSMutableAttributedString(string: text)
    guard let detector else {
      return AttributedString(result)
    }

    let fullRange = NSRange(location: 0, length: (text as NSString).length)
    for match in detector.matches(in: text, range: fullRange) {
      guard
        let url = match.url,
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else { continue }

      result.addAttributes(
        [
          .link: url,
          .foregroundColor: NSColor.systemBlue,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ],
        range: match.range
      )
    }

    return AttributedString(result)
  }
}

private struct DetailLabel: View {
  let icon: String
  let text: String

  var body: some View {
    Label {
      Text(text).lineLimit(1)
    } icon: {
      Image(systemName: icon)
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
  }
}

enum DateFormatting {
  static let time: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeStyle = .short
    return formatter
  }()

  static let shortDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh-Hans")
    formatter.dateFormat = "M月d日"
    return formatter
  }()

  static let monthAndYear: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh-Hans")
    formatter.setLocalizedDateFormatFromTemplate("yyyyMMMM")
    return formatter
  }()

  static let dayAndTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("M月d日 HH:mm")
    return formatter
  }()

  static let weekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh-Hans")
    formatter.dateFormat = "EEE"
    return formatter
  }()
}
