import SwiftUI
import UsageCore

/// The one distinctive element: a thin gauge for context-window use, ticked at quarters. At 85% and above it
/// also says so in words, so the warning never depends on color alone.
struct ContextTape: View {
    let percent: Double
    private var fraction: Double { min(max(percent / 100, 0), 1) }
    var tint: Color { percent >= 85 ? Theme.critical : percent >= 60 ? Theme.caution : Theme.accent }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.09)).frame(height: 6)
                Capsule().fill(tint).frame(width: max(6, g.size.width * fraction), height: 6)
                ForEach([0.25, 0.5, 0.75], id: \.self) { t in
                    Rectangle().fill(.primary.opacity(0.28)).frame(width: 1, height: 10).offset(x: g.size.width * t)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Context window")
        .accessibilityValue(Fmt.percent(percent))
    }
}

struct ModelChip: View {
    let modelID: String
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.color(ModelFamily(modelID: modelID))).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StatusDot: View {
    let status: String
    var body: some View {
        // Busy pulses via the label text, not only the color: color-blind readers still get "working".
        Circle().fill(status == "busy" ? Theme.good : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            .help(status == "busy" ? "Working" : "Idle")
    }
}

/// One open terminal, laid out like Claude Code's own status line but with room to breathe.
struct TerminalRow: View {
    @EnvironmentObject var store: UsageStore
    let row: LiveRow
    let compact: Bool

    private var host: String { row.session.entrypoint == "claude-desktop" ? "Desktop" : (row.tty ?? "terminal") }
    private var isArchived: Bool { store.archivedSessions.contains(row.id) }
    /// An archived session being shown for restoring is always one line. A collapsed one hides everything but its title and cost.
    private var isCollapsed: Bool { isArchived || store.collapsedSessions.contains(row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !isArchived {
                    Button { store.toggleCollapsed(row.id) } label: {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .bold)).frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless).help(isCollapsed ? "Expand this session" : "Collapse to one line")
                }
                // Title and context bar open this session's detail. The Compact and Clear buttons below stay separate.
                Clickable(help: "Open this session's detail", action: { store.drill(into: .session(row.id)) }) { titleBlock }
                rowMenu
            }
            if !isCollapsed {
                accountLine
                if row.contextPercent >= 85 {
                    Label("Context nearly full. Compact or clear soon.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.critical)
                }
                if !compact { details }
            }
        }
        .padding(.vertical, isCollapsed ? 5 : 8)
        .opacity(isArchived ? 0.55 : 1)
        .contextMenu { rowActions }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(status: row.session.status)
                Text(row.session.name.isEmpty ? Aggregator.projectName(row.session.cwd) : row.session.name)
                    .font(.system(.body, weight: .medium)).lineLimit(1)
                Text(host).font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if isCollapsed { Text(Fmt.percent(row.contextPercent)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                Text(Fmt.money(row.cost)).font(.system(.body, weight: .semibold)).monospacedDigit()
            }
            if !isCollapsed {
                HStack(spacing: 10) {
                    ContextTape(percent: row.contextPercent)
                    Text(Fmt.percent(row.contextPercent)).font(.caption.weight(.medium)).monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    /// Collapse and archive, in a small menu at the end of the title line and on right-click.
    private var rowMenu: some View {
        Menu { rowActions } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Collapse or archive this session")
    }

    @ViewBuilder private var rowActions: some View {
        if isArchived {
            Button("Restore to the list") { store.restore(row.id) }
        } else {
            Button(isCollapsed ? "Expand" : "Collapse") { store.toggleCollapsed(row.id) }
            Button("Archive (hide from this list)") { store.archive(row.id) }
        }
    }

    /// Which Claude account this window is running as, and on what license. Read from Claude Code's own config.
    @ViewBuilder private var accountLine: some View {
        if let account = row.account {
            Label {
                Text("\(account.email) · \(account.licenseLabel)").lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "person.crop.circle")
            }
            .font(.caption).foregroundStyle(.secondary)
            .help("Signed in as \(account.email)\(account.organization.map { " (\($0))" } ?? ""). Plan: \(account.licenseLabel). Read from Claude Code's config, ~/.claude.json.")
        }
    }

    @ViewBuilder private var details: some View {
        HStack(spacing: 12) {
            ModelChip(modelID: row.model, label: row.modelLabel)
            if let effort = row.statusline?.effort { Text("effort \(effort)").foregroundStyle(.secondary) }
            Text("\(Fmt.tokens(row.contextTokens)) of \(Fmt.tokens(row.contextWindow)) context")
                .foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            if let sl = row.statuslineCost {
                Text("status line \(Fmt.money(sl))").foregroundStyle(.tertiary).monospacedDigit()
                    .help("Claude Code's own running cost estimate. It can differ from token-based list price.")
            }
        }
        .font(.caption).lineLimit(1).minimumScaleFactor(0.85)
        // Stats and buttons share a line when they fit; otherwise the buttons drop below, never truncated.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { stats; Spacer(minLength: 8); controls }
            VStack(alignment: .leading, spacing: 6) {
                stats
                HStack { Spacer(); controls }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            usageStat("in", row.usage.input)
            usageStat("out", row.usage.output)
            usageStat("cache read", row.usage.cacheRead)
            usageStat("cache write", row.usage.cacheWrite)
            if let sl = row.statusline, sl.linesAdded + sl.linesRemoved > 0 {
                Text("+\(sl.linesAdded) −\(sl.linesRemoved)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let sl = row.statusline, sl.durationSeconds > 0 {
                Text(Fmt.duration(sl.durationSeconds)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1).fixedSize()
    }

    private func usageStat(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(Fmt.tokens(value)).foregroundStyle(.secondary).monospacedDigit()
        }.font(.caption)
    }

    @ViewBuilder private var controls: some View {
        let availability = store.availability(for: row)
        let reason: String? = { if case .unavailable(let r) = availability { return r } else { return nil } }()
        HStack(spacing: 6) {
            Button("Compact") { store.send(.compact, to: row) }
                .help(reason ?? "Types /compact into this terminal to summarize the conversation and free context.")
            Button("Clear") { store.pendingClear = row }
                .help(reason ?? "Types /clear into this terminal. The conversation history is dropped.")
        }
        .controlSize(.small).fixedSize()
        .disabled(reason != nil)
    }
}

struct LiveSection: View {
    @EnvironmentObject var store: UsageStore
    let compact: Bool
    var maxRows: Int = .max

    var body: some View {
        let all = store.dashboard?.live ?? []
        let split = SessionVisibility.partition(all, id: \.id, archived: store.archivedSessions)
        let rows = SessionVisibility.ordered(all, id: \.id, archived: store.archivedSessions, includeArchived: store.showArchived)
        // The total is for the sessions in the list; archived ones are counted in the footer so nothing silently drops out.
        let visibleCost = split.visible.reduce(0) { $0 + $1.cost }
        let visibleTokens = split.visible.reduce(0) { $0 + $1.usage.total }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(split.visible.count == 1 ? "1 open session" : "\(split.visible.count) open sessions").font(.headline)
                if split.visible.count > 1 {
                    let allCollapsed = split.visible.allSatisfy { store.collapsedSessions.contains($0.id) }
                    Button(allCollapsed ? "Expand all" : "Collapse all") {
                        if allCollapsed { store.collapsedSessions.subtract(split.visible.map(\.id)) } else { store.collapsedSessions.formUnion(split.visible.map(\.id)) }
                    }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if split.visible.count > 1 {
                    Text("Total \(Fmt.money(visibleCost))").font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text("\(Fmt.tokens(visibleTokens)) tokens").font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Text(all.isEmpty ? "No Claude Code sessions are open. Start one in a terminal and it appears here."
                                 : "Every open session is archived.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(Array(rows.prefix(maxRows))) { row in
                Divider()
                TerminalRow(row: row, compact: compact)
            }
            if rows.count > maxRows {
                Text("+\(rows.count - maxRows) more. Use a larger size to see all.").font(.caption).foregroundStyle(.secondary)
            }
            if !split.archived.isEmpty {
                archivedFooter(split.archived)
            }
        }
    }

    private func archivedFooter(_ archived: [LiveRow]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox").font(.caption)
            Text("\(archived.count) archived · \(Fmt.money(archived.reduce(0) { $0 + $1.cost }))")
            Spacer()
            Button(store.showArchived ? "Hide" : "Show") { store.showArchived.toggle() }.buttonStyle(.borderless)
        }
        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        .help("Archived sessions are hidden from this list only. They keep running and still count in the totals above.")
    }
}
