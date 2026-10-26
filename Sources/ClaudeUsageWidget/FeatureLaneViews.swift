import Charts
import SwiftUI
import UsageCore

extension FeatureLane {
    var color: Color {
        switch self {
        case .loop: Theme.laneLoop
        case .goal: Theme.good
        case .subagents: Theme.laneAgents
        case .tests: Theme.good
        case .plugins: Theme.lanePlugins
        }
    }

    var symbol: String {
        switch self {
        case .loop: "arrow.triangle.2.circlepath"
        case .goal: "checkmark.circle"
        case .subagents: "person.2"
        case .tests: "checkmark.seal"
        case .plugins: "puzzlepiece"
        }
    }
}

extension FeatureLanes {
    /// How tall a lane's chart is. The stack layout and the views both read this, so hover bands cannot drift from the drawing.
    func laneHeight(_ lane: FeatureLane, density: TimelineDensity) -> CGFloat {
        let base = density.panelHeight
        switch lane {
        case .loop, .goal: return base
        case .subagents: return max(34, CGFloat(subagents?.rowCount ?? 1) * 18 + 8) * density.scale
        case .tests: return base * 0.8
        case .plugins: return 26 * density.scale
        }
    }

    /// Stack items for every present lane: a header, then the lane.
    func stackItems(density: TimelineDensity) -> [StackItem] {
        present.flatMap { [StackItem(kind: .header, height: density.headerHeight), StackItem(kind: .lane, height: laneHeight($0, density: density), lane: $0)] }
    }

    /// The one-line summary on the right of a lane's header.
    func summary(_ lane: FeatureLane) -> String {
        switch lane {
        case .loop:
            guard let l = loop else { return "" }
            return "\(Fmt.count(l.iterations.count, "iteration")) · \(Fmt.money(l.totalCost)) · avg \(Fmt.money(l.averageCost))"
        case .goal: return ""
        case .subagents:
            guard let l = subagents else { return "" }
            return "\(Fmt.count(l.runs.count, "run")) · \(Fmt.money(l.totalCost))"
        case .tests:
            guard let l = tests else { return "" }
            switch l.lastState {
            case .unreadable: return "last run unreadable"
            case .green, .red:
                let s = l.runs.last!.summary!
                let pct = s.total > 0 ? Double(s.passed) / Double(s.total) * 100 : 0
                return "last run \(s.passed) / \(s.total) (\(Fmt.percent(pct)))" + (l.lastState == .red ? " · ended red" : "")
            }
        case .plugins:
            guard let l = plugins else { return "" }
            return l.segments.prefix(3).map { "\($0.name) \(Fmt.money($0.cost))" }.joined(separator: " · ")
        }
    }
}

/// The lanes under the session timeline. Each one shares the context chart's horizontal axis, so a loop iteration lines up
/// with the calls it made. Only lanes the session has data for are drawn.
struct FeatureLaneStack: View {
    let lanes: FeatureLanes
    let geometry: TimelineGeometry
    let density: TimelineDensity

    private var ticks: [Double] { geometry.ticks(maxTicks: density.kind == .compact ? 4 : density.kind == .standard ? 6 : 9) }

    var body: some View {
        VStack(alignment: .leading, spacing: TimelineDensity.spacing) {
            ForEach(lanes.present) { lane in
                header(lane)
                laneBody(lane).frame(height: lanes.laneHeight(lane, density: density))
            }
        }
    }

    private func header(_ lane: FeatureLane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(lane.color).frame(width: 10, height: 10)
                Text(lane.title).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                Text(lanes.summary(lane)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.bottom, 3)
        }
        .frame(height: density.headerHeight)
    }

    @ViewBuilder private func laneBody(_ lane: FeatureLane) -> some View {
        switch lane {
        case .loop: if let l = lanes.loop { LoopLaneChart(lane: l, geometry: geometry, ticks: ticks, showsLabels: density.showsLabels) }
        case .subagents: if let l = lanes.subagents { SubagentLaneChart(lane: l, geometry: geometry, ticks: ticks) }
        case .tests: if let l = lanes.tests { TestLaneChart(lane: l, geometry: geometry, ticks: ticks) }
        case .plugins: if let l = lanes.plugins { PluginLaneBar(lane: l) }
        case .goal: EmptyView()
        }
    }
}

