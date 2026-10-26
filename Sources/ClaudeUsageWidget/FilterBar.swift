import SwiftUI
import UsageCore

enum FilterMarker {
    /// Viewing "All usage" in detail is not a filter; every other detail page narrows the view to one thing.
    static func isFiltered(_ target: DrillTarget) -> Bool { target != .total }
}

/// Pinned along the foot of the window while a detail page is open: it says what the view is filtered to, and is the way
/// back. It sits outside the scrolling page, so it is always there however far down the page is scrolled.
struct FilterBar: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        let trail = store.trail
        let filtered = trail.targets.contains(where: FilterMarker.isFiltered)
        VStack(spacing: 0) {
            Rectangle().fill((filtered ? Theme.accent : Color.primary).opacity(filtered ? 0.55 : 0.12)).frame(height: filtered ? 1.5 : 0.5)
            ViewThatFits(in: .horizontal) {
                wide(trail, filtered: filtered)
                narrow(trail, filtered: filtered)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(filtered ? Theme.accent.opacity(0.09) : Color.clear)
        }
        .background(.bar)
    }

    /// A session reads as the name it has in the list, not its id.
    private func label(for target: DrillTarget?) -> String {
        guard let target else { return "" }
        if case .session(let id) = target, let name = store.sessionTitle(id) { return name }
        return target.title
    }

    private func backButton(_ trail: DrillStack, short: Bool) -> some View {
        Button { store.back() } label: {
            Label(short ? "Back" : "Back to \(trail.previousTitle ?? "the dashboard")", systemImage: "chevron.left").lineLimit(1)
        }
        .controlSize(.small).keyboardShortcut(.cancelAction)
        .help("Remove this filter and return to \(trail.previousTitle ?? "the dashboard") (Esc)")
    }

    private func marker(filtered: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "chart.bar.doc.horizontal")
            Text(filtered ? "Filtered" : "Viewing").fontWeight(.semibold)
        }
        .font(.caption).foregroundStyle(filtered ? Theme.accent : .secondary)
    }

    /// The whole trail, each earlier level a link back to it.
    private func wide(_ trail: DrillStack, filtered: Bool) -> some View {
        HStack(spacing: 10) {
            backButton(trail, short: false)
            marker(filtered: filtered)
            HStack(spacing: 4) {
                ForEach(Array(trail.crumbs.enumerated()), id: \.offset) { i, crumb in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                    let text = i == 0 ? crumb.label : label(for: trail.targets[i - 1])
                    if i == trail.crumbs.count - 1 {
                        Text(text).font(.caption.weight(.semibold)).lineLimit(1)
                    } else {
                        Button(text) { store.keepLevels(crumb.keeping) }.buttonStyle(.link).font(.caption).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if trail.depth > 1 {
                Button { store.closeDrill() } label: { Label("Clear all", systemImage: "xmark.circle") }
                    .controlSize(.small).help("Remove every filter and return to the dashboard")
            }
        }
    }

    /// Small windows: Back, what it is filtered to, and a clear button.
    private func narrow(_ trail: DrillStack, filtered: Bool) -> some View {
        HStack(spacing: 8) {
            backButton(trail, short: true)
            marker(filtered: filtered)
            Text(label(for: trail.current)).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if trail.depth > 1 {
                Button { store.closeDrill() } label: { Image(systemName: "xmark.circle") }.controlSize(.small).help("Remove every filter")
            }
        }
    }
}
