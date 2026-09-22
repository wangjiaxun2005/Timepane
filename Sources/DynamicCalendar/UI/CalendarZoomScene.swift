import SwiftUI

enum CalendarZoomDirection: Equatable {
  case weekToMonth
  case monthToWeek
}

enum CalendarZoomPhase: Equatable {
  case idle
  case detecting
  case preparing
  case animating
  case handoff
}

enum CalendarZoomGestureAction: Equatable {
  case none
  case prepare
  case trigger
}



struct CalendarZoomGestureTracker {
  private static let comparisonTolerance: CGFloat = 0.0001

  func direction(for mode: CalendarDisplayMode) -> CalendarZoomDirection {
    mode == .week ? .weekToMonth : .monthToWeek
  }

  func directionalDelta(
    magnification: CGFloat,
    direction: CalendarZoomDirection
  ) -> CGFloat {
    direction == .weekToMonth ? 1 - magnification : magnification - 1
  }

  func action(
    magnification: CGFloat,
    mode: CalendarDisplayMode,
    hasPrepared: Bool,
    hasTriggered: Bool
  ) -> CalendarZoomGestureAction {
    // Pinching is intentionally one-way: week -> month. Returning to the week
    // view is a deliberate click on the mode picker or a date in the month grid.
    guard mode == .week, !hasTriggered else { return .none }
    let direction = direction(for: mode)
    let delta = directionalDelta(magnification: magnification, direction: direction)
    if delta + Self.comparisonTolerance >= CalendarZoomMotionSpec.commitDelta {
      return .trigger
    }
    if !hasPrepared,
       delta + Self.comparisonTolerance >= CalendarZoomMotionSpec.preparationDelta {
      return .prepare
    }
    return .none
  }
}

struct CalendarZoomGestureSession {
  private(set) var isActive = false
  private var prepared = false
  private var triggered = false

  mutating func consume(magnification: CGFloat) -> CalendarZoomGestureAction {
    isActive = true
    let action = CalendarZoomGestureTracker().action(magnification: magnification, mode: .week,
      hasPrepared: prepared, hasTriggered: triggered)
    if action == .prepare { prepared = true }
    if action == .trigger { prepared = true; triggered = true }
    return action
  }

  mutating func end() {
    isActive = false
    prepared = false
    triggered = false
  }
}

struct CalendarZoomDateTrack: Identifiable, Equatable {
  var id: Date { date }
  let date: Date
  let dayIndex: Int
  let weekdayText: String
  let dayText: String
  let isToday: Bool
  let distanceFromFocus: Int
  let sourceFrame: CGRect?
  let targetFrame: CGRect?
}

struct CalendarZoomTimeTrack: Equatable {
  let label: String
  let fraction: CGFloat
}

enum CalendarZoomEventAppearance: Hashable {
  case weekTimed(
    dayIndex: Int,
    startMinute: Int,
    endMinute: Int,
    lane: Int,
    laneCount: Int,
    visibleStartMinute: Int,
    visibleEndMinute: Int,
    allDayHeight: CGFloat
  )
  case weekAllDay(dayIndex: Int, itemIndex: Int, itemCount: Int, allDayHeight: CGFloat)
  case monthTimed(
    rowIndex: Int,
    dayIndex: Int,
    itemIndex: Int,
    spanningLaneCount: Int,
    maximumTimedCount: Int
  )
  case monthSpan(
    rowIndex: Int,
    startDayIndex: Int,
    endDayIndex: Int,
    lane: Int,
    spanningLaneCount: Int,
    maximumTimedCount: Int
  )
  case monthDot(
    rowIndex: Int,
    dayIndex: Int,
    itemIndex: Int,
    visibleCount: Int,
    hasOverflow: Bool
  )
  case monthAllDayOverflow(rowIndex: Int, dayIndex: Int)
  case monthOverflow(rowIndex: Int, dayIndex: Int, slot: Int)
}

enum CalendarZoomEndpoint: Hashable {
  case source
  case target
}

