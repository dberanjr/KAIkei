import AppKit
import SwiftUI
import UsageCore

/// Which chart to open full screen, and what it is about. Codable and Hashable because a window is opened for a value.
struct ChartSpec: Codable, Hashable {
    enum Kind: String, Codable { case timeline, trend, billed, models, tokensVsDollars, treemap, responses, hours }
    var kind: Kind
    var target: DrillTarget
    /// For treemaps: which breakdown, as a `BreakdownTab` raw value.
    var tab: String?

    init(kind: Kind, target: DrillTarget, tab: String? = nil) { self.kind = kind; self.target = target; self.tab = tab }

    var title: String {
        let name: String
        switch kind {
        case .timeline: name = "Context window and cost"
        case .trend: name = "Last 30 days"
        case .billed: name = "Billed as"
        case .models: name = "By model"
        case .tokensVsDollars: name = "Tokens vs dollars"
        case .treemap: name = tab.flatMap(BreakdownTab.init(rawValue:)).map { "By \($0.rawValue.lowercased().dropLast())" } ?? "Breakdown"
        case .responses: name = "Most expensive responses"
        case .hours: name = "When the cost happens"
        }
        return target == .total ? name : "\(name) · \(target.title)"
    }
}

private struct ChartExpandedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside a maximized chart window: cards draw bigger and drop their own maximize button.
    var chartExpanded: Bool {
        get { self[ChartExpandedKey.self] }
        set { self[ChartExpandedKey.self] = newValue }
    }
}

/// A small corner button that opens its chart in a window as big as the screen.
struct MaximizeButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.chartExpanded) private var expanded
    let spec: ChartSpec

    var body: some View {
        if !expanded {
            Button {
                openWindow(value: spec)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Open this chart as big as the screen")
        }
    }
}

/// The content of a maximized chart window. Reads the same store as the main window, so it stays live and follows the
/// selected period; zoom and overlay choices are shared with the copy on the page.
struct ChartWindowView: View {
    @EnvironmentObject var store: UsageStore
    let spec: ChartSpec
    /// Its own pointer state, so hovering here does not move the crosshair on the page behind.
    @StateObject private var hover = TimelineHover()

    var body: some View {
        GeometryReader { box in
            ScrollView {
                // An exact width: left to size itself, wide content (the chart panels have no natural width) pushed past the window's edge.
                content(height: box.size.height - 56)
                    .padding(28)
                    .frame(width: box.size.width, alignment: .topLeading)
                    .frame(minHeight: box.size.height, alignment: .top)
            }
        }
        .environment(\.chartExpanded, true)
        .background(.regularMaterial)
        .background(FullScreenWindow(title: spec.title, store: store))
        .onAppear { hover.sliceDelay = store.hoverDelay; store.start() }
        .onChange(of: store.hoverDelay) { _, value in hover.sliceDelay = value }
        .overlay(alignment: .topTrailing) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut(.cancelAction).controlSize(.small).padding(10).help("Close this chart (Esc)")
        }
    }

    @ViewBuilder private func content(height: CGFloat) -> some View {
        let d = store.detail(for: spec.target)
        switch spec.kind {
        case .timeline:
            if case .session(let id) = spec.target, let timeline = d.timeline {
                SessionTimelineView(sessionID: id, timeline: timeline, focus: true, availableHeight: height, injectedHover: hover)
            } else {
                Text("No responses recorded for this session yet.").foregroundStyle(.secondary)
            }
        case .trend:
            DailyChart(daily: d.trend, title: "Last 30 days", opensDay: true, height: max(360, height - 120))
        case .billed, .models, .tokensVsDollars:
            CostAnatomy(detail: d, target: spec.target, only: spec.kind)
        case .treemap:
            CostAnatomy(detail: d, target: spec.target, only: .treemap, tab: spec.tab)
        case .responses:
            ResponseTreemapCard(messages: d.topMessages, target: spec.target)
        case .hours:
            HourRoseCard(profile: HourlyProfile(costs: d.hourly), target: spec.target)
        }
    }
}

/// Sizes the chart window to the screen it opens on and gives it the same stacking as the main window (above others
/// only while the main window is pinned), so a maximized chart is never hidden behind the floating widget.
struct FullScreenWindow: NSViewRepresentable {
    let title: String
    let store: UsageStore

    /// The headless snapshot renderer lays charts out in a window of its own size, so it turns this off.
    nonisolated(unsafe) static var enabled = true

    final class Coordinator { var sized = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard Self.enabled else { return }
        let stay = store.stayOnTop
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = title
            window.level = stay ? .floating : .normal
            window.isMovableByWindowBackground = false
            if !context.coordinator.sized {
                context.coordinator.sized = true
                if let visible = (window.screen ?? NSScreen.main)?.visibleFrame { window.setFrame(visible, display: true) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
