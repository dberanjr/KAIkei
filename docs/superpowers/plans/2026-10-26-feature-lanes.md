# Claude Code Feature Lanes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show `/loop`, sub-agents, test runs, plugins (and, once captured, `/goal`) as lanes under the session timeline, with a toggle that overlays the same markers on the main cost chart.

**Architecture:** The transcript parser emits small `FeatureSignal` values for the rows these features write. Pure builders in `UsageCore` combine signals with the existing `SessionTimeline` calls into lane models (`LoopLane`, `SubagentLane`, `TestLane`, `PluginLane`). SwiftUI lane views and an overlay layer draw those models on the shared time axis, using the existing `TimelineGeometry`, `TimelineStackLayout`, and hover pieces.

**Tech Stack:** Swift 6 toolchain in Swift 5 mode, SwiftUI + Charts, swift-testing (`@Suite`, `@Test`, `#expect`). Command Line Tools only, no Xcode.

**Spec:** `docs/superpowers/specs/2026-10-26-feature-lanes-design.md`

## Global Constraints

- Tests run with `swift test --scratch-path ~/Library/Caches/ClaudeUsageWidget/build [--filter Name]` (or `make test`); never build inside OneDrive (codesign fails). Baseline before this plan: 234 tests passing.
- The working tree has nine uncommitted files unrelated to this plan. Commit or stash them first so each task commit here is clean.
- Parsing logic and lane models live in `UsageCore` (testable); drawing lives in `ClaudeUsageWidget`. SwiftUI here has no `@State`; use `@StateObject`/store-held state.
- Never assign to a `@Published` property from its own `didSet` without guarding for equality (stack-overflow trap).
- Never show a number the transcript does not support: unreadable input yields no lane or an explicit "unreadable", never an estimate.
- Prompt and loop-prompt text stays in memory only and is truncated to 100 characters for display.
- Keep the byte-prefilter approach: decode a line as JSON only after a cheap `Data.range(of:)` marker match.
- Chart colors come from `Theme`; one colour family per lane; overlay and lane use the same colours.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

Most likely first. Each has a test in the task named.

1. A session that used none of these features shows no lane and no extra height (Tasks 8, 10).
2. A loop still running (no stop, no later wake-up) has an open last iteration costed up to now (Task 4).
3. Claude Code writes one transcript row per content block, so the same signal can arrive twice; it must count once (Task 2).
4. A test command whose output has no readable summary (build failure) is "unreadable", and a session whose last run is unreadable or red never shows green (Task 6).
5. A sub-agent whose spawn row is missing is still shown and costed, labelled "sub-agent" (Task 5).

## File Structure

- Create `Sources/UsageCore/FeatureSignal.swift`: `FeatureSignal` model + `TranscriptParser.parseSignal(line:)`.
- Create `Sources/UsageCore/LoopLane.swift`, `SubagentLane.swift`, `TestLane.swift`, `PluginLane.swift`, `FeatureLanes.swift`: lane models and builders.
- Create `Sources/ClaudeUsageWidget/FeatureLaneViews.swift`: lane views, overlay layer, hover cards.
- Modify `UsageRecord.swift`, `Timeline.swift`, `IncrementalReader.swift`, `UsageCollector.swift`, `TimelineHover.swift`, `Store.swift`, `SessionTimelineView.swift`, `SnapshotMode.swift`.
- Tests: `FeatureSignalTests`, `LoopLaneTests`, `SubagentLaneTests`, `TestLaneTests`, `PluginLaneTests`, `FeatureLaneLayoutTests` in `Tests/UsageCoreTests/`.

---

### Task 1: Parse feature signals from transcript rows

**Files:**
- Create: `Sources/UsageCore/FeatureSignal.swift`
- Test: `Tests/UsageCoreTests/FeatureSignalTests.swift`