enum CalendarZoomElementID: Hashable {
  case canvas
  case date(Date)
  case event(String, CalendarZoomEventAppearance)
  case appearance(CalendarZoomEventAppearance)
  case monthRow(Int)
}

struct CalendarZoomGeometryKey: Hashable {
  let endpoint: CalendarZoomEndpoint
  let element: CalendarZoomElementID
}

struct CalendarZoomGeometrySnapshot: Equatable {
  let canvas: CGRect
  let frames: [CalendarZoomElementID: CGRect]

  static func make(
    endpoint: CalendarZoomEndpoint,
    frames: [CalendarZoomGeometryKey: CGRect],
    requiredDates: [Date]
  ) -> CalendarZoomGeometrySnapshot? {
    guard let canvas = frames[CalendarZoomGeometryKey(endpoint: endpoint, element: .canvas)],
          canvas.width > 0,
          canvas.height > 0,
          requiredDates.allSatisfy({
            frames[CalendarZoomGeometryKey(endpoint: endpoint, element: .date($0))] != nil
          }) else {
      return nil
    }

    var endpointFrames: [CalendarZoomElementID: CGRect] = [:]
    for (key, value) in frames where key.endpoint == endpoint {
      endpointFrames[key.element] = value
    }
    return CalendarZoomGeometrySnapshot(canvas: canvas, frames: endpointFrames)
  }

  func frame(for element: CalendarZoomElementID) -> CGRect? {
    guard let frame = frames[element]?.offsetBy(dx: -canvas.minX, dy: -canvas.minY) else {
      return nil
    }
    switch element {
    case .event, .appearance:
      // A positioned SwiftUI child can accidentally report its parent's proposal.
      // Never let a bogus canvas-sized event become a full-window morph card.
      guard frame.width < canvas.width * 0.8 || frame.height < canvas.height * 0.8 else {
        return nil
      }
    case .canvas, .date, .monthRow:
      break
    }
    return frame
  }
}

struct CalendarZoomEventTrack: Identifiable, Equatable {
  let id: String
  let event: ScheduleEvent
  let source: CalendarZoomEventAppearance
  let target: CalendarZoomEventAppearance
}

struct CalendarZoomResolvedEventTrack: Identifiable, Equatable {
  let id: String
  let event: ScheduleEvent
  let timeText: String
  let sourceAppearance: CalendarZoomEventAppearance
  let targetAppearance: CalendarZoomEventAppearance
  let sourceRect: CGRect
  let targetRect: CGRect
  let sourceCompactness: CGFloat
  let targetCompactness: CGFloat
  let motionOrder: Int
}

enum CalendarZoomRowExitEdge: Equatable {
  case top
  case bottom
}

struct CalendarZoomRowTrack: Identifiable, Equatable {
  var id: Int { rowIndex }
  let rowIndex: Int
  let distance: Int
  let exitEdge: CalendarZoomRowExitEdge

  func verticalOffset(
    geometry: CalendarZoomGeometry,
    transitionProgress: CGFloat,
    direction: CalendarZoomDirection
  ) -> CGFloat {
    let localProgress = CalendarZoomMotionSpec.rowProgress(
      transitionProgress,
      distance: distance
    )
    let monthness = direction == .weekToMonth ? localProgress : 1 - localProgress
    let expandedMidY = geometry.monthHeaderHeight
      + (CGFloat(rowIndex) + 0.5) * geometry.monthRowHeight
    let collapsedMidY: CGFloat = exitEdge == .top
      ? -geometry.monthRowHeight / 2
      : geometry.size.height + geometry.monthRowHeight / 2
    return (collapsedMidY - expandedMidY) * (1 - monthness)
  }
}

