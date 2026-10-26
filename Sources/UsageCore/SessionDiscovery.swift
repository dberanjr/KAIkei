import Foundation

/// A running Claude Code process, as described by ~/.claude/sessions/<pid>.json.
public struct LiveSession: Identifiable, Equatable, Sendable {
    public var pid: Int
    public var sessionID: String
    public var cwd: String
    public var name: String
    /// "cli" for a terminal, "claude-desktop" for sessions hosted by the desktop app.
    public var entrypoint: String
    public var status: String
    public var startedAt: Date
    public var updatedAt: Date
    public var version: String
    public var id: String { sessionID }
}

public enum SessionDiscovery {
    public static var defaultDirectory: URL {
        DataHome.url.appendingPathComponent(".claude/sessions")
    }

    /// Sessions whose process still exists. Claude Code leaves the json behind after a crash, so
    /// the file alone doesn't prove the session is open.
    public static func liveSessions(in dir: URL = defaultDirectory) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(parse).filter { isAlive(pid: $0.pid) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    static func parse(_ url: URL) -> LiveSession? {
        guard let data = try? Data(contentsOf: url),
            let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let pid = (d["pid"] as? NSNumber)?.intValue,
            let id = d["sessionId"] as? String
        else { return nil }
        func date(_ key: String) -> Date {
            Date(timeIntervalSince1970: ((d[key] as? NSNumber)?.doubleValue ?? 0) / 1000)
        }
        return LiveSession(
            pid: pid, sessionID: id, cwd: d["cwd"] as? String ?? "",
            name: d["name"] as? String ?? "", entrypoint: d["entrypoint"] as? String ?? "cli",
            status: d["status"] as? String ?? "unknown", startedAt: date("startedAt"),
            updatedAt: date("updatedAt"), version: d["version"] as? String ?? "")
    }

    /// kill(pid, 0) probes existence without sending a signal. EPERM means it exists but isn't ours.
    public static func isAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
