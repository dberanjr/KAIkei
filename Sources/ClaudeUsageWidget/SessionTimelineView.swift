import Charts
import SwiftUI
import UsageCore

/// How much of the timeline to draw. Follows the size buttons: small windows get the essentials, larger ones the lot.
/// A maximized chart keeps the full density and stretches its panels with `scale`.
struct TimelineDensity: Equatable {
    enum Kind { case compact, standard, full }
    var kind: Kind
    /// Multiplies the heights of the data panels, for a chart that has the whole screen.
    var scale: CGFloat = 1
    /// Plot width used to size bars; a maximized chart is much wider than any window size.
    var wide = false

    static let compact = TimelineDensity(kind: .compact)
    static let standard = TimelineDensity(kind: .standard)
    static let full = TimelineDensity(kind: .full)

    init(kind: Kind) { self.kind = kind }
    init(_ size: WidgetSize) {
        switch size {
        case .small, .medium: self.init(kind: .compact)
        case .large: self.init(kind: .standard)
        case .xlarge: self.init(kind: .full)
        }
    }

    func scaled(_ factor: CGFloat) -> TimelineDensity { var d = TimelineDensity(kind: .full); d.scale = factor; d.wide = true; return d }

    var ribbonHeight: CGFloat { kind == .compact ? 16 : 22 }
    static let laneHeight: CGFloat = 14
    /// The suggestions bar carries 11-point icons, so it is a little taller than the prompt lane.
    static let adviceHeight: CGFloat = 17
    var mainHeight: CGFloat { (kind == .compact ? 150 : kind == .standard ? 190 : 250) * scale }
    var panelHeight: CGFloat { (kind == .full ? 100 : kind == .standard ? 78 : 60) * scale }
    var cumulativeHeight: CGFloat { (kind == .compact ? 56 : kind == .standard ? 72 : 90) * scale }
    /// The strip above every chart that says what it is. It is also the visual break between charts.
    var headerHeight: CGFloat { kind == .compact ? 24 : 28 }
    var showsLabels: Bool { kind != .compact }
    var plotWidth: Double { wide ? 1800 : kind == .compact ? 300 : kind == .standard ? 520 : 900 }
    static let spacing: CGFloat = 2
}

/// A call with its slot in the full call list, which is its position on the Calls axis.
struct IndexedCall: Identifiable {
    let index: Int
    let call: CallPoint
    var id: String { call.id }
}

/// The session's context window, model, caching and cost on one shared axis, for deciding when to compact or clear.
/// Zoom with the slider or by dragging a box on the charts. Any measure can be overlaid on the context chart; the ones
/// that are not get their own panel underneath. Resting on a slice opens a card with everything about it.
struct SessionTimelineView: View {
    @EnvironmentObject var store: UsageStore
    let sessionID: String
    let timeline: SessionTimeline
    /// A maximized chart: full density, no advice card, panels stretched to `availableHeight`.
    var focus = false
    var availableHeight: CGFloat = 0
    /// A maximized chart has its own pointer state, so it and the copy on the page do not fight over one.
    var injectedHover: TimelineHover?

    private var hover: TimelineHover { injectedHover ?? store.timelineHover }

    private static let layerNames = ["Cache read", "Cache write", "Uncached input"]
    private static let costNames = ["Cache reads", "Cache writes", "Output", "Input"]

    private var density: TimelineDensity {
        guard focus else { return TimelineDensity(store.size) }
        // Everything outside the data panels (title, readout, banner, chips, legend, headers, ribbon) takes about this much.
        let base = TimelineDensity.full
        // Lane charts stretch with the panels; each lane's header and the gaps around it do not.
        let overhead: CGFloat = 400 + CGFloat(lanes.present.count) * (base.headerHeight + 2 * TimelineDensity.spacing)
        let variable = base.mainHeight + separate.reduce(CGFloat(0)) { $0 + (($1 == .cumulative) ? base.cumulativeHeight : base.panelHeight) }
            + lanes.present.reduce(CGFloat(0)) { $0 + lanes.laneHeight($1, density: base) }
        let factor = availableHeight > 0 ? min(max((availableHeight - overhead) / max(variable, 1), 1), 3) : 1
        return base.scaled(factor)
    }
    private var geo: TimelineGeometry {
        let auto = timeline.end.timeIntervalSince(timeline.start) > 36 * 3600 ? TimelineAxis.calls : .time
        return TimelineGeometry(timeline: timeline, byCalls: (store.timelineAxis ?? auto) == .calls, window: store.timelineWindow)
    }
    private var isLive: Bool { store.dashboard?.live.contains { $0.id == sessionID } ?? false }
    private var ticksWanted: Int { density == .compact ? 4 : density == .standard ? 6 : 9 }

    /// Series that have their own panel: everything not overlaid on the context chart.
    private var separate: [TimelineSeries] { TimelineSeries.allCases.filter { !store.overlays.contains($0) } }

    /// Loop, sub-agent, test and plugin lanes for this session. Cached in the store, so a redraw does not rebuild them.
    private var lanes: FeatureLanes { store.featureLanes(sessionID: sessionID, timeline: timeline) }

    /// Where the compact advisor would have spoken, for the suggestions bar. Cached in the store.
    private var advice: [AdviceMarker] { store.adviceMarkers(sessionID: sessionID, timeline: timeline) }

    private func height(of series: TimelineSeries) -> CGFloat { series == .cumulative ? density.cumulativeHeight : density.panelHeight }

    /// The vertical layout, described once: the same items build the views and give the pointer its bands.
    private var layout: TimelineStackLayout {
        var items: [StackItem] = [
            .init(kind: .header, height: 20), .init(kind: .ribbon, height: density.ribbonHeight),
            .init(kind: .prompts, height: TimelineDensity.laneHeight),
        ]
        if !advice.isEmpty { items.append(.init(kind: .advice, height: TimelineDensity.adviceHeight)) }
        items += [.init(kind: .header, height: density.headerHeight), .init(kind: .data, height: density.mainHeight, overlay: true)]
        for series in separate { items += [.init(kind: .header, height: density.headerHeight), .init(kind: .data, height: height(of: series))] }
        items += lanes.stackItems(density: density)
        return TimelineStackLayout(items: items, spacing: TimelineDensity.spacing)
    }

    var body: some View {
        if timeline.mainCalls.isEmpty {
            Text("No responses recorded for this session yet.").font(.callout).foregroundStyle(.secondary)
        } else {
            let g = geo
            VStack(alignment: .leading, spacing: 10) {
                titleRow(g)
                if focus {
                    EmptyView()
                } else if isLive, let advice = CompactAdvisor.advise(timeline: timeline, now: Date()) {
                    AdvisorCard(advice: advice, showsDetail: density != .compact)
                } else {
                    EndedSummary(timeline: timeline)
                }
                TimelineReadout(hover: hover, timeline: timeline, density: density)
                windowBanner(g)
                overlayChips(g)
                eventLegend
                chartStack(g)
                xLabels(g)
            }
        }
    }

