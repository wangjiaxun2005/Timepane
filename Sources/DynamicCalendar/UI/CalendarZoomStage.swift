import AppKit
import QuartzCore
import SwiftUI

struct CalendarZoomStage: View {
  let scene: CalendarZoomScene
  let calendar: Calendar
  let progress: CGFloat
  var clock: CalendarMotionTrack? = nil
  var onSelectEvent: (ScheduleEvent) -> Void = { _ in }
  var onSelectDay: (Date) -> Void = { _ in }

  var body: some View {
    GeometryReader { proxy in
      let geometry = CalendarZoomGeometry(
        size: proxy.size,
        focusRowIndex: scene.focusRowIndex,
        monthRowCount: scene.monthRowCount
      )

      ZStack(alignment: .topLeading) {
        CalendarMorphingGrid(
          scene: scene,
          calendar: calendar,
          progress: progress, clock: clock
        )

        CalendarPeripheralEventLayer(
          scene: scene,
          calendar: calendar,
          geometry: geometry,
          progress: progress, clock: clock,
          onSelectEvent: onSelectEvent,
          onSelectDay: onSelectDay
        )

        CalendarPeripheralDateLayer(
          scene: scene,
          calendar: calendar,
          geometry: geometry,
          progress: progress, clock: clock
        )

        ZoomDateBridge(
          scene: scene,
          calendar: calendar,
          geometry: geometry,
          progress: progress, clock: clock,
          onSelectDay: onSelectDay
        )

        CalendarZoomEventBridgeLayer(
          scene: scene,
          geometry: geometry,
          progress: progress, clock: clock,
          onSelectEvent: onSelectEvent
        )
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .clipped()
    }
    .accessibilityHidden(true)
  }
}

struct CalendarMorphingGrid: View, Animatable {
  let scene: CalendarZoomScene
  let calendar: Calendar
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    GeometryReader { proxy in
      Canvas(rendersAsynchronously: true) { context, size in
        drawGrid(context: &context, size: size)
      }
      .overlay {
        WeekdayBridgeLayer(scene: scene, calendar: calendar, progress: progress, clock: clock)
      }
    }
  }

