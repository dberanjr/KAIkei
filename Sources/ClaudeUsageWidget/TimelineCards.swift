import SwiftUI
import UsageCore

/// The card that follows the pointer. Material background, hairline border, soft shadow: it floats above the charts
/// without hiding what is under it more than it must.
private struct CardChrome<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(12)
            .frame(width: width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
    }
}

private func clock(_ date: Date, seconds: Bool = true) -> String {
    date.formatted(seconds ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
}

private func promptOrdinal(_ id: String, in timeline: SessionTimeline) -> Int? {
    timeline.markers.filter { if case .prompt = $0.kind { true } else { false } }.firstIndex { $0.id == id }.map { $0 + 1 }
}

private func promptPreview(turn: Int, in timeline: SessionTimeline) -> String? {
    let prompts = timeline.markers.compactMap { m -> String? in if case .prompt(let p) = m.kind { p } else { nil } }
    return turn >= 1 && turn <= prompts.count ? prompts[turn - 1] : nil
}

private struct Row: View {
    let label: String, value: String
    var detail: String?
    var swatch: Color?
    var body: some View {
        HStack(spacing: 6) {
            if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
            if let detail { Text(detail).foregroundStyle(.tertiary).monospacedDigit().frame(width: 44, alignment: .trailing) }
        }
        .font(.caption)
    }
}

/// One line of the card's table: a swatch and label, then right-aligned columns for tokens, share of the context and cost.
private struct TableRow: View {
    let label: String, tokens: String, share: String, cost: String
    var swatch: Color?
    var header = false
    var body: some View {
        HStack(spacing: 6) {
            if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
            else { Color.clear.frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(tokens).frame(width: 52, alignment: .trailing)
            Text(share).foregroundStyle(header ? .secondary : .tertiary).frame(width: 78, alignment: .trailing).lineLimit(1)
            Text(cost).frame(width: 54, alignment: .trailing)
        }
        .font(header ? .caption2 : .caption).monospacedDigit()
        .foregroundStyle(header ? .tertiary : .primary)
    }
}

/// Everything about one call: the "time slice" that ends at it.
struct CallCard: View {
    let call: CallPoint
    let index: Int
    let timeline: SessionTimeline
    var width: CGFloat = 320

    private var previousMain: CallPoint? {
        guard !call.isSidechain else { return nil }
        return timeline.calls[..<index].last { !$0.isSidechain }
    }

    var body: some View {
        let window = timeline.contextWindow
        let context = max(call.contextTokens, 1)
        let slice = previousMain.map { timeline.markers(after: $0.time, through: call.time) } ?? []
        CardChrome(width: width) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Call \(index + 1) of \(timeline.calls.count)").font(.callout.weight(.semibold))
                    Spacer()
                    Text(clock(call.time)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Circle().fill(Theme.color(ModelFamily(modelID: call.model))).frame(width: 8, height: 8)
                    Text(ModelFamily.displayName(modelID: call.model) + (call.effort.map { " · \($0)" } ?? "")).font(.callout)
                    if call.isSidechain { Text("sub-agent").font(.caption).foregroundStyle(.secondary) }
                }
                if let preview = promptPreview(turn: call.turn, in: timeline) { promptSection(preview) }
                Divider()
                contextSection(window: window, total: context)
                Divider()
                cacheSection
                if !call.tools.isEmpty || call.skill != nil { toolsSection }
                if !slice.isEmpty { eventsSection(slice) }
            }
        }
    }

    /// The prompt this call was answering, quoted at more length than the one-line chart tooltips allow, with what the
    /// prompt has cost up to and including this call.
    private func promptSection(_ preview: String) -> some View {
        let sofar = timeline.calls[...index].filter { $0.turn == call.turn }
        return VStack(alignment: .leading, spacing: 3) {
            Text("Prompt \(call.turn)").font(.caption.weight(.semibold))
            Text("“\(preview)”").font(.caption).foregroundStyle(.secondary).lineLimit(6).fixedSize(horizontal: false, vertical: true)
            Text("\(Fmt.count(sofar.count, "call")) so far · \(Fmt.money(sofar.reduce(0) { $0 + $1.cost }))")
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    /// Context and cost in one table: what each part of the context was, its share, and what it cost on this call.
    private func contextSection(window: Int, total: Int) -> some View {
        let p = call.costParts
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context").font(.caption.weight(.semibold))
                Text(Fmt.tokens(call.contextTokens)).font(.callout.weight(.semibold)).monospacedDigit()
                if window > 0 { Text("\(Fmt.percent(Double(call.contextTokens) / Double(window) * 100)) of \(Fmt.tokens(window))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let delta = contextDelta { Text(delta).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            GeometryReader { g in
                HStack(spacing: 1) {
                    Rectangle().fill(Theme.ramp[0]).frame(width: g.size.width * Double(call.cacheRead) / Double(total))
                    Rectangle().fill(Theme.ramp[1]).frame(width: max(call.cacheWrite > 0 ? 2 : 0, g.size.width * Double(call.cacheWrite) / Double(total)))
                    Rectangle().fill(Theme.ramp[3]).frame(width: max(call.freshInput > 0 ? 2 : 0, g.size.width * Double(call.freshInput) / Double(total)))
                }.clipShape(Capsule())
            }.frame(height: 7)
            TableRow(label: "", tokens: "tokens", share: "share", cost: "cost", header: true)
            TableRow(label: "Cache read", tokens: Fmt.tokens(call.cacheRead), share: Fmt.percent(Double(call.cacheRead) / Double(total) * 100), cost: Fmt.money(p.cacheRead), swatch: Theme.ramp[0])
            TableRow(label: "Cache write", tokens: Fmt.tokens(call.cacheWrite), share: Fmt.percent(Double(call.cacheWrite) / Double(total) * 100), cost: Fmt.money(p.cacheWrite), swatch: Theme.ramp[1])
            TableRow(label: "Uncached input", tokens: Fmt.tokens(call.freshInput), share: Fmt.percent(Double(call.freshInput) / Double(total) * 100), cost: Fmt.money(p.input), swatch: Theme.ramp[3])
            TableRow(label: "Output", tokens: Fmt.tokens(call.output), share: call.thinkingTokens > 0 ? "\(Fmt.tokens(call.thinkingTokens)) thinking" : "", cost: Fmt.money(p.output), swatch: Theme.ramp[2])
            Divider()
            HStack(alignment: .firstTextBaseline) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.seriesCostPerCall).frame(width: 8, height: 8)
                Text("Cost of this call").font(.caption.weight(.semibold))
                Spacer()
                Text(Fmt.money(call.cost)).font(.callout.weight(.semibold)).monospacedDigit()
            }
            let sessionTotal = timeline.totalCost
            TableRow(label: "Cost so far", tokens: "", share: sessionTotal > 0 ? Fmt.percent(call.cumulativeCost / sessionTotal * 100) : "",
                     cost: Fmt.money(call.cumulativeCost), swatch: Theme.seriesCumulative)
        }
    }

    /// Change in context since the previous main-thread call, which is how a compaction or a big file read shows up.
    private var contextDelta: String? {
        guard let previous = previousMain else { return nil }
        let delta = call.contextTokens - previous.contextTokens
        if delta == 0 { return "no change" }
        return (delta > 0 ? "+" : "−") + Fmt.tokens(abs(delta)) + " since previous"
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let gap = call.idleGap {
                Text("\(gap < 60 ? "\(Int(gap))s" : Fmt.duration(Int(gap))) since the previous call").font(.caption).foregroundStyle(.secondary)
            }
            if call.cacheExpired {
                Label("Cache had expired: the context was re-written", systemImage: "snowflake").font(.caption).foregroundStyle(Theme.accent)
            } else if call.cacheRead > 0 {
                Label("Cache hit: \(Fmt.percent(Double(call.cacheRead) / Double(max(call.contextTokens, 1)) * 100)) of the context read from cache", systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !call.tools.isEmpty {
                let counts = Dictionary(call.tools.map { ($0, 1) }, uniquingKeysWith: +).sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                Text("Tools: " + counts.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let skill = call.skill { Text("Skill: \(skill)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func eventsSection(_ slice: [TimelineMarker]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            Text("In this slice").font(.caption.weight(.semibold))
            ForEach(slice) { m in
                switch m.kind {
                case .prompt(let p): Text("Prompt \(promptOrdinal(m.id, in: timeline).map(String.init) ?? "?"): “\(p)”").lineLimit(1)
                case .compact(let trigger, let pre, let post, _):
                    Text("Compaction (\(trigger))" + (pre.flatMap { a in post.map { " \(Fmt.tokens(a))→\(Fmt.tokens($0))" } } ?? ""))
                case .clear: Text("Context cleared")
                case .command(let name): Text(name)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A prompt, a compaction or a clear.
struct MarkerCard: View {
    let marker: TimelineMarker
    let timeline: SessionTimeline
    var width: CGFloat = 290

    var body: some View {
        CardChrome(width: width) {
            VStack(alignment: .leading, spacing: 6) {
                switch marker.kind {
                case .prompt(let preview): prompt(preview)
                case .compact(let trigger, let pre, let post, let ms): compaction(trigger, pre, post, ms)
                case .clear: clear
                case .command(let name): header(name, "Command")
                }
            }
        }
    }

    private func header(_ title: String, _ kind: String) -> some View {
        HStack {
            Text(title).font(.callout.weight(.semibold))
            Spacer()
            Text(clock(marker.time)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private func prompt(_ preview: String) -> some View {
        let n = promptOrdinal(marker.id, in: timeline)
        header("Prompt \(n.map(String.init) ?? "")", "Prompt")
        Text("“\(preview)”").font(.callout).fixedSize(horizontal: false, vertical: true)
        if let n, let turn = timeline.turnSummary(n) {
            Divider()
            Text("Answered with \(Fmt.count(turn.calls, "call")) · \(Fmt.money(turn.cost)) · \(Fmt.tokens(turn.outputTokens)) output tokens")
                .font(.caption).foregroundStyle(.secondary)
            Text("Took \(Fmt.duration(max(0, Int(turn.end.timeIntervalSince(turn.start)))))").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func compaction(_ trigger: String, _ pre: Int?, _ post: Int?, _ ms: Int?) -> some View {
        header("Compaction (\(trigger))", "Compaction")
        if let pre, let post {
            Text("\(Fmt.tokens(pre)) → \(Fmt.tokens(post)) tokens").font(.callout).monospacedDigit()
            Text("\(Fmt.tokens(max(0, pre - post))) freed from the context window").font(.caption).foregroundStyle(.secondary)
        }
        if let ms { Text("The summary took \(ms >= 1000 ? "\(ms / 1000)s" : "\(ms)ms")").font(.caption).foregroundStyle(.secondary) }
        if let next = timeline.mainCalls.first(where: { $0.time > marker.time }) {
            Divider()
            Text("First call after: \(Fmt.money(next.cost)) · wrote \(Fmt.tokens(next.cacheWrite)) to the cache").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var clear: some View {
        header("Context cleared", "Clear")
        Text("A fresh conversation starts here. Nothing before it is carried forward, so the context begins nearly empty.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A stretch of the model ribbon.
struct ModelSpanCard: View {
    let span: ModelSpan
    let timeline: SessionTimeline
    var width: CGFloat = 270

    var body: some View {
        let peak = timeline.mainCalls.filter { $0.time >= span.start && $0.time <= span.end }.map(\.contextTokens).max() ?? 0
        CardChrome(width: width) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.color(ModelFamily(modelID: span.model))).frame(width: 9, height: 9)
                    Text(ModelFamily.displayName(modelID: span.model)).font(.callout.weight(.semibold))
                    Spacer()
                    Text(span.model).font(.caption).foregroundStyle(.tertiary)
                }
                Text("\(clock(span.start, seconds: false)) to \(clock(span.end, seconds: false)) · \(Fmt.duration(max(0, Int(span.end.timeIntervalSince(span.start)))))")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("\(Fmt.count(span.callCount, "call")) · \(Fmt.money(span.cost))").font(.caption).foregroundStyle(.secondary)
                Text("Context peaked at \(Fmt.tokens(peak)) on this model").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Hover card for something in a feature lane: a loop iteration or decision, a sub-agent run, or a test run.
struct LaneCard: View {
    let target: LaneTarget
    let lanes: FeatureLanes
    var width: CGFloat = 290

    var body: some View {
        CardChrome(width: width) {
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }

    @ViewBuilder private var content: some View {
        switch target {
        case .iteration(let n):
            if let loop = lanes.loop, let it = loop.iterations.first(where: { $0.index == n }) { iteration(it, of: loop.iterations.count) }
        case .decision(let id):
            if let d = lanes.loop?.decisions.first(where: { $0.id == id }) { decision(d) }
        case .subagent(let id):
            if let run = lanes.subagents?.runs.first(where: { $0.id == id }) { subagent(run) }
        case .testRun(let id):
            if let run = lanes.tests?.runs.first(where: { $0.id == id }) { testRun(run) }
        }
    }

    private func title(_ text: String, _ lane: FeatureLane, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: lane.symbol).foregroundStyle(lane.color)
            Text(text).font(.callout.weight(.semibold))
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
        }
    }

    private func line(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    @ViewBuilder private func iteration(_ it: LoopIteration, of count: Int) -> some View {
        title("Loop iteration \(it.index) of \(count)", .loop)
        line("\(clock(it.start)) to \(clock(it.end)) · \(Fmt.spanLength(it.end.timeIntervalSince(it.start)))")
        Divider()
        line("\(Fmt.count(it.callCount, "call")) · \(Fmt.money(it.cost)) · \(Fmt.tokens(it.outputTokens)) tokens written")
        switch it.startedBy {
        case .invoked: line("Started when the loop was set up")
        case .scheduledWake:
            if let late = it.lateness, let due = it.plannedFor { line("Due \(clock(due)), woke \(Fmt.spanLength(max(late, 0))) later") }
            else { line("Woke on the schedule Claude set") }
        case .fallbackWake: line("Woke on the harness's fallback timer: the previous iteration neither rescheduled nor stopped")
        }
        if !it.prompt.isEmpty { line("“\(it.prompt)”") }
    }

    @ViewBuilder private func decision(_ d: LoopDecision) -> some View {
        switch d.kind {
        case .again(let seconds, let reason):
            title("Claude chose to loop again", .loop, trailing: clock(d.time))
            line("Wake in \(Fmt.spanLength(TimeInterval(seconds))) (after iteration \(d.afterIteration))")
            if let reason, !reason.isEmpty { line(reason) }
        case .stop:
            title("Claude stopped the loop", .loop, trailing: clock(d.time))
            line("After iteration \(d.afterIteration)")
        }
    }

    @ViewBuilder private func subagent(_ run: SubagentRun) -> some View {
        title(run.label, .subagents, trailing: run.type)
        line("\(clock(run.start)) to \(clock(run.end)) · \(Fmt.spanLength(run.end.timeIntervalSince(run.start)))")
        Divider()
        line("\(Fmt.count(run.callCount, "call")) · \(Fmt.money(run.cost)) · \(Fmt.tokens(run.outputTokens)) tokens written")
    }

    @ViewBuilder private func testRun(_ run: TestRun) -> some View {
        title("Test run", .tests, trailing: clock(run.time))
        Text(run.shortCommand).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        Divider()
        if let s = run.summary {
            let pct = s.total > 0 ? Double(s.passed) / Double(s.total) * 100 : 0
            line("\(s.passed) of \(s.total) passed (\(Fmt.percent(pct)))" + (s.failed > 0 ? " · \(s.failed) failed" : "") + (s.skipped > 0 ? " · \(s.skipped) skipped" : ""))
            line("Read from \(s.runner) output")
        } else {
            line("The result could not be read from the output")
        }
    }
}

/// Hover card for a place on the suggestions bar: what the advisor would have said, and when.
struct AdviceCard: View {
    let marker: AdviceMarker
    var width: CGFloat = 290

    var body: some View {
        CardChrome(width: width) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: marker.level.symbol).foregroundStyle(marker.level.color)
                    Text(marker.headline).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                Text(clock(marker.time)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Divider()
                Text(marker.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Replayed from the transcript at today's list prices: where KAIkei would have suggested this.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension CompactAdvice.Level {
    var symbol: String {
        switch self {
        case .fine: "checkmark.circle"
        case .consider: "lightbulb.fill"
        case .compactSoon: "exclamationmark.triangle.fill"
        case .coldCache: "snowflake"
        }
    }
    var color: Color {
        switch self {
        case .fine: Theme.good
        case .consider: Theme.accent
        case .compactSoon: Theme.caution
        case .coldCache: Theme.accent
        }
    }
}
