import Foundation
import Testing
@testable import UsageCore

@Suite struct StatuslineTests {
    // Trimmed copy of the JSON Claude Code pipes to a statusLine command.
    let sample = #"""
    {"session_id":"abc","model":{"id":"claude-sonnet-5-5","display_name":"Sonnet 5.5"},
     "effort":{"level":"high"},"cost":{"total_cost_usd":0.174134,"total_duration_ms":1036572,"total_lines_added":4,"total_lines_removed":1},
     "context_window":{"context_window_size":1000000,"used_percentage":7,"current_usage":{"input_tokens":2}},
     "prompt_cache":{"warm":true,"hit_ratio":0.85,"expires_at":1792942974},"fast_mode":false,"thinking":{"enabled":true}}
    """#

    @Test func parsesTheFieldsTheWidgetShows() throws {
        let info = try #require(StatuslineReader.parse(Data(sample.utf8)))
        #expect(info.sessionID == "abc")
        #expect(info.modelDisplayName == "Sonnet 5.5")
        #expect(info.effort == "high")
        #expect(abs(info.costUSD - 0.174134) < 1e-9)
        #expect(info.contextWindowSize == 1_000_000)
        #expect(info.contextUsedPercent == 7)
        #expect(info.cacheHitRatio == 0.85)
        #expect(info.linesAdded == 4 && info.linesRemoved == 1)
        #expect(info.durationSeconds == 1036)
    }

    @Test func loadsEveryJsonFileKeyedBySession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try sample.write(to: dir.appendingPathComponent("shared.json"), atomically: true, encoding: .utf8)
        try sample.write(to: dir.appendingPathComponent("ttys000.json"), atomically: true, encoding: .utf8)
        let loaded = StatuslineReader.load(from: dir)
        #expect(loaded.count == 1) // shared.json and ttys000.json describe the same session
        #expect(loaded["abc"]?.tty == "ttys000")
    }

    @Test func missingDirectoryYieldsNothing() {
        #expect(StatuslineReader.load(from: URL(fileURLWithPath: "/nonexistent/dir")).isEmpty)
    }
}
