import Foundation

/// A moment the compact advisor would have said something, replayed from the transcript.
public struct AdviceMarker: Identifiable, Equatable, Sendable {
    public var id: String
    public var time: Date
    public var level: CompactAdvice.Level
    public var headline: String
    public var detail: String
    public var contextTokens: Int
}

/// Replays `CompactAdvisor` over a finished or running session to find where its advice changed, so the timeline can show
/// when KAIkei would have suggested compacting or clearing. These are reconstructions: the app was not necessarily open at
/// the time, and prices are today's list prices.
public enum AdviceHistory {
    /// The same level is not marked again within this many calls, so advice hovering around a threshold does not flicker.
    public static let repeatGuard = 10

    public static func markers(timeline: SessionTimeline, billing: CacheWriteBilling = .listPrice, limit: Int = 20_000) -> [AdviceMarker] {
        let main = timeline.mainCalls
        guard !main.isEmpty, main.count <= limit else { return [] }
        var out: [AdviceMarker] = []
        var previous = CompactAdvice.Level.fine
        var lastMarked: [CompactAdvice.Level: Int] = [:]

        func evaluate(_ call: CallPoint, index: Int, now: Date, markedAt: Date) {
            // The advisor reads only the latest main-thread call, the compactions so far, and the cache lifetime.
            var t = SessionTimeline()
            t.calls = [call]
            t.markers = timeline.markers.filter { $0.time <= now }
            t.cacheTTL = timeline.cacheTTL
            t.contextWindow = Pricing.lookup(call.model).rate.contextWindow
            guard let advice = CompactAdvisor.advise(timeline: t, now: now, billing: billing) else { return }
            defer { previous = advice.level }
            guard advice.level != .fine, advice.level != previous else { return }
            if let last = lastMarked[advice.level], index - last < repeatGuard { return }
            lastMarked[advice.level] = index
            out.append(AdviceMarker(id: "advice|\(call.id)|\(advice.level)", time: markedAt, level: advice.level,
                                    headline: advice.headline, detail: advice.detail, contextTokens: advice.contextTokens))
        }

        for (i, call) in main.enumerated() {
            if i > 0 {
                // The cache can lapse in the pause before this call; the advice appears when it does.
                let before = main[i - 1]
                let expiry = before.time.addingTimeInterval(timeline.cacheTTL)
                if call.time > expiry { evaluate(before, index: i - 1, now: expiry.addingTimeInterval(1), markedAt: expiry) }
            }
            evaluate(call, index: i, now: call.time, markedAt: call.time)
        }
        return out
    }
}