**Interfaces:**
- Produces:
```swift
public struct FeatureSignal: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case loopInvoked(prompt: String)                       // /loop command row, or Skill tool_use with skill "loop"
        case loopWakeup(taskID: String, cron: String?)         // system row subtype scheduled_task_fire, taskKind "loop"
        case wakeupScheduled(toolUseID: String, delaySeconds: Int, reason: String?)  // ScheduleWakeup tool_use without stop
        case wakeupAck(toolUseID: String, scheduledFor: Date)  // its tool_result: toolUseResult.scheduledFor (epoch ms)
        case loopStopped(toolUseID: String)                    // ScheduleWakeup tool_use with stop: true
        case agentSpawned(toolUseID: String, type: String?, description: String)  // tool_use named "Agent"
        case testCommand(toolUseID: String, command: String)   // Bash tool_use whose command contains a known runner
        case testOutput(toolUseID: String, text: String)       // tool_result text containing a runner summary marker
    }
    public var id: String          // row uuid, plus "#<toolUseID>" for tool rows so duplicates share an id
    public var sessionID: String
    public var timestamp: Date
    public var kind: Kind
    public var isSidechain: Bool
}
extension TranscriptParser { public static func parseSignal(line: Data) -> FeatureSignal? }
```

- [ ] **Step 1: Write failing tests** in `FeatureSignalTests`, with local row builders `fireLine`, `scheduleLine`, `ackLine`, `stopLine`, `agentLine`, `bashLine`, `outputLine`, `skillLoopLine`, and `loopCommandLine` (modelled on `promptLine` in `EventParsingTests.swift`). Shapes come from the real run in the spec's Facts. One `@Test` per kind, each asserting `kind` and `sessionID`:
  - `aFireRowBecomesAWakeup`: `loopWakeup(taskID: "50d65d60", cron: "57 11 * * *")`
  - `aScheduleWakeupCallCarriesDelayAndReason`: `wakeupScheduled(toolUseID: "t1", delaySeconds: 1200, reason: "no event to watch")`
  - `aStopCallIsAStop`: `loopStopped(toolUseID: "t2")`
  - `anAckCarriesTheScheduledTime`: `scheduledFor == Date(timeIntervalSince1970: 1_790_186_220)` from `1790186220000` ms
  - `theLoopSkillAndTheLoopCommandBothMeanInvoked`
  - `anAgentCallCarriesTypeAndDescription`: `agentSpawned(toolUseID:, type: "fork", description: "Explore data")`
  - `onlyKnownRunnerCommandsBecomeTestCommands`: `swift test --filter X` yes, `ls` no
  - `aToolResultOnlyBecomesTestOutputWhenItHasASummaryMarker`
  - `unrelatedRowsReturnNil`: plain assistant row, prompt row, `scheduled_task_fire` with `taskKind` other than `loop`.
- [ ] **Step 2: Run** `swift test --scratch-path ~/Library/Caches/ClaudeUsageWidget/build --filter FeatureSignalTests`. Expected: compile failure (`parseSignal` not defined).
- [ ] **Step 3: Implement `parseSignal(line:)`** in `FeatureSignal.swift`. Prefilter on any of these byte markers, return nil if none match: `scheduled_task_fire`, `"name":"ScheduleWakeup"`, `"name":"Skill"`, `<command-name>/loop`, `"name":"Agent"`, `"name":"Bash"`, `"scheduledFor"`, and for results `"tool_result"` together with a summary marker (`Test run with`, `Executed `, ` passed`, `Tests:`). Decode once; first matching tool_use block wins (rows carry one block). Known runners (substring of the Bash command): `swift test`, `pytest`, `jest`, `vitest`, `make test`, `npm test`, `xcodebuild test`. Truncate `loopInvoked` prompt to 100 characters. Reuse `TranscriptParser.isoFractional/isoPlain` for timestamps.
- [ ] **Step 4: Run** the same filter. Expected: all pass.
- [ ] **Step 5: Commit** `git add Sources/UsageCore/FeatureSignal.swift Tests/UsageCoreTests/FeatureSignalTests.swift && git commit -m "feat: parse loop, agent and test signals from transcript rows"`

### Task 2: Carry signals through the reader, store and dashboard

**Files:**
- Modify: `Sources/UsageCore/UsageRecord.swift` (RecordStore), `Sources/UsageCore/IncrementalReader.swift`, `Sources/UsageCore/UsageCollector.swift` (Dashboard)
- Test: `Tests/UsageCoreTests/FeatureSignalTests.swift` (add), `Tests/UsageCoreTests/CollectorTests.swift` (add)

**Interfaces:**
- Consumes: `FeatureSignal`, `parseSignal(line:)`.
- Produces: `RecordStore.signals: [FeatureSignal]`, `RecordStore.add(_ signal: FeatureSignal)` (dedupe by `id`), `Dashboard.signals: [FeatureSignal]`.

