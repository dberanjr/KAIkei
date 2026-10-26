import Charts
import SwiftUI
import UsageCore

/// Headline for the selected range. Clicking it opens the full detail for that range.
struct TotalsBand: View {
    @EnvironmentObject var store: UsageStore
    let big: Bool

    var body: some View {
        let s = store.snapshot
        Clickable(help: "Open the full breakdown for this period", action: { store.drill(into: .total) }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.money(s.totalCost))
                        .font(.system(size: big ? 40 : 30, weight: .semibold)).monospacedDigit()
                    Text(store.range == .all ? "all time" : store.range == .today ? "today" : "last \(store.range.rawValue)")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Text("\(Fmt.tokens(s.totalUsage.total)) tokens")
                    Text("\(Fmt.tokens(s.totalUsage.output)) output")
                    Text(Fmt.count(s.messageCount, "response"))
                }
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Horizontal bars with the number beside each: the table view and the chart in one.
/// With `onSelect`, each row opens its own detail.
struct BarRows: View {
    struct Item: Identifiable { var id: String; var label: String; var detail: String; var cost: Double; var color: Color }
    let items: [Item]
    var limit = 6
    var onSelect: ((String) -> Void)?

    var body: some View {
        let shown = Array(items.prefix(limit))
        let top = max(shown.map(\.cost).max() ?? 0, 0.0001)
        let total = max(items.reduce(0) { $0 + $1.cost }, 0.0001)
        VStack(spacing: 9) {
            ForEach(shown) { item in
                if let onSelect {
                    Clickable(help: "Open \(item.label)", action: { onSelect(item.id) }) { row(item, top: top, total: total) }
                } else {
                    row(item, top: top, total: total)
                }
            }
            if items.count > limit {
                Text("+\(items.count - limit) more").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
    }

    private func row(_ item: Item, top: Double, total: Double) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.label).lineLimit(1).truncationMode(.middle)
                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.tertiary) }
                Spacer(minLength: 8)
                Text(Fmt.percent(item.cost / total * 100)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(Fmt.money(item.cost)).font(.system(.callout, weight: .medium)).monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
            }
            GeometryReader { g in
                Capsule().fill(item.color).frame(width: max(3, g.size.width * item.cost / top), height: 4)
            }.frame(height: 4)
        }
    }
}

/// How each breakdown tab turns snapshot rows into bars, and what a click on one opens. Shared with the detail view.
enum Breakdowns {
    static func items(for tab: BreakdownTab, in s: Snapshot) -> [BarRows.Item] {
        func rows(_ list: [BreakdownRow], _ detail: (BreakdownRow) -> String) -> [BarRows.Item] {
            list.map { .init(id: $0.key, label: $0.key, detail: detail($0), cost: $0.cost, color: Theme.accent) }
        }
        switch tab {
        case .models:
            return s.byModel.map {
                .init(id: $0.key, label: ModelFamily.displayName(modelID: $0.key), detail: Fmt.count($0.count, "response"),
                      cost: $0.cost, color: Theme.color(ModelFamily(modelID: $0.key)))
            }
        case .skills: return rows(s.bySkill) { Fmt.count($0.count, "response") }
        case .plugins: return rows(s.byPlugin) { Fmt.count($0.count, "response") }
        case .tools: return rows(s.byTool) { Fmt.count($0.count, "call") }
        case .projects: return rows(s.byProject) { Fmt.count($0.count, "response") }
        }
    }

    static func target(for tab: BreakdownTab, key: String) -> DrillTarget {
        switch tab {
        case .models: .model(key)
        case .skills: .skill(key)
        case .plugins: .plugin(key)
        case .tools: .tool(key)
        case .projects: .project(key)
        }
    }
}

struct BreakdownSection: View {
    @EnvironmentObject var store: UsageStore
    var limit = 6
    var showTabs = true

