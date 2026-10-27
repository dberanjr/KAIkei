import SwiftUI
import UsageCore

struct HeaderBar: View {
    @EnvironmentObject var store: UsageStore

    private var pin: some View {
        Toggle(isOn: $store.stayOnTop) { Image(systemName: store.stayOnTop ? "pin.fill" : "pin.slash") }
            .toggleStyle(.button)
            .help(store.stayOnTop ? "Always on top. Click to let other windows cover it." : "Behaves like a normal window. Click to keep it on top.")
    }

    /// A popover rather than a menu: a menu cannot hold a slider.
    private var more: some View {
        Button { store.showSettings.toggle() } label: {
            HStack(spacing: 2) { Image(systemName: "ellipsis.circle"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .buttonStyle(.borderless).help("Settings")
        .popover(isPresented: $store.showSettings, arrowEdge: .bottom) { SettingsPanel().environmentObject(store) }
    }

    /// Segmented controls when there is room, compact menus when there isn't (S and M sizes).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Picker("Range", selection: $store.range) { ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 310)
                Spacer(minLength: 4)
                Picker("Size", selection: $store.size) { ForEach(WidgetSize.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120).help("Widget size")
                pin
                more
            }
            HStack(spacing: 8) {
                Picker("Range", selection: $store.range) { ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                Spacer(minLength: 4)
                Picker("Size", selection: $store.size) { ForEach(WidgetSize.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize().help("Widget size")
                pin
                more
            }
        }
    }
}

/// The name and a few-word description, centered in the strip at the top of the window. The two small marks on
/// either side are lifted from the app icon (rising bars, a gold dollar sign) so the header and the Dock icon read as
/// one brand. They are decorative: the name carries the meaning, and they drop away when the window is too narrow.
struct BrandBar: View {
    private static let gold = Theme.dynamic(light: 0xc99700, dark: 0xf0b800)

    var body: some View {
        VStack(spacing: 1) {
            // The glow is the background of the name row alone, so it spans the full window width and ends exactly
            // at the bottom of the "KAIkei" text; the tagline below sits on the plain window background.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { BarsMark(); name; dollarMark }
                name
            }
            .padding(.top, 8).padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background { glow }
            Text("Live Claude Code cost & usage")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    /// Warm light from the top edge in a subdued Claude orange: a vertical fade that reaches zero at the bottom of
    /// the row, plus a soft pool behind the name. Peaks stay at 20% so the header reads in both light and dark.
    private var glow: some View {
        ZStack {
            // Eased stops, not a straight ramp: a linear fade ends with a visible seam (a Mach band) at its last stop.
            LinearGradient(stops: [
                .init(color: Theme.claudeOrange.opacity(0.20), location: 0), .init(color: Theme.claudeOrange.opacity(0.11), location: 0.35),
                .init(color: Theme.claudeOrange.opacity(0.04), location: 0.7), .init(color: Theme.claudeOrange.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.claudeOrange.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: 130)
        }
    }

    // Same heavy sans as the icon's wordmark. Size and weight do the work; the name stays in plain ink because the
    // UI's blues and oranges mean model families in the charts.
    private var name: some View {
        Text("KAIkei").font(.system(size: 28, weight: .heavy)).tracking(-0.4).fixedSize()
    }

    private var dollarMark: some View {
        Text("$").font(.system(size: 24, weight: .heavy)).foregroundStyle(Self.gold)
            .shadow(color: Self.gold.opacity(0.55), radius: 5)
            .accessibilityHidden(true)
    }
}

/// Four rising bars in the icon's coral-to-gold ramp.
struct BarsMark: View {
    private let bars: [(height: CGFloat, color: UInt32)] = [
        (12, 0xc8553a), (19, 0xd4603f), (9, 0xe07b00), (24, 0xe8b200),
    ]
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: NSColor(hex: bar.color)))
                    .frame(width: 5, height: bar.height)
            }
        }
        .frame(height: 24, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

struct RootView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandBar()
            HeaderBar().padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
            if store.drillTarget != nil {
                // Detail pages scroll: they are the "much more data" view, and the size buttons give them more room.
                DetailView().frame(maxHeight: .infinity, alignment: .top)
                // Pinned to the foot of the window, outside the scrolling page, so going back never needs a scroll to the top.
                FilterBar()
            } else {
                // No ScrollView on the dashboard: each size shows the richest variant of its content that fits the
                // window, so nothing ever hangs below the bottom edge.
                SizedContent()
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    // minHeight 0 lets this area collapse and clip when even the leanest variant is too tall; without it the
                    // whole column overflows and the header is pushed off the top of the window.
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .clipped()
            }
            if let notice = store.notice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button("Dismiss") { store.notice = nil }.buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 16).padding(.vertical, 8).background(.thinMaterial)
            }
        }
        .frame(minWidth: 300, minHeight: 220)
        .background(.regularMaterial)
        .onAppear { store.start() }
        .confirmationDialog(
            "Clear “\(store.pendingClear?.session.name ?? "")”?",
            isPresented: Binding(get: { store.pendingClear != nil }, set: { if !$0 { store.pendingClear = nil } }),
            presenting: store.pendingClear
        ) { row in
            Button("Clear conversation", role: .destructive) { store.send(.clear, to: row) }
        } message: { _ in
            Text("This types /clear into the terminal and starts a fresh context. It can't be undone.")
        }
    }

}

