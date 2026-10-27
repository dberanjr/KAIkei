import Foundation

/// How heavy the work in a project usually is, from its recent turns. Lets a "this is light work" or "this is hard" call
/// lean on more than the last few prompts. Small and `Codable` because the terminal advisor caches it between prompts.
public struct ProjectProfile: Codable, Equatable, Sendable {
    public var turns: Int
    public var heavy: Int
    public var light: Int

    public init(turns: Int, heavy: Int, light: Int) { self.turns = turns; self.heavy = heavy; self.light = light }

    /// Below this many turns a project has no usual weight yet.
    static let minTurns = 10
    public var heavyShare: Double { turns > 0 ? Double(heavy) / Double(turns) : 0 }
    public var lightShare: Double { turns > 0 ? Double(light) / Double(turns) : 0 }
    public var isUsuallyHeavy: Bool { turns >= Self.minTurns && heavyShare >= 0.5 }
    public var isUsuallyLight: Bool { turns >= Self.minTurns && lightShare >= 0.6 }

    public static func build(timelines: [SessionTimeline]) -> ProjectProfile {
        var p = ProjectProfile(turns: 0, heavy: 0, light: 0)
        for turn in timelines.flatMap(\.turnEnds) {
            p.turns += 1
            switch TurnWeight.of(turn) {
            case .heavy: p.heavy += 1
            case .light: p.light += 1
            case .medium: break
            }
        }
        return p
    }
}

/// One short, opinionated recommendation for the moment before a prompt is sent. Every dollar figure is an estimate.
public struct TerminalAdvice: Equatable, Sendable {
    public enum Compact: Equatable, Sendable { case compact, clear }
    public enum Direction: Equatable, Sendable { case cheaper, stronger }
    public struct ModelMove: Equatable, Sendable {
        public var tier: ModelTier
        public var direction: Direction
        /// True when switching now would cost more than it is likely to save, so the advice is to wait for a compact or clear.
        public var deferred: Bool
        /// What the switch costs once: the context re-cached on the new model. Zero while the cache is already cold.
        public var switchCost: Double
    }

    public var compact: Compact?
    public var model: ModelMove?
    /// 1 is a suggestion; 2 is the cache expiring or the window nearly full.
    public var urgency: Int
    /// The terminal message, one line, prefixed.
    public var line: String
    /// A few words for the status line.
    public var short: String
    /// What the advice is about, so the same advice is not repeated prompt after prompt.
    public var key: String
}

public enum PromptAdvisor {
    static let deferAbove = 0.20
    static let payBackWithin = 15.0
    static let prefix = "KAIkei ▸ "

    public static func advise(
        timeline: SessionTimeline, prompt: String?, now: Date, billing: CacheWriteBilling = .listPrice, project: ProjectProfile? = nil,
        liveModelID: String? = nil
    ) -> TerminalAdvice? {
        guard let last = timeline.mainCalls.last, let advice = CompactAdvisor.advise(timeline: timeline, now: now, billing: billing) else { return nil }
        let newTopic = prompt.map(PromptClassifier.startsNewTopic) ?? false
        var compact: TerminalAdvice.Compact?
        var urgency = 1
        switch advice.level {
        case .coldCache: compact = newTopic ? .clear : .compact; urgency = 2
        case .compactSoon: compact = .compact; urgency = 2
        case .consider: compact = .compact
        case .fine: break
        }
        let move = modelMove(
            timeline: timeline, last: last, prompt: prompt, cold: advice.cacheIsCold, billing: billing, project: project, liveModelID: liveModelID)
        guard compact != nil || move != nil else { return nil }

        let (line, short) = words(compact: compact, move: move?.move, reason: move?.reason, advice: advice, context: last.contextTokens, currentTier: ModelTier(modelID: last.model))
        let key = [compact.map { "\($0)" }, move.map { "model:\($0.move.tier.alias)" }].compactMap { $0 }.joined(separator: "+")
        return TerminalAdvice(compact: compact, model: move?.move, urgency: urgency, line: prefix + line, short: short, key: key)
    }

    // MARK: choosing a model

    struct Reason { var text: String }

