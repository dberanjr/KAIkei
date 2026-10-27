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

    static let strongHeavy = [
        "root cause", "race condition", "deadlock", "memory leak", "security review", "security audit", "threat model",
        "architecture", "architect", "design the", "design a", "system design", "trade-off", "tradeoff", "migrate", "migration plan",
        "rewrite", "performance regression", "concurrency", "vulnerab",
    ]
    static let lightCues = [
        "typo", "rename", "reformat", "format the", "lint", "commit message", "docstring", "add a comment", "add comments",
        "what does", "what is", "explain", "summarize", "summarise", "list the", "show me", "run the test", "run tests", "git status",
        "git diff", "bump the version", "bump version", "fix the import", "spelling",
    ]
    static let weakHeavy = ["refactor", "debug", "investigate", "why is", "why does", "optimi", "across the", "implement"]
    static let newTopic = ["new task", "unrelated", "different topic", "something else", "switching gears", "start over", "separate question", "new feature:"]
    static let longPrompt = 800

    public static func classify(_ prompt: String) -> Result {
        let text = prompt.lowercased()
        if let cue = strongHeavy.first(where: text.contains) { return Result(kind: .strongHeavy, cue: cue) }
        if let cue = weakHeavy.first(where: text.contains) { return Result(kind: .weakHeavy, cue: cue) }
        if text.count >= longPrompt { return Result(kind: .weakHeavy, cue: "a long, detailed prompt") }
        if let cue = lightCues.first(where: text.contains) { return Result(kind: .light, cue: cue) }
        return Result(kind: .unknown, cue: nil)
    }

    public static func startsNewTopic(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        return newTopic.contains(where: text.contains)
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