struct CalendarZoomScene: Equatable {
  let source: CalendarViewportState
  let target: CalendarViewportState
  let direction: CalendarZoomDirection
  let focusedDate: Date
  let focusRowIndex: Int
  let monthRowCount: Int
  let dateTracks: [CalendarZoomDateTrack]
  let timeTracks: [CalendarZoomTimeTrack]
  let weekAllDayHeight: CGFloat
  let eventTracks: [CalendarZoomEventTrack]
  let rowTracks: [CalendarZoomRowTrack]
  let rowTracksByIndex: [CalendarZoomRowTrack?]
  let resolvedEventTracks: [CalendarZoomResolvedEventTrack]
  let sourceGeometry: CalendarZoomGeometrySnapshot?
  let targetGeometry: CalendarZoomGeometrySnapshot?

  static func make(
    source: CalendarViewportState,
    targetMode: CalendarDisplayMode,
    focusedDate: Date,
    calendar: Calendar
  ) -> CalendarZoomScene {
    let weekEngine = WeekLayoutEngine(calendar: calendar)
    let monthEngine = MonthLayoutEngine(calendar: calendar)
    let sourceEvents = source.periodSchedule.events
    let targetWeekLayout: WeekLayout
    let targetMonthLayout: MonthLayout
    let targetInterval: DateInterval

    switch targetMode {
    case .week:
      targetWeekLayout = weekEngine.makeLayout(events: sourceEvents, weekStart: focusedDate)
      targetMonthLayout = source.monthLayout
      targetInterval = DateInterval(start: targetWeekLayout.weekStart, end: targetWeekLayout.weekEnd)
    case .month:
      targetWeekLayout = source.weekLayout
      targetMonthLayout = monthEngine.makeLayout(events: sourceEvents, containing: focusedDate)
      targetInterval = DateInterval(start: targetMonthLayout.gridStart, end: targetMonthLayout.gridEnd)
    }

    let targetEvents = sourceEvents.filter {
      $0.startDate < targetInterval.end && $0.endDate > targetInterval.start
    }
    let target = CalendarViewportState(
      displayMode: targetMode,
      focusedDate: focusedDate,
      periodSchedule: CalendarPeriodSchedule(
        startDate: targetInterval.start,
        endDate: targetInterval.end,
        events: targetEvents
      ),
      weekLayout: targetWeekLayout,
      monthLayout: targetMonthLayout,
      navigationDirection: .stationary
    )
    return build(source: source, target: target, focusedDate: focusedDate, calendar: calendar)
  }

  static func make(
    source: CalendarViewportState,
    target: CalendarViewportState,
    focusedDate: Date,
    calendar: Calendar
  ) -> CalendarZoomScene {
    build(source: source, target: target, focusedDate: focusedDate, calendar: calendar)
  }

