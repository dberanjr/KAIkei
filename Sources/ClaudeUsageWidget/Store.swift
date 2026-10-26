import Foundation
import SwiftUI
import UsageCore

enum WidgetSize: String, CaseIterable, Identifiable {
    case small = "S", medium = "M", large = "L", xlarge = "XL"
    var id: String { rawValue }
    var dimensions: CGSize {
        switch self {
        case .small: CGSize(width: 330, height: 300)
        case .medium: CGSize(width: 440, height: 520)
        case .large: CGSize(width: 580, height: 900)
        case .xlarge: CGSize(width: 1000, height: 760)
        }
    }
}

/// What the session timeline's horizontal axis means. Time shows idle gaps (which is when caches expire); Calls
/// spaces every response evenly, which reads better when a session spans days.
enum TimelineAxis: String, CaseIterable, Identifiable {
    case time = "Time", calls = "Calls"
    var id: String { rawValue }
}

/// A measure that can be drawn on its own panel under the context chart, or overlaid on the context chart itself.
/// Each has its own color so it stays recognisable either way.
enum TimelineSeries: String, CaseIterable, Identifiable {
    case output = "Output tokens", costPerCall = "Cost per call", cumulative = "Cost so far"
    var id: String { rawValue }
    /// What a fresh install draws on the context chart.
    static let defaultOverlays: Set<TimelineSeries> = [.output, .cumulative]
    var color: Color {
        switch self {
        case .output: Theme.seriesOutput
        case .costPerCall: Theme.seriesCostPerCall
        case .cumulative: Theme.seriesCumulative
        }
    }
    /// Said in the panel's own header, so each chart announces what it measures.
    var blurb: String {
        switch self {
        case .output: "tokens the model wrote each call (lighter is thinking)"
        case .costPerCall: "what each response billed, by kind"
        case .cumulative: "running session total"
        }
    }
}

enum BreakdownTab: String, CaseIterable, Identifiable {
    case models = "Models", skills = "Skills", plugins = "Plugins", tools = "Tools", projects = "Projects"
    var id: String { rawValue }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var dashboard: Dashboard?
    @Published private(set) var terminalApps: [String: TerminalApp] = [:]
    @Published var notice: String?
    // Transient UI state lives here rather than in @State: that is a macro whose plugin only ships with Xcode.
    @Published var pendingClear: LiveRow?
    @Published var trendSelection: Date?
    /// Pointer state for the session timeline. A separate object so mouse movement never redraws the charts.
    let timelineHover = TimelineHover()
    /// Nil means automatic: Time, unless the session spans more than a day and a half.
    @Published var timelineAxis: TimelineAxis? { didSet { if oldValue != timelineAxis { timelineWindow = nil } } }
    /// The zoomed stretch of the session timeline, as real dates. Nil shows the whole session.
    @Published var timelineWindow: ClosedRange<Date>?
    /// Drill-down trail: empty shows the dashboard, otherwise the last element is the detail on screen and Back pops it.
    @Published private(set) var trail = DrillStack()
    /// Bumped when the user picks a size so the window resizes once, without fighting manual resizing.
    @Published private(set) var sizeRequest = 0