/// One layout per size, each as an ordered list of variants from richest to leanest. `ViewThatFits(in: .vertical)`
/// shows the first variant that fits the window, so a busy day with many terminals sheds live rows, then breakdown
/// rows, then the lower charts instead of scrolling. The leanest variant is the fallback and is clipped, never scrolled.
struct SizedContent: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        switch store.size {
        case .small:
            ViewThatFits(in: .vertical) {
                small(rows: .max, plan: true); small(rows: 2, plan: true); small(rows: 1, plan: true); small(rows: 1, plan: false)
            }
        case .medium:
            ViewThatFits(in: .vertical) {
                medium(rows: .max, breakdown: 3, plan: true); medium(rows: 3, breakdown: 3, plan: true)
                medium(rows: 2, breakdown: 3, plan: true); medium(rows: 2, breakdown: 2, plan: true)
                medium(rows: 1, breakdown: 2, plan: true); medium(rows: 1, breakdown: 0, plan: true)
                medium(rows: 1, breakdown: 0, plan: false)
            }
        case .large:
            ViewThatFits(in: .vertical) {
                large(rows: .max, breakdown: 6, split: true, strip: true); large(rows: 4, breakdown: 6, split: true, strip: true)
                large(rows: 3, breakdown: 6, split: false, strip: true); large(rows: 3, breakdown: 4, split: false, strip: true)
                large(rows: 2, breakdown: 4, split: false, strip: true); large(rows: 2, breakdown: 3, split: false, strip: false)
                large(rows: 1, breakdown: 3, split: false, strip: false)
            }
        case .xlarge, .full:
            HStack(alignment: .top, spacing: 28) {
                ViewThatFits(in: .vertical) {
                    xlLeft(rows: .max); xlLeft(rows: 4); xlLeft(rows: 3); xlLeft(rows: 2); xlLeft(rows: 1)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                ViewThatFits(in: .vertical) {
                    xlRight(breakdown: 8, split: true, strip: true); xlRight(breakdown: 6, split: true, strip: true)
                    xlRight(breakdown: 5, split: false, strip: true); xlRight(breakdown: 3, split: false, strip: true)
                    xlRight(breakdown: 3, split: false, strip: false)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func small(rows: Int, plan: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TotalsBand(big: false)
            if plan { PlanBand(compact: true) }
            LiveSection(compact: true, maxRows: rows)
        }
    }

    private func medium(rows: Int, breakdown: Int, plan: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TotalsBand(big: false)
            if plan { PlanBand(compact: true) }
            LiveSection(compact: false, maxRows: rows)
            if breakdown > 0 { BreakdownSection(limit: breakdown, showTabs: false) }
        }
    }

    private func large(rows: Int, breakdown: Int, split: Bool, strip: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            TotalsBand(big: true)
            PlanBand(compact: false)
            LiveSection(compact: false, maxRows: rows)
            BreakdownSection(limit: breakdown)
            TrendChart()
            if strip { TrendStrip() }
            if split { MoneySplit() }
        }
    }

    private func xlLeft(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            TotalsBand(big: true)
            PlanBand(compact: false)
            LiveSection(compact: false, maxRows: rows)
        }
    }

    private func xlRight(breakdown: Int, split: Bool, strip: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            TrendChart()
            if strip { TrendStrip() }
            BreakdownSection(limit: breakdown)
            if split { MoneySplit() }
        }
    }
}

/// Reaches the hosting NSWindow for things SwiftUI can't express: window level, spaces, chrome, sizing.
struct WindowConfigurator: NSViewRepresentable {
    @ObservedObject var store: UsageStore

    final class Coordinator { var appliedSizeRequest = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let request = store.sizeRequest
        let stay = store.stayOnTop, everywhere = store.allDesktops, size = store.size
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            w.level = stay ? .floating : .normal
            w.collectionBehavior = everywhere ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            if context.coordinator.appliedSizeRequest != request {
                context.coordinator.appliedSizeRequest = request
                var frame = w.frame
                var target = w.frameRect(forContentRect: NSRect(origin: .zero, size: size.dimensions)).size
                // Never ask for more than the screen has: the layouts shed content to fit, so a shorter window is fine.
                if let visible = w.screen?.visibleFrame {
                    target.height = min(target.height, visible.height - 8)
                    target.width = min(target.width, visible.width - 8)
                }
                frame.origin.y += frame.height - target.height  // keep the top-left corner anchored
                frame.size = target
                // Full covers the usable area of the window's screen exactly, wherever the window was.
                if size == .full, let visible = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame { frame = visible }
                w.setFrame(frame, display: true, animate: context.coordinator.appliedSizeRequest > 0)
            }
        }
    }
}