  private static func build(
    source: CalendarViewportState,
    target: CalendarViewportState,
    focusedDate: Date,
    calendar: Calendar
  ) -> CalendarZoomScene {
    let direction: CalendarZoomDirection = target.displayMode == .month ? .weekToMonth : .monthToWeek
    let monthLayout = target.displayMode == .month ? target.monthLayout : source.monthLayout
    let dayOffset = calendar.dateComponents(
      [.day],
      from: monthLayout.gridStart,
      to: calendar.startOfDay(for: focusedDate)
    ).day ?? 0
    let rowCount = max(1, monthLayout.weeks.count)
    let focusRow = min(rowCount - 1, max(0, dayOffset / 7))
    let focusDates = direction == .weekToMonth
      ? source.weekLayout.days.map(\.date)
      : target.weekLayout.days.map(\.date)
    let focusedDayIndex = focusDates.firstIndex {
      calendar.isDate($0, inSameDayAs: focusedDate)
    } ?? 3
    let dateTracks = focusDates.enumerated().map {
      CalendarZoomDateTrack(
        date: $0.element,
        dayIndex: $0.offset,
        weekdayText: DateFormatting.weekday.string(from: $0.element),
        dayText: "\(calendar.component(.day, from: $0.element))",
        isToday: calendar.isDateInToday($0.element),
        distanceFromFocus: abs($0.offset - focusedDayIndex),
        sourceFrame: nil,
        targetFrame: nil
      )
    }
    let focusWeekLayout = source.displayMode == .week ? source.weekLayout : target.weekLayout
    let minuteSpan = max(
      1,
      focusWeekLayout.visibleEndMinute - focusWeekLayout.visibleStartMinute
    )
    let startHour = focusWeekLayout.visibleStartMinute / 60
    let endHour = focusWeekLayout.visibleEndMinute / 60
    // Performance invariant: build labels and normalized positions once per scene.
    // CalendarMorphingGrid consumes these tracks every frame and must not format
    // time strings or derive the visible range inside its draw loop.
    let timeTracks: [CalendarZoomTimeTrack]
    if startHour <= endHour {
      timeTracks = (startHour...endHour).map { hour in
        CalendarZoomTimeTrack(
          label: String(format: "%02d", hour),
          fraction: CGFloat(hour * 60 - focusWeekLayout.visibleStartMinute)
            / CGFloat(minuteSpan)
        )
      }
    } else {
      timeTracks = []
    }

    let focusStart = focusDates.first.map { calendar.startOfDay(for: $0) } ?? focusedDate
    let focusEnd = calendar.date(byAdding: .day, value: 7, to: focusStart) ?? focusStart
    let combinedEvents = source.periodSchedule.events + target.periodSchedule.events
    var eventByID: [String: ScheduleEvent] = [:]
    for event in combinedEvents where event.startDate < focusEnd && event.endDate > focusStart {
      eventByID[event.id] = event
    }
    let tracks: [CalendarZoomEventTrack] = eventByID.values.sorted(by: eventSort).compactMap {
      event -> CalendarZoomEventTrack? in
      guard
        let sourceAppearance = appearance(
          for: event,
          viewport: source,
          focusRowIndex: focusRow,
          calendar: calendar
        ),
        let targetAppearance = appearance(
          for: event,
          viewport: target,
          focusRowIndex: focusRow,
          calendar: calendar
        )
      else { return nil }
      return CalendarZoomEventTrack(
        id: event.id,
        event: event,
        source: sourceAppearance,
        target: targetAppearance
      )
    }
    let rowTracks = (0..<rowCount).compactMap { rowIndex -> CalendarZoomRowTrack? in
      guard rowIndex != focusRow else { return nil }
      return CalendarZoomRowTrack(
        rowIndex: rowIndex,
        distance: abs(rowIndex - focusRow),
        exitEdge: rowIndex < focusRow ? .top : .bottom
      )
    }
    let rowTracksByIndex = indexedRowTracks(rowTracks, rowCount: rowCount)

    return CalendarZoomScene(
      source: source,
      target: target,
      direction: direction,
      focusedDate: focusedDate,
      focusRowIndex: focusRow,
      monthRowCount: rowCount,
      dateTracks: dateTracks,
      timeTracks: timeTracks,
      weekAllDayHeight: weekAllDayHeight(focusWeekLayout),
      eventTracks: tracks,
      rowTracks: rowTracks,
      rowTracksByIndex: rowTracksByIndex,
      resolvedEventTracks: [],
      sourceGeometry: nil,
      targetGeometry: nil
    )
  }