    @Published var range: TimeRange { didSet { defaults.set(range.rawValue, forKey: "range"); refresh() } }
    @Published var size: WidgetSize { didSet { defaults.set(size.rawValue, forKey: "size"); sizeRequest += 1 } }
    @Published var tab: BreakdownTab { didSet { defaults.set(tab.rawValue, forKey: "tab") } }
    @Published var stayOnTop: Bool { didSet { defaults.set(stayOnTop, forKey: "stayOnTop") } }
    @Published var allDesktops: Bool { didSet { defaults.set(allDesktops, forKey: "allDesktops") } }
    @Published var billing: CacheWriteBilling { didSet { defaults.set(billing.rawValue, forKey: "billing"); refresh() } }
    /// Seconds the pointer must rest before a slice card opens, 0 to 1. Event bars use a fraction of it.
    @Published var hoverDelay: Double {
        didSet {
            // Assigning to a @Published property from its own didSet goes back through the wrapper's setter and runs didSet
            // again, so write back only when the clamp changes something. Unconditionally, this recursed until the stack ran out.
            let clamped = DwellTracker.clamp(hoverDelay)
            if clamped != hoverDelay { hoverDelay = clamped; return }
            defaults.set(hoverDelay, forKey: "hoverDelay")
            timelineHover.sliceDelay = hoverDelay
        }
    }
    /// The series drawn on the context chart. Any series not in here has its own panel underneath.
    @Published var overlays: Set<TimelineSeries> {
        didSet { defaults.set(overlays.map(\.rawValue).sorted(), forKey: "overlays") }
    }
    /// Also draws the feature lanes' markers (loop iterations, sub-agent runs, test runs) on the context chart. Off by default:
    /// the lanes under the chart already show them.
    @Published var featureOverlayOn: Bool { didSet { defaults.set(featureOverlayOn, forKey: "featureOverlayOn") } }
    /// Which lanes are drawn on the context chart while `featureOverlayOn` is set.
    @Published var featureOverlayLanes: Set<FeatureLane> {
        didSet { defaults.set(featureOverlayLanes.map(\.rawValue).sorted(), forKey: "featureOverlayLanes") }
    }
    @Published var showSettings = false
    /// Sessions folded down to one line. Remembered across launches, by session id.
    @Published var collapsedSessions: Set<String> { didSet { defaults.set(collapsedSessions.sorted(), forKey: "collapsedSessions") } }
    /// Sessions hidden from the open-sessions list. A display preference only: the session keeps running and its spend
    /// still counts in the totals for the period.
    @Published var archivedSessions: Set<String> { didSet { defaults.set(archivedSessions.sorted(), forKey: "archivedSessions") } }
    /// Temporarily lists archived sessions again, dimmed, so one can be restored.
    @Published var showArchived = false

    private let defaults: UserDefaults
    private let collector = UsageCollector()
    private let queue = DispatchQueue(label: "claude-usage.collector", qos: .utility)
    private var timer: Timer?
    private var refreshing = false

