import Foundation
import Testing
@testable import UsageCore

@Suite struct SessionDiscoveryTests {
    func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func sessionJSON(pid: Int, id: String, name: String = "my session", entry: String = "cli", status: String = "busy") -> String {
        #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"/work/alpha","startedAt":1792938350554,"version":"2.1.309","kind":"interactive","entrypoint":"\#(entry)","name":"\#(name)","status":"\#(status)","updatedAt":1792939356191}"#
    }

    @Test func listsOnlySessionsWhoseProcessIsAlive() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        try sessionJSON(pid: me, id: "alive").write(to: dir.appendingPathComponent("\(me).json"), atomically: true, encoding: .utf8)
        try sessionJSON(pid: 99_999_999, id: "dead").write(to: dir.appendingPathComponent("99999999.json"), atomically: true, encoding: .utf8)

        let live = SessionDiscovery.liveSessions(in: dir)
        #expect(live.map(\.sessionID) == ["alive"])
    }

    @Test func parsesDisplayFields() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        try sessionJSON(pid: me, id: "a", name: "dashboards", entry: "claude-desktop", status: "idle")
            .write(to: dir.appendingPathComponent("\(me).json"), atomically: true, encoding: .utf8)
        let s = try #require(SessionDiscovery.liveSessions(in: dir).first)
        #expect(s.name == "dashboards")
        #expect(s.cwd == "/work/alpha")
        #expect(s.entrypoint == "claude-desktop")
        #expect(s.status == "idle")
        #expect(s.pid == me)
        #expect(abs(s.startedAt.timeIntervalSince1970 - 1_792_938_350.554) < 0.001)
    }

    @Test func ignoresUnparseableFilesAndKeyFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "not json".write(to: dir.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try "secret".write(to: dir.appendingPathComponent("1.abc.key"), atomically: true, encoding: .utf8)
        #expect(SessionDiscovery.liveSessions(in: dir).isEmpty)
    }
}