    private static func modelMove(
        timeline: SessionTimeline, last: CallPoint, prompt: String?, cold: Bool, billing: CacheWriteBilling, project: ProjectProfile?,
        liveModelID: String?
    ) -> (move: TerminalAdvice.ModelMove, reason: Reason)? {
        guard let tier = ModelTier(modelID: last.model) else { return nil }
        // The live model can be ahead of the transcript: you switched, and no response on the new model has landed yet.
        if let live = liveModelID.flatMap(ModelTier.init(modelID:)), live != tier { return nil }
        // So can a /model command after the last response: the next response will be on a different model.
        if timeline.markers.contains(where: { if case .command("/model") = $0.kind { $0.time > last.time } else { false } }) { return nil }
        // Someone who just picked this model has a reason; don't argue with it for a few responses.
        if timeline.modelSpans.count > 1, let span = timeline.modelSpans.last, span.callCount <= 3 { return nil }

        let recent = timeline.turnEnds.suffix(3).map(TurnWeight.of)
        let lastTwoLight = recent.count >= 2 && recent.suffix(2).allSatisfy { $0 == .light }
        let lastThreeLight = recent.count == 3 && recent.allSatisfy { $0 == .light }
        let heavyCount = recent.filter { $0 == .heavy }.count
        let lastThreeHeavy = recent.count == 3 && heavyCount == 3
        let heavyProject = project?.isUsuallyHeavy ?? false
        let read = prompt.map(PromptClassifier.classify) ?? PromptClassifier.Result(kind: .unknown, cue: nil)

        var target: (tier: ModelTier, direction: TerminalAdvice.Direction, reason: String)?

        // Down: only when the prompt itself says the work is light (an approval or an unlabelled request says nothing) and the
        // last turns agree.
        if read.kind == .light, lastTwoLight, let cheaper = tier.cheaper, cheaper != .haiku || (lastThreeLight && !heavyProject) {
            target = (cheaper, .cheaper, "Light work (\(read.cue ?? "this")) after \(lastThreeLight ? 3 : 2) light turns")
        }

        // Up: the work looks hard, and the session or project agrees (or the prompt is hard enough on its own).
        if target == nil, read.kind != .light, let stronger = tier.stronger {
            let small = tier <= .sonnet
            if read.kind == .strongHeavy, small || (tier == .opus && lastThreeHeavy) {
                target = (stronger, .stronger, "Hard one (\(read.cue ?? "this"))")
            } else if small, read.kind == .weakHeavy, heavyCount >= 2 || heavyProject {
                target = (stronger, .stronger, "“\(read.cue ?? "this")” after \(heavyCount >= 2 ? "\(heavyCount) heavy turns" : "a heavy project")")
            } else if small, lastThreeHeavy, let prompt, !PromptClassifier.isAcknowledgement(prompt) {
                target = (stronger, .stronger, "3 heavy turns in a row")
            }
        }
        guard let target else { return nil }

        let context = last.contextTokens
        let mult = timeline.cacheTTL >= 3600 ? (billing == .listPrice ? 2.0 : 1.25) : 1.25
        let newRates = Pricing.effectiveRates(model: target.tier.pricingModelID, contextTokens: context)
        let switchCost = cold ? 0 : Double(context) * newRates.input * mult / 1_000_000
        var deferred = false
        if target.direction == .cheaper, switchCost >= deferAbove {
            let sample = timeline.mainCalls.suffix(3)
            let saving = sample.reduce(0.0) { $0 + Pricing.cost(of: $1.usage, model: tier.pricingModelID, billing: billing)
                - Pricing.cost(of: $1.usage, model: target.tier.pricingModelID, billing: billing) } / Double(max(sample.count, 1))
            deferred = saving <= 0 || switchCost / saving > payBackWithin
        }
        return (.init(tier: target.tier, direction: target.direction, deferred: deferred, switchCost: switchCost), Reason(text: target.reason))
    }

    // MARK: words

