import AppKit
import QuartzCore
import SwiftUI

struct WeekGridView: View, Equatable {
  let layout: WeekLayout
  let calendar: Calendar
  let onSelectEvent: (ScheduleEvent) -> Void
  let onDismissDetail: () -> Void
  var renderRevision: UInt64 = 0
  var hidesHeaderDates = false
  var hidesEvents = false
  var eventsOnly = false
  var zoomEndpoint: CalendarZoomEndpoint? = nil

  private let timeAxisWidth: CGFloat = 48

  static func == (lhs: WeekGridView, rhs: WeekGridView) -> Bool {
    layoutsMatch(lhs, rhs)
      && lhs.calendar == rhs.calendar
      && lhs.hidesHeaderDates == rhs.hidesHeaderDates
      && lhs.hidesEvents == rhs.hidesEvents
      && lhs.eventsOnly == rhs.eventsOnly
      && lhs.zoomEndpoint == rhs.zoomEndpoint
  }

  private static func layoutsMatch(_ lhs: WeekGridView, _ rhs: WeekGridView) -> Bool {
    if lhs.renderRevision != 0 || rhs.renderRevision != 0 {
      return lhs.renderRevision == rhs.renderRevision
    }
    return lhs.layout == rhs.layout
  }

  var body: some View {
    GeometryReader { proxy in
      let allDayHeight = allDayBandHeight
      VStack(spacing: 0) {
        if eventsOnly {
          Color.clear.frame(height: 43)
        } else {
          DayHeaderRow(
            layout: layout,
            calendar: calendar,
            hidesDates: hidesHeaderDates,
            timeAxisWidth: timeAxisWidth,
            zoomEndpoint: zoomEndpoint
          )
            .frame(height: 43)
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismissDetail)
        }

        Divider().opacity(eventsOnly ? 0 : 0.52)

        AllDayBand(
          layout: layout,
          timeAxisWidth: timeAxisWidth,
          onSelectEvent: onSelectEvent,
          onDismissDetail: onDismissDetail,
          showsChrome: !eventsOnly,
          showsEvents: !hidesEvents,
          allDayHeight: allDayHeight,
          zoomEndpoint: zoomEndpoint
        )
        .frame(height: allDayHeight)

        Divider().opacity(eventsOnly ? 0 : 0.52)

        TimedWeekGrid(
          layout: layout,
          calendar: calendar,
          timeAxisWidth: timeAxisWidth,
          onSelectEvent: onSelectEvent,
          onDismissDetail: onDismissDetail,
          showsChrome: !eventsOnly,
          showsEvents: !hidesEvents,
          allDayHeight: allDayHeight,
          zoomEndpoint: zoomEndpoint
        )
        .frame(height: max(80, proxy.size.height - 43 - allDayHeight - 2))
      }
    }
  }

  private var allDayBandHeight: CGFloat {
    let count = layout.maximumAllDayEventCount
    guard count > 0 else { return 24 }
    return min(88, max(28, CGFloat(count) * 19 + 6))
  }
}

struct DayHeaderRow: View {
  let layout: WeekLayout
  let calendar: Calendar
  let hidesDates: Bool
  let timeAxisWidth: CGFloat
  let zoomEndpoint: CalendarZoomEndpoint?

  var body: some View {
    HStack(spacing: 0) {
      Color.clear.frame(width: timeAxisWidth)
      ForEach(layout.days) { day in
        let isToday = calendar.isDateInToday(day.date)
        VStack(spacing: 2) {
          Text(DateFormatting.weekday.string(from: day.date))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
          Text("\(calendar.component(.day, from: day.date))")
            .font(.system(size: 14, weight: isToday ? .semibold : .medium))
            .foregroundStyle(isToday ? Color.white : Color.primary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
            .opacity(hidesDates ? 0 : 1)
            .calendarZoomGeometry(.date(day.date), endpoint: zoomEndpoint)
        }
        .frame(maxWidth: .infinity)
      }
    }
  }
}

struct AllDayBand: View {
  @Environment(\.calendarEventOffset) private var eventOffset
  let layout: WeekLayout
  let timeAxisWidth: CGFloat
  let onSelectEvent: (ScheduleEvent) -> Void
  let onDismissDetail: () -> Void
  var showsChrome = true
  var showsEvents = true
  let allDayHeight: CGFloat
  let zoomEndpoint: CalendarZoomEndpoint?

