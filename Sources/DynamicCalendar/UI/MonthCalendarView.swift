import SwiftUI

struct MonthCalendarRowMotion: Equatable {
  let tracksByIndex: [CalendarZoomRowTrack?]
  let geometry: CalendarZoomGeometry
  let direction: CalendarZoomDirection
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil

  func track(at index: Int) -> CalendarZoomRowTrack? {
    guard tracksByIndex.indices.contains(index) else { return nil }
    return tracksByIndex[index]
  }
}

struct CalendarZoomRowMotionModifier: AnimatableModifier {
  let track: CalendarZoomRowTrack?
  let geometry: CalendarZoomGeometry?
  let direction: CalendarZoomDirection?
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil

  init(
    track: CalendarZoomRowTrack?,
    geometry: CalendarZoomGeometry?,
    direction: CalendarZoomDirection?,
    progress: CGFloat,
    clock: CalendarMotionTrack? = nil
  ) {
    self.track = track
    self.geometry = geometry
    self.direction = direction
    self.progress = progress
    self.clock = clock
  }

  init(motion: MonthCalendarRowMotion?, rowIndex: Int) {
    track = motion?.track(at: rowIndex)
    geometry = motion?.geometry
    direction = motion?.direction
    progress = motion?.progress ?? 1
    clock = motion?.clock
  }

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    content.offset(y: verticalOffset)
  }

  private var verticalOffset: CGFloat {
    guard let track, let geometry, let direction else { return 0 }
    return track.verticalOffset(
        geometry: geometry,
        transitionProgress: clock?.value(at: Double(progress)) ?? progress,
        direction: direction
      )
  }
}

struct MonthCalendarGrid: View, Equatable {
  let layout: MonthLayout
  let calendar: Calendar
  let onSelectEvent: (ScheduleEvent) -> Void
  let onSelectDay: (Date) -> Void
  var renderRevision: UInt64 = 0
  var hiddenDateRowIndex: Int? = nil
  var hiddenEventRowIndex: Int? = nil
  var hidesAllEvents = false
  var eventsOnly = false
  var rowMotion: MonthCalendarRowMotion? = nil
  var zoomEndpoint: CalendarZoomEndpoint? = nil

  static func == (lhs: MonthCalendarGrid, rhs: MonthCalendarGrid) -> Bool {
    layoutsMatch(lhs, rhs)
      && lhs.calendar == rhs.calendar
      && lhs.hiddenDateRowIndex == rhs.hiddenDateRowIndex
      && lhs.hiddenEventRowIndex == rhs.hiddenEventRowIndex
      && lhs.hidesAllEvents == rhs.hidesAllEvents
      && lhs.eventsOnly == rhs.eventsOnly
      && lhs.rowMotion == rhs.rowMotion
      && lhs.zoomEndpoint == rhs.zoomEndpoint
  }

  private static func layoutsMatch(_ lhs: MonthCalendarGrid, _ rhs: MonthCalendarGrid) -> Bool {
    if lhs.renderRevision != 0 || rhs.renderRevision != 0 {
      return lhs.renderRevision == rhs.renderRevision
    }
    return lhs.layout == rhs.layout
  }

  var body: some View {
    VStack(spacing: 0) {
      if eventsOnly {
        Color.clear.frame(height: 28)
      } else {
        MonthWeekdayHeader(layout: layout, calendar: calendar)
          .frame(height: 28)
      }

      if eventsOnly {
        Color.clear.frame(height: 1)
      } else {
        Divider().opacity(0.52)
      }

      GeometryReader { proxy in
        let weekCount = max(1, layout.weeks.count)
        let rowHeight = proxy.size.height / CGFloat(weekCount)

        ZStack(alignment: .topLeading) {
          VStack(spacing: 0) {
            ForEach(Array(layout.weeks.enumerated()), id: \.element.id) { index, week in
              MonthWeekRow(
                week: week,
                rowIndex: index,
                calendar: calendar,
                onSelectEvent: onSelectEvent,
                onSelectDay: onSelectDay,
                hidesDateHeaders: hiddenDateRowIndex == index,
                hidesEvents: hidesAllEvents || hiddenEventRowIndex == index,
                showsChrome: !eventsOnly,
                renderRevision: renderRevision,
                zoomEndpoint: zoomEndpoint
              )
              .equatable()
              .frame(height: rowHeight)
              .modifier(CalendarZoomRowMotionModifier(motion: rowMotion, rowIndex: index))
              .calendarZoomGeometry(.monthRow(index), endpoint: zoomEndpoint)
            }
          }

          if !eventsOnly, weekCount > 1 {
            ForEach(1..<weekCount, id: \.self) { index in
              Rectangle()
                .fill(Color.primary.opacity(0.046))
                .frame(width: proxy.size.width, height: 0.5)
                .offset(y: rowHeight * CGFloat(index))
            }
          }
        }
      }
    }
    .padding(.bottom, 12)
  }
}