extension LoopDecision.Kind {
    var symbol: String {
        switch self {
        case .again: "arrow.triangle.2.circlepath"
        case .stop: "stop.circle.fill"
        }
    }
}

/// Where a mark's icon sits in a lane: a small view anchored on the mark.
func laneIcon(_ symbol: String, _ color: Color) -> some View {
    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
}

struct LoopLaneChart: View {
    let lane: LoopLane
    let geometry: TimelineGeometry
    let ticks: [Double]
    let showsLabels: Bool

    var body: some View {
        let g = geometry
        let top = max(lane.iterations.map(\.cost).max() ?? 0, 0.0001) * 1.35
        let minWidth = (g.domain.upperBound - g.domain.lowerBound) * 0.008
        let waits = lane.decisions.compactMap { d -> (LoopDecision, LoopIteration)? in
            guard case .again = d.kind, let next = lane.iterations.first(where: { $0.index == d.afterIteration + 1 }) else { return nil }
            return (d, next)
        }
        Chart {
            ForEach(waits, id: \.0.id) { d, next in
                RuleMark(xStart: .value("Decided", g.x(time: d.time)), xEnd: .value("Woke", g.x(time: next.start)), y: .value("Wait", top * 0.88))
                    .foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .bottom, alignment: .center, spacing: 0) {
                        if showsLabels && !g.byCalls {
                            Text("wait \(Fmt.spanLength(next.start.timeIntervalSince(d.time)))").font(.system(size: 8)).foregroundStyle(.secondary).fixedSize()
                        }
                    }
            }
            ForEach(lane.iterations) { it in
                let x0 = g.x(time: it.start)
                RectangleMark(
                    xStart: .value("Start", x0), xEnd: .value("End", max(g.x(endingAt: it.end), x0 + minWidth)),
                    yStart: .value("Base", 0), yEnd: .value("Cost", max(it.cost, top * 0.04)))
                    .foregroundStyle(FeatureLane.loop.color.opacity(0.85))
                if it.startedBy == .fallbackWake {
                    PointMark(x: .value("Fallback", x0), y: .value("Top", top * 0.88)).opacity(0)
                        .annotation(position: .overlay) { laneIcon("exclamationmark.triangle.fill", Theme.caution) }
                }
            }
            ForEach(lane.decisions) { d in
                PointMark(x: .value("Decision", g.x(time: d.time)), y: .value("Top", top * 0.88)).opacity(0)
                    .annotation(position: .overlay) { laneIcon(d.kind.symbol, FeatureLane.loop.color) }
            }
        }
        .panel(g, ticks: ticks)
        .chartYScale(domain: 0...top)
    }
}

struct SubagentLaneChart: View {
    let lane: SubagentLane
    let geometry: TimelineGeometry
    let ticks: [Double]