    private static func words(
        compact: TerminalAdvice.Compact?, move: TerminalAdvice.ModelMove?, reason: Reason?, advice: CompactAdvice, context: Int, currentTier: ModelTier?
    ) -> (line: String, short: String) {
        let ctx = CompactAdvisor.tokens(context)
        let money = CompactAdvisor.money
        let current = currentTier?.displayName ?? "This model"

        func switchNote(_ m: TerminalAdvice.ModelMove) -> String {
            m.switchCost == 0 ? "the cache is cold anyway, so switching is free" : "re-caches \(ctx) once (~\(money(m.switchCost)))"
        }
        func tierShort(_ m: TerminalAdvice.ModelMove) -> String { "→ \(m.tier.alias == "claude-fable-5-1" ? "fable" : m.tier.alias)" }

        let compactWords: String? = compact.map { action in
            let verb = action == .clear ? "/clear" : "/compact"
            switch advice.level {
            case .coldCache:
                return "Cache expired\(action == .clear ? ", new topic" : ""): \(verb) first (+\(money(advice.coldPenalty ?? 0)) to resume \(ctx))"
            case .compactSoon: return "Context \(Int(advice.contextPercent.rounded()))% full: \(verb) at this break (~\(money(advice.compactCost)))"
            default: return "\(verb) now: every call re-reads \(ctx) (~\(money(advice.carryCostPerCall)))"
            }
        }
        let compactShort: String? = compact.map { action in
            switch advice.level {
            case .coldCache: action == .clear ? "clear: cache cold" : "compact: cache cold"
            case .compactSoon: "compact: \(Int(advice.contextPercent.rounded()))% full"
            default: "compact: pays back in ~\(Int((advice.breakEvenCalls ?? 0).rounded(.up))) calls"
            }
        }

        switch (compactWords, move, reason) {
        case let (c?, m?, _?):
            let why = m.direction == .cheaper ? "light work" : "hard work"
            return ("\(c), then /model \(m.tier.alias): \(why).", "\(compactShort ?? ""), then \(tierShort(m))")
        case let (c?, nil, _):
            return ("\(c).", compactShort ?? "")
        case let (nil, m?, r?):
            if m.deferred {
                return ("\(current) is more than this needs, but switching now re-caches \(ctx) (~\(money(m.switchCost))). Switch at your next /compact or /clear.",
                        "\(tierShort(m)) at next /compact")
            }
            if m.direction == .cheaper {
                return ("\(r.text): \(m.tier.displayName) is enough. /model \(m.tier.alias) · \(switchNote(m)).", "\(tierShort(m)) (light work)")
            }
            return ("\(r.text) on \(current): try /model \(m.tier.alias) · \(switchNote(m)).", "\(tierShort(m)) (hard work)")
        default:
            return ("", "")
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// Keeps the prompt hook from nagging: the same advice is not repeated for the next few prompts unless it got more urgent.
/// `Codable` because each prompt runs in a fresh process and the state lives in a small file.
public struct AdviceThrottle: Codable, Equatable, Sendable {
    var lastKey: String?
    var lastUrgency = 0
    var promptsSince = 0
    static let quietPrompts = 3

    public init() {}

    public mutating func shouldShow(_ advice: TerminalAdvice?) -> Bool {
        guard let advice else { lastKey = nil; return false }
        if advice.key == lastKey, advice.urgency <= lastUrgency, promptsSince < Self.quietPrompts {
            promptsSince += 1
            return false
        }
        lastKey = advice.key; lastUrgency = advice.urgency; promptsSince = 0
        return true
    }
}

/// The status line segment: where the session stands in a glance, and the advice in a few words when there is some.
public enum StatusLineText {
    /// `cost` and `contextPercent` override the transcript's own figures, for when only the tail of a transcript was read.
    public static func make(
        timeline: SessionTimeline, advice: TerminalAdvice?, now: Date, color: Bool, cost: Double? = nil, contextPercent: Double? = nil
    ) -> String {
        guard let last = timeline.mainCalls.last else { return "KAIkei" }
        func paint(_ code: String, _ text: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
        let percent = contextPercent.map { Int($0.rounded()) }
            ?? (timeline.contextWindow > 0 ? Int((Double(last.contextTokens) / Double(timeline.contextWindow) * 100).rounded()) : 0)
        let left = last.time.addingTimeInterval(timeline.cacheTTL).timeIntervalSince(now)
        let cache = left <= 0 ? "cache cold" : left < 60 ? "cache <1m" : "cache \(Int(left / 60))m"
        var text = paint("2", "KAIkei  ctx \(percent)% · \(cache) · \(CompactAdvisor.money(cost ?? timeline.totalCost))")
        if let advice {
            text += " " + paint(advice.urgency >= 2 ? "1;33" : "33", "▸ \(advice.short)")
        }
        return text
    }
}