private struct MonthWeekdayHeader: View {
  let layout: MonthLayout
  let calendar: Calendar

  var body: some View {
    HStack(spacing: 0) {
      ForEach(headerDates, id: \.self) { date in
        Text(DateFormatting.weekday.string(from: date))
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
      }
    }
  }

  private var headerDates: [Date] {
    guard let firstWeek = layout.weeks.first else { return [] }
    return firstWeek.days.map(\.date)
  }
}

private struct MonthWeekRow: View, Equatable {
  @Environment(\.calendarEventOffset) private var eventOffset
  let week: MonthWeekLayout
  let rowIndex: Int
  let calendar: Calendar
  let onSelectEvent: (ScheduleEvent) -> Void
  let onSelectDay: (Date) -> Void
  let hidesDateHeaders: Bool
  let hidesEvents: Bool
  let showsChrome: Bool
  let renderRevision: UInt64
  let zoomEndpoint: CalendarZoomEndpoint?

  private let dateHeaderHeight: CGFloat = 23
  private let minimumLineHeight: CGFloat = 11
  private let idealLineHeight: CGFloat = 16

  static func == (lhs: MonthWeekRow, rhs: MonthWeekRow) -> Bool {
    let contentMatches = lhs.renderRevision != 0 || rhs.renderRevision != 0
      ? lhs.renderRevision == rhs.renderRevision
      : lhs.week == rhs.week
    return contentMatches
      && lhs.rowIndex == rhs.rowIndex
      && lhs.calendar == rhs.calendar
      && lhs.hidesDateHeaders == rhs.hidesDateHeaders
      && lhs.hidesEvents == rhs.hidesEvents
      && lhs.showsChrome == rhs.showsChrome
      && lhs.zoomEndpoint == rhs.zoomEndpoint
  }

