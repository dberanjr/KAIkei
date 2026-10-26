import Charts
import SwiftUI
import UsageCore

/// What a click on any number, bar or row opens: the same data narrowed to that one thing, with its own trend,
/// the other breakdowns cut by it, and the individual sessions and responses behind it. Rows inside open the next level.
struct DetailView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        if let target = store.drillTarget {
            let d = store.detail(for: target)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(target, d)
                    if d.snapshot.messageCount == 0 {
                        Text("Nothing recorded for this in the selected period. Try a longer range.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        if case .session(let id) = target, let timeline = d.timeline {
                            SessionTimelineView(sessionID: id, timeline: timeline)
                        }
                        summary(d)
                        if case .day = target {} else { DailyChart(daily: d.trend, title: "Last 30 days", opensDay: true, maximize: ChartSpec(kind: .trend, target: target)) }
                        CostAnatomy(detail: d, target: target)
                        topSessions(d)
                        DetailLowerPanels(messages: d.topMessages, hourly: d.hourly, target: target)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onExitCommand { store.back() }
        }
    }

    // MARK: header and summary

    private func title(_ target: DrillTarget, _ d: DrillDetail) -> String {
        if case .session(let id) = target { return store.sessionTitle(id) ?? d.topSessions.first?.project ?? target.title }
        return target.title
    }

    private func header(_ target: DrillTarget, _ d: DrillDetail) -> some View {
        let when = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        return VStack(alignment: .leading, spacing: 5) {
            // The same marker the pinned bar at the foot of the window carries, so a filtered page is recognisable at a glance.
            if FilterMarker.isFiltered(target) {
                Label("Filtered to \(target.kind.lowercased())", systemImage: "line.3.horizontal.decrease")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Theme.accent.opacity(0.15)))
            } else {
                Text(target.kind).font(.caption).foregroundStyle(.secondary)
            }
            Text(title(target, d)).font(.system(size: 26, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7)
            if let first = d.firstSeen, let last = d.lastSeen {
                let period: String = {
                    switch target {
                    case .day, .session: return ""  // these cover their own span, not the selected range
                    default: return "\(store.range.rawValue) · "
                    }
                }()
                Text("\(period)\(Fmt.count(d.snapshot.messageCount, "response")) · first \(first.formatted(when)) · latest \(last.formatted(when))")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func summary(_ d: DrillDetail) -> some View {
        let s = d.snapshot
        let u = s.totalUsage
        let average = s.messageCount > 0 ? s.totalCost / Double(s.messageCount) : 0
        return VStack(alignment: .leading, spacing: 12) {
            Text(Fmt.money(s.totalCost)).font(.system(size: 40, weight: .semibold)).monospacedDigit()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 10) {
                StatTile(label: "Responses", value: "\(s.messageCount)")
                StatTile(label: "Per response", value: Fmt.money(average))
                if let rate = u.cacheHitRate { StatTile(label: "Cache hit rate", value: Fmt.percent(rate * 100)) }
                StatTile(label: "Input", value: Fmt.tokens(u.input))
                StatTile(label: "Output", value: Fmt.tokens(u.output))
                StatTile(label: "Cache read", value: Fmt.tokens(u.cacheRead))
                StatTile(label: "Cache write", value: Fmt.tokens(u.cacheWrite))
            }
        }
    }

    // MARK: lists

    @ViewBuilder private func topSessions(_ d: DrillDetail) -> some View {
        // A single session is the thing being looked at, so listing it again would just repeat the page.
        if !d.topSessions.isEmpty, !(d.topSessions.count == 1 && isSession(d.target)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Costliest sessions").font(.headline)
                ForEach(d.topSessions) { s in
                    Clickable(help: "Open this session", action: { store.drill(into: .session(s.sessionID)) }) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(store.sessionTitle(s.sessionID) ?? s.project).lineLimit(1)
                                Text("\(Fmt.count(s.messageCount, "response")) · \(s.lastSeen.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(Fmt.money(s.cost)).font(.system(.callout, weight: .medium)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func isSession(_ t: DrillTarget) -> Bool { if case .session = t { true } else { false } }
}

struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, weight: .semibold)).monospacedDigit()
        }
    }
}
