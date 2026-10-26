# KAIkei: Claude Code feature lanes (design)

Date: 2026-10-26. Status: draft for review. Part 1 of 3 (the others: UI performance, prompt-time advisor).

## Intent and why

KAIkei shows what a Claude Code session costs, but `/loop`, `/goal`, test runs and plugins appear only as plain command markers or as donut slices. A user running an autonomous loop or a goal wants to know what it is costing, what it is doing, and whether it is finished, without reading a transcript. This adds a "feature lanes" area under the session timeline for those four things, and an optional overlay of the same markers on the main cost chart.

## What the user sees

Under the main session cost chart, on the same time axis, up to four lanes. A lane appears only if the session used that feature. Order: `/loop`, `/goal`, Sub-agents, Test runs, Plugins and skills.

Overlay is a toggle (off by default). When on, the selected lanes' markers are drawn on the main cost chart as well. The lanes stay visible. Per-lane checkboxes choose what overlays.

### `/loop` lane
- **Iteration bands.** Each iteration that ran is a vertical band; band height in the lane is that iteration's cost. In the overlay the band is a translucent full-height strip across the main chart.
- **Decision icon.** An icon (the loop arrow glyph) at the moment Claude decided to loop again, from the `ScheduleWakeup` call. A distinct icon for "decided to stop" (`stop: true`), and another for a fallback wake-up Claude did not schedule (see below).
- **Wait.** A dashed line from the decision to the iteration, labelled with the planned delay.
- **Header.** Iteration count, total cost, average cost per iteration.
- Fixed-interval loops (`/loop 5m ...`) are cron jobs, not `ScheduleWakeup`. They get the same bands, but their decision icon is the schedule creation, and waits are the fixed interval.
- Hover on any element: iteration number, cost, tokens, delay planned vs actual, the loop prompt (first ~100 characters, in memory only like existing prompt previews).

### `/goal` lane
- Header: the goal condition (truncated), turns taken, elapsed time, cost so far.
- A tick per turn where the goal was evaluated and judged not met.
- An end marker showing how it ended: **met** (check), **impossible** (cross), **stalled** (pause), **cleared by the user**. If still active, an open end with a "running" indicator.
- Cost is the cost of the main-thread turns between setting the goal and its end. The evaluator's own small-model calls are included only if they appear in the transcript (unknown, see Open items).

### Test runs lane
- One bar per test run, split into passed and failed, scaled to that run's total. Header shows the last run as "234 / 234 (100%)".
- 100% is not expected on every run. A TDD session should show red runs first and end green. The lane's job is to show the trend and the final state, and to flag a session that ends red.
- Detection is best-effort: it reads the output of Bash tool calls and recognises a small set of runner summaries (start with `swift test`/XCTest; add `pytest`, `jest`/`vitest`, `go test`, `cargo test`). Unrecognised output is ignored, never guessed at.

### Plugins and skills lane
- A single stacked bar of cost by plugin over the session, with the top few named and the rest as "other". Uses the existing `attributionPlugin` and `attributionSkill` fields. Clicking a segment opens the existing plugin or skill drill-down.

### Sub-agents lane (added after approval, at the user's request)
- One horizontal bar per sub-agent run, from its first to its last row, positioned on the shared time axis. Parallel runs stack into separate rows. Bar label is the spawn's `description`, with `subagent_type` in the hover card.
- Header: run count and total sub-agent cost. Hover: description, type, duration, calls, tokens, cost.
- A run is grouped by the `agentId` carried on its sidechain rows and linked to its spawn through the parent `Agent` tool_use (see Facts).
- In the overlay, runs draw as thin translucent bars along the bottom edge of the main chart.
- Sub-agent spend that happens inside a loop iteration or goal already counts toward that iteration's cost; the lane shows it separately as well.

## Things I added beyond the request (my calls)
- Distinguish a loop's fallback wake-up (about 20 minutes after an iteration that neither rescheduled nor stopped) from a deliberate one.
- Cost trend across loop iterations (are later iterations costlier as context grows?) shown as the band height itself, so no extra widget.
- Test lane flags "ended red".
- Goal lane shows why it ended, not just that it did.

## Goals
- Every iteration, goal end and test result a user can see in a transcript is visible and correctly costed.
- Lanes share the main chart's zoom, pan and hover behaviour.
- Zero extra clutter for sessions that use none of these features.

## Non-goals
- No control actions (stopping a loop, clearing a goal) from the app in this project.
- No cross-session aggregate view of loops or goals.
- No live status-line or hook integration (that belongs to the advisor project).

## Anti-goals
- Never show a number the transcript doesn't support. If goal outcome or test counts can't be read, show nothing rather than an estimate presented as fact.
- Don't slow the window down (see the performance project): lanes must draw from precomputed data, not recompute per frame.

