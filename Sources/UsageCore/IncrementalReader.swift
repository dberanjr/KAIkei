import Foundation

/// Tails JSONL transcripts: remembers how far into each file it has read and only parses new,
/// newline-terminated lines, so a refresh costs time proportional to what changed.
public struct IncrementalReader {
    private var offsets: [String: UInt64] = [:]
    private let chunkSize = 8 * 1024 * 1024

    public init() {}

    public mutating func ingest(_ url: URL, into store: inout RecordStore) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 }  // truncated or replaced: start over
        var carry = Data()

        while offset < size {
            do { try handle.seek(toOffset: offset) } catch { break }
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            var buffer = carry + chunk
            // Only consume complete lines; hold the trailing partial line for the next pass.
            guard let lastNewline = buffer.lastIndex(of: 0x0A) else { carry = buffer; continue }
            carry = Data(buffer[buffer.index(after: lastNewline)...])
            buffer = Data(buffer[buffer.startIndex...lastNewline])
            for line in buffer.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let data = Data(line)
                if let rec = TranscriptParser.parse(line: data) { store.add(rec) }
                else if let event = TranscriptParser.parseEvent(line: data) { store.add(event) }
            }
        }
        offsets[url.path] = offset - UInt64(carry.count)
    }
}