    var body: some View {
        let g = geometry
        let rows = Double(max(lane.rowCount, 1))
        let minWidth = (g.domain.upperBound - g.domain.lowerBound) * 0.006
        Chart {
            ForEach(lane.runs) { run in
                let x0 = g.x(time: run.start)
                RectangleMark(
                    xStart: .value("Start", x0), xEnd: .value("End", max(g.x(endingAt: run.end), x0 + minWidth)),
                    yStart: .value("Row", Double(run.row) + 0.1), yEnd: .value("RowEnd", Double(run.row) + 0.9))
                    .foregroundStyle(FeatureLane.subagents.color.opacity(0.8))
            }
        }
        .panel(g, ticks: ticks)
        .chartYScale(domain: 0...rows)
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let frame = proxy.plotFrame {
                    ForEach(lane.runs) { run in
                        let x0 = proxy.position(forX: g.x(time: run.start)) ?? 0
                        let x1 = proxy.position(forX: g.x(endingAt: run.end)) ?? x0
                        if let y = proxy.position(forY: Double(run.row) + 0.5), x1 - x0 > 48 {
                            Text(run.label).font(.system(size: 9)).foregroundStyle(.white).lineLimit(1)
                                .frame(width: x1 - x0 - 6, alignment: .leading)
                                .offset(x: geo[frame].minX + x0 + 3, y: geo[frame].minY + y - 6)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

struct TestLaneChart: View {
    let lane: TestLane
    let geometry: TimelineGeometry
    let ticks: [Double]

    var body: some View {
        let g = geometry
        Chart {
            ForEach(lane.runs) { run in
                let x = g.x(time: run.time)
                if let s = run.summary, s.total > 0 {
                    let passedShare = Double(s.passed) / Double(s.total)
                    BarMark(x: .value("When", x), yStart: .value("Base", 0), yEnd: .value("Passed", passedShare), width: .fixed(8))
                        .foregroundStyle(Theme.good)
                    if s.failed > 0 {
                        BarMark(x: .value("When", x), yStart: .value("Passed", passedShare), yEnd: .value("All", 1), width: .fixed(8))
                            .foregroundStyle(Theme.critical)
                    }
                } else {
                    BarMark(x: .value("When", x), yStart: .value("Base", 0), yEnd: .value("Unknown", 1), width: .fixed(8))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                }
            }
        }
        .panel(g, ticks: ticks)
        .chartYScale(domain: 0...1.05)
    }
}

/// One stacked bar of cost by plugin across the full width. It is a session total, so it does not pan or zoom.
struct PluginLaneBar: View {
    let lane: PluginLane

    var body: some View {
        GeometryReader { box in
            HStack(spacing: 1) {
                ForEach(Array(lane.segments.enumerated()), id: \.element.id) { i, seg in
                    let width = max(2, box.size.width * seg.cost / max(lane.total, 0.000001))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(seg.name == FeatureLanes.otherPluginName ? Color.secondary.opacity(0.35) : FeatureLane.plugins.color.opacity(1 - Double(i) * 0.18))
                        if width > 70 {
                            Text(seg.name).font(.system(size: 9)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 4)
                        }
                    }
                    .frame(width: width)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension FeatureLane {
    /// Lanes that have something to draw on the context chart. The plugin lane is a session total, so it stays a lane.
    var canOverlay: Bool { self == .loop || self == .subagents || self == .tests }
}

/// The lanes' markers drawn on the context chart: loop iterations as translucent vertical bands with their decision icons
/// along the top, sub-agent runs as thin bars along the bottom, and test runs as dots just under the top.
@ChartContentBuilder
func featureOverlayMarks(_ lanes: FeatureLanes, selected: Set<FeatureLane>, g: TimelineGeometry, top: Double) -> some ChartContent {
    let minWidth = (g.domain.upperBound - g.domain.lowerBound) * 0.006
    if selected.contains(.loop), let loop = lanes.loop {
        ForEach(loop.iterations) { it in
            let x0 = g.x(time: it.start)
            RectangleMark(
                xStart: .value("Iteration start", x0), xEnd: .value("Iteration end", max(g.x(endingAt: it.end), x0 + minWidth)),
                yStart: .value("Bottom", 0), yEnd: .value("Top", top))
                .foregroundStyle(FeatureLane.loop.color.opacity(0.16))
            if it.startedBy == .fallbackWake {
                PointMark(x: .value("Fallback wake", x0), y: .value("Icon", top * 0.93)).opacity(0)
                    .annotation(position: .overlay) { laneIcon("exclamationmark.triangle.fill", Theme.caution) }
            }
        }
        ForEach(loop.decisions) { d in
            PointMark(x: .value("Decision", g.x(time: d.time)), y: .value("Icon", top * 0.93)).opacity(0)
                .annotation(position: .overlay) { laneIcon(d.kind.symbol, FeatureLane.loop.color) }
        }
    }
    if selected.contains(.subagents), let agents = lanes.subagents {
        ForEach(agents.runs) { run in
            let x0 = g.x(time: run.start)
            let floor = top * 0.025 * Double(run.row)
            RectangleMark(
                xStart: .value("Run start", x0), xEnd: .value("Run end", max(g.x(endingAt: run.end), x0 + minWidth)),
                yStart: .value("Row bottom", floor), yEnd: .value("Row top", floor + top * 0.02))
                .foregroundStyle(FeatureLane.subagents.color.opacity(0.8))
        }
    }
    if selected.contains(.tests), let tests = lanes.tests {
        ForEach(tests.runs) { run in
            let color: Color = run.summary.map { $0.failed == 0 && $0.total > 0 ? Theme.good : Theme.critical } ?? Color.secondary
            PointMark(x: .value("Test run", g.x(time: run.time)), y: .value("Dot", top * 0.82)).symbolSize(34)
                .foregroundStyle(color)
        }
    }
}
