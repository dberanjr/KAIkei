import SwiftUI
import UsageCore

/// The two panels at the foot of a detail page, side by side when there is room: the costliest responses as a treemap,
/// and when in the day the money goes as a 24-hour dial.
struct DetailLowerPanels: View {
    let messages: [MessageRow]
    let hourly: [Double]
    let target: DrillTarget

    var body: some View {
        let hasMessages = !messages.isEmpty
        let hasHours = hourly.contains { $0 > 0 }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                if hasMessages { ResponseTreemapCard(messages: messages, target: target) }
                if hasHours { HourRoseCard(profile: HourlyProfile(costs: hourly), target: target).frame(width: 380) }
            }
            VStack(alignment: .leading, spacing: 14) {
                if hasMessages { ResponseTreemapCard(messages: messages, target: target) }
                if hasHours { HourRoseCard(profile: HourlyProfile(costs: hourly), target: target) }
            }
        }
    }
}

// MARK: costliest responses

/// The most expensive responses as tiles: area is dollars, color is the model. Replaces a ten-row list with something
/// a fraction of the height. Click a tile to open its session; hover for the full detail.
struct ResponseTreemapCard: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.chartExpanded) private var expanded
    let messages: [MessageRow]
    let target: DrillTarget

    var body: some View {
        let total = max(messages.reduce(0) { $0 + $1.cost }, 0.0001)
        AnatomyCard(title: "Most expensive responses", subtitle: "area is dollars, color is the model", maximize: ChartSpec(kind: .responses, target: target)) {
            GeometryReader { g in
                let rects = Treemap.layout(weights: messages.map(\.cost), in: TreemapRect(x: 0, y: 0, width: g.size.width, height: g.size.height))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        let r = rects[i]
                        if r.width > 0, r.height > 0 {
                            tile(m, width: r.width, height: r.height, total: total)
                                .frame(width: max(r.width - 2, 0), height: max(r.height - 2, 0))
                                .offset(x: r.x + 1, y: r.y + 1)
                        }
                    }
                }
            }
            .frame(minHeight: expanded ? 520 : 170, maxHeight: expanded ? .infinity : 170)
            Text("Together \(Fmt.money(total)). Click a tile to open its session.").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var sameDay: Bool {
        guard let first = messages.first?.timestamp else { return true }
        return messages.allSatisfy { Calendar.current.isDate($0.timestamp, inSameDayAs: first) }
    }

    private func tile(_ m: MessageRow, width: Double, height: Double, total: Double) -> some View {
        let family = ModelFamily(modelID: m.model)
        let ink: Color = family == .haiku || family == .other ? Color.black.opacity(0.85) : .white
        let when = sameDay ? m.timestamp.formatted(.dateTime.hour().minute()) : m.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let detail = "\(ModelFamily.displayName(modelID: m.model)) · \(m.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(Fmt.money(m.cost)) · \(Fmt.tokens(m.usage.total)) tokens"
            + (m.tools.isEmpty ? "" : " · \(m.tools.joined(separator: ", "))") + " · \(m.project)"
        return Clickable(help: detail, action: { store.drill(into: .session(m.sessionID)) }) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.color(family).opacity(0.88))
                VStack(alignment: .leading, spacing: 1) {
                    if width > 46, height > 26 { Text(Fmt.money(m.cost)).font(expanded ? .title3.weight(.semibold) : .caption.weight(.semibold)).monospacedDigit().lineLimit(1) }
                    if width > 62, height > 40 { Text(when).font(expanded ? .callout : .caption2).lineLimit(1) }
                    if width > 80, height > 54 { Text("\(Fmt.tokens(m.usage.total)) tok").font(expanded ? .callout : .caption2).opacity(0.85).lineLimit(1) }
                }
                .foregroundStyle(ink).padding(5)
            }
        }
    }
}

// MARK: the 24-hour dial

/// Pointer state for the dial, kept in its own object (no @State in this build).
final class RoseHover: ObservableObject {
    @Published var hour: Int?
}