  private func drawGrid(context: inout GraphicsContext, size: CGSize) {
    let focusProgress = CalendarZoomMotionSpec.focusProgress(clock?.value(at: Double(progress)) ?? progress)
    let monthness = min(
      1.06,
      max(-0.06, scene.direction == .weekToMonth ? focusProgress : 1 - focusProgress)
    )
    let boundedMonthness = min(1, max(0, monthness))
    let geometry = CalendarZoomGeometry(
      size: size,
      focusRowIndex: scene.focusRowIndex,
      monthRowCount: scene.monthRowCount
    )
    let weekAllDayHeight = scene.weekAllDayHeight
    let weekTop: CGFloat = 43
    let weekGridTop = 45 + weekAllDayHeight
    let monthTop: CGFloat = 29
    let monthBottom = size.height - 12
    let weekDayWidth = max(1, size.width - 48) / 7
    let monthDayWidth = max(1, size.width / 7)
    var verticalPath = Path()

    for index in 0...7 {
      let weekX = 48 + weekDayWidth * CGFloat(index)
      let monthX = monthDayWidth * CGFloat(index)
      let x = interpolate(weekX, monthX, monthness)
      let top = interpolate(weekTop, monthTop, monthness)
      let bottom = interpolate(size.height, monthBottom, monthness)
      verticalPath.move(to: CGPoint(x: x, y: top))
      verticalPath.addLine(to: CGPoint(x: x, y: bottom))
    }
    context.stroke(
      verticalPath,
      with: .color(Color.primary.opacity(0.052)),
      lineWidth: 0.5
    )

    let weekTimedHeight = max(1, size.height - weekGridTop)
    let focusTop = monthTop + geometry.monthRowHeight * CGFloat(scene.focusRowIndex)

    var headerSeparator = Path()
    let headerY = interpolate(weekTop, monthTop, monthness)
    headerSeparator.move(to: CGPoint(x: 0, y: headerY))
    headerSeparator.addLine(to: CGPoint(x: size.width, y: headerY))
    context.stroke(
      headerSeparator,
      with: .color(Color.primary.opacity(0.075)),
      lineWidth: 0.5
    )

    var weekPath = Path()
    let weekRetreat = CalendarZoomMotionSpec.smoothStep(boundedMonthness)
    let weekLeading = interpolate(48, size.width / 2, weekRetreat)
    let weekTrailing = interpolate(size.width, size.width / 2, weekRetreat)
    for track in scene.timeTracks {
      let sourceY = weekGridTop + track.fraction * weekTimedHeight
      let targetY = focusTop + min(1, max(0, track.fraction)) * geometry.monthRowHeight
      let y = interpolate(sourceY, targetY, monthness)
      weekPath.move(to: CGPoint(x: weekLeading, y: y))
      weekPath.addLine(to: CGPoint(x: weekTrailing, y: y))
    }
    let allDayBoundary = interpolate(weekGridTop, focusTop, monthness)
    weekPath.move(to: CGPoint(x: interpolate(0, size.width / 2, weekRetreat), y: allDayBoundary))
    weekPath.addLine(to: CGPoint(x: weekTrailing, y: allDayBoundary))
    context.stroke(weekPath, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)

    var monthPath = Path()
    let monthReveal = CalendarZoomMotionSpec.smoothStep(boundedMonthness)
    let monthLeading = size.width / 2 * (1 - monthReveal)
    let monthTrailing = size.width - monthLeading
    for rowIndex in 0..<scene.monthRowCount {
      let offset = scene.rowTrack(at: rowIndex)?.verticalOffset(
        geometry: geometry,
        transitionProgress: clock?.value(at: Double(progress)) ?? progress,
        direction: scene.direction
      ) ?? 0
      let top = monthTop + geometry.monthRowHeight * CGFloat(rowIndex) + offset
      let bottom = top + geometry.monthRowHeight
      monthPath.move(to: CGPoint(x: monthLeading, y: top))
      monthPath.addLine(to: CGPoint(x: monthTrailing, y: top))
      monthPath.move(to: CGPoint(x: monthLeading, y: bottom))
      monthPath.addLine(to: CGPoint(x: monthTrailing, y: bottom))
    }
    context.stroke(monthPath, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)

    if boundedMonthness < 0.98 {
      let maximumDistance = max(
        abs(weekGridTop - geometry.focusRowMidY),
        abs(weekGridTop + weekTimedHeight - geometry.focusRowMidY),
        1
      )
      for track in scene.timeTracks {
        let weekY = weekGridTop + track.fraction * weekTimedHeight
        let normalizedDistance = abs(weekY - geometry.focusRowMidY) / maximumDistance
        let localProgress = CalendarZoomMotionSpec.timeLabelProgress(
          clock?.value(at: Double(progress)) ?? progress,
          normalizedDistance: normalizedDistance
        )
        let localMonthness = scene.direction == .weekToMonth
          ? localProgress
          : 1 - localProgress
        let y = interpolate(weekY, geometry.focusRowMidY, localMonthness)
        context.opacity = CalendarZoomMotionSpec.timeLabelOpacity(monthness: localMonthness)
        context.draw(
          Text(track.label)
            .font(.system(size: 9, design: .rounded))
            .foregroundStyle(.tertiary),
          at: CGPoint(x: 41, y: y + 6),
          anchor: .trailing
        )
      }
      context.opacity = 1
    }
  }

  private func interpolate(_ source: CGFloat, _ target: CGFloat, _ amount: CGFloat) -> CGFloat {
    source + (target - source) * amount
  }
}