  func installing(
    sourceGeometry: CalendarZoomGeometrySnapshot,
    targetGeometry: CalendarZoomGeometrySnapshot
  ) -> CalendarZoomScene {
    let fallbackSize = sourceGeometry.canvas.size.width > 0 && sourceGeometry.canvas.size.height > 0
      ? sourceGeometry.canvas.size
      : targetGeometry.canvas.size
    let fallbackGeometry = CalendarZoomGeometry(
      size: fallbackSize,
      focusRowIndex: focusRowIndex,
      monthRowCount: monthRowCount
    )
    let resolvedEventTracks = eventTracks.enumerated().map { motionOrder, track in
      CalendarZoomResolvedEventTrack(
        id: track.id,
        event: track.event,
        timeText: DateFormatting.time.string(from: track.event.startDate),
        sourceAppearance: track.source,
        targetAppearance: track.target,
        sourceRect: measuredFrame(
          for: track.source,
          eventID: track.id,
          geometry: sourceGeometry
        ) ?? fallbackGeometry.rect(for: track.source),
        targetRect: measuredFrame(
          for: track.target,
          eventID: track.id,
          geometry: targetGeometry
        ) ?? fallbackGeometry.rect(for: track.target),
        sourceCompactness: Self.isMonthAppearance(track.source) ? 1 : 0,
        targetCompactness: Self.isMonthAppearance(track.target) ? 1 : 0,
        motionOrder: motionOrder
      )
    }
    // Performance invariant: resolve endpoint frames before animation starts.
    // ZoomDateBridge runs on every frame and must not query geometry dictionaries.
    let resolvedDateTracks = dateTracks.map { track in
      CalendarZoomDateTrack(
        date: track.date,
        dayIndex: track.dayIndex,
        weekdayText: track.weekdayText,
        dayText: track.dayText,
        isToday: track.isToday,
        distanceFromFocus: track.distanceFromFocus,
        sourceFrame: sourceGeometry.frame(for: .date(track.date)),
        targetFrame: targetGeometry.frame(for: .date(track.date))
      )
    }
    return CalendarZoomScene(
      source: source,
      target: target,
      direction: direction,
      focusedDate: focusedDate,
      focusRowIndex: focusRowIndex,
      monthRowCount: monthRowCount,
      dateTracks: resolvedDateTracks,
      timeTracks: timeTracks,
      weekAllDayHeight: weekAllDayHeight,
      eventTracks: eventTracks,
      rowTracks: rowTracks,
      rowTracksByIndex: rowTracksByIndex,
      resolvedEventTracks: resolvedEventTracks,
      sourceGeometry: sourceGeometry,
      targetGeometry: targetGeometry
    )
  }

  func rowTrack(at index: Int) -> CalendarZoomRowTrack? {
    guard rowTracksByIndex.indices.contains(index) else { return nil }
    return rowTracksByIndex[index]
  }

  func eventTracksResolved(in fallbackGeometry: CalendarZoomGeometry) -> [CalendarZoomResolvedEventTrack] {
    guard resolvedEventTracks.isEmpty else { return resolvedEventTracks }
    return eventTracks.enumerated().map { motionOrder, track in
      CalendarZoomResolvedEventTrack(
        id: track.id,
        event: track.event,
        timeText: DateFormatting.time.string(from: track.event.startDate),
        sourceAppearance: track.source,
        targetAppearance: track.target,
        sourceRect: measuredFrame(
          for: track.source,
          eventID: track.id,
          geometry: sourceGeometry
        ) ?? fallbackGeometry.rect(for: track.source),
        targetRect: measuredFrame(
          for: track.target,
          eventID: track.id,
          geometry: targetGeometry
        ) ?? fallbackGeometry.rect(for: track.target),
        sourceCompactness: Self.isMonthAppearance(track.source) ? 1 : 0,
        targetCompactness: Self.isMonthAppearance(track.target) ? 1 : 0,
        motionOrder: motionOrder
      )
    }
  }

  private func measuredFrame(
    for appearance: CalendarZoomEventAppearance,
    eventID: String,
    geometry: CalendarZoomGeometrySnapshot?
  ) -> CGRect? {
    return geometry?.frame(for: .event(eventID, appearance))
      ?? geometry?.frame(for: .appearance(appearance))
  }

  private static func indexedRowTracks(
    _ rowTracks: [CalendarZoomRowTrack],
    rowCount: Int
  ) -> [CalendarZoomRowTrack?] {
    var indexed = Array<CalendarZoomRowTrack?>(repeating: nil, count: rowCount)
    for track in rowTracks where indexed.indices.contains(track.rowIndex) {
      indexed[track.rowIndex] = track
    }
    return indexed
  }