## Constraints
- Native SwiftUI app; parsing in `UsageCore`, drawing in `ClaudeUsageWidget`. Existing patterns: `SessionEvent` and `TranscriptParser.parseEvent` for rows, `Timeline`/`TimelineGeometry` for layout, `TimelineHover` for hover, snapshot mode for rendering checks.
- Test-driven, as the rest of the codebase is. Fixtures come from real transcript rows where possible.
- Prompt text stays in memory only and is truncated, as today.
- Tool inputs are not currently kept by the parser; reading `ScheduleWakeup` inputs and Bash tool results means extending it, and must keep the byte-prefilter approach so parsing stays fast.

## Facts established
- A real `/loop` run exists in `casualchaosv1/d86c4d96-....jsonl`: the `/loop` command row, `ScheduleWakeup` tool_use rows (with `delaySeconds`, `prompt`, `noop`), the wake-up arriving as a user row carrying the loop prompt, and a final `ScheduleWakeup {stop: true}`.
- Per the Claude Code docs: `/goal` is judged after each turn by a small fast model; ends as met, impossible, stalled or cleared; "achieved" and "failed" entries are written to the transcript. The docs do not document the row format and say the transcript format is internal and may change.
- No `/goal` run exists in any local transcript.
- Refinements found while planning, from the same real `/loop` run:
  - A wake-up is marked by a `system` row with `subtype: "scheduled_task_fire"`, `taskKind: "loop"`, `taskId`, `cron`, `prompt`. It is followed by a `<command-name>/loop` user row and the skill-expansion row (`isMeta: true`).
  - `ScheduleWakeup` input is `{delaySeconds, noop, prompt, reason}`; its `tool_result` row carries `toolUseResult: {scheduledFor (epoch ms), clampedDelaySeconds, wasClamped}`. Stop is `{stop: true}`.
  - A loop can be started by Claude calling the `Skill` tool with `skill: "loop"` as well as by a `<command-name>/loop` row.
- Sub-agents: spawned by an assistant `tool_use` named `Agent` with input `{subagent_type, description, prompt}`. Their rows live in `<session>/subagents/agent-<id>.jsonl` with `isSidechain: true` and an `agentId`; they also carry the same attribution fields as main-thread rows.

## Open items for the builder
- **`/goal` row format is unknown.** Build the goal lane against a captured real `/goal` run. First task of the plan: run a short `/goal` in a throwaway session and capture the rows. Until then the lane is behind a feature flag.
- Whether goal evaluator calls appear as billed rows. Decide after the capture.
- Exact `ScheduleWakeup` and cron-tool input schemas: take from real rows.
- Layout details (lane heights, colours, icon art, how many lanes can be shown in the maximized window) are left to the builder following the existing theme and the approved mockup (`.superpowers/brainstorm/*/content/feature-lanes.html`).

- Found while building and reviewing (real data): a sub-agent run is linked to its spawn by the `Agent` call's tool result (`toolUseResult.agentId`), because a sub-agent row's `wireToolInputs` key is the spawn id only for forks. A command counts as a test run only when a shell segment starts with a known runner, since commit messages and installs mention runner names. vitest prints `Tests  7 passed (7)`.

## Decisions made after the builder check (author's calls, marked for review)
1. **Delivery order.** `/loop`, test runs and plugins ship first and independently. The `/goal` lane is a separable milestone: it ships when a real `/goal` capture exists and its end reasons are readable. If the capture is unparseable, the project is still done without it, and the goal lane stays hidden.
2. **Iteration cost.** An iteration is every billed row, main thread and sub-agents, from the wake-up row to the next wake-up, loop stop, or user-typed prompt, whichever comes first. The first iteration starts at the `/loop` command. User-typed prompts end an iteration and are not attributed to the loop. Uses the existing duplicate-row handling.
3. **Cron loops.** First cut covers `ScheduleWakeup` (self-paced) loops only. Fixed-interval loops follow once a real cron fixture is captured. Cron jobs that are not from `/loop` get no lane.
4. **Fallback wake-up.** Identified structurally, not by a time window: a `scheduled_task_fire` row whose preceding iteration contained no `ScheduleWakeup` call. If that cannot be shown from the rows, no fallback icon is drawn. (Amended after approval: wake-ups themselves are now identified by the `scheduled_task_fire` row, not inferred.)
5. **Test counting.** Pair the Bash `tool_use` with its `tool_result` by id and require a known runner command. Use the final total line, not per-suite lines. Skipped tests are shown separately and are not in the denominator. Truncated results are ignored.
6. **Ended red.** If the last test command was a known runner but its output has no readable summary (for example a build failure), the lane shows "last run unreadable", never green.
7. **Plugins lane.** One session-total stacked bar, not time-bucketed, so it does not pan or zoom. Rows with no attribution are folded into "other".
8. **Persistence.** The overlay toggle and per-lane checkboxes persist app-wide as a setting.

## Approval
Approved by the user on 2026-10-26. Implemented on branch `feature/feature-lanes`; the `/goal` lane (plan Task 14) is deferred until a real `/goal` run is captured.