struct WeekdayBridgeLayer: View, Animatable {
  let scene: CalendarZoomScene
  let calendar: Calendar
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    GeometryReader { proxy in
      let weekDayWidth = max(1, proxy.size.width - 48) / 7
      let monthDayWidth = max(1, proxy.size.width / 7)
      ZStack(alignment: .topLeading) {
        ForEach(scene.dateTracks) { track in
          let localProgress = CalendarZoomMotionSpec.headerProgress(
            clock?.value(at: Double(progress)) ?? progress,
            distanceFromFocus: track.distanceFromFocus
          )
          let monthness = scene.direction == .weekToMonth
            ? localProgress
            : 1 - localProgress
          Text(track.weekdayText)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: interpolate(weekDayWidth, monthDayWidth, monthness))
          .position(
            x: interpolate(
              48 + weekDayWidth * (CGFloat(track.dayIndex) + 0.5),
              monthDayWidth * (CGFloat(track.dayIndex) + 0.5),
              monthness
            ),
            y: interpolate(9, 14, monthness)
          )
        }
      }
    }
  }

  private func interpolate(_ source: CGFloat, _ target: CGFloat, _ amount: CGFloat) -> CGFloat {
    source + (target - source) * amount
  }
}

struct ZoomDateBridge: View, Animatable {
  let scene: CalendarZoomScene
  let calendar: Calendar
  let geometry: CalendarZoomGeometry
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil
  var onSelectDay: (Date) -> Void = { _ in }

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let weekDayWidth = max(1, geometry.size.width - 48) / 7
    let monthDayWidth = max(1, geometry.size.width / 7)
    let monthTop = geometry.monthHeaderHeight
      + geometry.monthRowHeight * CGFloat(scene.focusRowIndex)

    return ZStack(alignment: .topLeading) {
      ForEach(scene.dateTracks) { track in
        let localProgress = CalendarZoomMotionSpec.headerProgress(
          clock?.value(at: Double(progress)) ?? progress,
          distanceFromFocus: track.distanceFromFocus
        )
        let fallbackWeekPoint = CGPoint(
          x: 48 + weekDayWidth * (CGFloat(track.dayIndex) + 0.5),
          y: 28
        )
        let fallbackMonthPoint = CGPoint(
          x: monthDayWidth * CGFloat(track.dayIndex) + 14,
          y: monthTop + 11.5
        )
        let sourceFallback = scene.direction == .weekToMonth
          ? fallbackWeekPoint
          : fallbackMonthPoint
        let targetFallback = scene.direction == .weekToMonth
          ? fallbackMonthPoint
          : fallbackWeekPoint
        let sourceFrame = track.sourceFrame
        let targetFrame = track.targetFrame
        let sourcePoint = sourceFrame?.center ?? sourceFallback
        let targetPoint = targetFrame?.center ?? targetFallback
        let point = CGPoint(
          x: sourcePoint.x + (targetPoint.x - sourcePoint.x) * localProgress,
          y: sourcePoint.y + (targetPoint.y - sourcePoint.y) * localProgress
        )
        let isToday = track.isToday

        Text(track.dayText)
          .font(.system(
            size: bridgedFontSize(progress: localProgress),
            weight: isToday ? .semibold : .medium
          ))
          .foregroundStyle(isToday ? Color.white : Color.primary.opacity(0.84))
          .frame(
            width: bridgedDiameter(
              sourceFrame: sourceFrame,
              targetFrame: targetFrame,
              progress: localProgress
            ),
            height: bridgedDiameter(
              sourceFrame: sourceFrame,
              targetFrame: targetFrame,
              progress: localProgress
            )
          )
          .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
          .contentShape(Circle())
          .onTapGesture {
            let monthness = scene.direction == .weekToMonth ? localProgress : 1 - localProgress
            if monthness > 0.5 { onSelectDay(track.date) }
          }
          .position(point)
      }
    }
  }

  private func bridgedDiameter(
    sourceFrame: CGRect?,
    targetFrame: CGRect?,
    progress: CGFloat
  ) -> CGFloat {
    let fallbackSource: CGFloat = scene.direction == .weekToMonth ? 24 : 21
    let fallbackTarget: CGFloat = scene.direction == .weekToMonth ? 21 : 24
    let source = sourceFrame.map { min($0.width, $0.height) } ?? fallbackSource
    let target = targetFrame.map { min($0.width, $0.height) } ?? fallbackTarget
    return source + (target - source) * progress
  }

  private func bridgedFontSize(progress: CGFloat) -> CGFloat {
    let source: CGFloat = scene.direction == .weekToMonth ? 14 : 11
    let target: CGFloat = scene.direction == .weekToMonth ? 11 : 14
    return source + (target - source) * progress
  }
}