  private static func isMonthAppearance(_ appearance: CalendarZoomEventAppearance) -> Bool {
    switch appearance {
    case .weekTimed, .weekAllDay:
      return false
    case .monthTimed, .monthSpan, .monthDot, .monthAllDayOverflow, .monthOverflow:
      return true
    }
  }

  private static func appearance(
    for event: ScheduleEvent,
    viewport: CalendarViewportState,
    focusRowIndex: Int,
    calendar: Calendar
  ) -> CalendarZoomEventAppearance? {
    switch viewport.displayMode {
    case .week:
      let allDayHeight = weekAllDayHeight(viewport.weekLayout)
      for (dayIndex, day) in viewport.weekLayout.days.enumerated() {
        if let itemIndex = day.allDayEvents.firstIndex(where: { $0.id == event.id }) {
          return .weekAllDay(
            dayIndex: dayIndex,
            itemIndex: itemIndex,
            itemCount: day.allDayEvents.count,
            allDayHeight: allDayHeight
          )
        }
        if let item = day.timedEvents.first(where: { $0.event.id == event.id }) {
          return .weekTimed(
            dayIndex: item.dayIndex,
            startMinute: item.startMinute,
            endMinute: item.endMinute,
            lane: item.lane,
            laneCount: item.laneCount,
            visibleStartMinute: viewport.weekLayout.visibleStartMinute,
            visibleEndMinute: viewport.weekLayout.visibleEndMinute,
            allDayHeight: allDayHeight
          )
        }
      }
      return nil

    case .month:
      guard viewport.monthLayout.weeks.indices.contains(focusRowIndex) else { return nil }
      let week = viewport.monthLayout.weeks[focusRowIndex]
      let maximumTimedCount = week.maximumTimedEventCount
      for (dayIndex, day) in week.days.enumerated() {
        if let itemIndex = day.allDayEvents.firstIndex(where: { $0.id == event.id }) {
          let visibleCount = min(3, day.allDayEvents.count)
          guard itemIndex < visibleCount else {
            return .monthAllDayOverflow(
              rowIndex: focusRowIndex,
              dayIndex: dayIndex
            )
          }
          return .monthDot(
            rowIndex: focusRowIndex,
            dayIndex: dayIndex,
            itemIndex: itemIndex,
            visibleCount: visibleCount,
            hasOverflow: day.allDayEvents.count > visibleCount
          )
        }
        if let itemIndex = day.timedEvents.firstIndex(where: { $0.id == event.id }) {
          return .monthTimed(
            rowIndex: focusRowIndex,
            dayIndex: dayIndex,
            itemIndex: itemIndex,
            spanningLaneCount: week.spanningLaneCount,
            maximumTimedCount: maximumTimedCount
          )
        }
      }
      if let span = week.spanningEvents.first(where: { $0.event.id == event.id }) {
        return .monthSpan(
          rowIndex: focusRowIndex,
          startDayIndex: span.startDayIndex,
          endDayIndex: span.endDayIndex,
          lane: span.lane,
          spanningLaneCount: week.spanningLaneCount,
          maximumTimedCount: maximumTimedCount
        )
      }
      let eventDay = calendar.startOfDay(for: event.startDate)
      let dayIndex = week.days.firstIndex { calendar.isDate($0.date, inSameDayAs: eventDay) } ?? 0
      return .monthOverflow(rowIndex: focusRowIndex, dayIndex: dayIndex, slot: 0)
    }
  }

  private static func weekAllDayHeight(_ layout: WeekLayout) -> CGFloat {
    let count = layout.maximumAllDayEventCount
    guard count > 0 else { return 24 }
    return min(88, max(28, CGFloat(count) * 19 + 6))
  }

  private static func eventSort(_ lhs: ScheduleEvent, _ rhs: ScheduleEvent) -> Bool {
    if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
    if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
    return lhs.id < rhs.id
  }
}