  var body: some View {
    GeometryReader { proxy in
      let dayWidth = proxy.size.width / 7
      let contentHeight = max(1, proxy.size.height - dateHeaderHeight - 3)
      let maxSlots = max(1, Int(floor(contentHeight / minimumLineHeight)))
      let maximumTimedCount = week.maximumTimedEventCount
      let requestedSlots = week.spanningLaneCount + maximumTimedCount
      let usesOverflow = requestedSlots > maxSlots
      let visibleSpanLanes = min(
        week.spanningLaneCount,
        usesOverflow ? max(0, maxSlots - 1) : maxSlots
      )
      let renderedSlots = usesOverflow ? maxSlots : max(1, requestedSlots)
      let lineHeight = min(
        idealLineHeight,
        max(minimumLineHeight, contentHeight / CGFloat(renderedSlots))
      )

      ZStack(alignment: .topLeading) {
        if showsChrome {
          dayHitAreas(dayWidth: dayWidth, height: proxy.size.height)
          gridLines(dayWidth: dayWidth, height: proxy.size.height)
        }
        dateHeaders(dayWidth: dayWidth, showsDates: showsChrome)

        if !hidesEvents {
          ForEach(week.spanningEvents.filter { $0.lane < visibleSpanLanes }) { span in
            let appearance = CalendarZoomEventAppearance.monthSpan(
              rowIndex: rowIndex,
              startDayIndex: span.startDayIndex,
              endDayIndex: span.endDayIndex,
              lane: span.lane,
              spanningLaneCount: week.spanningLaneCount,
              maximumTimedCount: maximumTimedCount
            )
            MonthSpanChip(event: span.event, height: lineHeight - 1)
              .modifier(CalendarEventOffsetModifier(motion: eventOffset))
              .opacity(spanOpacity(span))
              .frame(
                width: max(4, dayWidth * CGFloat(span.daySpan) - 4),
                height: lineHeight - 1
              )
              .calendarZoomGeometry(
                .event(span.event.id, appearance),
                endpoint: zoomEndpoint
              )
              .position(
                x: dayWidth * CGFloat(span.startDayIndex) + 2
                  + max(4, dayWidth * CGFloat(span.daySpan) - 4) / 2,
                y: dateHeaderHeight + CGFloat(span.lane) * lineHeight + lineHeight / 2
              )
              .onTapGesture { onSelectEvent(span.event) }
              .help(span.event.title)
          }
        }

        ForEach(Array(week.days.enumerated()), id: \.element.id) { dayIndex, day in
          let hiddenSpanCount = week.spanningEvents.filter {
            $0.lane >= visibleSpanLanes
              && dayIndex >= $0.startDayIndex
              && dayIndex <= $0.endDayIndex
          }.count
          let availableTimedSlots = max(0, maxSlots - visibleSpanLanes)
          let needsMore = hiddenSpanCount + day.timedEvents.count > availableTimedSlots
          let visibleTimedCount = min(
            day.timedEvents.count,
            needsMore ? max(0, availableTimedSlots - 1) : availableTimedSlots
          )
          let moreCount = hiddenSpanCount + day.timedEvents.count - visibleTimedCount

          if !hidesEvents {
            ForEach(Array(day.timedEvents.prefix(visibleTimedCount).enumerated()), id: \.element.id) {
              eventIndex, event in
              MonthTimedEventChip(event: event, height: lineHeight - 1)
                .modifier(CalendarEventOffsetModifier(motion: eventOffset))
                .opacity(day.isInDisplayedMonth ? 1 : 0.5)
                .frame(width: max(4, dayWidth - 6), height: lineHeight - 1)
                .calendarZoomGeometry(
                  .event(
                    event.id,
                    .monthTimed(
                      rowIndex: rowIndex,
                      dayIndex: dayIndex,
                      itemIndex: eventIndex,
                      spanningLaneCount: week.spanningLaneCount,
                      maximumTimedCount: maximumTimedCount
                    )
                  ),
                  endpoint: zoomEndpoint
                )
                .position(
                  x: dayWidth * CGFloat(dayIndex) + dayWidth / 2,
                  y: dateHeaderHeight
                    + CGFloat(visibleSpanLanes + eventIndex) * lineHeight
                    + lineHeight / 2
                )
                .onTapGesture { onSelectEvent(event) }
                .help(event.title)
            }
          }

          if moreCount > 0, !hidesEvents {
            Button {
              onSelectDay(day.date)
            } label: {
              Text("还有 \(moreCount) 项")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .frame(width: max(4, dayWidth - 6), height: lineHeight - 1)
            .calendarZoomGeometry(
              .appearance(
                .monthOverflow(
                  rowIndex: rowIndex,
                  dayIndex: dayIndex,
                  slot: visibleSpanLanes + visibleTimedCount
                )
              ),
              endpoint: zoomEndpoint
            )
            .position(
              x: dayWidth * CGFloat(dayIndex) + dayWidth / 2,
              y: dateHeaderHeight
                + CGFloat(visibleSpanLanes + visibleTimedCount) * lineHeight
                + lineHeight / 2
            )
          }
        }
      }
      .clipped()
    }
  }

  private func dayHitAreas(dayWidth: CGFloat, height: CGFloat) -> some View {
    ForEach(Array(week.days.enumerated()), id: \.element.id) { index, day in
      Button {
        onSelectDay(day.date)
      } label: {
        Color.clear
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(width: dayWidth, height: height)
      .position(x: dayWidth * CGFloat(index) + dayWidth / 2, y: height / 2)
    }
  }

  private func gridLines(dayWidth: CGFloat, height: CGFloat) -> some View {
    ForEach(1..<7, id: \.self) { index in
      Rectangle()
        .fill(Color.primary.opacity(0.052))
        .frame(width: 0.5, height: height)
        .position(x: dayWidth * CGFloat(index), y: height / 2)
        .allowsHitTesting(false)
    }
  }

  private func dateHeaders(dayWidth: CGFloat, showsDates: Bool) -> some View {
    ForEach(Array(week.days.enumerated()), id: \.element.id) { index, day in
      MonthDateHeader(
        day: day,
        rowIndex: rowIndex,
        dayIndex: index,
        calendar: calendar,
        onSelectEvent: onSelectEvent,
        onSelectDay: onSelectDay,
        showsDate: showsDates,
        showsEvents: !hidesEvents,
        zoomEndpoint: zoomEndpoint
      )
      .opacity(hidesDateHeaders && showsDates ? 0 : 1)
      .frame(width: max(1, dayWidth - 8), height: dateHeaderHeight)
      .position(
        x: dayWidth * CGFloat(index) + dayWidth / 2,
        y: dateHeaderHeight / 2
      )
    }
  }

  private func spanOpacity(_ span: MonthEventSpan) -> Double {
    let coveredDays = week.days[span.startDayIndex...span.endDayIndex]
    return coveredDays.contains(where: \.isInDisplayedMonth) ? 1 : 0.5
  }
}

private struct MonthDateHeader: View {
  @Environment(\.calendarEventOffset) private var eventOffset
  let day: MonthDayLayout
  let rowIndex: Int
  let dayIndex: Int
  let calendar: Calendar
  let onSelectEvent: (ScheduleEvent) -> Void
  let onSelectDay: (Date) -> Void
  let showsDate: Bool
  let showsEvents: Bool
  let zoomEndpoint: CalendarZoomEndpoint?

  private let maximumVisibleDots = 3

  var body: some View {
    let isToday = calendar.isDateInToday(day.date)
    let visibleEvents = showsEvents
      ? Array(day.allDayEvents.prefix(maximumVisibleDots))
      : []
    let overflowCount = showsEvents
      ? max(0, day.allDayEvents.count - visibleEvents.count)
      : 0

    HStack(spacing: 2) {
      if showsDate {
        Text("\(calendar.component(.day, from: day.date))")
          .font(.system(size: 11, weight: isToday ? .semibold : .medium))
          .foregroundStyle(
            isToday ? Color.white : Color.primary.opacity(day.isInDisplayedMonth ? 0.82 : 0.32)
          )
          .frame(width: 21, height: 21)
          .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
          .allowsHitTesting(false)
          .calendarZoomGeometry(.date(day.date), endpoint: zoomEndpoint)
      } else {
        Color.clear.frame(width: 21, height: 21)
      }

      Spacer(minLength: 1)

      HStack(spacing: 0) {
        ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { eventIndex, event in
          Button {
            onSelectEvent(event)
          } label: {
            Circle()
              .fill(Color(hex: event.colorHex))
              .frame(width: 6, height: 6)
              .frame(width: 14, height: 14)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(event.title)
          .accessibilityLabel(event.title)
          .calendarZoomGeometry(
            .event(
              event.id,
              .monthDot(
                rowIndex: rowIndex,
                dayIndex: dayIndex,
                itemIndex: eventIndex,
                visibleCount: visibleEvents.count,
                hasOverflow: overflowCount > 0
              )
            ),
            endpoint: zoomEndpoint
          )
        }

        if overflowCount > 0 {
          Button {
            onSelectDay(day.date)
          } label: {
            Text("+\(overflowCount)")
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(minWidth: 15, minHeight: 14)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("还有 \(overflowCount) 个全天事项")
          .calendarZoomGeometry(
            .appearance(.monthAllDayOverflow(rowIndex: rowIndex, dayIndex: dayIndex)),
            endpoint: zoomEndpoint
          )
        }
      }
      .opacity(day.isInDisplayedMonth ? 1 : 0.45)
      .modifier(CalendarEventOffsetModifier(motion: eventOffset))
    }
  }
}

private struct MonthSpanChip: View {
  let event: ScheduleEvent
  let height: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(Color(hex: event.colorHex))
        .frame(width: CalendarEventStyle.colorBarWidth)
      Text(event.title)
        .font(.system(size: CalendarEventStyle.compactFontSize(height: height), weight: .medium))
        .lineLimit(1)
        .padding(.leading, 3)
      Spacer(minLength: 0)
    }
    .padding(.trailing, 3)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(hex: event.colorHex).opacity(0.16))
    .clipShape(RoundedRectangle(cornerRadius: CalendarEventStyle.monthCornerRadius, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: CalendarEventStyle.monthCornerRadius, style: .continuous))
  }
}

private struct MonthTimedEventChip: View {
  let event: ScheduleEvent
  let height: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(Color(hex: event.colorHex))
        .frame(width: CalendarEventStyle.colorBarWidth)
      Text("\(DateFormatting.time.string(from: event.startDate)) \(event.title)")
        .font(.system(size: CalendarEventStyle.compactFontSize(height: height), weight: .medium))
        .lineLimit(1)
        .padding(.leading, 3)
      Spacer(minLength: 0)
    }
    .padding(.trailing, 3)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(hex: event.colorHex).opacity(0.11))
    .clipShape(RoundedRectangle(cornerRadius: CalendarEventStyle.monthCornerRadius, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: CalendarEventStyle.monthCornerRadius, style: .continuous))
  }
}