struct CalendarPeripheralDateLayer: View {
  let scene: CalendarZoomScene
  let calendar: Calendar
  let geometry: CalendarZoomGeometry
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil

  var body: some View {
    let layout = scene.direction == .weekToMonth ? scene.target.monthLayout : scene.source.monthLayout
    ZStack(alignment: .topLeading) {
      ForEach(scene.rowTracks) { track in
        if layout.weeks.indices.contains(track.rowIndex) {
          CalendarPeripheralDateRow(
            week: layout.weeks[track.rowIndex],
            rowIndex: track.rowIndex,
            calendar: calendar,
            geometry: geometry
          )
          .equatable()
          .modifier(CalendarZoomRowMotionModifier(
            track: track,
            geometry: geometry,
            direction: scene.direction,
            progress: progress, clock: clock
          ))
        }
      }
    }
  }
}

struct CalendarPeripheralDateRow: View, Equatable {
  let week: MonthWeekLayout
  let rowIndex: Int
  let calendar: Calendar
  let geometry: CalendarZoomGeometry

  var body: some View {
    let dayWidth = max(1, geometry.size.width / 7)
    ZStack(alignment: .topLeading) {
      ForEach(Array(week.days.enumerated()), id: \.element.date) { dayIndex, day in
        Text("\(calendar.component(.day, from: day.date))")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color.primary.opacity(day.isInDisplayedMonth ? 0.82 : 0.32))
          .frame(width: 21, height: 21)
          .position(
            x: dayWidth * CGFloat(dayIndex) + 14,
            y: geometry.monthHeaderHeight
              + geometry.monthRowHeight * CGFloat(rowIndex)
              + 11.5
          )
      }
    }
    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
  }
}

struct CalendarPeripheralEventLayer: View {
  @Environment(\.calendarEventOffset) private var eventOffset

  let scene: CalendarZoomScene
  let calendar: Calendar
  let geometry: CalendarZoomGeometry
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil
  var onSelectEvent: (ScheduleEvent) -> Void = { _ in }
  var onSelectDay: (Date) -> Void = { _ in }

  var body: some View {
    let viewport = scene.direction == .weekToMonth
      ? scene.target
      : scene.source
    CalendarViewportContent(
      viewport: viewport,
      calendar: calendar,
      onSelectEvent: onSelectEvent,
      onDismissDetail: {},
      onSelectDay: onSelectDay,
      hiddenEventRowIndex: scene.focusRowIndex,
      eventsOnly: true,
      monthRowMotion: MonthCalendarRowMotion(
        // Performance invariant: the scene owns this indexed lookup table.
        // Do not rebuild it from rowTracks while animation progress changes.
        tracksByIndex: scene.rowTracksByIndex,
        geometry: geometry,
        direction: scene.direction,
        progress: progress, clock: clock
      )
    )
    .environment(\.calendarEventOffset, CalendarEventMotion())
    .clipped()
    .modifier(CalendarEventOffsetModifier(motion: eventOffset))
  }
}

struct CalendarZoomEventBridgeLayer: View {
  @Environment(\.calendarEventOffset) private var eventOffset

  let scene: CalendarZoomScene
  let geometry: CalendarZoomGeometry
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil
  var onSelectEvent: (ScheduleEvent) -> Void = { _ in }

  var body: some View {
    let tracks = scene.eventTracksResolved(in: geometry)
    ZStack(alignment: .topLeading) {
      ForEach(tracks) { track in
        CalendarZoomEventTrackView(
          track: track,
          progress: progress, clock: clock,
          motionCount: tracks.count,
          onSelectEvent: onSelectEvent
        )
      }
    }
    .modifier(CalendarEventOffsetModifier(motion: eventOffset))
  }
}