    /// `defaults` is injectable so the headless snapshot tool can run against a throwaway preferences store instead of the real one.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        range = TimeRange(rawValue: defaults.string(forKey: "range") ?? "") ?? .today
        size = WidgetSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .large
        tab = BreakdownTab(rawValue: defaults.string(forKey: "tab") ?? "") ?? .models
        stayOnTop = defaults.object(forKey: "stayOnTop") as? Bool ?? true
        allDesktops = defaults.object(forKey: "allDesktops") as? Bool ?? false
        billing = CacheWriteBilling(rawValue: defaults.string(forKey: "billing") ?? "") ?? .listPrice
        let delay = defaults.object(forKey: "hoverDelay") as? Double ?? DwellTracker.defaultSliceDelay
        hoverDelay = DwellTracker.clamp(delay)
        // A fresh install overlays output tokens and the running cost on the context chart; cost per call keeps its own panel.
        // Once the user has made a choice (even to overlay nothing) that choice wins.
        overlays = defaults.object(forKey: "overlays") == nil
            ? TimelineSeries.defaultOverlays
            : Set((defaults.stringArray(forKey: "overlays") ?? []).compactMap(TimelineSeries.init(rawValue:)))
        featureOverlayOn = defaults.object(forKey: "featureOverlayOn") as? Bool ?? false
        featureOverlayLanes = defaults.object(forKey: "featureOverlayLanes") == nil
            ? Set(FeatureLane.allCases)
            : Set((defaults.stringArray(forKey: "featureOverlayLanes") ?? []).compactMap(FeatureLane.init(rawValue:)))
        collapsedSessions = Set(defaults.stringArray(forKey: "collapsedSessions") ?? [])
        archivedSessions = Set(defaults.stringArray(forKey: "archivedSessions") ?? [])
        timelineHover.sliceDelay = hoverDelay  // after every stored property is set, so self is usable
    }

    private var laneCache: [String: (key: [Int], lanes: FeatureLanes)] = [:]

    /// The feature lanes for a session, rebuilt only when its calls or the transcript signals change.
    func featureLanes(sessionID: String, timeline: SessionTimeline) -> FeatureLanes {
        let signals = dashboard?.signals ?? []
        let key = [timeline.calls.count, signals.count, Int(timeline.end.timeIntervalSince1970)]
        if let hit = laneCache[sessionID], hit.key == key { return hit.lanes }
        let lanes = FeatureLanes.build(signals: signals, timeline: timeline, sessionID: sessionID)
        laneCache[sessionID] = (key, lanes)
        return lanes
    }

    func toggleCollapsed(_ id: String) {
        if collapsedSessions.contains(id) { collapsedSessions.remove(id) } else { collapsedSessions.insert(id) }
    }

    func archive(_ id: String) { archivedSessions.insert(id); collapsedSessions.remove(id) }

    func restore(_ id: String) {
        archivedSessions.remove(id)
        if archivedSessions.isEmpty { showArchived = false }
    }

    func restoreAllArchived() { archivedSessions = []; showArchived = false }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let billing = self.billing
        queue.async { [collector] in
            collector.billing = billing
            let dash = collector.refresh()
            let table = dash.live.isEmpty ? [:] : TerminalControl.processTable()
            let apps = Dictionary(uniqueKeysWithValues: dash.live.map {
                ($0.id, TerminalControl.detectApp(pid: $0.session.pid, table: table))
            })
            DispatchQueue.main.async {
                self.dashboard = self.padded(dash)
                self.terminalApps = apps
                self.refreshing = false
            }
        }
    }

    /// Snapshot mode only: repeats the open sessions until there are this many, to check how a layout copes with
    /// many terminals. Applied on every refresh so the 3-second timer cannot overwrite it mid-render.
    var previewLiveCount: Int? { didSet { if let d = dashboard { dashboard = padded(d) } } }

    private func padded(_ dash: Dashboard) -> Dashboard {
        guard let count = previewLiveCount, !dash.live.isEmpty else { return dash }
        var out = dash
        let originals = dash.live
        while out.live.count < count {
            var copy = originals[out.live.count % originals.count]
            copy.session.sessionID += "-preview\(out.live.count)"
            out.live.append(copy)
        }
        out.live = Array(out.live.prefix(count))
        return out
    }

    var drillTarget: DrillTarget? { trail.current }

    func drill(into target: DrillTarget) {
        guard trail.current != target else { return }
        trendSelection = nil
        timelineWindow = nil
        trail.push(target)
    }

    func back() { if trail.isFiltered { trail.back(); timelineWindow = nil } }
    func closeDrill() { trail.clear(); timelineWindow = nil }
    /// Jumps to an earlier level of the trail (0 is the dashboard).
    func keepLevels(_ count: Int) { trail.keep(count); timelineWindow = nil }

    /// Built on demand from the records already in memory, for whatever range is selected.
    func detail(for target: DrillTarget) -> DrillDetail {
        Drilldown.detail(
            records: dashboard?.records ?? [], events: dashboard?.events ?? [], target: target, range: range, now: Date(), calendar: .current, billing: billing)
    }

    /// A readable name for a session target: the live terminal's name if it is open, else the project it ran in.
    func sessionTitle(_ id: String) -> String? {
        dashboard?.live.first { $0.id == id }.map { $0.session.name.isEmpty ? Aggregator.projectName($0.session.cwd) : $0.session.name }
    }

    var snapshot: Snapshot { dashboard?.snapshots[range] ?? Snapshot() }
    var monthSnapshot: Snapshot { dashboard?.snapshots[.month] ?? Snapshot() }
    var todayCost: Double { dashboard?.snapshots[.today]?.totalCost ?? 0 }

    func availability(for row: LiveRow) -> Availability {
        TerminalControl.availability(app: terminalApps[row.id] ?? .unsupported, tty: row.tty, status: row.session.status)
    }

    func send(_ command: ControlCommand, to row: LiveRow) {
        guard let tty = row.tty else { return }
        let pid = row.session.pid
        queue.async {
            let problem = TerminalControl.send(command, pid: pid, tty: tty)
            DispatchQueue.main.async { self.notice = problem ?? "Sent \(command.rawValue) to \(row.session.name)." }
        }
    }
}