    var body: some View {
        let tab = showTabs ? store.tab : BreakdownTab.models
        VStack(alignment: .leading, spacing: 10) {
            if showTabs {
                Picker("Break down by", selection: $store.tab) {
                    ForEach(BreakdownTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            } else {
                Text("By model").font(.headline)
            }
            BarRows(items: Breakdowns.items(for: tab, in: store.snapshot), limit: limit) {
                store.drill(into: Breakdowns.target(for: tab, key: $0))
            }
            if showTabs && store.tab == .tools {
                Text("Each response's cost is split evenly across the tool calls it made, so tool costs are estimates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Where the money goes by billing kind, in the dollars (magenta) ramp. The drill-down page uses `CostAnatomy` instead.
struct MoneySplit: View {
    @EnvironmentObject var store: UsageStore
    /// Defaults to the selected range's totals; the detail view passes its own.
    var parts: CostParts?
    var opensDetail = true

    var body: some View {
        if opensDetail {
            Clickable(help: "Open the full breakdown for this period", action: { store.drill(into: .total) }) { content }
        } else {
            content
        }
    }

    private var content: some View {
        let p = parts ?? store.snapshot.costParts
        let rows: [(String, Double)] = [
            ("Cache reads", p.cacheRead), ("Cache writes", p.cacheWrite), ("Output", p.output), ("Input", p.input),
        ]
        let total = max(p.total, 0.0001)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Where the money goes").font(.headline)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, part in
                        Rectangle().fill(Theme.billedRamp[i])
                            .frame(width: max(part.1 > 0 ? 3 : 0, (g.size.width - 6) * part.1 / total))
                    }
                }.clipShape(Capsule())
            }.frame(height: 10)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, part in
                HStack {
                    Circle().fill(Theme.billedRamp[i]).frame(width: 8, height: 8)
                    Text(part.0)
                    Spacer()
                    Text(Fmt.percent(part.1 / total * 100)).foregroundStyle(.secondary).monospacedDigit()
                    Text(Fmt.money(part.1)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }.font(.callout)
            }
        }
    }
}

/// The last 30 days from the store, as clickable bars.
struct TrendChart: View {
    @EnvironmentObject var store: UsageStore
    var body: some View { DailyChart(daily: store.monthSnapshot.daily, title: "Last 30 days", opensDay: true, height: 150, maximize: ChartSpec(kind: .trend, target: .total)) }
}

/// Daily cost stacked by model family. Hover shows a day's total; with `opensDay`, clicking a bar opens that day.
struct DailyChart: View {
    @EnvironmentObject var store: UsageStore
    let daily: [DailyPoint]
    let title: String
    var opensDay = false
    var height: CGFloat = 180
    /// When set, a corner button opens this chart full screen.
    var maximize: ChartSpec?

    struct Point: Identifiable { var day: Date; var family: ModelFamily; var cost: Double; var id: String { "\(day)\(family)" } }

    static func span(now: Date = Date()) -> ClosedRange<Date> {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now)) ?? now
        return start...(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now)
    }

    private var points: [Point] {
        var sums: [String: Point] = [:]
        for d in daily {
            let f = ModelFamily(modelID: d.model)
            sums["\(d.day.timeIntervalSince1970)|\(f.rawValue)", default: Point(day: d.day, family: f, cost: 0)].cost += d.cost
        }
        return sums.values.sorted { ($0.day, $0.family.rawValue) < ($1.day, $1.family.rawValue) }
    }

    var body: some View {
        let pts = points
        let selected = store.trendSelection
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let day = selected.map({ Calendar.current.startOfDay(for: $0) }) {
                    let dayPts = pts.filter { $0.day == day }
                    Text("\(day.formatted(.dateTime.month().day())): \(Fmt.money(dayPts.reduce(0) { $0 + $1.cost }))")
                        .font(.callout.weight(.medium)).monospacedDigit()
                    if opensDay, !dayPts.isEmpty { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                }
                if let maximize { MaximizeButton(spec: maximize) }
            }
            if pts.isEmpty {
                Text("No usage in the last 30 days.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(pts) { p in
                    BarMark(x: .value("Day", p.day, unit: .day), y: .value("Cost", p.cost))
                        .foregroundStyle(by: .value("Model family", p.family.rawValue))
                        .cornerRadius(2)
                    if let selected {
                        RuleMark(x: .value("Selected", selected, unit: .day)).foregroundStyle(.secondary.opacity(0.4))
                    }
                }
                .chartForegroundStyleScale(
                    domain: ModelFamily.allCases.map(\.rawValue), range: ModelFamily.allCases.map { Theme.color($0) })
                // Always the same 30-day span, so a single day of data is a thin bar in context, not one giant block.
                .chartXScale(domain: Self.span())
                .chartXSelection(value: $store.trendSelection)
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.axisMoney(d)).font(.caption2) } }
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month().day()).font(.caption2) } }
                .chartLegend(position: .top, alignment: .leading, spacing: 12)
                .frame(height: height)
                .onTapGesture {
                    // The hover selection already tracks the bar under the pointer, so a click opens that day.
                    guard opensDay, let day = store.trendSelection.map({ Calendar.current.startOfDay(for: $0) }),
                        pts.contains(where: { $0.day == day }) else { return }
                    store.drill(into: .day(day))
                }
                .onContinuousHover { if opensDay, case .active = $0 { NSCursor.pointingHand.set() } }
            }
        }
    }
}