/// When the cost happens, as a dial of 24 wedges (midnight at the top, clockwise like a clock). Each wedge's area is the
/// spend in that hour, so busy hours stand out and a quiet one is a sliver. The faint outline shows every hour's slot.
struct HourRoseCard: View {
    let profile: HourlyProfile
    let target: DrillTarget
    @Environment(\.chartExpanded) private var expanded

    var body: some View {
        let side: CGFloat = expanded ? 600 : 220
        AnatomyCard(title: "When the cost happens", subtitle: "each wedge is an hour; area is dollars", maximize: ChartSpec(kind: .hours, target: target)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: expanded ? 40 : 14) { HourRose(profile: profile).frame(width: side, height: side); facts }
                VStack(alignment: .leading, spacing: 8) { HourRose(profile: profile).frame(width: side, height: side).frame(maxWidth: .infinity); facts }
            }
            Text("By hour of the day in your time zone, over the selected period.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let peak = profile.peakHour {
                fact("Peak hour", "\(HourlyProfile.label(peak)) · \(Fmt.money(profile.peakCost))", "\(Fmt.percent(profile.peakCost / profile.total * 100)) of the spend")
            }
            if let w = profile.busiestWindow(hours: 3) {
                fact("Busiest 3 hours", "\(HourlyProfile.label(w.start)) – \(HourlyProfile.label((w.start + 3) % 24))", "\(Fmt.percent(w.share * 100)) of the spend")
            }
            fact("Active", "\(profile.activeHours) of 24 hours", "")
        }
    }

    private func fact(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(expanded ? .body : .caption).foregroundStyle(.secondary)
            Text(value).font(expanded ? .title2.weight(.semibold) : .callout.weight(.semibold)).monospacedDigit()
            if !note.isEmpty { Text(note).font(expanded ? .callout : .caption2).foregroundStyle(.secondary) }
        }
    }
}

struct HourRose: View {
    let profile: HourlyProfile
    @StateObject private var hover = RoseHover()

    var body: some View {
        GeometryReader { box in
            let side = min(box.size.width, box.size.height)
            let layout = RoseLayout(side: side, peak: niceTop)
            ZStack {
                RoseCanvas(profile: profile, layout: layout, hover: hover)
                RoseCenter(profile: profile, k: layout.textScale, hover: hover)
            }
            .frame(width: side, height: side)
            .position(x: box.size.width / 2, y: box.size.height / 2)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let h = layout.hour(at: p)
                    if hover.hour != h { hover.hour = h }
                case .ended: hover.hour = nil
                }
            }
        }
    }

    /// The outer ring is a round number just above the peak, so the rings can be labelled in whole amounts.
    private var niceTop: Double { NiceScale.top(for: max(profile.peakCost, 0.0001), count: 2) }
}

/// Where things sit on the dial, shared by the drawing and the pointer so a hover lands on the wedge it is over.
struct RoseLayout {
    let side: Double
    let peak: Double
    var center: (x: Double, y: Double) { (side / 2, side / 2) }
    /// Text grows with the dial when it is maximized.
    var textScale: Double { max(1, side / 240) }
    /// Room around the dial for the hour labels.
    var outer: Double { side / 2 - 24 * textScale }
    var inner: Double { outer * 0.32 }

    func radius(_ value: Double) -> Double { Rose.radius(value: value, peak: peak, inner: inner, outer: outer) }

    /// The hour under a point, or nil in the hole and outside the dial.
    func hour(at p: CGPoint) -> Int? {
        let dx = Double(p.x) - center.x, dy = Double(p.y) - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        guard r >= inner * 0.6, r <= outer + 14 * textScale else { return nil }
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return min(Int(degrees / Rose.wedgeDegrees), 23)
    }
}

private struct Wedge: Shape {
    let hour: Int
    let inner: Double
    let outer: Double
    /// Space either side, so neighbouring wedges do not touch.
    var gap = 0.7

