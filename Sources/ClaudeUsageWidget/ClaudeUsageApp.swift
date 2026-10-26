import SwiftUI
import UsageCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The menu-bar item keeps the app useful when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore()

    init() {
        // Maximized chart windows are opened on demand; they should not come back on their own at the next launch.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        if CommandLine.arguments.contains("--dump") { Dump.run(); exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--send") { Dump.send(Array(CommandLine.arguments.dropFirst(i + 1))); exit(0) }
        if CommandLine.arguments.contains("--snapshot") {
            MainActor.assumeIsolated { SnapshotMode.run(arguments: CommandLine.arguments) }
            exit(0)
        }
    }

    var body: some Scene {
        Window("KAIkei", id: "main") {
            RootView()
                .environmentObject(store)
                .background(WindowConfigurator(store: store))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: WidgetSize.large.dimensions.width, height: WidgetSize.large.dimensions.height)

        // Any chart, opened as big as the screen. One window per chart.
        WindowGroup("Chart", id: "chart", for: ChartSpec.self) { $spec in
            if let spec { ChartWindowView(spec: spec).environmentObject(store) }
        }
        .defaultSize(width: 1200, height: 800)

        MenuBarExtra {
            MenuBarContent().environmentObject(store)
        } label: {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(Fmt.money(store.todayCost))
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.money(store.todayCost)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text("today").foregroundStyle(.secondary)
            }
            LiveSection(compact: true, maxRows: 4)
            Divider()
            HStack {
                Button("Open window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14).frame(width: 340)
        .onAppear { store.start() }
    }
}

/// `ClaudeUsageWidget --dump` prints what the collector sees: handy for checking numbers against reality.
enum Dump {
    /// `--send <compact|clear> <pid> <ttysNNN>` runs the exact code path the buttons use, for testing against a scratch terminal.
    static func send(_ args: [String]) {
        guard args.count == 3, let command = ControlCommand(rawValue: "/" + args[0]), let pid = Int(args[1]) else {
            print("usage: --send <compact|clear> <pid> <ttysNNN>"); return
        }
        print(TerminalControl.send(command, pid: pid, tty: args[2]) ?? "sent")
    }

    static func run() {
        let collector = UsageCollector()
        let t0 = Date()
        let dash = collector.refresh()
        print(String(format: "scan took %.2fs", Date().timeIntervalSince(t0)))
        for row in dash.live {
            print("LIVE \(row.session.name.prefix(40)) tty=\(row.tty ?? "-") \(row.session.entrypoint) status=\(row.session.status)")
            print(String(format: "   computed $%.4f | status line %@ | ctx %d/%d (%.1f%%) | %d responses",
                         row.cost, row.statuslineCost.map { String(format: "$%.4f", $0) } ?? "n/a",
                         row.contextTokens, row.contextWindow, row.contextPercent, row.messageCount))
        }
        for range in TimeRange.allCases {
            let s = dash.snapshots[range]!
            print(String(format: "%@: $%.2f, %d responses", range.rawValue, s.totalCost, s.messageCount))
        }
    }
}
