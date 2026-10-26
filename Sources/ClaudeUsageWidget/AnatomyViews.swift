import Charts
import SwiftUI
import UsageCore

/// "Where the money went" as one dense panel instead of five lists. Three kinds of view, each for the job it does best:
/// donuts for a small whole split into a few parts (what it was billed as, which model), a pair of aligned bars for
/// comparing two measures of the same parts (share of tokens against share of dollars), and treemaps for long tails
/// (skills, plugins, tools, projects), where area makes the big few and the many small ones readable together.
///
/// Color keeps one meaning throughout: model colors identify models; the magenta family is always dollars.
struct CostAnatomy: View {
    @EnvironmentObject var store: UsageStore
    let detail: DrillDetail
    let target: DrillTarget
    /// A maximized chart shows just one of the cards.
    var only: ChartSpec.Kind?
    var tab: String?

    init(detail: DrillDetail, target: DrillTarget, only: ChartSpec.Kind? = nil, tab: String? = nil) {
        self.detail = detail; self.target = target; self.only = only; self.tab = tab
    }

    private var snapshot: Snapshot { detail.snapshot }

    @ViewBuilder var body: some View {
        if let only { single(only) } else { full }
    }

    @ViewBuilder private func single(_ kind: ChartSpec.Kind) -> some View {
        switch kind {
        case .billed: billedCard
        case .models: modelCard
        case .tokensVsDollars: tokensVersusDollars
        case .treemap:
            if let name = tab, let t = BreakdownTab(rawValue: name) {
                let items = Breakdowns.items(for: t, in: snapshot)
                if !items.isEmpty { treemapCard(t, items) }
            }
        default: EmptyView()
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Where the money went").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                billedCard
                if !isModelTarget { modelCard }
                tokensVersusDollars
            }
            let dims = dimensions
            if !dims.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(dims, id: \.tab) { dim in treemapCard(dim.tab, dim.items) }
                }
            }
        }
    }

    @Environment(\.chartExpanded) private var expanded

    private var isModelTarget: Bool { if case .model = target { true } else { false } }

    /// The breakdowns worth a panel: not the one this page is already about, and not empty.
    private var dimensions: [(tab: BreakdownTab, items: [BarRows.Item])] {
        BreakdownTab.allCases.compactMap { tab in
            switch (tab, target) {
            case (.models, _): return nil   // shown as a donut
            case (.skills, .skill), (.plugins, .plugin), (.tools, .tool), (.projects, .project): return nil
            default: break
            }
            let items = Breakdowns.items(for: tab, in: snapshot)
            return items.isEmpty ? nil : (tab, items)
        }
    }

    // MARK: donuts

    private static let billedNames = ["Cache reads", "Cache writes", "Output", "Input"]

    private var billedParts: [Double] {
        let p = snapshot.costParts
        return [p.cacheRead, p.cacheWrite, p.output, p.input]
    }

    private var billedCard: some View {
        let total = max(snapshot.costParts.total, 0.0001)
        let slices = zip(Self.billedNames.indices, billedParts).map { i, v in
            DonutSlice(id: Self.billedNames[i], label: Self.billedNames[i], value: v, color: Theme.billedRamp[i], detail: "")
        }
        return AnatomyCard(title: "Billed as", subtitle: "what the dollars paid for", maximize: ChartSpec(kind: .billed, target: target)) {
            DonutWithLegend(slices: slices, centerTop: Fmt.money(snapshot.costParts.total), centerBottom: "total", total: total, onSelect: nil)
        }
    }

    private var modelCard: some View {
        // Versions of one family share its color; they are told apart by how faded they are, and by the legend.
        var seen: [ModelFamily: Int] = [:]
        let slices = snapshot.byModel.map { row -> DonutSlice in
            let family = ModelFamily(modelID: row.key)
            let n = seen[family, default: 0]
            seen[family] = n + 1
            return DonutSlice(id: row.key, label: ModelFamily.displayName(modelID: row.key), value: row.cost,
                              color: Theme.color(family).opacity(max(0.35, 1 - 0.25 * Double(n))), detail: Fmt.count(row.count, "response"))
        }
        let top = snapshot.byModel.first
        return AnatomyCard(title: "By model", subtitle: "\(Fmt.count(snapshot.byModel.count, "model"))", maximize: ChartSpec(kind: .models, target: target)) {
            DonutWithLegend(
                slices: slices, centerTop: top.map { ModelFamily.displayName(modelID: $0.key) } ?? "–",
                centerBottom: top.map { Fmt.percent($0.cost / max(snapshot.totalCost, 0.0001) * 100) } ?? "",
                total: max(snapshot.totalCost, 0.0001), onSelect: { store.drill(into: .model($0)) })
        }
    }

    // MARK: tokens against dollars

    /// Two bars cut the same four ways: the top by tokens, the bottom by dollars. Where a segment is wider on top than
    /// below, that kind of token is cheap; this is how cache reads can be 90% of the tokens and a fraction of the bill.
    private var tokensVersusDollars: some View {
        let u = snapshot.totalUsage
        let tokens = [Double(u.cacheRead), Double(u.cacheWrite), Double(u.output), Double(u.input)]
        let tokenTotal = max(tokens.reduce(0, +), 1)
        let dollars = billedParts
        let dollarTotal = max(dollars.reduce(0, +), 0.0001)
        struct Seg: Identifiable { var id: String; var measure: String; var kind: String; var share: Double }
        var segs: [Seg] = []
        for i in 0..<4 {
            segs.append(Seg(id: "t\(i)", measure: "Tokens", kind: Self.billedNames[i], share: tokens[i] / tokenTotal))
            segs.append(Seg(id: "d\(i)", measure: "Dollars", kind: Self.billedNames[i], share: dollars[i] / dollarTotal))
        }
        let readTokens = tokens[0] / tokenTotal, readDollars = dollars[0] / dollarTotal
        return AnatomyCard(title: "Tokens vs dollars", subtitle: "same four parts, two measures", maximize: ChartSpec(kind: .tokensVsDollars, target: target)) {
            VStack(alignment: .leading, spacing: 8) {
                Chart(segs) { seg in
                    BarMark(x: .value("Share", seg.share), y: .value("Measure", seg.measure), height: .fixed(26))
                        .foregroundStyle(by: .value("Kind", seg.kind))
                        .annotation(position: .overlay) {
                            if seg.share >= 0.09 {
                                Text(Fmt.percent(seg.share * 100)).font(.caption2.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(seg.kind == "Cache reads" ? Color.black.opacity(0.8) : Color.white)
                            }
                        }
                }
                .chartForegroundStyleScale(domain: Self.billedNames, range: Theme.billedRamp)
                .chartLegend(.hidden)
                .chartXScale(domain: 0...1)
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption) } }
                .frame(height: expanded ? 220 : 78)
                HStack(spacing: 10) {
                    ForEach(Array(Self.billedNames.enumerated()), id: \.offset) { i, name in
                        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Theme.billedRamp[i]).frame(width: 8, height: 8); Text(name) }
                    }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if tokens[0] > 0, dollars[0] > 0 {
                    Text("Cache reads are \(Fmt.percent(readTokens * 100)) of the tokens but \(Fmt.percent(readDollars * 100)) of the dollars.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: treemaps

    private func treemapCard(_ tab: BreakdownTab, _ items: [BarRows.Item]) -> some View {
        let total = max(items.reduce(0) { $0 + $1.cost }, 0.0001)
        let title: String = {
            switch tab {
            case .skills: "By skill"
            case .plugins: "By plugin"
            case .tools: "By tool"
            case .projects: "By project"
            case .models: "By model"
            }
        }()
        return AnatomyCard(title: title, subtitle: items.count == 1 ? "1 item" : "\(items.count) items, area is dollars", maximize: ChartSpec(kind: .treemap, target: target, tab: tab.rawValue)) {
            VStack(alignment: .leading, spacing: 6) {
                if items.count == 1 {
                    Clickable(help: "Open \(items[0].label)", action: { store.drill(into: Breakdowns.target(for: tab, key: items[0].id)) }) {
                        HStack { Text(items[0].label).lineLimit(1); Text(items[0].detail).font(.caption).foregroundStyle(.tertiary); Spacer(); Text(Fmt.money(items[0].cost)).monospacedDigit() }
                            .font(.callout)
                    }
                } else {
                    TreemapView(items: items, total: total) { store.drill(into: Breakdowns.target(for: tab, key: $0)) }
                        .frame(minHeight: expanded ? 460 : (items.count > 4 ? 170 : 130), maxHeight: expanded ? .infinity : (items.count > 4 ? 170 : 130))
                }
                if tab == .tools {
                    Text("Each response's cost is split evenly across its tool calls, so these are estimates.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A titled panel with a hairline outline: the container every part of the anatomy sits in.
struct AnatomyCard<Content: View>: View {
    let title: String
    let subtitle: String
    /// When set, the card gets a corner button that opens it full screen.
    var maximize: ChartSpec?
    @ViewBuilder var content: Content
    @Environment(\.chartExpanded) private var expanded

    init(title: String, subtitle: String, maximize: ChartSpec? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.maximize = maximize; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(expanded ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                Text(subtitle).font(expanded ? .callout : .caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let maximize { MaximizeButton(spec: maximize) }
            }
            content
        }
        .padding(expanded ? 20 : 12)
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

struct DonutSlice: Identifiable {
    var id: String
    var label: String
    var value: Double
    var color: Color
    var detail: String
}

/// A donut with the total in its hole and a legend of share and dollars beside it. With `onSelect`, legend rows open details.
struct DonutWithLegend: View {
    let slices: [DonutSlice]
    let centerTop: String
    let centerBottom: String
    let total: Double
    var onSelect: ((String) -> Void)?
    @Environment(\.chartExpanded) private var expanded

    var body: some View {
        HStack(alignment: .center, spacing: expanded ? 40 : 14) {
            Chart(slices.filter { $0.value > 0 }) { slice in
                SectorMark(angle: .value("Dollars", slice.value), innerRadius: .ratio(0.64), angularInset: 1.5)
                    .foregroundStyle(slice.color).cornerRadius(3)
            }
            .chartLegend(.hidden)
            .chartBackground { proxy in
                GeometryReader { g in
                    if let frame = proxy.plotFrame {
                        let r = g[frame]
                        VStack(spacing: 0) {
                            Text(centerTop).font(.system(size: expanded ? 30 : 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                            Text(centerBottom).font(.system(size: expanded ? 18 : 10)).foregroundStyle(.secondary)
                        }
                        .frame(width: r.width * 0.6).position(x: r.midX, y: r.midY)
                    }
                }
            }
            .frame(width: expanded ? 340 : 104, height: expanded ? 340 : 104)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(slices.prefix(6)) { slice in
                    if let onSelect {
                        Clickable(help: "Open \(slice.label)", action: { onSelect(slice.id) }) { legendRow(slice) }
                    } else {
                        legendRow(slice)
                    }
                }
                if slices.count > 6 {
                    Text("+\(slices.count - 6) more").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Name on one line, share and dollars under it: a one-line row leaves a donut card too narrow for the name.
    private func legendRow(_ s: DonutSlice) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 9, height: 9).padding(.top, 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.label).font(expanded ? .title3.weight(.medium) : .caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.money(s.value)) · \(Fmt.percent(s.value / total * 100))").font(expanded ? .body : .caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Tiles sized by dollars. The long tail folds into one "other" tile so no tile is a sliver too small to read.
struct TreemapView: View {
    let items: [BarRows.Item]
    let total: Double
    var onSelect: (String) -> Void
    @Environment(\.chartExpanded) private var expanded

    private static let keep = 8

    private struct Tile: Identifiable { var id: String; var label: String; var detail: String; var cost: Double; var openable: Bool; var isNone: Bool }

    private var tiles: [Tile] {
        let folded = Treemap.collapse(weights: items.map(\.cost), keeping: Self.keep)
        var out = folded.kept.map { Tile(id: items[$0].id, label: items[$0].label, detail: items[$0].detail, cost: items[$0].cost, openable: true, isNone: items[$0].id == Snapshot.noSkill) }
        if folded.restCount > 0 { out.append(Tile(id: "other", label: "\(folded.restCount) smaller", detail: "", cost: folded.restWeight, openable: false, isNone: true)) }
        return out
    }

    var body: some View {
        let list = tiles
        GeometryReader { g in
            let rects = Treemap.layout(weights: list.map(\.cost), in: TreemapRect(x: 0, y: 0, width: g.size.width, height: g.size.height))
            let top = max(list.map(\.cost).max() ?? 1, 0.0001)
            ZStack(alignment: .topLeading) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, tile in
                    let r = rects[i]
                    if r.width > 0, r.height > 0 {
                        tileView(tile, width: r.width, height: r.height, strength: tile.cost / top)
                            .frame(width: max(r.width - 2, 0), height: max(r.height - 2, 0))
                            .offset(x: r.x + 1, y: r.y + 1)
                    }
                }
            }
        }
    }

    @ViewBuilder private func tileView(_ tile: Tile, width: Double, height: Double, strength: Double) -> some View {
        let fill = tile.isNone ? Color.primary.opacity(0.08) : Theme.seriesCostPerCall.opacity(0.16 + 0.34 * strength)
        let content = ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(fill)
            VStack(alignment: .leading, spacing: 1) {
                if width > 54, height > 28 { Text(tile.label).font(expanded ? .body.weight(.medium) : .caption.weight(.medium)).lineLimit(1).truncationMode(.middle) }
                if width > 54, height > 44 { Text("\(Fmt.money(tile.cost)) · \(Fmt.percent(tile.cost / total * 100))").font(expanded ? .callout : .caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(5)
        }
        .help("\(tile.label)  \(Fmt.money(tile.cost)) · \(Fmt.percent(tile.cost / total * 100))\(tile.detail.isEmpty ? "" : " · \(tile.detail)")")
        if tile.openable {
            Clickable(help: "Open \(tile.label)", action: { onSelect(tile.id) }) { content }
        } else {
            content
        }
    }
}