enum CalendarZoomPreparedTargetResolver {
  static func sourceCoversTarget(_ scene: CalendarZoomScene) -> Bool {
    scene.source.periodSchedule.startDate <= scene.target.periodSchedule.startDate
      && scene.source.periodSchedule.endDate >= scene.target.periodSchedule.endDate
  }

  static func resolve(
    scene: CalendarZoomScene,
    preparedViewport: CalendarViewportState?,
    calendar: Calendar
  ) -> CalendarZoomScene? {
    guard let preparedViewport,
          preparedViewport.displayMode == scene.target.displayMode,
          preparedViewport.focusedDate == scene.target.focusedDate,
          preparedViewport.periodSchedule.startDate == scene.target.periodSchedule.startDate,
          preparedViewport.periodSchedule.endDate == scene.target.periodSchedule.endDate else {
      return nil
    }

    guard preparedViewport != scene.target else { return scene }
    return CalendarZoomScene.make(
      source: scene.source,
      target: preparedViewport,
      focusedDate: scene.focusedDate,
      calendar: calendar
    )
  }
}

struct CalendarZoomGeometry: Equatable {
  let size: CGSize
  let focusRowIndex: Int
  let monthRowCount: Int
  let monthHeaderHeight: CGFloat

  init(
    size: CGSize,
    focusRowIndex: Int,
    monthRowCount: Int,
    monthHeaderHeight: CGFloat = 29
  ) {
    self.size = size
    self.focusRowIndex = focusRowIndex
    self.monthRowCount = max(1, monthRowCount)
    self.monthHeaderHeight = monthHeaderHeight
  }

  var monthRowHeight: CGFloat {
    max(1, (size.height - monthHeaderHeight - 12) / CGFloat(monthRowCount))
  }

  var focusRowMidY: CGFloat {
    monthHeaderHeight + (CGFloat(focusRowIndex) + 0.5) * monthRowHeight
  }

