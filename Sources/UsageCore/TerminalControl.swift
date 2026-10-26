import Foundation

public struct ProcessInfoRow: Equatable, Sendable {
    public var ppid: Int
    public var command: String
    public init(ppid: Int, command: String) { self.ppid = ppid; self.command = command }
}

/// Slash commands the widget can type into a Claude Code prompt.
public enum ControlCommand: String, Sendable {
    case compact = "/compact"
    case clear = "/clear"
}

public enum TerminalApp: Equatable, Sendable {
    case terminal, iterm, unsupported
}

public enum Availability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Sends /compact and /clear to the terminal tab a session runs in, by typing into that tab's tty via
/// AppleScript. Only Terminal.app and iTerm2 expose tabs by tty; other hosts are reported unsupported.
public enum TerminalControl {
    public static func detectApp(pid: Int, table: [Int: ProcessInfoRow]) -> TerminalApp {
        var current = pid
        var seen = Set<Int>()
        while let row = table[current], seen.insert(current).inserted {
            if row.command.contains("Terminal.app/") { return .terminal }
            if row.command.contains("iTerm.app/") || row.command.contains("iTerm2") { return .iterm }
            current = row.ppid
        }
        return .unsupported
    }

    public static func availability(app: TerminalApp, tty: String?, status: String) -> Availability {
        guard let tty, !tty.isEmpty else { return .unavailable("No terminal found for this session.") }
        guard app != .unsupported else { return .unavailable("Only Terminal and iTerm2 can be controlled.") }
        guard status != "busy" else { return .unavailable("Claude is working. Wait until it is idle.") }
        return .available
    }

    /// nil when the tty isn't a plain `ttysNNN` name (it is interpolated into the script) or the app is unsupported.
    public static func appleScript(app: TerminalApp, tty: String, command: ControlCommand) -> String? {
        guard tty.range(of: #"^ttys\d+$"#, options: .regularExpression) != nil else { return nil }
        let device = "/dev/\(tty)"
        switch app {
        case .terminal:
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(device)" then
                                do script "\(command.rawValue)" in t
                                return "ok"
                            end if
                        end repeat
                    end repeat
                    return "not found"
                end tell
                """
        case .iterm:
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(device)" then
                                    tell s to write text "\(command.rawValue)"
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return "not found"
                end tell
                """
        case .unsupported:
            return nil
        }
    }

    /// Live `ps` snapshot used to walk from a Claude process up to the terminal app that hosts it.
    public static func processTable() -> [Int: ProcessInfoRow] {
        guard let out = UsageCollector.run("/bin/ps", ["-axo", "pid=,ppid=,comm="]) else { return [:] }
        var table: [Int: ProcessInfoRow] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            table[pid] = ProcessInfoRow(ppid: ppid, command: String(parts[2]))
        }
        return table
    }

    /// Runs the command. Returns nil on success or a message to show the user.
    public static func send(_ command: ControlCommand, pid: Int, tty: String) -> String? {
        let app = detectApp(pid: pid, table: processTable())
        guard let script = appleScript(app: app, tty: tty, command: command) else { return "This terminal can't be controlled." }
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", script]
        p.standardOutput = out; p.standardError = err
        guard (try? p.run()) != nil else { return "Couldn't run osascript." }
        let result = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            return errText.contains("-1743") ? "Allow KAIkei to control the terminal in System Settings > Privacy & Security > Automation." : "AppleScript failed: \(errText.prefix(120))"
        }
        return result == "ok" ? nil : "Couldn't find that terminal tab."
    }
}