- [ ] **Step 1: Write failing tests:** `theSameSignalTwiceCountsOnce` (store with two equal signals has `signals.count == 1`; Review Focus 3); in `CollectorTests`, `dashboardExposesFeatureSignals` writing a temp transcript with a `fireLine` and asserting `dashboard.signals.count == 1`, following the pattern of the existing `dashboardExposesTranscriptEventsForTheTimeline`.
- [ ] **Step 2: Run** filters `FeatureSignalTests` and `CollectorTests`. Expected: FAIL (no `signals`).
- [ ] **Step 3: Implement.** In `IncrementalReader.ingest`, a line may be a billed record and a signal (ScheduleWakeup, Agent and Bash calls are assistant rows with usage), so call `parse`, `parseEvent` and `parseSignal` independently rather than `else if`. `Dashboard` gains `signals` filled from `store.signals`.
- [ ] **Step 4: Run** the full suite. Expected: 234 existing tests still pass plus the new ones.
- [ ] **Step 5: Commit** `feat: plumb feature signals to the dashboard`

### Task 3: Attribute calls to sub-agents and plugins

**Files:**
- Modify: `Sources/UsageCore/UsageRecord.swift`, `Sources/UsageCore/TranscriptParser.swift`, `Sources/UsageCore/Timeline.swift` (`CallPoint`, `Timelines.build`)
- Test: `Tests/UsageCoreTests/TranscriptTests.swift`, `Tests/UsageCoreTests/TimelineTests.swift` (add)

**Interfaces:**
- Produces: `UsageRecord.agentID: String?`, `UsageRecord.spawnToolUseID: String?`; `CallPoint.plugin: String?`, `CallPoint.agentID: String?`, `CallPoint.spawnToolUseID: String?`. All default nil so existing initialisers and the `tcall` helper keep compiling.