  var body: some View {
    GeometryReader { proxy in
      let contentWidth = max(1, proxy.size.width - timeAxisWidth)
      let dayWidth = contentWidth / 7

      ZStack(alignment: .topLeading) {
        if showsChrome {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismissDetail)

          Text("全天")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .frame(width: timeAxisWidth - 7, alignment: .trailing)
            .padding(.top, 7)
            .allowsHitTesting(false)

          ForEach(1..<7, id: \.self) { index in
            Rectangle()
              .fill(Color.primary.opacity(0.055))
              .frame(width: 0.5, height: proxy.size.height)
              .offset(x: timeAxisWidth + dayWidth * CGFloat(index))
              .allowsHitTesting(false)
          }
        }

        if showsEvents {
          ForEach(layout.days.indices, id: \.self) { dayIndex in
            let day = layout.days[dayIndex]
            AllDayColumn(
              events: day.allDayEvents,
              dayIndex: dayIndex,
              allDayHeight: allDayHeight,
              zoomEndpoint: zoomEndpoint,
              onSelectEvent: onSelectEvent
            )
              .frame(width: max(1, dayWidth - 6), height: proxy.size.height - 4)
              .offset(x: timeAxisWidth + dayWidth * CGFloat(dayIndex) + 3, y: 2)
              .modifier(CalendarEventOffsetModifier(motion: eventOffset))
          }
        }
      }
    }
  }
}

struct AllDayColumn: View {
  let events: [ScheduleEvent]
  let dayIndex: Int
  let allDayHeight: CGFloat
  let zoomEndpoint: CalendarZoomEndpoint?
  let onSelectEvent: (ScheduleEvent) -> Void

  var body: some View {
    GeometryReader { proxy in
      let spacing = events.count > 5 ? CGFloat(0.5) : CGFloat(2)
      let available = max(1, proxy.size.height - CGFloat(max(0, events.count - 1)) * spacing)
      let chipHeight = events.isEmpty ? 0 : available / CGFloat(events.count)

      VStack(spacing: spacing) {
        ForEach(Array(events.enumerated()), id: \.element.id) { itemIndex, event in
          Button {
            onSelectEvent(event)
          } label: {
            HStack(spacing: 0) {
              Rectangle()
                .fill(Color(hex: event.colorHex))
                .frame(width: CalendarEventStyle.colorBarWidth)

              HStack(spacing: 0) {
                Text(event.title)
                  .font(.system(size: max(8, min(10, chipHeight - 5)), weight: .medium))
                  .lineLimit(1)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: event.colorHex).opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: CalendarEventStyle.monthCornerRadius, style: .continuous))
          }
          .buttonStyle(.plain)
          .frame(height: chipHeight)
          .calendarZoomGeometry(
            .event(
              event.id,
              .weekAllDay(
                dayIndex: dayIndex,
                itemIndex: itemIndex,
                itemCount: events.count,
                allDayHeight: allDayHeight
              )
            ),
            endpoint: zoomEndpoint
          )
        }
      }
    }
  }
}

struct TimedWeekGrid: View {
  @Environment(\.calendarEventOffset) private var eventOffset
  let layout: WeekLayout
  let calendar: Calendar
  let timeAxisWidth: CGFloat
  let onSelectEvent: (ScheduleEvent) -> Void
  let onDismissDetail: () -> Void
  var showsChrome = true
  var showsEvents = true
  let allDayHeight: CGFloat
  let zoomEndpoint: CalendarZoomEndpoint?

  var body: some View {
    GeometryReader { proxy in
      let contentWidth = max(1, proxy.size.width - timeAxisWidth)
      let dayWidth = contentWidth / 7
      let minuteSpan = max(1, layout.visibleEndMinute - layout.visibleStartMinute)

      ZStack(alignment: .topLeading) {
        if showsChrome {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismissDetail)

          gridLines(size: proxy.size, dayWidth: dayWidth, minuteSpan: minuteSpan)
            .allowsHitTesting(false)
        }

        if showsEvents {
          ForEach(layout.days) { day in
            ForEach(day.timedEvents) { item in
              timedEvent(item, size: proxy.size, dayWidth: dayWidth, minuteSpan: minuteSpan)
                .modifier(CalendarEventOffsetModifier(motion: eventOffset))
            }
          }
        }

        if showsChrome {
          CurrentTimeIndicator(
            layout: layout,
            calendar: calendar,
            timeAxisWidth: timeAxisWidth,
            dayWidth: dayWidth,
            size: proxy.size
          )
          .zIndex(100)
        }
      }
      .clipped()
    }
  }

  @ViewBuilder
  private func gridLines(size: CGSize, dayWidth: CGFloat, minuteSpan: Int) -> some View {
    ForEach(startHour...endHour, id: \.self) { hour in
      let minute = hour * 60
      let y = yPosition(for: minute, height: size.height, minuteSpan: minuteSpan)
      Text(String(format: "%02d", minute / 60))
        .font(.system(size: 9, design: .rounded))
        .foregroundStyle(.tertiary)
        .frame(width: timeAxisWidth - 7, alignment: .trailing)
        .position(x: (timeAxisWidth - 7) / 2, y: max(6, y + 6))

      Rectangle()
        .fill(Color.primary.opacity(minute % 120 == 0 ? 0.085 : 0.045))
        .frame(width: size.width - timeAxisWidth, height: 0.5)
        .position(x: timeAxisWidth + (size.width - timeAxisWidth) / 2, y: y)
    }

    ForEach(0...7, id: \.self) { index in
      Rectangle()
        .fill(Color.primary.opacity(index == 0 ? 0.075 : 0.052))
        .frame(width: 0.5, height: size.height)
        .position(x: timeAxisWidth + dayWidth * CGFloat(index), y: size.height / 2)
    }
  }

  @ViewBuilder
  private func timedEvent(
    _ item: TimedEventLayout, size: CGSize, dayWidth: CGFloat, minuteSpan: Int
  ) -> some View {
    let rawTop = yPosition(for: item.startMinute, height: size.height, minuteSpan: minuteSpan)
    let rawBottom = yPosition(for: item.endMinute, height: size.height, minuteSpan: minuteSpan)
    let height = min(size.height, max(16, rawBottom - rawTop))
    let top = min(max(0, rawTop), max(0, size.height - height))
    let laneWidth = max(5, (dayWidth - 5) / CGFloat(max(1, item.laneCount)))
    let width = max(4, laneWidth - 2)
    let x =
      timeAxisWidth
      + dayWidth * CGFloat(item.dayIndex)
      + 3
      + laneWidth * CGFloat(item.lane)

    Button {
      onSelectEvent(item.event)
    } label: {
      TimedEventCard(event: item.event, height: height)
    }
    .buttonStyle(.plain)
    .frame(width: width, height: height)
    .calendarZoomGeometry(
      .event(
        item.event.id,
        .weekTimed(
          dayIndex: item.dayIndex,
          startMinute: item.startMinute,
          endMinute: item.endMinute,
          lane: item.lane,
          laneCount: item.laneCount,
          visibleStartMinute: layout.visibleStartMinute,
          visibleEndMinute: layout.visibleEndMinute,
          allDayHeight: allDayHeight
        )
      ),
      endpoint: zoomEndpoint
    )
    .position(x: x + width / 2, y: top + height / 2)
    .help(item.event.title)
  }

  private var startHour: Int { layout.visibleStartMinute / 60 }
  private var endHour: Int { layout.visibleEndMinute / 60 }

  private func yPosition(for minute: Int, height: CGFloat, minuteSpan: Int) -> CGFloat {
    let clamped = min(layout.visibleEndMinute, max(layout.visibleStartMinute, minute))
    return CGFloat(clamped - layout.visibleStartMinute) / CGFloat(minuteSpan) * height
  }
}

