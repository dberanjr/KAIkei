# KAIkei: terminal advisor (design)

Date: 2026-10-26. Status: approved by instruction ("move forward with implementation"). Part 3 of 3 (feature lanes and timeline polish shipped as v0.2.0 and v0.2.1).

## Intent

Mid-session, with no time to think about context size, cache or model, the user wants one short, opinionated line in the terminal they are working in: compact, clear, or change model. It must also be glanceable (status line) and must stay quiet when there is nothing worth saying.

## What the user gets

- **A prompt hook** (`UserPromptSubmit`). When the user submits a prompt, a one-line message appears in the terminal, shown to the user only (never added to Claude's context). Silent when the advice is "carry on".
- **A status line segment.** Always-on and short: context percent, cache state, session cost, and the current advice in a few words. It wraps the status line command already configured (the Claude Console handler), so that keeps working.
- **Model suggestions in both**, up and down:
  - Down only when the stronger model is overkill: the prompt reads as light work *and* the last turns in the session were light *and* the project is not usually heavy. Never because a model is merely cheaper.
  - Up when the work is hard: a hard-looking prompt together with evidence from the session (recent heavy turns) or the project, or a very hard prompt on a small model.
  - The ladder is Haiku, Sonnet, Opus, Fable. One step at a time.
  - Switching model drops the prompt cache, so the line says what the switch costs once and, for a downshift, how soon it pays back. A downshift that would not pay back soon is suggested after a compact or clear, or not at all.
  - A model the user changed in the last few responses is left alone.

## Goals / non-goals / anti-goals

- Goals: short (one line, about 110 characters), opinionated, quiet, fast (the hook must not stall typing), explainable (`kaikei-advise explain`).
- Non-goals: blocking a prompt; changing the model for the user; sending any data off the machine; app UI changes (the app's suggestions bar stays compact/clear only for now).
- Anti-goals: nagging (the hook does not repeat the same advice for the next three prompts unless it got more urgent); advising on a guess (every dollar figure is a list-price estimate and says "about"); a model downshift on cost alone.

## Design (my calls)

- `UsageCore` gains the pure logic: `ModelTier`, `PromptClassifier` (light/heavy cues in the prompt text), `TurnWeight` (light/medium/heavy from tools, output tokens, thinking tokens, duration), `ProjectProfile` (share of heavy and light turns in the project's recent sessions), `PromptAdvisor` (combines `CompactAdvisor`, the above, and the cache cost of switching), and `StatusLineText`.
- A new executable target `kaikei-advise` (UsageCore only, no UI, fast start) with subcommands `prompt` (the hook), `statusline [--then CMD]`, `explain`. It is installed to `~/.kaikei/bin/kaikei-advise`, a stable path that does not move when the app is rebuilt.
- `scripts/install_advisor.py` merges the hook and status line into `~/.claude/settings.json` (backup first, idempotent, keeps every existing hook, wraps the existing status line command) and `--uninstall` reverses it.
- Project profile: the heavy/light share over the most recent turns of the project's other recent transcripts (same project folder), cached in `~/.kaikei/cache` keyed by file size and modification time, under a time budget.
- Heuristics, not machine learning: thresholds live in one place and are covered by tests. They are starting values and will want tuning from real use.

## Deferred

- Showing model suggestions in the app's suggestions bar and card.
- A per-user config file for thresholds.