- [ ] **Step 1: Write failing tests:** `parsesAgentIDAndSpawnIDFromSidechainRows` (row with `"agentId":"a9556657103b4de13"` and `"wireToolInputs":{"toolu_01TWi":{}}` gives `agentID == "a9556657103b4de13"`, `spawnToolUseID == "toolu_01TWi"`); `mainThreadRowsHaveNoAgentID`; `callsCarryPluginAndAgent` (a `tcall` record with those set appears on its `CallPoint`); `mergingDuplicateRowsKeepsAgentID`.
- [ ] **Step 2: Run** `--filter TranscriptTests` and `--filter TimelineTests`. Expected: FAIL.
- [ ] **Step 3: Implement** in `parse(line:)` (read `agentId`, and the first key of `wireToolInputs` that starts with `toolu_`), in `RecordStore.add` merge (`??` like `skill`), and in `Timelines.build` mapping.
- [ ] **Step 4: Run** full suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat: attribute calls to sub-agents and plugins`

### Task 4: Loop lane builder

**Files:**
- Create: `Sources/UsageCore/LoopLane.swift`
- Test: `Tests/UsageCoreTests/LoopLaneTests.swift`

**Interfaces:**
- Consumes: `FeatureSignal`, `SessionTimeline` (`calls`, `markers`, `end`), `CallPoint.cost`.
- Produces:
```swift
public struct LoopIteration: Identifiable, Equatable, Sendable {
    public enum Start: Equatable, Sendable { case invoked, scheduledWake, fallbackWake }
    public var id: String; public var index: Int          // 1-based
    public var start: Date; public var end: Date
    public var cost: Double; public var callCount: Int; public var outputTokens: Int
    public var startedBy: Start; public var plannedFor: Date?; public var prompt: String
    public var lateness: TimeInterval? { plannedFor.map { start.timeIntervalSince($0) } }
}
public struct LoopDecision: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case again(delaySeconds: Int, reason: String?), stop }
    public var id: String; public var time: Date; public var kind: Kind; public var afterIteration: Int
}
public struct LoopLane: Equatable, Sendable {
    public var iterations: [LoopIteration]; public var decisions: [LoopDecision]
    public var totalCost: Double { get }; public var averageCost: Double { get }
}
extension FeatureLanes { public static func loop(signals: [FeatureSignal], timeline: SessionTimeline, sessionID: String) -> LoopLane? }
```
(`FeatureLanes` is declared as an empty `public enum FeatureLanes {}` here and given its model in Task 8.)

- [ ] **Step 1: Write failing tests** using `tcall`/`tevent` and a local `tsignal(_ minute:, _ kind:)` helper. Base scenario S: `loopInvoked` m0; calls c1 m1, c2 m3.5; `wakeupScheduled(t1, 1200, "no event to watch")` m3; `wakeupAck(t1, scheduledFor: t0+23m)`; `loopWakeup` m23.3; c3 m24, c4 m25 (sidechain), `loopStopped(t2)` m26, c5 m26.5. Assert:
  - `iterationsAreCostedFromWakeToWake`: 2 iterations; `it1.cost == c1+c2` costs; `it2.cost == c3+c4+c5` (sub-agent included); `it2.startedBy == .scheduledWake`; `it2.plannedFor == t0+23m`; `abs(it2.lateness! - 18) < 0.001`.
  - `decisionsMarkAgainAndStop`: `[.again(delaySeconds: 1200, reason: "no event to watch")` at m3 after iteration 1, `.stop` at m26 after iteration 2`]`.
  - `aTypedPromptEndsAnIteration`: add a prompt marker at m24.5; `c4`, `c5` fall outside `it2`.
  - `anIterationWithNoDecisionLeadsToAFallbackWake`: remove the schedule/ack signals; the wake-up is `.fallbackWake` and iteration 1 has no decision.
  - `anOpenLoopRunsToTheEndOfTheTimeline`: drop the stop; last iteration `end == timeline.end`, and decisions contain no `.stop` (Review Focus 2).
  - `aLoopCommandRightAfterAWakeupIsNotANewInvocation`: `loopInvoked` 0.1 s after `loopWakeup` adds no iteration.
  - `noLoopSignalsMeansNoLane`: returns nil.
- [ ] **Step 2: Run** `--filter LoopLaneTests`. Expected: FAIL (not defined).
- [ ] **Step 3: Implement `FeatureLanes.loop`.** Boundaries are `loopInvoked` (unless within 2 s after a `loopWakeup`) and every `loopWakeup`; an iteration spans from its boundary to the earliest of the next boundary, the next prompt marker after it, or `timeline.end`; its cost is the sum of every `timeline.calls` entry in `[start, end)`, sidechain included. Pair each `wakeupScheduled` with its `wakeupAck` by `toolUseID`; the next wake-up after a scheduled decision takes that ack's `scheduledFor` as `plannedFor`. A wake-up with no preceding `again` decision in the previous iteration is `.fallbackWake`. Take `prompt` from the `loopInvoked` signal.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat: build the loop lane model`

### Task 5: Sub-agent lane builder

**Files:**
- Create: `Sources/UsageCore/SubagentLane.swift`
- Test: `Tests/UsageCoreTests/SubagentLaneTests.swift`

**Interfaces:**
- Consumes: `CallPoint.agentID`, `.spawnToolUseID`, `.isSidechain`; `FeatureSignal.Kind.agentSpawned`.
- Produces:
```swift
public struct SubagentRun: Identifiable, Equatable, Sendable {
    public var id: String                 // agentID
    public var label: String              // spawn description, or "sub-agent" when no spawn row matches
    public var type: String?
    public var start: Date; public var end: Date
    public var cost: Double; public var callCount: Int; public var outputTokens: Int
    public var row: Int                   // 0-based stacking row so overlapping runs do not collide
}
public struct SubagentLane: Equatable, Sendable { public var runs: [SubagentRun]; public var totalCost: Double { get }; public var rowCount: Int { get } }
extension FeatureLanes { public static func subagents(signals: [FeatureSignal], timeline: SessionTimeline) -> SubagentLane? }
```

- [ ] **Step 1: Write failing tests:** `aRunSpansItsFirstToItsLastCallAndSumsCost`; `labelComesFromTheMatchingSpawn` (spawn `toolUseID` equals call `spawnToolUseID`; label is the description, `type == "fork"`); `overlappingRunsStackInSeparateRows` (two runs overlapping in time get rows 0 and 1; a later non-overlapping run reuses row 0); `aRunWithoutASpawnRowIsStillShown` (label `"sub-agent"`, cost counted; Review Focus 5); `noSidechainCallsMeansNoLane`.
- [ ] **Step 2: Run** `--filter SubagentLaneTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Group `timeline.calls` where `isSidechain && agentID != nil` by `agentID`; greedy row packing sorted by `start`.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat: build the sub-agent lane model`