struct CurrentTimeIndicatorPlacement: Equatable {
  let dayIndex: Int
  let verticalFraction: CGFloat
}

enum CurrentTimeIndicatorGeometry {
  static func placement(
    at date: Date,
    layout: WeekLayout,
    calendar: Calendar
  ) -> CurrentTimeIndicatorPlacement? {
    guard let dayIndex = layout.days.firstIndex(where: {
      calendar.isDate($0.date, inSameDayAs: date)
    }) else {
      return nil
    }

    let components = calendar.dateComponents([.hour, .minute, .second], from: date)
    let minute =
      CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
      + CGFloat(components.second ?? 0) / 60
    let start = CGFloat(layout.visibleStartMinute)
    let end = CGFloat(layout.visibleEndMinute)
    guard minute >= start, minute < end, end > start else { return nil }

    return CurrentTimeIndicatorPlacement(
      dayIndex: dayIndex,
      verticalFraction: (minute - start) / (end - start)
    )
  }
}

struct CurrentTimeIndicator: View {
  let layout: WeekLayout
  let calendar: Calendar
  let timeAxisWidth: CGFloat
  let dayWidth: CGFloat
  let size: CGSize

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      if let placement = CurrentTimeIndicatorGeometry.placement(
        at: context.date,
        layout: layout,
        calendar: calendar
      ) {
        let rawY = placement.verticalFraction * size.height
        let y = min(max(3, rawY), max(3, size.height - 3))
        let leadingX =
          timeAxisWidth
          + dayWidth * CGFloat(placement.dayIndex)
        let indicatorColor = Color(red: 0.34, green: 0.70, blue: 1.0)
        let lineWidth = max(4, dayWidth - 6)

        ZStack(alignment: .topLeading) {
          Capsule()
            .fill(indicatorColor)
            .frame(width: lineWidth, height: 1.5)
            .position(x: leadingX + 3 + lineWidth / 2, y: y)

          Circle()
            .fill(indicatorColor)
            .frame(width: 5, height: 5)
            .position(x: leadingX + 3, y: y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct TimedEventCard: View {
  let event: ScheduleEvent
  let height: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(Color(hex: event.colorHex))
        .frame(width: CalendarEventStyle.colorBarWidth)

      CalendarWeekEventText(title: event.title,
        timeText: DateFormatting.time.string(from: event.startDate),
        location: event.location, height: height)
        .equatable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(hex: event.colorHex).opacity(CalendarEventStyle.weekFillOpacity))
    .clipShape(RoundedRectangle(cornerRadius: CalendarEventStyle.weekCornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: CalendarEventStyle.weekCornerRadius, style: .continuous)
        .stroke(Color(hex: event.colorHex).opacity(CalendarEventStyle.weekBorderOpacity), lineWidth: 0.5)
    }
    .contentShape(RoundedRectangle(cornerRadius: CalendarEventStyle.weekCornerRadius, style: .continuous))
  }
}