    func path(in rect: CGRect) -> Path {
        let c = (x: Double(rect.midX), y: Double(rect.midY))
        let a0 = Rose.startAngle(hour: hour) + gap, a1 = Rose.startAngle(hour: hour) + Rose.wedgeDegrees - gap
        let steps = 6
        var path = Path()
        func pt(_ r: Double, _ a: Double) -> CGPoint { let p = Rose.point(center: c, radius: r, degrees: a); return CGPoint(x: p.x, y: p.y) }
        path.move(to: pt(outer, a0))
        for i in 1...steps { path.addLine(to: pt(outer, a0 + (a1 - a0) * Double(i) / Double(steps))) }
        for i in 0...steps { path.addLine(to: pt(inner, a1 - (a1 - a0) * Double(i) / Double(steps))) }
        path.closeSubpath()
        return path
    }
}

/// The drawing. Observes the hover only to outline the wedge under the pointer.
private struct RoseCanvas: View {
    let profile: HourlyProfile
    let layout: RoseLayout
    @ObservedObject var hover: RoseHover

    var body: some View {
        ZStack {
            // Every hour's slot, faint, so the dial reads as a clock even where nothing was spent.
            ForEach(0..<24, id: \.self) { h in
                Wedge(hour: h, inner: layout.inner, outer: layout.outer).fill(Color.primary.opacity(h >= 6 && h < 18 ? 0.045 : 0.075))
            }
            ring(layout.peak / 2, label: Fmt.axisMoney(layout.peak / 2))
            ring(layout.peak, label: Fmt.axisMoney(layout.peak))
            ForEach(0..<24, id: \.self) { h in
                let v = profile.costs[h]
                if v > 0 {
                    let r = layout.radius(v)
                    Wedge(hour: h, inner: layout.inner, outer: max(r, layout.inner + 1.5))
                        .fill(Theme.seriesCostPerCall.opacity(0.4 + 0.6 * min(v / max(profile.peakCost, 0.0001), 1)))
                }
            }
            if let h = hover.hour {
                Wedge(hour: h, inner: layout.inner, outer: layout.outer, gap: 0.3).stroke(Color.primary.opacity(0.7), lineWidth: 1.2)
            }
            ForEach([0, 6, 12, 18], id: \.self) { h in label(h) }
        }
    }

    private func ring(_ value: Double, label: String) -> some View {
        let r = layout.radius(value)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                .frame(width: r * 2, height: r * 2)
            // The label sits just right of twelve o'clock on its ring.
            Text(label).font(.system(size: 8 * layout.textScale)).foregroundStyle(.secondary)
                .position(x: layout.center.x + 12 * layout.textScale, y: layout.center.y - r + 6 * layout.textScale)
        }
        .frame(width: layout.side, height: layout.side)
    }

    private func label(_ hour: Int) -> some View {
        let p = Rose.point(center: layout.center, radius: layout.outer + 13 * layout.textScale, degrees: Rose.startAngle(hour: hour))
        return Text(HourlyProfile.label(hour)).font(.system(size: 9 * layout.textScale, weight: .medium)).foregroundStyle(.secondary)
            .position(x: p.x, y: p.y)
    }
}

/// The hole: the hour under the pointer with its spend, or the peak when the pointer is elsewhere.
private struct RoseCenter: View {
    let profile: HourlyProfile
    let k: Double
    @ObservedObject var hover: RoseHover

    var body: some View {
        let hour = hover.hour ?? profile.peakHour
        VStack(spacing: 0) {
            if let hour {
                Text(HourlyProfile.label(hour)).font(.system(size: 11 * k, weight: .semibold))
                Text(Fmt.money(profile.costs[hour])).font(.system(size: 10 * k)).monospacedDigit()
                Text(hover.hour == nil ? "peak" : "").font(.system(size: 8 * k)).foregroundStyle(.secondary)
            }
        }
    }
}