### Task 6: Test-run lane builder

**Files:**
- Create: `Sources/UsageCore/TestLane.swift`
- Test: `Tests/UsageCoreTests/TestLaneTests.swift`

**Interfaces:**
- Consumes: `FeatureSignal.Kind.testCommand/.testOutput`.
- Produces:
```swift
public struct TestSummary: Equatable, Sendable { public var runner: String; public var passed: Int; public var failed: Int; public var skipped: Int
    public var total: Int { get }  /* passed + failed, skipped excluded */ }
public enum TestSummaryParser { public static func parse(_ output: String) -> TestSummary? }
public struct TestRun: Identifiable, Equatable, Sendable { public var id: String; public var time: Date; public var command: String; public var summary: TestSummary? /* nil = unreadable */ }
public struct TestLane: Equatable, Sendable {
    public enum State: Equatable, Sendable { case green, red, unreadable }
    public var runs: [TestRun]; public var lastState: State { get }
}
extension FeatureLanes { public static func tests(signals: [FeatureSignal]) -> TestLane? }
```

- [ ] **Step 1: Write failing tests** with real output strings:
  - `swiftTestingSummary`: `"✔ Test run with 234 tests in 32 suites passed after 0.274 seconds."` gives passed 234, failed 0.
  - `swiftTestingFailureCountsFailedTests`: output with three `✘ Test x() failed` lines and `✘ Test run with 234 tests in 32 suites failed after 0.3 seconds with 3 issues.` gives failed 3, passed 231.
  - `xctestUsesTheLastExecutedLine`: per-suite `Executed 5 tests, with 0 failures` lines then a final `Executed 12 tests, with 2 failures (0 unexpected)` gives passed 10, failed 2.
  - `pytestSummary`: `"== 8 passed, 1 failed, 2 skipped in 0.5s =="` gives 8/1/2 and `total == 9`.
  - `jestSummary`: `"Tests:       1 failed, 5 passed, 6 total"`.
  - `noMarkerMeansNil`: `"error: build failed"` returns nil.
  - Lane: `runsPairCommandsWithOutputsByToolUseID`; `aCommandWithUnreadableOutputIsAnUnreadableRun` and `lastStateIsUnreadableNotGreenAfterAnEarlierGreenRun` (green run then unreadable run gives `.unreadable`; Review Focus 4); `lastStateIsRedWhenTheLastRunFailed`; `aCommandWithNoOutputRowIsUnreadable`; `noTestCommandsMeansNoLane`.
- [ ] **Step 2: Run** `--filter TestLaneTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Parser tries each runner in order using `NSRegularExpression`; swift-testing and XCTest first. `go test` and `cargo test` are out of this first cut (YAGNI); add when a real transcript needs them. Output text longer than 20,000 characters keeps its last 20,000.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat: build the test-run lane model`

### Task 7: Plugin lane builder

**Files:**
- Create: `Sources/UsageCore/PluginLane.swift`
- Test: `Tests/UsageCoreTests/PluginLaneTests.swift`

**Interfaces:**
- Produces:
```swift
public struct PluginSegment: Identifiable, Equatable, Sendable { public var id: String { name }; public var name: String; public var cost: Double }
public struct PluginLane: Equatable, Sendable { public var segments: [PluginSegment]; public var total: Double { get } }
extension FeatureLanes { public static func plugins(timeline: SessionTimeline, top: Int = 4) -> PluginLane? }
```

- [ ] **Step 1: Write failing tests:** `costIsSummedPerPluginLargestFirst`; `smallPluginsFoldIntoOther` (five plugins with `top: 2` gives two named plus "other"); `unattributedCallsFoldIntoOther`; `noPluginAttributionMeansNoLane`.
- [ ] **Step 2: Run** `--filter PluginLaneTests`. Expected: FAIL.
- [ ] **Step 3: Implement** by grouping `timeline.calls` by `plugin`, sidechain included.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat: build the plugin lane model`

### Task 8: Aggregate model and lane identities

**Files:**
- Create: `Sources/UsageCore/FeatureLanes.swift`
- Test: `Tests/UsageCoreTests/FeatureLaneLayoutTests.swift`

**Interfaces:**
- Produces:
```swift
public enum FeatureLane: String, CaseIterable, Identifiable, Sendable { case loop, goal, subagents, tests, plugins
    public var id: String { rawValue }; public var title: String { get } }   // "/loop", "/goal", "Sub-agents", "Test runs", "Plugins and skills"