  func rect(for appearance: CalendarZoomEventAppearance) -> CGRect {
    switch appearance {
    case let .weekTimed(
      dayIndex, startMinute, endMinute, lane, laneCount,
      visibleStartMinute, visibleEndMinute, allDayHeight
    ):
      let dayWidth = max(1, size.width - 48) / 7
      let gridTop = 45 + allDayHeight
      let gridHeight = max(80, size.height - 43 - allDayHeight - 2)
      let minuteSpan = max(1, visibleEndMinute - visibleStartMinute)
      let topFraction = CGFloat(max(visibleStartMinute, startMinute) - visibleStartMinute)
        / CGFloat(minuteSpan)
      let bottomFraction = CGFloat(min(visibleEndMinute, endMinute) - visibleStartMinute)
        / CGFloat(minuteSpan)
      let height = min(gridHeight, max(16, (bottomFraction - topFraction) * gridHeight))
      let y = min(max(gridTop, gridTop + topFraction * gridHeight), size.height - height)
      let laneWidth = max(5, (dayWidth - 5) / CGFloat(max(1, laneCount)))
      let width = max(4, laneWidth - 2)
      let x = 48 + dayWidth * CGFloat(dayIndex) + 3 + laneWidth * CGFloat(lane)
      return CGRect(x: x, y: y, width: width, height: height)

    case let .weekAllDay(dayIndex, itemIndex, itemCount, allDayHeight):
      let dayWidth = max(1, size.width - 48) / 7
      let spacing: CGFloat = itemCount > 5 ? 0.5 : 2
      let available = max(1, allDayHeight - 4 - CGFloat(max(0, itemCount - 1)) * spacing)
      let height = itemCount == 0 ? 0 : available / CGFloat(itemCount)
      return CGRect(
        x: 48 + dayWidth * CGFloat(dayIndex) + 3,
        y: 46 + CGFloat(itemIndex) * (height + spacing),
        width: max(4, dayWidth - 6),
        height: height
      )

    case let .monthTimed(rowIndex, dayIndex, itemIndex, spanningLaneCount, maximumTimedCount):
      let metrics = monthMetrics(
        spanningLaneCount: spanningLaneCount,
        maximumTimedCount: maximumTimedCount
      )
      let slot = metrics.visibleSpanLanes + itemIndex
      if slot >= metrics.maxSlots {
        return monthOverflowRect(rowIndex: rowIndex, dayIndex: dayIndex, slot: metrics.maxSlots - 1)
      }
      return CGRect(
        x: dayWidth * CGFloat(dayIndex) + 3,
        y: monthHeaderHeight + monthRowHeight * CGFloat(rowIndex) + 23
          + CGFloat(slot) * metrics.lineHeight,
        width: max(4, dayWidth - 6),
        height: max(4, metrics.lineHeight - 1)
      )

    case let .monthSpan(
      rowIndex, startDayIndex, endDayIndex, lane, spanningLaneCount, maximumTimedCount
    ):
      let metrics = monthMetrics(
        spanningLaneCount: spanningLaneCount,
        maximumTimedCount: maximumTimedCount
      )
      guard lane < metrics.visibleSpanLanes else {
        return monthOverflowRect(
          rowIndex: rowIndex,
          dayIndex: startDayIndex,
          slot: metrics.maxSlots - 1
        )
      }
      return CGRect(
        x: dayWidth * CGFloat(startDayIndex) + 2,
        y: monthHeaderHeight + monthRowHeight * CGFloat(rowIndex) + 23
          + CGFloat(lane) * metrics.lineHeight,
        width: max(4, dayWidth * CGFloat(endDayIndex - startDayIndex + 1) - 4),
        height: max(4, metrics.lineHeight - 1)
      )

    case let .monthDot(rowIndex, dayIndex, itemIndex, visibleCount, hasOverflow):
      let right = dayWidth * CGFloat(dayIndex + 1) - 4
      let count = max(1, visibleCount)
      let overflowWidth: CGFloat = hasOverflow ? 15 : 0
      let centerX = right - overflowWidth - 7 - CGFloat(count - itemIndex - 1) * 14
      return CGRect(
        x: centerX - 3,
        y: monthHeaderHeight + monthRowHeight * CGFloat(rowIndex) + 8.5,
        width: 6,
        height: 6
      )

    case let .monthAllDayOverflow(rowIndex, dayIndex):
      let right = dayWidth * CGFloat(dayIndex + 1) - 4
      return CGRect(
        x: right - 15,
        y: monthHeaderHeight + monthRowHeight * CGFloat(rowIndex) + 4.5,
        width: 15,
        height: 14
      )

    case let .monthOverflow(rowIndex, dayIndex, slot):
      return monthOverflowRect(rowIndex: rowIndex, dayIndex: dayIndex, slot: slot)
    }
  }

  private var dayWidth: CGFloat { max(1, size.width / 7) }

  private func monthOverflowRect(rowIndex: Int, dayIndex: Int, slot: Int) -> CGRect {
    CGRect(
      x: dayWidth * CGFloat(dayIndex) + 3,
      y: monthHeaderHeight + monthRowHeight * CGFloat(rowIndex) + 23
        + CGFloat(max(0, slot)) * 11,
      width: max(4, dayWidth - 6),
      height: 10
    )
  }

  private func monthMetrics(
    spanningLaneCount: Int,
    maximumTimedCount: Int
  ) -> (maxSlots: Int, visibleSpanLanes: Int, lineHeight: CGFloat) {
    let contentHeight = max(1, monthRowHeight - 26)
    let maxSlots = max(1, Int(floor(contentHeight / 11)))
    let requestedSlots = spanningLaneCount + maximumTimedCount
    let usesOverflow = requestedSlots > maxSlots
    let visibleSpanLanes = min(
      spanningLaneCount,
      usesOverflow ? max(0, maxSlots - 1) : maxSlots
    )
    let renderedSlots = usesOverflow ? maxSlots : max(1, requestedSlots)
    return (
      maxSlots,
      visibleSpanLanes,
      min(16, max(11, contentHeight / CGFloat(renderedSlots)))
    )
  }
}

