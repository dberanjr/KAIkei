import Foundation

/// The rungs of the model ladder the advisor moves along, one step at a time. Ordered by capability and price.
public enum ModelTier: Int, Comparable, CaseIterable, Sendable {
    case haiku, sonnet, opus, fable

    public init?(modelID: String) {
        switch ModelFamily(modelID: modelID) {
        case .haiku: self = .haiku
        case .sonnet: self = .sonnet
        case .opus: self = .opus
        case .other:
            guard Pricing.normalize(modelID).contains("fable") else { return nil }
            self = .fable
        }
    }

    public static func < (a: ModelTier, b: ModelTier) -> Bool { a.rawValue < b.rawValue }
    public var cheaper: ModelTier? { ModelTier(rawValue: rawValue - 1) }
    public var stronger: ModelTier? { ModelTier(rawValue: rawValue + 1) }
    /// What you type after `/model`.
    public var alias: String { self == .fable ? "claude-fable-5-1" : "\(self)" }
    public var displayName: String { self == .fable ? "Fable" : "\(self)".capitalized }
    /// A concrete model id to price this tier with.
    var pricingModelID: String {
        switch self {
        case .haiku: "claude-haiku-5-5"
        case .sonnet: "claude-sonnet-5-5"
        case .opus: "claude-opus-5-5"
        case .fable: "claude-fable-5-1"
        }
    }
}

/// What a prompt's wording says about the work: a rough read from cue words, never a promise.
public enum PromptClassifier {
    public enum Kind: Equatable, Sendable { case light, unknown, weakHeavy, strongHeavy }
    public struct Result: Equatable, Sendable {
        public var kind: Kind
        /// The phrase that decided it, for the message ("root cause"). Nil when nothing did.
        public var cue: String?
    }

    /// Hard on their own: a technical problem that wants careful reasoning.
    static let hardProblems = [
        "root cause", "race condition", "deadlock", "memory leak", "security review", "security audit", "threat model",
        "performance regression", "concurrency", "vulnerab", "system design", "trade-off", "tradeoff",
    ]
    /// Hard when they are about the code, not when they are about writing something up ("update the architecture diagram").
    static let designWords = ["architecture", "architect", "design the", "design a", "migrate", "migration plan", "rewrite"]
    static let writingContext = ["commit message", "diagram", "readme", "docs", "documentation", "comment", "changelog", "docstring"]
    static let lightCues = [
        "typo", "rename", "reformat", "format the", "lint", "commit message", "docstring", "add a comment", "add comments",
        "what does", "what is", "explain", "summarize", "summarise", "list the", "show me", "run the test", "run tests", "git status",
        "git diff", "bump the version", "bump version", "fix the import", "spelling",
    ]
    static let weakHeavy = ["refactor", "debug", "investigate", "why is", "why does", "optimi", "across the", "implement"]
    static let newTopic = ["new task", "unrelated", "different topic", "something else", "switching gears", "start over", "separate question", "new feature:"]
    static let acknowledgements: Set<String> = [
        "yes", "yep", "yeah", "ok", "okay", "thanks", "thank", "lgtm", "continue", "sure", "go", "proceed", "do", "approved", "great",
        "nice", "good", "perfect",
    ]
    static let longPrompt = 800
    /// A prompt this long, or with code or a stack trace in it, is not "light work" whatever words it contains.
    static let lightPromptLimit = 160

    /// A phrase at the start of a word ("optimi" in "optimize"), compiled once.
    private static func startsWord(_ cues: [String]) -> [NSRegularExpression] {
        cues.compactMap { try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: $0)) }
    }
    /// A whole word, allowing a plural or common ending ("typo", "typos", "linting"), compiled once.
    private static func wholeWord(_ cues: [String]) -> [NSRegularExpression] {
        cues.compactMap { try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "(s|es|ed|ing)?\\b") }
    }
    private static let hardRegex = startsWord(hardProblems), designRegex = startsWord(designWords), writingRegex = startsWord(writingContext)
    private static let weakRegex = startsWord(weakHeavy), lightRegex = wholeWord(lightCues)

    private static func firstHit(_ regexes: [NSRegularExpression], in text: String, cues: [String]) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for (regex, cue) in zip(regexes, cues) where regex.firstMatch(in: text, range: range) != nil { return cue }
        return nil
    }

    public static func classify(_ prompt: String) -> Result {
        let text = prompt.lowercased()
        if let cue = firstHit(hardRegex, in: text, cues: hardProblems) { return Result(kind: .strongHeavy, cue: cue) }
        if firstHit(writingRegex, in: text, cues: writingContext) == nil,
            let cue = firstHit(designRegex, in: text, cues: designWords) { return Result(kind: .strongHeavy, cue: cue) }
        if let cue = firstHit(weakRegex, in: text, cues: weakHeavy) { return Result(kind: .weakHeavy, cue: cue) }
        if text.count >= longPrompt { return Result(kind: .weakHeavy, cue: "a long, detailed prompt") }
        let looksLikeCode = text.contains("\n") || text.contains("```")
        if text.count <= lightPromptLimit, !looksLikeCode, let cue = firstHit(lightRegex, in: text, cues: lightCues) {
            return Result(kind: .light, cue: cue)
        }
        return Result(kind: .unknown, cue: nil)
    }

    public static func startsNewTopic(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        return newTopic.contains(where: text.contains)
    }

    /// "yes go ahead", "thanks", "ok": a reply to Claude, not a task, so it says nothing about how hard the work is.
    public static func isAcknowledgement(_ prompt: String) -> Bool {
        let words = prompt.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return !words.isEmpty && words.count <= 3 && acknowledgements.contains(words[0])
    }
}

/// How demanding a finished turn was, from what it actually did.
public enum TurnWeight: Equatable, Sendable {
    case light, medium, heavy

    static let heavyTools = 12, heavyOutput = 6_000, heavyThinking = 10_000, heavySeconds = 600.0
    static let lightTools = 3, lightOutput = 1_500

    public static func of(_ turn: TurnEnd) -> TurnWeight {
        if turn.tools >= heavyTools || turn.outputTokens >= heavyOutput || turn.thinkingTokens >= heavyThinking || turn.duration >= heavySeconds {
            return .heavy
        }
        if turn.tools <= lightTools && turn.outputTokens <= lightOutput && turn.thinkingTokens == 0 { return .light }
        return .medium
    }
}