public struct FeatureLanes: Equatable, Sendable {
    public var loop: LoopLane?; public var subagents: SubagentLane?; public var tests: TestLane?; public var plugins: PluginLane?
    public var present: [FeatureLane] { get }      // in FeatureLane order, only lanes with data
    public var isEmpty: Bool { get }
    public static func build(signals: [FeatureSignal], timeline: SessionTimeline, sessionID: String) -> FeatureLanes
}
```
(The `public enum FeatureLanes {}` stub from Task 4 becomes this struct; the static builders stay as extensions.)

- [ ] **Step 1: Write failing tests:** `aSessionWithNoFeaturesIsEmpty` (Review Focus 1); `presentListsOnlyLanesWithDataInOrder` (loop + plugins data gives `[.loop, .plugins]`); `signalsFromOtherSessionsAreIgnored`.
- [ ] **Step 2: Run** `--filter FeatureLaneLayoutTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the struct and `build`, filtering signals to `sessionID`.
- [ ] **Step 4: Run** the full suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat: aggregate feature lanes per session`

### Task 9: Overlay settings in the store

**Files:**
- Modify: `Sources/ClaudeUsageWidget/Store.swift`

**Interfaces:**
- Consumes: `FeatureLane`.
- Produces: `UsageStore.featureOverlayOn: Bool` (key `featureOverlayOn`, default `false`), `UsageStore.featureOverlayLanes: Set<FeatureLane>` (key `featureOverlayLanes`, default all cases, stored as sorted raw values like `overlays`).

- [ ] **Step 1: Implement** both `@Published` properties with `didSet` persistence, initialised in `init(defaults:)` like `overlays`, treating a missing key as the default and an empty stored array as an empty set. No clamping logic, so no self-assignment in `didSet`.
- [ ] **Step 2: Run** `swift build --scratch-path ~/Library/Caches/ClaudeUsageWidget/build`. Expected: builds. Behaviour is verified by the snapshot flags added in Task 13 (the executable target has no unit tests, as with `overlays`).
- [ ] **Step 3: Commit** `feat: remember the feature overlay settings`

### Task 10: Lane views under the timeline

**Files:**
- Create: `Sources/ClaudeUsageWidget/FeatureLaneViews.swift`
- Modify: `Sources/UsageCore/TimelineHover.swift` (`StackItem.Kind` and `PanelBand.Kind` gain `.lane`), `Sources/ClaudeUsageWidget/SessionTimelineView.swift` (`layout`, `chartStack`), `Sources/ClaudeUsageWidget/Theme.swift` (lane colours)
- Test: `Tests/UsageCoreTests/FeatureLaneLayoutTests.swift` (add)

**Interfaces:**
- Consumes: `FeatureLanes`, `TimelineGeometry` (`x(time:)`, `x(endingAt:)`, `domain`), `Theme`.
- Produces: `struct FeatureLaneStack: View` with `init(lanes: FeatureLanes, geometry: TimelineGeometry, density: TimelineDensity)`; `StackItem.Kind.lane`, `PanelBand.Kind.lane`.

- [ ] **Step 1: Write failing test** `laneItemsProduceLaneBandsAndShiftNothingAbove`: a `TimelineStackLayout` with ribbon, prompts, data and two `.lane` items yields bands whose first three equal the layout without lanes, followed by two `.lane` bands.
- [ ] **Step 2: Run** `--filter FeatureLaneLayoutTests`. Expected: FAIL (no `.lane`).
- [ ] **Step 3: Implement** `.lane` in both enums and `TimelineStackLayout.bands`. Then the views, each lane a header row (title left, summary right: for `/loop` "5 iterations · $1.64 · avg $0.33") above a 62-pt-tall (scaled by density) strip drawn with Swift Charts on the shared geometry, matching the approved mockup (`.superpowers/brainstorm/*/content/feature-lanes.html`):
  - Loop: one `RectangleMark` per iteration, height proportional to its cost within the lane, drawn as a vertical band; decision icons via SF Symbols `arrow.triangle.2.circlepath` (again), `stop.circle` (stop), `exclamationmark.triangle` (fallback wake); dashed `RuleMark` from decision to wake-up with a "wait 20m" label.
  - Sub-agents: horizontal bars by `row`, label inside when wide enough.
  - Tests: one stacked bar per run (passed/failed scaled to that run's total; unreadable as hatched grey); header shows "234 / 234 (100%)" for a readable last run, "last run unreadable" otherwise, and "ended red" when `lastState == .red`.
  - Plugins: one horizontal stacked bar across the full width, ignoring pan and zoom.
  `FeatureLaneStack` renders only `lanes.present` lanes, so an empty `FeatureLanes` adds no height. In `SessionTimelineView`, append the stack after the separate panels, add one `StackItem(kind: .lane, height:)` per present lane to `layout`, and build `FeatureLanes` from `store.dashboard?.signals` once per timeline change, not per frame.
- [ ] **Step 4: Run** the full suite, then `swift build`. Expected: PASS and a clean build.
- [ ] **Step 5: Commit** `feat: draw feature lanes under the session timeline`

### Task 11: Hover cards for lane elements

**Files:**
- Create: `Sources/UsageCore/FeatureLaneHit.swift`
- Modify: `Sources/ClaudeUsageWidget/FeatureLaneViews.swift`, `Sources/ClaudeUsageWidget/SessionTimelineView.swift` (`TimelineHoverOverlay` handles `.lane` bands)
- Test: `Tests/UsageCoreTests/FeatureLaneLayoutTests.swift` (add)

**Interfaces:**
- Produces:
```swift
public enum LaneTarget: Equatable, Sendable { case iteration(Int), decision(String), subagent(String), testRun(String) }
extension FeatureLanes { public func target(lane: FeatureLane, at time: Date) -> LaneTarget? }
```

- [ ] **Step 1: Write failing tests:** `hoveringInsideAnIterationFindsIt`, `hoveringADecisionTimeFindsTheDecisionBeforeTheIteration`, `hoveringAnEmptyStretchFindsNothing`, `hoveringAnOverlappingSubagentRowFindsTheRunAtThatTime`.
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement** `target(lane:at:)` (decisions win within 20 pt-equivalent of time; the view passes a time tolerance derived from the geometry). Add cards showing the hover content from the spec: iteration number, cost, tokens, planned vs actual delay, loop prompt (first 100 characters); sub-agent description, type, duration, calls, tokens, cost; test run pass ratio and runner. Reuse the existing `TimelineHover` dwell delays; do not add per-move state to `UsageStore`.
- [ ] **Step 4: Run** full suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat: hover cards for feature lane elements`

### Task 12: Overlay on the main cost chart, with toggle

**Files:**
- Modify: `Sources/ClaudeUsageWidget/SessionTimelineView.swift` (`mainChart`, `overlayChips`), `Sources/ClaudeUsageWidget/FeatureLaneViews.swift`

**Interfaces:**
- Consumes: `store.featureOverlayOn`, `store.featureOverlayLanes`, `FeatureLanes`.
- Produces: `@ChartContentBuilder func featureOverlay(_ lanes: FeatureLanes, selected: Set<FeatureLane>, g: TimelineGeometry, top: Double) -> some ChartContent`.

- [ ] **Step 1: Implement the toggle** next to the existing overlay chips: a `Toggle("Overlay lanes", isOn: $store.featureOverlayOn)` and, when on, one chip per present lane bound to `featureOverlayLanes` (same chip styling as `chip(_:_:)`).
- [ ] **Step 2: Implement `featureOverlay`** and call it inside `mainChart`'s `Chart` after the existing overlay lines: translucent full-height `RectangleMark` per loop iteration (the vertical bands), the decision icons from Task 10 at the top edge, thin translucent bars along the bottom edge for sub-agent runs, one dot per readable test run (green all passed, red otherwise) placed on the cumulative-cost position of the nearest call, and lane colours identical to the lanes. Draw nothing for lanes the session lacks.
- [ ] **Step 3: Run** `swift build --scratch-path ~/Library/Caches/ClaudeUsageWidget/build`. Expected: builds. Visual check follows in Task 13.
- [ ] **Step 4: Commit** `feat: overlay feature lanes on the main chart`

### Task 13: Snapshot flags and check against real transcripts

**Files:**
- Modify: `Sources/ClaudeUsageWidget/SnapshotMode.swift`, `README.md` (one line listing the flags)

**Interfaces:**
- Produces: snapshot flags `lanes=on|off` (sets `featureOverlayOn`) and `lanesoverlay=loop,agents,tests,plugins|all` (sets `featureOverlayLanes`).

- [ ] **Step 1: Implement the flags** beside the existing `overlay=` handling.
- [ ] **Step 2: Render** the real `/loop` session with lanes shown and then overlaid, using the existing snapshot invocation documented in `README.md`/`SnapshotMode.swift` with `session:<id>` for the casualchaosv1 session `d86c4d96-4670-41da-98d7-b0f898bdbe03`. Expected: the loop lane shows iterations at the real wake-up times with a stop decision at the end; the sub-agent lane shows the fork run; the overlay shows bands and icons. Compare with the approved mockup and fix layout defects.
- [ ] **Step 3: Check numbers.** For that session, the loop lane's total cost equals the sum of `CallPoint.cost` from the first wake-up to the end within one cent; note any difference.
- [ ] **Step 4: Run** `make test`. Expected: all tests pass (234 baseline plus the new ones).
- [ ] **Step 5: Commit** `feat: snapshot flags for feature lanes`

### Task 14: `/goal` lane (gated on a real capture)

**Files:**
- Create: `Sources/UsageCore/GoalLane.swift`, `Tests/UsageCoreTests/GoalLaneTests.swift`, `Tests/Fixtures/goal-run.jsonl`
- Modify: `FeatureSignal.swift`, `FeatureLanes.swift`, `FeatureLaneViews.swift`

**Interfaces:**
- Produces (shape fixed now, fields confirmed by the capture): `GoalLane { condition: String; start: Date; checks: [Date]; end: GoalEnd?; turns: Int; cost: Double }`, `GoalEnd { case met(Date), impossible(Date, reason: String?), stalled(Date), cleared(Date) }`, `FeatureLanes.goal: GoalLane?`.

- [ ] **Step 1: Capture.** In a throwaway session run a short `/goal` (for example "create a file named a.txt containing hello, then stop") and let it finish; run another and `/goal clear` it; copy the transcript rows around the `/goal` command and the "achieved"/"failed" entries into `Tests/Fixtures/goal-run.jsonl`. Record in the spec's Facts what the rows look like. If no end entries are written to the transcript, stop here: the goal lane stays hidden and the project is complete without it (spec decision 1).
- [ ] **Step 2: Write failing tests** against the fixture: `theGoalConditionIsRead`, `aMetGoalEndsMet`, `aClearedGoalEndsCleared`, `anActiveGoalHasNoEnd`, `goalCostIsMainThreadSpendBetweenStartAndEnd`.
- [ ] **Step 3: Run** `--filter GoalLaneTests`. Expected: FAIL.
- [ ] **Step 4: Implement** new `FeatureSignal.Kind` cases for the goal rows as captured, the builder, the view (condition text, a tick per evaluated turn, end marker with check / cross / pause / clear icon and header "reached after N turns · $X"), and add `.goal` to `present`. Include it in the overlay as a vertical line at the end time.
- [ ] **Step 5: Run** `make test`. Expected: PASS. **Commit** `feat: goal lane from captured transcript rows`

---

## Self-Review Notes

- Spec coverage: loop lane, bands and decision icons (Tasks 4, 10, 12); fallback wake (Task 4); goal lane gated (Task 14); sub-agent lane (Tasks 3, 5, 10, 12); tests lane incl. unreadable and ended-red (Tasks 6, 10); plugins lane (Tasks 3, 7, 10); overlay toggle with per-lane checkboxes and persistence (Tasks 9, 12); hover (Task 11); first-cut cron loops and `go test`/`cargo test` explicitly deferred.
- Gaps accepted: fixed-interval (cron) loops do not get decision icons until a real fixture is captured; the fire row's `taskKind: "loop"` may already cover their wake-ups and iterations, which Task 13's check against real data should confirm.
- Types used across tasks match their definitions: `FeatureSignal.Kind` cases, `LoopLane`/`SubagentLane`/`TestLane`/`PluginLane`, `FeatureLanes.build`, `FeatureLane`, `LaneTarget`.