struct CalendarZoomEventTrackView: View, Animatable {
  let track: CalendarZoomResolvedEventTrack
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil
  let motionCount: Int
  var onSelectEvent: (ScheduleEvent) -> Void = { _ in }

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let localProgress = CalendarZoomMotionSpec.eventProgress(
      clock?.value(at: Double(progress)) ?? progress,
      order: track.motionOrder,
      count: motionCount
    )
    let rect = interpolatedRect(track.sourceRect, track.targetRect, progress: localProgress)
    let middleStretch = sin(.pi * min(1, max(0, localProgress)))
    ZoomEventMorphCard(
      event: track.event,
      timeText: track.timeText,
      sourceAppearance: track.sourceAppearance,
      targetAppearance: track.targetAppearance,
      sourceSize: track.sourceRect.size,
      targetSize: track.targetRect.size,
      currentSize: rect.size,
      textTransferProgress: CalendarZoomMotionSpec.eventTextTransferProgress(localProgress),
      compactness: compactness(track: track, progress: localProgress)
    )
    .frame(
      width: max(4, rect.width * (1 + middleStretch * 0.025)),
      height: max(4, rect.height * (1 - middleStretch * 0.018))
    )
    .contentShape(Rectangle())
    .onTapGesture { onSelectEvent(track.event) }
    .position(x: rect.midX, y: rect.midY)
  }

  private func interpolatedRect(_ source: CGRect, _ target: CGRect, progress: CGFloat) -> CGRect {
    CGRect(
      x: source.minX + (target.minX - source.minX) * progress,
      y: source.minY + (target.minY - source.minY) * progress,
      width: source.width + (target.width - source.width) * min(1, max(0, progress)),
      height: source.height + (target.height - source.height) * min(1, max(0, progress))
    )
  }

  private func compactness(track: CalendarZoomResolvedEventTrack, progress: CGFloat) -> CGFloat {
    track.sourceCompactness
      + (track.targetCompactness - track.sourceCompactness) * min(1, max(0, progress))
  }
}

private extension CalendarZoomEventAppearance {
  var isMonthAppearance: Bool {
    switch self {
    case .weekTimed, .weekAllDay:
      return false
    case .monthTimed, .monthSpan, .monthDot, .monthAllDayOverflow, .monthOverflow:
      return true
    }
  }
}

struct ZoomEventMorphCard: View {
  let event: ScheduleEvent
  let timeText: String
  let sourceAppearance: CalendarZoomEventAppearance
  let targetAppearance: CalendarZoomEventAppearance
  let sourceSize: CGSize
  let targetSize: CGSize
  let currentSize: CGSize
  let textTransferProgress: CGFloat
  let compactness: CGFloat

  var body: some View {
    let eventColor = Color(hex: event.colorHex)
    ZStack(alignment: .topLeading) {
      HStack(spacing: 0) {
        Rectangle()
          .fill(eventColor)
          .frame(width: CalendarEventStyle.colorBarWidth)
        Spacer(minLength: 0)
      }

      ZoomEventEndpointTypography(
        event: event,
        timeText: timeText,
        appearance: sourceAppearance,
        size: sourceSize
      )
        .equatable()
        .frame(width: max(1, sourceSize.width), height: max(1, sourceSize.height), alignment: .topLeading)
        .frame(width: max(1, currentSize.width), height: max(1, currentSize.height), alignment: .topLeading)
        .mask(ZoomEventTypographyClip(progress: textTransferProgress, role: .source))

      ZoomEventEndpointTypography(
        event: event,
        timeText: timeText,
        appearance: targetAppearance,
        size: targetSize
      )
        .equatable()
        .frame(width: max(1, targetSize.width), height: max(1, targetSize.height), alignment: .topLeading)
        .frame(width: max(1, currentSize.width), height: max(1, currentSize.height), alignment: .topLeading)
        .mask(ZoomEventTypographyClip(progress: textTransferProgress, role: .target))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(eventColor.opacity(CalendarEventStyle.weekFillOpacity))
    .clipShape(RoundedRectangle(cornerRadius: 6 - compactness * 2, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 6 - compactness * 2, style: .continuous)
        .stroke(eventColor.opacity(CalendarEventStyle.weekBorderOpacity), lineWidth: 0.5)
    }
    .clipped()
  }
}

// Endpoint typography is visually static during a zoom. Keeping it Equatable
// prevents animated masks and geometry from rebuilding the Text hierarchy.
// Keep progress-dependent work in ZoomEventMorphCard, not in this view.
