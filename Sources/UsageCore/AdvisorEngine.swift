import Foundation

/// Reads the end of a transcript, which is all the advisor needs: the last few turns and the latest response. A 50 MB
/// transcript costs the same to advise on as a 2 MB one.
public enum TranscriptTail {
    public static func load(_ url: URL, maxBytes: Int) -> RecordStore {
        var store = RecordStore()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return store }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return store }
        // Starting mid-file lands inside a row: drop everything up to the first newline.
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return store }
            data = Data(data[data.index(after: newline)...])
        }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let row = Data(line)
            if let record = TranscriptParser.parse(line: row) { store.add(record) }
            else if let event = TranscriptParser.parseEvent(line: row) { store.add(event) }
        }
        return store
    }
}

/// Everything the terminal advisor does between "Claude Code gave us JSON" and "here is what to print". No output of its own,
/// never throws: the hook and the status line must not get in the way of typing.
public struct AdvisorEngine {
    public var stateDir: URL
    public var now: () -> Date
    var tailBytes = 8 * 1024 * 1024
    static let profileFiles = 4

    public init(stateDir: URL, now: @escaping () -> Date = Date.init) {
        self.stateDir = stateDir
        self.now = now
    }

    public static var defaultStateDir: URL {
        if let override = ProcessInfo.processInfo.environment["KAIKEI_ADVISOR_HOME"] { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kaikei")
    }

    struct Input {
        var sessionID: String
        var transcript: URL
        var prompt: String?
        var costUSD: Double?
        var contextPercent: Double?
    }

    static func parse(_ data: Data) -> Input? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let session = d["session_id"] as? String, let path = d["transcript_path"] as? String
        else { return nil }
        let cost = (d["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber
        let used = (d["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber
        return Input(sessionID: session, transcript: URL(fileURLWithPath: path), prompt: d["prompt"] as? String,
                     costUSD: cost?.doubleValue, contextPercent: used?.doubleValue)
    }

    func timeline(sessionID: String, transcript: URL) -> SessionTimeline? {
        let store = TranscriptTail.load(transcript, maxBytes: tailBytes)
        guard !store.records.isEmpty else { return nil }
        return Timelines.build(records: store.records, events: store.events, sessionID: sessionID)
    }

    func advice(for input: Input) -> TerminalAdvice? {
        guard let timeline = timeline(sessionID: input.sessionID, transcript: input.transcript) else { return nil }
        return PromptAdvisor.advise(
            timeline: timeline, prompt: input.prompt, now: now(), project: projectProfile(for: input.transcript))
    }

    // MARK: the prompt hook

    /// The JSON for the hook's stdout, or nil to print nothing. `systemMessage` is shown to the user and never added to
    /// Claude's context; plain stdout from this hook would be.
    public func hookOutput(_ data: Data) -> String? {
        guard let input = Self.parse(data) else { return nil }
        let advice = self.advice(for: input)
        var throttle = loadThrottle(session: input.sessionID)
        let show = throttle.shouldShow(advice)
        saveThrottle(throttle, session: input.sessionID)
        guard show, let advice, let json = try? JSONSerialization.data(withJSONObject: ["systemMessage": advice.line]) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    // MARK: the status line

    public func statusLine(_ data: Data, color: Bool) -> String {
        guard let input = Self.parse(data), let timeline = timeline(sessionID: input.sessionID, transcript: input.transcript) else { return "KAIkei" }
        let advice = PromptAdvisor.advise(timeline: timeline, prompt: nil, now: now(), project: projectProfile(for: input.transcript))
        // Claude Code's own cost and context figures win: the transcript tail only knows the recent part of the session.
        return StatusLineText.make(
            timeline: timeline, advice: advice, now: now(), color: color, cost: input.costUSD, contextPercent: input.contextPercent)
    }

    // MARK: state files

    private func throttleURL(_ session: String) -> URL { stateDir.appendingPathComponent("state/throttle-\(Self.safe(session)).json") }

    private func loadThrottle(session: String) -> AdviceThrottle {
        (try? JSONDecoder().decode(AdviceThrottle.self, from: Data(contentsOf: throttleURL(session)))) ?? AdviceThrottle()
    }

    private func saveThrottle(_ throttle: AdviceThrottle, session: String) {
        let url = throttleURL(session)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(throttle).write(to: url, options: .atomic)
    }

    static func safe(_ s: String) -> String { String(s.unicodeScalars.map { $0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || $0 == "-" ? Character($0) : "_" }) }

    // MARK: the project profile

    /// How heavy this project's work usually is, from the tails of its other recent transcripts. Cached by their sizes and
    /// modification times, so most prompts only stat a few files.
    public func projectProfile(for transcript: URL) -> ProjectProfile {
        let dir = transcript.deletingLastPathComponent()
        let siblings = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent != transcript.lastPathComponent }
            .compactMap { url -> (URL, Date, Int)? in
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let date = v?.contentModificationDate, let size = v?.fileSize else { return nil }
                return (url, date, size)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.profileFiles)
        let signature = siblings.map { "\($0.0.lastPathComponent):\($0.2):\(Int($0.1.timeIntervalSince1970))" }.joined(separator: "|")
        let cacheURL = stateDir.appendingPathComponent("cache/profile-\(Self.fnv(dir.path)).json")

        struct Cached: Codable { var signature: String; var profile: ProjectProfile }
        if let cached = (try? JSONDecoder().decode(Cached.self, from: Data(contentsOf: cacheURL))), cached.signature == signature { return cached.profile }

        var timelines: [SessionTimeline] = []
        for (url, _, _) in siblings {
            let store = TranscriptTail.load(url, maxBytes: tailBytes)
            for (session, records) in Dictionary(grouping: store.records, by: \.sessionID) where !records.isEmpty {
                timelines.append(Timelines.build(records: store.records, events: store.events, sessionID: session))
            }
        }
        let profile = ProjectProfile.build(timelines: timelines)
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cached(signature: signature, profile: profile)).write(to: cacheURL, options: .atomic)
        return profile
    }

    /// A hash that is the same in every process (Swift's `hashValue` is not), for naming cache files.
    static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
