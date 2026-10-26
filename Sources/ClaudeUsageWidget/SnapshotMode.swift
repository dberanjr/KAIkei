import AppKit
import SwiftUI
import UsageCore

/// `ClaudeUsageWidget --snapshot <S|M|L|XL> <out.png> [dark] [sessions=N] [drill=KIND:VALUE] [height=N] [axis=calls] [tip=call:N|prompt:N|compact:N|model:N] [zoom=LO-HI] [overlay=output,cost,cum|all] [lanes=on] [lanesoverlay=loop,agents,tests|all] [collapse=all] [archive=N] [chart=KIND[:TAB] width=N height=N]` renders the real view hierarchy to a PNG
/// without needing a visible window, so layouts can be reviewed (and screenshotted) headlessly.
enum SnapshotMode {
    @MainActor static func run(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 2,
            let size = WidgetSize(rawValue: arguments[flag + 1].uppercased())
        else {
            FileHandle.standardError.write(Data("usage: --snapshot <S|M|L|XL> <out.png> [dark]\n".utf8))
            return
        }
        let output = arguments[flag + 2]
        let dark = arguments.contains("dark")

        _ = NSApplication.shared
        FullScreenWindow.enabled = false
        // A throwaway preferences store, wiped each run: snapshots start from a fresh install's defaults and never touch the real preferences.
        let suite = UserDefaults(suiteName: "local.claude-usage-widget.snapshot")!
        suite.removePersistentDomain(forName: "local.claude-usage-widget.snapshot")
        let store = UsageStore(defaults: suite)
        store.size = size
        store.start()
        if let pad = arguments.first(where: { $0.hasPrefix("sessions=") }), let count = Int(pad.dropFirst(9)) {
            store.previewLiveCount = count
        }
        RunLoop.main.run(until: Date().addingTimeInterval(3))  // let the first background scan land
        if arguments.contains("axis=calls") { store.timelineAxis = .calls }
        if let o = arguments.first(where: { $0.hasPrefix("overlay=") })?.dropFirst(8) {
            var set = Set<TimelineSeries>()
            for name in o.split(separator: ",") {
                switch name {
                case "output": set.insert(.output)
                case "cost": set.insert(.costPerCall)
                case "cum": set.insert(.cumulative)
                case "all": set = Set(TimelineSeries.allCases)
                default: break
                }
            }
            store.overlays = set
        }
        // `lanes=on` also draws the feature lanes' markers on the context chart; `lanesoverlay=` picks which (default: all).
        if arguments.contains("lanes=on") { store.featureOverlayOn = true }
        if let o = arguments.first(where: { $0.hasPrefix("lanesoverlay=") })?.dropFirst(13) {
            var set = Set<FeatureLane>()
            for name in o.split(separator: ",") {
                switch name {
                case "loop": set.insert(.loop)
                case "agents": set.insert(.subagents)
                case "tests": set.insert(.tests)
                case "all": set = Set(FeatureLane.allCases)
                default: break
                }
            }
            store.featureOverlayLanes = set
        }
        // `hoverdelay=V` drives the same setter the settings slider uses (a regression check for it crashing).
        if let v = arguments.first(where: { $0.hasPrefix("hoverdelay=") }).flatMap({ Double($0.dropFirst(11)) }) {
            for step in stride(from: 0.8, through: v, by: v < 0.8 ? -0.05 : 0.05) { store.hoverDelay = step }
            store.hoverDelay = v
            print("hover delay now", store.hoverDelay, "tracker", store.timelineHover.sliceDelay)
        }
        if arguments.contains("collapse=all") { store.collapsedSessions = Set((store.dashboard?.live ?? []).map(\.id)) }
        if let a = arguments.first(where: { $0.hasPrefix("archive=") }), let n = Int(a.dropFirst(8)) {
            store.archivedSessions = Set((store.dashboard?.live ?? []).prefix(n).map(\.id))
        }
        let tip = arguments.first(where: { $0.hasPrefix("tip=") }).map { String($0.dropFirst(4)) }
        // Repeat `drill=` to go several levels deep, in order.
        for arg in arguments where arg.hasPrefix("drill=") {
            if let target = target(from: String(arg.dropFirst(6)), store: store) { store.drill(into: target) }
        }

        if let z = arguments.first(where: { $0.hasPrefix("zoom=") })?.dropFirst(5), case .session(let id)? = store.drillTarget,
            let timeline = store.detail(for: .session(id)).timeline {
            let bounds = z.split(separator: "-").compactMap { Double($0) }
            let g = TimelineGeometry(timeline: timeline, byCalls: store.timelineAxis == .calls)
            if bounds.count == 2 {
                let full = g.fullDomain, width = full.upperBound - full.lowerBound
                store.timelineWindow = g.window(selecting: full.lowerBound + bounds[0] * width, full.lowerBound + bounds[1] * width)
            }
        }
        if let tip, case .session(let id)? = store.drillTarget {
            let timeline = store.detail(for: .session(id)).timeline
            previewTip(tip, timeline: timeline, store: store)
        }
        // `chart=timeline|trend|billed|models|tokensVsDollars|treemap:Skills|responses|hours` renders that chart as the full-screen
        // chart window would show it (about the current drill target), at `width` x `height`.
        let host: NSHostingView<AnyView>
        if let c = arguments.first(where: { $0.hasPrefix("chart=") })?.dropFirst(6) {
            let parts = c.split(separator: ":").map(String.init)
            let kind = ChartSpec.Kind(rawValue: parts.first ?? "") ?? .timeline
            let spec = ChartSpec(kind: kind, target: store.drillTarget ?? .total, tab: parts.count > 1 ? parts[1] : nil)
            host = NSHostingView(rootView: AnyView(ChartWindowView(spec: spec).environmentObject(store)))
        } else {
            host = NSHostingView(rootView: AnyView(RootView().environmentObject(store)))
        }
        var dimensions = size.dimensions
        if let h = arguments.first(where: { $0.hasPrefix("height=") }), let value = Double(h.dropFirst(7)) { dimensions.height = value }
        if let w = arguments.first(where: { $0.hasPrefix("width=") }), let value = Double(w.dropFirst(6)) { dimensions.width = value }
        let frame = NSRect(origin: .zero, size: dimensions)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))  // charts lay out on the next pass

        // `drag=X0,Y0>X1,Y1` (points from the top-left) sends real mouse events through the window, so the gestures
        // can be checked without a person at the mouse. A picture is taken mid-drag, and the result is printed.
        if let spec = arguments.first(where: { $0.hasPrefix("drag=") })?.dropFirst(5) {
            drive(spec: String(spec), window: window, host: host, store: store, frame: frame, output: output)
        }
        // `hover=X,Y[,SECONDS]` rests the pointer there, as the surface would see it, and reports which card opened.
        if let spec = arguments.first(where: { $0.hasPrefix("hover=") })?.dropFirst(6) {
            let v = spec.split(separator: ",").compactMap { Double($0) }
            if v.count >= 2, let event = mouse(.mouseMoved, CGPoint(x: v[0], y: v[1]), window: window, height: frame.height) {
                let target = host.hitTest(CGPoint(x: v[0], y: frame.height - v[1])) ?? host
                print("hover target view:", String(describing: type(of: target)))
                target.mouseMoved(with: event)
                RunLoop.main.run(until: Date().addingTimeInterval(v.count > 2 ? v[2] : 1.2))
                print("hover shown:", store.timelineHover.shown.map { "\($0)" } ?? "nothing", "· delay", store.hoverDelay)
            }
        }
        if let spec = arguments.first(where: { $0.hasPrefix("scroll=") })?.dropFirst(7) {
            scroll(spec: String(spec), window: window, host: host, store: store)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: frame) else { return }
        host.cacheDisplay(in: frame, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: output))
            print("wrote \(output) (\(Int(frame.width))x\(Int(frame.height)))")
        }
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, window: NSWindow, height: CGFloat) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: CGPoint(x: point.x, y: height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    @MainActor private static func drive(spec: String, window: NSWindow, host: NSView, store: UsageStore, frame: NSRect, output: String) {
        let ends = spec.split(separator: ">").map { $0.split(separator: ",").compactMap { Double($0) } }
        guard ends.count == 2, ends[0].count == 2, ends[1].count == 2 else { return }
        let a = CGPoint(x: ends[0][0], y: ends[0][1]), b = CGPoint(x: ends[1][0], y: ends[1][1])
        let h = frame.height
        window.isMovableByWindowBackground = true  // as in the real window
        window.orderBack(nil)
        window.sendEvent(mouse(.mouseMoved, a, window: window, height: h)!)
        window.sendEvent(mouse(.leftMouseDown, a, window: window, height: h)!)
        for i in 1...12 {
            let t = Double(i) / 12
            window.sendEvent(mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), window: window, height: h)!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        print("mid-drag: selection =", store.timelineHover.selection.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "none")
        if let rep = host.bitmapImageRepForCachingDisplay(in: frame) {
            host.cacheDisplay(in: frame, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.replacingOccurrences(of: ".png", with: "-mid.png")))
        }
        window.sendEvent(mouse(.leftMouseUp, b, window: window, height: h)!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        print("after release: window =", store.timelineWindow.map { "\($0.lowerBound.timeIntervalSince1970)...\($0.upperBound.timeIntervalSince1970) (\(Int($0.upperBound.timeIntervalSince($0.lowerBound))) s)" } ?? "none")
    }

    @MainActor private static func scroll(spec: String, window: NSWindow, host: NSView, store: UsageStore) {
        // `scroll=X,Y,DX` : a horizontal scroll of DX points at (X, Y)
        let v = spec.split(separator: ",").compactMap { Double($0) }
        guard v.count == 3 else { return }
        let before = store.timelineWindow
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(v[2]), wheel3: 0)
        cg?.location = CGPoint(x: v[0], y: v[1])
        if let cg, let event = NSEvent(cgEvent: cg) {
            let target = host.hitTest(CGPoint(x: v[0], y: host.frame.height - v[1])) ?? host
            target.scrollWheel(with: event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func secs(_ w: ClosedRange<Date>?) -> String { w.map { String(format: "%.1f...%.1f", $0.lowerBound.timeIntervalSince1970 - 1792690000, $0.upperBound.timeIntervalSince1970 - 1792690000) } ?? "none" }
        print("scroll: window \(secs(before)) -> \(secs(store.timelineWindow))")
    }

    /// `total`, `session:live` (the first open session), `day:N` (N days ago), or `model|skill|plugin|tool|project|session:VALUE`.
    @MainActor private static func target(from spec: String, store: UsageStore) -> DrillTarget? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "total": return .total
        case "model": return .model(value)
        case "skill": return .skill(value)
        case "plugin": return .plugin(value)
        case "tool": return .tool(value)
        case "project": return .project(value)
        case "session": return .session(value == "live" ? (store.dashboard?.live.first?.id ?? value) : value)
        case "day": return .day(Calendar.current.startOfDay(for: Date().addingTimeInterval(-(Double(value) ?? 0) * 86_400)))
        default: return nil
        }
    }

    /// Opens a hover card without a pointer so it can be reviewed in a PNG: `call:N` (1-based), `prompt:N`, `compact:N`, `model:N`.
    @MainActor private static func previewTip(_ spec: String, timeline: SessionTimeline?, store: UsageStore) {
        guard let timeline else { return }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 2, let n = Int(parts[1]), n >= 1 else { return }
        switch parts[0] {
        case "call" where n <= timeline.calls.count:
            store.timelineHover.preview(.call(n - 1), focus: n - 1)
        case "prompt":
            let prompts = timeline.markers.filter { if case .prompt = $0.kind { true } else { false } }
            if n <= prompts.count { store.timelineHover.preview(.marker(prompts[n - 1].id), focus: nil) }
        case "compact":
            let compacts = timeline.markers.filter { if case .compact = $0.kind { true } else { false } }
            if n <= compacts.count { store.timelineHover.preview(.marker(compacts[n - 1].id), focus: nil) }
        case "model" where n <= timeline.modelSpans.count:
            store.timelineHover.preview(.modelSpan(timeline.modelSpans[n - 1].id), focus: nil)
        default: break
        }
    }
}