    // MARK: title, zoom and the window

    private func titleRow(_ g: TimelineGeometry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Context window and cost").font(.headline)
                Spacer(minLength: 8)
                zoomSlider(g).frame(width: 190)
                axisPicker(g)
                if !focus { MaximizeButton(spec: ChartSpec(kind: .timeline, target: .session(sessionID))) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Context window and cost").font(.headline); Spacer(minLength: 8); axisPicker(g)
                    if !focus { MaximizeButton(spec: ChartSpec(kind: .timeline, target: .session(sessionID))) }
                }
                zoomSlider(g)
            }
        }
    }

    private func axisPicker(_ g: TimelineGeometry) -> some View {
        Picker("Axis", selection: Binding(get: { g.byCalls ? TimelineAxis.calls : .time }, set: { store.timelineAxis = $0 })) {
            ForEach(TimelineAxis.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 110)
        .help("Time shows idle gaps, which is when the prompt cache expires. Calls spaces every response evenly.")
    }

    /// Log-scaled, so each step of the slider is the same multiple. Starting from the whole session it zooms in on the
    /// most recent activity, which is where the decision about compacting is made; from there it zooms around the middle of the view.
    private func zoomSlider(_ g: TimelineGeometry) -> some View {
        let top = log(TimelineGeometry.maxZoom)
        let binding = Binding<Double>(
            get: { log(max(g.zoomFactor, 1)) / top },
            set: { value in
                let factor = exp(value * top)
                store.timelineWindow = factor < 1.04 ? nil : g.window(zoomFactor: factor, anchor: g.isZoomed ? nil : g.fullDomain.upperBound)
            })
        return HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass").font(.caption).foregroundStyle(.secondary)
            Slider(value: binding, in: 0...1).controlSize(.small)
            Image(systemName: "plus.magnifyingglass").font(.caption).foregroundStyle(.secondary)
            Text(g.isZoomed ? String(format: "%.0f×", g.zoomFactor) : "1×").font(.caption.weight(.medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .help("Zoom in on part of the session. You can also drag a box across the charts.")
    }

    /// Always says which stretch of time the charts show, so a zoomed view is never mistaken for the whole session.
    private func windowBanner(_ g: TimelineGeometry) -> some View {
        let shown = g.visibleCalls.count
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: g.isZoomed ? "scope" : "clock").foregroundStyle(g.isZoomed ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(g.isZoomed ? "Zoomed to" : "Whole session")  \(Fmt.range(g.visibleStart, g.visibleEnd))").font(.callout.weight(.semibold)).lineLimit(2)
                Text("\(Fmt.spanLength(g.visibleEnd.timeIntervalSince(g.visibleStart))) · \(g.isZoomed ? "\(shown) of \(timeline.calls.count)" : "\(shown)") calls · \(Fmt.money(g.visibleCost))\(g.isZoomed ? " of \(Fmt.money(timeline.totalCost))" : " total")")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if g.isZoomed {
                Button { store.timelineWindow = g.panned(by: -0.5) } label: { Image(systemName: "chevron.left") }.help("Move the view earlier")
                Button { store.timelineWindow = g.panned(by: 0.5) } label: { Image(systemName: "chevron.right") }.help("Move the view later")
                Button("Show all") { store.timelineWindow = nil }.help("Back to the whole session (or double-click the charts)")
            } else {
                Text("Drag a box on the charts to zoom").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(g.isZoomed ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.04)))
    }

    // MARK: overlay selection

    private func peak(of series: TimelineSeries, _ g: TimelineGeometry) -> Double {
        let visible = g.visibleCalls.map { timeline.calls[$0] }
        switch series {
        case .output: return Double(visible.map(\.output).max() ?? 0)
        case .costPerCall: return visible.map(\.cost).max() ?? 0
        case .cumulative: return g.visibleCost
        }
    }

    private func peakText(_ series: TimelineSeries, _ g: TimelineGeometry) -> String {
        let p = peak(of: series, g)
        return series == .output ? Fmt.tokens(Int(p)) : Fmt.money(p)
    }

    /// Checkboxes for what to draw on the context chart. A measure left unchecked keeps its own panel below.
    private func overlayChips(_ g: TimelineGeometry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Overlay on the context chart").font(.caption.weight(.semibold))
                Text("unchecked ones get their own panel below").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                Button("All") { store.overlays = Set(TimelineSeries.allCases) }.disabled(store.overlays.count == TimelineSeries.allCases.count)
                Button("None") { store.overlays = [] }.disabled(store.overlays.isEmpty)
            }
            .buttonStyle(.borderless).font(.caption)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { ForEach(TimelineSeries.allCases) { series in chip(series, g) } }
                VStack(alignment: .leading, spacing: 5) { ForEach(TimelineSeries.allCases) { series in chip(series, g) } }
            }
            featureOverlayToggle
        }
    }

    /// Draws the prompts, suggestions and the lanes' markers (loop, sub-agent, test) on the context chart too. Off by default;
    /// the bars and lanes around the chart always show them. The chips pick what is drawn.
    private var featureOverlayToggle: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $store.featureOverlayOn) { Text("Overlay lanes on the context chart").font(.caption.weight(.semibold)) }
                .toggleStyle(.switch).controlSize(.mini)
            if store.featureOverlayOn {
                overlayChip("Prompts", color: Theme.accent, on: $store.promptOverlayOn)
                if !advice.isEmpty { overlayChip("Suggestions", color: Theme.caution, on: $store.suggestionOverlayOn) }
                ForEach(lanes.present.filter(\.canOverlay)) { lane in laneChip(lane) }
            }
            Spacer(minLength: 0)
        }
    }

    private func overlayChip(_ title: String, color: Color, on: Binding<Bool>) -> some View {
        chipLabel(title, color: color, on: on.wrappedValue) { on.wrappedValue.toggle() }
    }

    private func chipLabel(_ title: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(color)
                Text(title).fontWeight(.medium)
            }
            .font(.caption).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(on ? color.opacity(0.14) : Color.clear))
            .overlay(Capsule().stroke(on ? color : Color.primary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func laneChip(_ lane: FeatureLane) -> some View {
        let on = store.featureOverlayLanes.contains(lane)
        return chipLabel(lane.title, color: lane.color, on: on) {
            if on { store.featureOverlayLanes.remove(lane) } else { store.featureOverlayLanes.insert(lane) }
        }
    }

    private func chip(_ series: TimelineSeries, _ g: TimelineGeometry) -> some View {
        let on = store.overlays.contains(series)
        return Button {
            if on { store.overlays.remove(series) } else { store.overlays.insert(series) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(series.color)
                Text(series.rawValue).fontWeight(.medium)
                if on { Text("0–\(peakText(series, g))").foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.caption).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(on ? series.color.opacity(0.14) : Color.clear))
            .overlay(Capsule().stroke(on ? series.color : Color.primary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(on ? "Drawn on the context chart, scaled from 0 to its own peak in view. Click to give it its own panel."
                 : "Has its own panel below. Click to draw it on the context chart instead.")
    }

    private var eventLegend: some View {
        HStack(spacing: 14) {
            line("Prompt", dash: nil, width: 1, opacity: 0.45, tall: false)
            HStack(spacing: 5) { Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.good); Text("Turn end") }
            line("Compact", dash: nil, width: 1.5, opacity: 0.8, tall: true)
            line("Clear", dash: [3, 3], width: 1.5, opacity: 0.8, tall: true)
            swatch(Color.primary.opacity(0.14), density == .compact ? "Expired" : "Cache expired")
        }
        .lineLimit(1)
        .font(.caption).foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10); Text(text) }
    }

    private func line(_ text: String, dash: [CGFloat]?, width: CGFloat, opacity: Double, tall: Bool) -> some View {
        HStack(spacing: 5) {
            Path { p in p.move(to: CGPoint(x: 1, y: 0)); p.addLine(to: CGPoint(x: 1, y: tall ? 11 : 7)) }
                .stroke(Color.primary.opacity(opacity), style: StrokeStyle(lineWidth: width, dash: dash ?? []))
                .frame(width: 3, height: 11)
            Text(text)
        }
    }

    // MARK: the stack of aligned panels

    private func chartStack(_ g: TimelineGeometry) -> some View {
        let height = density.headerHeight
        return VStack(spacing: TimelineDensity.spacing) {
            sectionLabel("Model in use, and the prompts you typed", blurb: density == .compact ? "" : (advice.isEmpty ? "bar colors are models; each tick is a prompt" : "bar colors are models; each tick is a prompt; each icon is a suggestion"), height: 20, divider: false)
            modelRibbon(g)
            promptLane(g)
            if !advice.isEmpty { adviceLane(g) }
            panelHeader("Context window", color: Theme.ramp[2], blurb: density == .compact ? "" : "tokens held in the conversation each call", height: height) { mainLegend(g) }
            mainChart(g)
            ForEach(separate) { series in
                panelHeader(title(of: series, g), color: series.color, blurb: density == .compact ? "" : blurb(of: series, g), height: height) { seriesLegend(series, g) }
                separatePanel(series, g)
            }
            if !lanes.isEmpty { FeatureLaneStack(lanes: lanes, geometry: g, density: density) }
        }
        .coordinateSpace(name: "timelineStack")
        .background(GeometryReader { box in
            Color.clear
                .onAppear { hover.containerSize = box.size }
                .onChange(of: box.size) { _, size in hover.containerSize = size }
        })
        // One AppKit surface handles hover, the drag-to-zoom box, double-click and sideways scrolling. See PointerSurface for why
        // these are not SwiftUI gestures.
        .overlay { pointerSurface(g) }
        // The crosshair and cards live in an overlay that observes the hover model, so the charts above never redraw.
        .overlay(alignment: .topLeading) {
            TimelineHoverOverlay(hover: hover, timeline: timeline, geometry: g, bands: layout.bands, lanes: lanes, advice: advice)
        }
    }

    private func pointerSurface(_ g: TimelineGeometry) -> some View {
        PointerSurface(
            onMove: { pointerMoved($0, g) },
            onExit: { hover.pointerLeft() },
            onDrag: { start, current in
                hover.select(max(min(start.x, current.x), 0)...max(max(start.x, current.x), 0))
            },
            onDragEnd: { start, end in
                hover.select(nil)
                let width = Double(hover.containerSize.width)
                guard width > 0 else { return }
                let a = TimelineHitTester.x(atPixel: Double(start.x), width: width, geometry: g)
                let b = TimelineHitTester.x(atPixel: Double(end.x), width: width, geometry: g)
                if let window = g.window(selecting: a, b) { store.timelineWindow = window }
            },
            onDoubleClick: { store.timelineWindow = nil },
            onScroll: { points in scrolled(points) })
    }

    /// Sideways scroll, in points, from the live window (not a captured copy), so rapid events build on each other.
    private func scrolled(_ points: CGFloat) -> CGFloat {
        let width = Double(hover.containerSize.width)
        guard let result = geo.panned(byPoints: Double(points), ofWidth: width) else { return points }  // not zoomed: nothing to keep
        if result.window != store.timelineWindow { store.timelineWindow = result.window }
        return CGFloat(result.consumed)
    }

    private func pointerMoved(_ point: CGPoint, _ g: TimelineGeometry) {
        let width = Double(hover.containerSize.width)
        let bands = layout.bands
        guard width > 0, let first = bands.first, let last = bands.last, Double(point.y) >= first.minY, Double(point.y) <= last.maxY else {
            hover.pointerLeft()
            return
        }
        let target = TimelineHitTester.target(atX: Double(point.x), y: Double(point.y), width: width, bands: bands, geometry: g, lanes: lanes,
            overlay: store.featureOverlayOn ? store.featureOverlayLanes : [], advice: advice,
            adviceOverlaid: store.featureOverlayOn && store.suggestionOverlayOn, turnEnds: timeline.turnEnds)
        let x = TimelineHitTester.x(atPixel: Double(point.x), width: width, geometry: g)
        hover.pointerMoved(to: point, target: target, focus: g.nearestCall(to: x))
    }

    // MARK: headers: what each chart is

    private func sectionLabel(_ title: String, blurb: String, height: CGFloat, divider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if divider { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                if !blurb.isEmpty { Text(blurb).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)
        }
        .frame(height: height)
    }

    /// Title bar above a chart: a swatch in the chart's own color, its name, what it measures, and its key.
    /// The hairline above it and the extra space are the visual break between charts.
    private func panelHeader<T: View>(_ title: String, color: Color, blurb: String, height: CGFloat, @ViewBuilder legend: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                if !blurb.isEmpty { Text(blurb).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 6)
                legend().font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.bottom, 3)
        }
        .frame(height: height)
    }

    private func mainLegend(_ g: TimelineGeometry) -> some View {
        let compact = density == .compact
        return HStack(spacing: 8) {
            swatch(Theme.ramp[0], compact ? "Read" : "Cache read")
            swatch(Theme.ramp[1], compact ? "Write" : "Cache write")
            swatch(Theme.ramp[3], compact ? "Uncached" : "Uncached input")
        }
    }

    private func title(of series: TimelineSeries, _ g: TimelineGeometry) -> String {
        series == .cumulative && g.isZoomed ? "Spend in this view" : series.rawValue
    }

    private func blurb(of series: TimelineSeries, _ g: TimelineGeometry) -> String {
        series == .cumulative && g.isZoomed ? "running total from $0 at the left edge of the view" : series.blurb
    }

    @ViewBuilder private func seriesLegend(_ series: TimelineSeries, _ g: TimelineGeometry) -> some View {
        switch series {
        case .output:
            HStack(spacing: 8) { swatch(Theme.seriesOutput, "Output"); swatch(Theme.seriesOutput.opacity(0.45), "Thinking") }
        case .costPerCall:
            HStack(spacing: 8) {
                ForEach(Array(Self.costNames.enumerated()), id: \.offset) { i, name in swatch(Theme.billedRamp[i], density == .compact ? String(name.split(separator: " ").last ?? "") : name) }
            }
        case .cumulative:
            Text("peak \(peakText(.cumulative, g))").monospacedDigit()
        }
    }

    // MARK: data helpers

    /// The calls to draw: those in view plus one either side, so lines run to the edge of the plot instead of stopping short.
    private func drawn(_ g: TimelineGeometry) -> [IndexedCall] {
        guard g.isZoomed else { return timeline.calls.enumerated().map { IndexedCall(index: $0.offset, call: $0.element) } }
        let visible = g.visibleCalls
        guard let first = visible.first, let last = visible.last else { return [] }
        return (max(first - 1, 0)...min(last + 1, timeline.calls.count - 1)).map { IndexedCall(index: $0, call: timeline.calls[$0]) }
    }

    /// Spend before the first call in view, so the cumulative panel can restart at $0 at the left edge when zoomed.
    private func spendBeforeView(_ g: TimelineGeometry) -> Double {
        guard g.isZoomed, let first = g.visibleCalls.first, first > 0 else { return 0 }
        return timeline.calls[first - 1].cumulativeCost
    }

    private func cumulativeValue(_ call: CallPoint, base: Double) -> Double { max(0, call.cumulativeCost - base) }

    private func inView(_ x: Double, _ g: TimelineGeometry) -> Bool { g.domain.contains(x) }

    // MARK: ribbon and prompts

    private func modelRibbon(_ g: TimelineGeometry) -> some View {
        let d = g.domain
        let spans: [(span: ModelSpan, range: ClosedRange<Double>)] = timeline.modelSpans.compactMap { span in
            let r = g.xRange(of: span)
            let lo = max(r.lowerBound, d.lowerBound), hi = min(r.upperBound, d.upperBound)
            return lo < hi ? (span, lo...hi) : nil
        }
        return Chart {
            ForEach(spans, id: \.span.id) { item in
                let family = ModelFamily(modelID: item.span.model)
                RectangleMark(
                    xStart: .value("From", item.range.lowerBound), xEnd: .value("To", item.range.upperBound),
                    yStart: .value("Bottom", 0), yEnd: .value("Top", 1)
                )
                .foregroundStyle(Theme.color(family)).cornerRadius(3)
                .annotation(position: .overlay, alignment: .leading) {
                    if density.showsLabels {
                        Text(ModelFamily.displayName(modelID: item.span.model))
                            .font(.caption2.weight(.semibold)).lineLimit(1).padding(.leading, 5)
                            .foregroundStyle(family == .haiku || family == .other ? Color.black.opacity(0.85) : Color.white)
                    }
                }
            }
            ForEach(timeline.modelSpans.dropFirst().filter { inView(g.x(time: $0.start), g) }) { span in
                RuleMark(x: .value("Boundary", g.x(time: span.start))).foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .panel(g, ticks: g.ticks(maxTicks: ticksWanted))
        .chartYScale(domain: 0...1)
        .frame(height: density.ribbonHeight)
    }

    /// Prompts as full-height ticks, and under them each turn: a thin line from the prompt to the moment the main thread
    /// finished answering, ending in a circle. Hover the circle for the turn's duration, tools and tokens.
    private func promptLane(_ g: TimelineGeometry) -> some View {
        let prompts = timeline.markers.filter { if case .prompt = $0.kind { inView(g.x(time: $0.time), g) } else { false } }
        let promptTimes = timeline.markers.compactMap { m -> Date? in if case .prompt = m.kind { m.time } else { nil } }
        let ends = timeline.turnEnds.filter { inView(g.x(time: $0.time), g) }
        return Chart {
            ForEach(ends) { end in
                let start = promptTimes[end.turn - 1]
                RuleMark(xStart: .value("Prompt", g.x(time: start)), xEnd: .value("Turn end", g.x(time: end.time)), y: .value("Row", 0.25))
                    .foregroundStyle(Theme.good.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(prompts) { m in
                RuleMark(x: .value("Prompt", g.x(time: m.time)), yStart: .value("Bottom", 0), yEnd: .value("Top", 1))
                    .foregroundStyle(Color.primary.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(ends) { end in
                PointMark(x: .value("Turn end", g.x(time: end.time)), y: .value("Row", 0.25)).opacity(0)
                    .annotation(position: .overlay) { Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.good) }
            }
        }
        .panel(g, ticks: g.ticks(maxTicks: ticksWanted))
        .chartYScale(domain: 0...1)
        .frame(height: TimelineDensity.laneHeight)
    }

    /// An event bar of the moments the advisor would have suggested compacting or clearing. Hover an icon for what it said.
    private func adviceLane(_ g: TimelineGeometry) -> some View {
        let shown = advice.filter { inView(g.x(time: $0.time), g) }
        return Chart {
            ForEach(shown) { m in
                PointMark(x: .value("Suggestion", g.x(time: m.time)), y: .value("Row", 0.5)).opacity(0)
                    .annotation(position: .overlay) { laneIcon(m.level.symbol, m.level.color) }
            }
        }
        .panel(g, ticks: g.ticks(maxTicks: ticksWanted))
        .chartYScale(domain: 0...1)
        .frame(height: TimelineDensity.adviceHeight)
    }

    // MARK: the context chart, with overlays

    private func mainChart(_ g: TimelineGeometry) -> some View {
        let main = drawn(g).filter { !$0.call.isSidechain }
        let visibleMain = g.visibleCalls.map { timeline.calls[$0] }.filter { !$0.isSidechain }
        let peakContext = visibleMain.map(\.contextTokens).max() ?? 0
        let yTicks = NiceScale.ticks(max: Double(max(peakContext, 1)) * 1.05)
        let top = yTicks.last ?? 1
        let layers: [(String, KeyPath<CallPoint, Int>)] = [("Cache read", \.cacheRead), ("Cache write", \.cacheWrite), ("Uncached input", \.freshInput)]
        let overlaid = TimelineSeries.allCases.filter { store.overlays.contains($0) }
        let base = spendBeforeView(g)
        let scaled = drawn(g)
        return Chart {
            expiredBands(g, top: top)
            ForEach(yTicks, id: \.self) { RuleMark(y: .value("Tick", $0)).foregroundStyle(Color.primary.opacity(0.08)).lineStyle(StrokeStyle(lineWidth: 0.5)) }
            ForEach(layers, id: \.0) { name, key in
                ForEach(main) { item in
                    AreaMark(x: .value("When", g.x(callIndex: item.index)), y: .value("Tokens", item.call[keyPath: key]), series: .value("Layer", name))
                        .foregroundStyle(by: .value("Layer", name)).interpolationMethod(.stepEnd)
                }
            }
            if Double(timeline.contextWindow) <= top {
                RuleMark(y: .value("Window", timeline.contextWindow)).foregroundStyle(Color.primary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("window \(Fmt.tokens(timeline.contextWindow))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            ForEach(overlaid) { series in
                overlayLine(series, calls: scaled, top: top, peak: peak(of: series, g), base: base, g: g)
            }
            if store.featureOverlayOn, store.promptOverlayOn { promptRules(g) }
            if store.featureOverlayOn, store.suggestionOverlayOn { adviceOverlayMarks(g, top: top) }
            if store.featureOverlayOn { featureOverlayMarks(lanes, selected: store.featureOverlayLanes, g: g, top: top) }
            eventRules(g, labels: density.showsLabels)
        }
        .chartForegroundStyleScale(domain: Self.layerNames, range: [Theme.ramp[0], Theme.ramp[1], Theme.ramp[3]])
        .chartLegend(.hidden)
        .panel(g, ticks: g.ticks(maxTicks: ticksWanted))
        .chartYScale(domain: 0...top)
        .yLabels(yTicks, format: { Fmt.tokens(Int($0)) })
        .frame(height: density.mainHeight)
    }

    /// A measure drawn over the context chart, scaled so its own peak reaches the top. Two real scales on one axis would
    /// mislead, so this is a shape-only view: the peak is printed in the chip and in the hover card has the true values.
    @ChartContentBuilder private func overlayLine(_ series: TimelineSeries, calls: [IndexedCall], top: Double, peak: Double, base: Double, g: TimelineGeometry) -> some ChartContent {
        let scale = peak > 0 ? top / peak : 0
        ForEach(calls) { item in
            LineMark(
                x: .value("When", g.x(callIndex: item.index)), y: .value(series.rawValue, value(series, item.call, base: base) * scale),
                series: .value("Series", series.rawValue)
            )
            .foregroundStyle(series.color).lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            .interpolationMethod(series == .cumulative ? .stepEnd : .linear)
        }
        if series != .cumulative, calls.count <= 90 {
            ForEach(calls) { item in
                PointMark(x: .value("When", g.x(callIndex: item.index)), y: .value(series.rawValue, value(series, item.call, base: base) * scale))
                    .symbolSize(14).foregroundStyle(series.color)
            }
        }
    }

    private func value(_ series: TimelineSeries, _ call: CallPoint, base: Double) -> Double {
        switch series {
        case .output: Double(call.output)
        case .costPerCall: call.cost
        case .cumulative: cumulativeValue(call, base: base)
        }
    }

    // MARK: separate panels

    @ViewBuilder private func separatePanel(_ series: TimelineSeries, _ g: TimelineGeometry) -> some View {
        switch series {
        case .output: outputPanel(g)
        case .costPerCall: costPanel(g)
        case .cumulative: cumulativePanel(g)
        }
    }

    private func barWidth(count: Int, zoomed: Bool) -> CGFloat {
        CGFloat(min(zoomed ? 12 : 6, max(1.5, density.plotWidth / Double(max(count, 1)) * 0.75)))
    }

    private func outputPanel(_ g: TimelineGeometry) -> some View {
        let calls = drawn(g)
        let visible = g.visibleCalls.map { timeline.calls[$0] }
        // The axis top must come from the same ticks that are drawn, or the top label lands outside its own panel.
        let yTicks = NiceScale.ticks(max: Double(visible.map(\.output).max() ?? 0) * 1.05, count: 2)
        let top = yTicks.last ?? 1
        let width = barWidth(count: max(visible.count, 1), zoomed: g.isZoomed)
        return Chart {
            ForEach(yTicks, id: \.self) { RuleMark(y: .value("Tick", $0)).foregroundStyle(Color.primary.opacity(0.08)).lineStyle(StrokeStyle(lineWidth: 0.5)) }
            ForEach(calls) { item in
                BarMark(x: .value("When", g.x(callIndex: item.index)), y: .value("Tokens", item.call.visibleOutput), width: .fixed(width))
                    .foregroundStyle(by: .value("Kind", "Output"))
                BarMark(x: .value("When", g.x(callIndex: item.index)), y: .value("Tokens", item.call.thinkingTokens), width: .fixed(width))
                    .foregroundStyle(by: .value("Kind", "Thinking"))
            }
            eventRules(g, labels: false, faint: true)
        }
        .chartForegroundStyleScale(domain: ["Output", "Thinking"], range: [Theme.seriesOutput, Theme.seriesOutput.opacity(0.45)])
        .chartLegend(.hidden)
        .panel(g, ticks: g.ticks(maxTicks: ticksWanted))
        .chartYScale(domain: 0...top)
        .yLabels(yTicks, format: { "\(Fmt.tokens(Int($0))) out" })
        .frame(height: density.panelHeight)
    }

    private func costPanel(_ g: TimelineGeometry) -> some View {
        let calls = drawn(g)
        let visible = g.visibleCalls.map { timeline.calls[$0] }
        let yTicks = NiceScale.ticks(max: (visible.map(\.cost).max() ?? 0) * 1.05, count: 2)
        let top = yTicks.last ?? 1
        let width = barWidth(count: max(visible.count, 1), zoomed: g.isZoomed)
        return Chart {
            ForEach(yTicks, id: \.self) { RuleMark(y: .value("Tick", $0)).foregroundStyle(Color.primary.opacity(0.08)).lineStyle(StrokeStyle(lineWidth: 0.5)) }
            ForEach(calls) { item in
                let x = g.x(callIndex: item.index)
                let p = item.call.costParts
                let parts = [p.cacheRead, p.cacheWrite, p.output, p.input]
                ForEach(Array(Self.costNames.enumerated()), id: \.offset) { i, name in
                    BarMark(x: .value("When", x), y: .value("Cost", parts[i]), width: .fixed(width))
                        .foregroundStyle(by: .value("Billed as", name))
                        .opacity(item.call.isSidechain ? 0.4 : 1)
                }
            }
            eventRules(g, labels: false, faint: true)
        }
        .chartForegroundStyleScale(domain: Self.costNames, range: Theme.billedRamp)
        .chartLegend(.hidden)
        .panel(g, ticks: g.ticks(maxTicks: ticksWanted))
        .chartYScale(domain: 0...top)
        .yLabels(yTicks, format: { Fmt.axisMoney($0) + "/call" })
        .frame(height: density.panelHeight)
    }

    /// Spend so far as a step line, in its own panel: it is dollars on a different scale from cost per call, and two
    /// scales on one axis would mislead. When zoomed it restarts at $0 at the left edge, so a short window shows what
    /// was spent in it rather than a flat line near the session total. The running total labels the end of the line.
    private func cumulativePanel(_ g: TimelineGeometry) -> some View {
        let calls = drawn(g)
        let base = spendBeforeView(g)
        let total = g.visibleCost
        // Barely any headroom: with 5%, a $19 total tips into the next tick and the line only fills half the panel.
        let yTicks = NiceScale.ticks(max: total * 1.01, count: 2)
        let top = yTicks.last ?? 1
        let last = g.visibleCalls.last
        return Chart {
            ForEach(yTicks, id: \.self) { RuleMark(y: .value("Tick", $0)).foregroundStyle(Color.primary.opacity(0.08)).lineStyle(StrokeStyle(lineWidth: 0.5)) }
            ForEach(calls) { item in
                AreaMark(x: .value("When", g.x(callIndex: item.index)), y: .value("Spent", cumulativeValue(item.call, base: base)), series: .value("S", "area"))
                    .foregroundStyle(Theme.seriesCumulative.opacity(0.14)).interpolationMethod(.stepEnd)
            }
            ForEach(calls) { item in
                LineMark(x: .value("When", g.x(callIndex: item.index)), y: .value("Spent", cumulativeValue(item.call, base: base)), series: .value("S", "line"))
                    .foregroundStyle(Theme.seriesCumulative).lineStyle(StrokeStyle(lineWidth: 1.8)).interpolationMethod(.stepEnd)
            }
            eventRules(g, labels: false, faint: true)
            if let last {
                PointMark(x: .value("When", g.x(callIndex: last)), y: .value("Spent", total)).symbolSize(34).foregroundStyle(Theme.seriesCumulative)
                    // Below and to the left: the line ends near the top of its panel, so a label beside it would be clipped.
                    .annotation(position: .bottomLeading, spacing: 2) {
                        Text(Fmt.money(total)).font(.caption2.weight(.semibold)).monospacedDigit()
                    }
            }
        }
        .panel(g, ticks: g.ticks(maxTicks: ticksWanted))
        .chartYScale(domain: 0...top)
        .yLabels(yTicks, format: { Fmt.axisMoney($0) + (g.isZoomed ? " in view" : " total") })
        .frame(height: density.cumulativeHeight)
    }

    private func xLabels(_ g: TimelineGeometry) -> some View {
        let ticks = g.ticks(maxTicks: ticksWanted)
        let d = g.domain
        return GeometryReader { box in
            ForEach(ticks, id: \.self) { t in
                let f = (t - d.lowerBound) / (d.upperBound - d.lowerBound)
                Text(g.label(forX: t)).font(.caption2).foregroundStyle(.secondary).fixedSize()
                    .position(x: min(max(f * box.size.width, 22), box.size.width - 22), y: 7)
            }
        }
        .frame(height: 14)
    }

    // MARK: shared marks

    /// The suggestion icons over the context chart, a thin guide line down from each. Hover one for what it said.
    @ChartContentBuilder private func adviceOverlayMarks(_ g: TimelineGeometry, top: Double) -> some ChartContent {
        ForEach(advice.filter { inView(g.x(time: $0.time), g) }) { m in
            RuleMark(x: .value("Suggestion", g.x(time: m.time)), yStart: .value("Bottom", 0), yEnd: .value("Top", top))
                .foregroundStyle(m.level.color.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
            PointMark(x: .value("Suggestion", g.x(time: m.time)), y: .value("Icon", top * FeatureOverlayLayout.adviceIconFraction)).opacity(0)
                .annotation(position: .overlay) { laneIcon(m.level.symbol, m.level.color) }
        }
    }

    /// A faint dashed line at every prompt you typed, over the context chart.
    @ChartContentBuilder private func promptRules(_ g: TimelineGeometry) -> some ChartContent {
        ForEach(timeline.markers.filter { if case .prompt = $0.kind { inView(g.x(time: $0.time), g) } else { false } }) { m in
            RuleMark(x: .value("Prompt", g.x(time: m.time)))
                .foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    /// Stretches where the cache had expired: from the moment the entry lapsed to the call that had to re-write it.
    @ChartContentBuilder private func expiredBands(_ g: TimelineGeometry, top: Double) -> some ChartContent {
        let calls = timeline.calls
        let d = g.domain
        ForEach(calls.indices.filter { calls[$0].cacheExpired }, id: \.self) { i in
            let previous = previousMain(before: i)
            let start = g.byCalls ? Double(previous) : g.x(time: calls[previous].time.addingTimeInterval(timeline.cacheTTL))
            let end = g.x(callIndex: i)
            if end >= d.lowerBound, start <= d.upperBound {
                RectangleMark(xStart: .value("Expired", start), xEnd: .value("Re-written", end), yStart: .value("Bottom", 0), yEnd: .value("Top", top))
                    .foregroundStyle(Color.primary.opacity(0.07))
            }
        }
    }

    /// Compactions as solid lines and clears as dashed ones. Labels only where there is room.
    @ChartContentBuilder private func eventRules(_ g: TimelineGeometry, labels: Bool, faint: Bool = false) -> some ChartContent {
        ForEach(timeline.markers.filter { isStructural($0) && inView(g.x(time: $0.time), g) }) { m in
            let isClear: Bool = { if case .clear = m.kind { true } else { false } }()
            RuleMark(x: .value("Event", g.x(time: m.time)))
                .foregroundStyle(Color.primary.opacity(faint ? 0.3 : 0.75))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: isClear ? [3, 3] : []))
                // Overlay, not top: an annotation above the rule would sit outside the plot and be clipped by it.
                .annotation(position: .overlay, alignment: .topLeading, spacing: 0) {
                    if labels {
                        Text(label(for: m)).font(.caption2.weight(.medium)).foregroundStyle(.secondary).fixedSize().padding(.leading, 4).padding(.top, 2)
                    }
                }
        }
    }

    private func isStructural(_ m: TimelineMarker) -> Bool {
        switch m.kind {
        case .compact, .clear: true
        default: false
        }
    }

    private func label(for m: TimelineMarker) -> String {
        switch m.kind {
        case .compact(let trigger, let pre, let post, _):
            let sizes = pre.flatMap { a in post.map { b in " \(Fmt.tokens(a))→\(Fmt.tokens(b))" } } ?? ""
            return "compact (\(trigger))\(sizes)"
        case .clear: return "clear"
        default: return ""
        }
    }

    private func previousMain(before i: Int) -> Int {
        (stride(from: i - 1, through: 0, by: -1).first { !timeline.calls[$0].isSidechain }) ?? max(i - 1, 0)
    }
}

// MARK: readout and hover overlay (the only views that observe the pointer)

/// Details for the call under the pointer, or the latest call when nothing is hovered.
struct TimelineReadout: View {
    @ObservedObject var hover: TimelineHover
    let timeline: SessionTimeline
    let density: TimelineDensity

    var body: some View {
        let calls = timeline.calls
        let latest = calls.lastIndex { !$0.isSidechain } ?? calls.count - 1
        let index = min(hover.focusedCall ?? latest, calls.count - 1)
        let c = calls[index]
        let window = timeline.contextWindow
        let share = window > 0 ? Fmt.percent(Double(c.contextTokens) / Double(window) * 100) : "?"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(hover.focusedCall == nil ? "Latest call" : "Call \(index + 1) of \(calls.count)").fontWeight(.semibold)
                Text(c.time.formatted(density == .compact ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute().second()))
                Text("·")
                Circle().fill(Theme.color(ModelFamily(modelID: c.model))).frame(width: 8, height: 8)
                Text(ModelFamily.displayName(modelID: c.model) + (c.effort.map { " · \($0)" } ?? ""))
                if c.isSidechain { Text("sub-agent").foregroundStyle(.secondary) }
            }
            .font(.callout).lineLimit(1).minimumScaleFactor(0.8)
            if density == .compact {
                Text("Context \(Fmt.tokens(c.contextTokens)) (\(share)) · output \(Fmt.tokens(c.output)) · \(Fmt.money(c.cost)) · total \(Fmt.money(c.cumulativeCost))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            } else {
                detailTile(c, share: share, window: window)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Everything about the call in one tile: context, output, cost split by what was billed, and timing.
    private func detailTile(_ c: CallPoint, share: String, window: Int) -> some View {
        let p = c.costParts
        let timing: (String, String) = {
            guard let gap = c.idleGap else { return ("first call", "") }
            return (gap < 60 ? "\(Int(gap))s" : Fmt.duration(Int(gap)), "since the previous call")
        }()
        let cacheState = c.cacheExpired ? "expired, re-written"
            : c.cacheRead > 0 ? "hit \(Fmt.percent(Double(c.cacheRead) / Double(max(c.contextTokens, 1)) * 100))" : "cold"
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .top)], alignment: .leading, spacing: 12) {
                stat("Context", Fmt.tokens(c.contextTokens), "\(share) of \(Fmt.tokens(window))", [
                    ("Cache read", Fmt.tokens(c.cacheRead)), ("Cache write", Fmt.tokens(c.cacheWrite)), ("Uncached input", Fmt.tokens(c.freshInput))])
                stat("Output", Fmt.tokens(c.output), c.thinkingTokens > 0 ? "\(Fmt.tokens(c.thinkingTokens)) thinking" : "", [])
                stat("Cost of this call", Fmt.money(c.cost), "", [
                    ("Cache reads", Fmt.money(p.cacheRead)), ("Cache writes", Fmt.money(p.cacheWrite)),
                    ("Output", Fmt.money(p.output)), ("Input", Fmt.money(p.input))])
                stat("Session so far", Fmt.money(c.cumulativeCost), "", [])
                stat("Timing", timing.0, timing.1, [("Cache", cacheState)])
            }
            if let prompt = promptText(c) {
                Text("Answering prompt \(c.turn): “\(prompt)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }

    private func stat(_ label: String, _ value: String, _ note: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(rows[i].0).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(rows[i].1).monospacedDigit()
                }
                .font(.caption2)
            }
        }
    }

    /// The prompt this call answered, if there is one.
    private func promptText(_ c: CallPoint) -> String? {
        guard c.turn > 0 else { return nil }
        let prompts = timeline.markers.compactMap { m -> String? in if case .prompt(let p) = m.kind { p } else { nil } }
        return c.turn <= prompts.count ? prompts[c.turn - 1] : nil
    }
}

/// The crosshair and the hover cards, drawn above the charts. Observes the hover model so the charts underneath
/// do not have to redraw as the pointer moves.
struct TimelineHoverOverlay: View {
    @ObservedObject var hover: TimelineHover
    let timeline: SessionTimeline
    let geometry: TimelineGeometry
    let bands: [PanelBand]
    let lanes: FeatureLanes
    let advice: [AdviceMarker]

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .topLeading) {
                if let selection = hover.selection {
                    selectionBox(selection, in: box.size)
                }
                if hover.selection == nil, let x = crosshairX(width: box.size.width) {
                    Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 1, height: box.size.height).offset(x: x)
                }
                if let target = hover.shown {
                    let origin = origin(for: target, in: box.size)
                    card(for: target, in: box.size).fixedSize().offset(x: origin.x, y: origin.y)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The box being dragged to zoom, with the stretch it will zoom to written at its top edge.
    private func selectionBox(_ range: ClosedRange<CGFloat>, in size: CGSize) -> some View {
        let width = Double(max(size.width, 1))
        let a = TimelineHitTester.x(atPixel: Double(range.lowerBound), width: width, geometry: geometry)
        let b = TimelineHitTester.x(atPixel: Double(min(range.upperBound, size.width)), width: width, geometry: geometry)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.accent.opacity(0.14)).overlay(Rectangle().stroke(Theme.accent.opacity(0.7), lineWidth: 1))
                .frame(width: max(range.upperBound - range.lowerBound, 1), height: size.height).offset(x: range.lowerBound)
            Text("Zoom to \(geometry.label(forX: a)) – \(geometry.label(forX: b))")
                .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.regularMaterial)).fixedSize()
                .offset(x: min(max(range.lowerBound, 0), max(size.width - 190, 0)), y: 4)
        }
    }

    /// Snaps to the call under the pointer while over a data panel, so the line shows exactly which call is meant.
    private func crosshairX(width: CGFloat) -> CGFloat? {
        if let call = hover.focusedCall, let p = hover.pointer, isOverData(p.y), call < timeline.calls.count {
            return CGFloat(TimelineHitTester.pixel(forX: geometry.x(callIndex: call), width: Double(width), geometry: geometry))
        }
        if hover.pointer == nil, let call = hover.focusedCall, call < timeline.calls.count {  // a preview without a pointer
            return CGFloat(TimelineHitTester.pixel(forX: geometry.x(callIndex: call), width: Double(width), geometry: geometry))
        }
        return hover.pointer?.x
    }

    private func isOverData(_ y: CGFloat) -> Bool { bands.contains { $0.kind == .data && Double(y) >= $0.minY && Double(y) <= $0.maxY } }

    /// Cards are capped to the width of the chart stack, so in a small window they shrink instead of running off its edge.
    @ViewBuilder private func card(for target: HoverTarget, in container: CGSize) -> some View {
        let width = cardWidth(for: target, in: container)
        switch target {
        case .call(let i):
            if i < timeline.calls.count { CallCard(call: timeline.calls[i], index: i, timeline: timeline, width: width) }
        case .marker(let id):
            if let m = timeline.markers.first(where: { $0.id == id }) { MarkerCard(marker: m, timeline: timeline, width: width) }
        case .modelSpan(let id):
            if let s = timeline.modelSpans.first(where: { $0.id == id }) { ModelSpanCard(span: s, timeline: timeline, width: width) }
        case .lane(let target):
            LaneCard(target: target, lanes: lanes, width: width)
        case .advice(let id):
            if let m = advice.first(where: { $0.id == id }) { AdviceCard(marker: m, width: width) }
        case .turnEnd(let n):
            if let end = timeline.turnEnds.first(where: { $0.turn == n }) { TurnEndCard(end: end, width: width) }
        }
    }

    private func cardWidth(for target: HoverTarget, in container: CGSize) -> CGFloat {
        let preferred: CGFloat = { if case .call = target { 320 } else if case .modelSpan = target { 270 } else { 290 } }()
        return max(220, min(preferred, container.width - 8))
    }

    private func size(of target: HoverTarget, in container: CGSize) -> CGSize {
        let height: CGFloat = {
            switch target {
            case .call: 470
            case .modelSpan: 120
            case .lane: 150
            case .advice: 170
            case .turnEnd: 120
            default: 130
            }
        }()
        return CGSize(width: cardWidth(for: target, in: container), height: height)
    }

    /// Below and to the right of the pointer, flipping to the other side near an edge. Without a pointer (a preview),
    /// the card is anchored to the thing it describes.
    private func origin(for target: HoverTarget, in container: CGSize) -> CGPoint {
        let card = size(of: target, in: container)
        let anchor = hover.shownLocation.x >= 0 ? hover.shownLocation : previewAnchor(for: target, in: container)
        var x = anchor.x + 16
        if x + card.width > container.width - 4 { x = anchor.x - 16 - card.width }
        var y = anchor.y + 18
        if y + card.height > container.height + 40 { y = anchor.y - 12 - card.height }
        return CGPoint(x: max(4, x), y: max(-card.height + 20, y))
    }

    private func previewAnchor(for target: HoverTarget, in container: CGSize) -> CGPoint {
        let width = Double(container.width)
        switch target {
        case .call(let i):
            return CGPoint(x: TimelineHitTester.pixel(forX: geometry.x(callIndex: i), width: width, geometry: geometry), y: container.height * 0.35)
        case .marker(let id):
            let t = timeline.markers.first { $0.id == id }?.time ?? timeline.start
            return CGPoint(x: TimelineHitTester.pixel(forX: geometry.x(time: t), width: width, geometry: geometry), y: 28)
        case .modelSpan(let id):
            let span = timeline.modelSpans.first { $0.id == id }
            let mid = span.map { (geometry.xRange(of: $0).lowerBound + geometry.xRange(of: $0).upperBound) / 2 } ?? 0
            return CGPoint(x: TimelineHitTester.pixel(forX: mid, width: width, geometry: geometry), y: 10)
        case .lane:
            return CGPoint(x: width / 2, y: container.height - 40)
        case .advice(let id):
            let t = advice.first { $0.id == id }?.time ?? timeline.start
            return CGPoint(x: TimelineHitTester.pixel(forX: geometry.x(time: t), width: width, geometry: geometry), y: 40)
        case .turnEnd(let n):
            let t = timeline.turnEnds.first { $0.turn == n }?.time ?? timeline.start
            return CGPoint(x: TimelineHitTester.pixel(forX: geometry.x(time: t), width: width, geometry: geometry), y: 40)
        }
    }
}

// MARK: chart styling shared by every panel

extension View {
    /// The same x-scale and faint vertical grid on every panel, with no axis labels of its own: y labels sit inside the
    /// plot and x labels are drawn once underneath, so the panels line up exactly. Hover is handled by the stack, not here.
    func panel(_ g: TimelineGeometry, ticks: [Double]) -> some View {
        self
            .chartXScale(domain: g.domain)
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks(values: ticks) { AxisGridLine().foregroundStyle(Color.primary.opacity(0.06)) } }
            .chartPlotStyle { $0.background(Color.primary.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 4)) }
    }

    /// Y labels drawn inside the plot, at the left, just above their gridline.
    func yLabels(_ ticks: [Double], format: @escaping (Double) -> String) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                if let frame = proxy.plotFrame {
                    ZStack(alignment: .topLeading) {
                        ForEach(ticks, id: \.self) { t in
                            if let y = proxy.position(forY: t) {
                                Text(format(t)).font(.system(size: 9)).foregroundStyle(.secondary)
                                    // Above its gridline, except for a tick at the very top of the plot, which goes below it
                                    // so the label stays inside its own panel instead of landing on the chart above.
                                    .offset(x: geo[frame].minX + 4, y: geo[frame].minY + (y < 14 ? y + 1 : y - 12))
                            }
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: advice and summary

/// The cost-based nudge: what carrying this context costs now, what compacting would cost, and whether the cache is warm.
struct AdvisorCard: View {
    let advice: CompactAdvice
    var showsDetail = true

    private var tint: Color {
        switch advice.level {
        case .fine: Color.secondary
        case .consider, .coldCache: Theme.accent
        case .compactSoon: Theme.caution
        }
    }
    private var icon: String {
        switch advice.level {
        case .fine: "checkmark.circle"
        case .consider: "lightbulb"
        case .compactSoon: "gauge.with.dots.needle.67percent"
        case .coldCache: "snowflake"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(advice.headline).font(.headline)
                if showsDetail { Text(advice.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text(facts).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help((showsDetail ? "" : advice.detail + " ") + "Estimates from list prices. The size after compacting is \(advice.postCompactSource == .observed ? "the median of this session's own compactions" : "assumed to be about 20K tokens").")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
    }

    private var facts: String {
        let expiry = advice.cacheIsCold
            ? "cache expired \(advice.cacheExpiresAt.formatted(.relative(presentation: .named)))"
            : "cache warm until \(advice.cacheExpiresAt.formatted(date: .omitted, time: .shortened))"
        return "\(Fmt.tokens(advice.contextTokens)) of \(Fmt.tokens(advice.windowTokens)) · \(Fmt.money(advice.carryCostPerCall)) per call to carry · \(expiry)"
    }
}

/// For sessions that are no longer open, advice about "now" means nothing, so this looks back instead.
struct EndedSummary: View {
    let timeline: SessionTimeline

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("Session closed").font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10)))
    }

    private var summary: String {
        let window = timeline.contextWindow
        var parts = ["Context peaked at \(Fmt.tokens(timeline.peakContext))" + (window > 0 ? " (\(Fmt.percent(Double(timeline.peakContext) / Double(window) * 100)) of the window)." : ".")]
        parts.append(timeline.compactionCount == 0 ? "No compactions." : "\(Fmt.count(timeline.compactionCount, "compaction")).")
        if timeline.expiryCount > 0 {
            parts.append("The cache expired \(Fmt.count(timeline.expiryCount, "time")) while idle, costing about \(Fmt.money(timeline.coldRewriteExtraCost)) more than reading it warm.")
        }
        return parts.joined(separator: " ")
    }
}
