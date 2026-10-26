#!/usr/bin/env python3
"""Builds a synthetic home directory so KAIkei can be screenshotted without exposing real sessions.

    scripts/make_demo_home.py OUT_DIR PID1,PID2,PID3

Also writes one finished /loop session (OUT_DIR/lanes-session-id holds its id) so the feature lanes have data.
Writes OUT_DIR/.claude.json, OUT_DIR/.claude/projects/**.jsonl (30 days of invented history) and
OUT_DIR/.claude/sessions/<pid>.json for three "open" sessions. KAIkei treats a session as open only while its
process exists, so pass the pids of three long-running processes (scripts/screenshots.sh starts `sleep`s for this).

Everything is seeded, so repeated runs give the same picture (shifted to "now").
"""
import json
import os
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone

HOME = sys.argv[1]
PIDS = [int(p) for p in sys.argv[2].split(",")]
NOW = datetime.now(timezone.utc).replace(microsecond=0)
rng = random.Random(55)

PROJECTS = {
    "payments-api": {"w": 4, "skills": [("superpowers:test-driven-development", "superpowers"), ("superpowers:systematic-debugging", "superpowers")]},
    "web-dashboard": {"w": 3, "skills": [("frontend-design", "frontend-design"), ("superpowers:brainstorming", "superpowers")]},
    "infra-terraform": {"w": 2, "skills": [("engineering:deploy-checklist", "engineering")]},
    "docs-site": {"w": 1, "skills": [("engineering:documentation", "engineering")]},
}
TOOLS = ["Bash", "Read", "Edit", "Grep", "Write", "Glob", "Task", "WebFetch"]
PROMPTS = [
    "Add retry with exponential backoff to the charge client and cover it with tests",
    "Why does the nightly settlement job double-count refunds? Trace it through the ledger code",
    "Rework the usage table so it paginates and keeps the filter in the URL",
    "Split the monolithic module into network and compute, keep state addresses stable",
    "Write the migration guide for v2 of the public API",
    "The flaky checkout test fails one run in ten. Find out why",
    "Replace the hand-rolled date picker with the design-system one",
    "Review the diff on this branch and list anything risky",
    "Make the build faster. Profile first, then change things",
    "Explain how the webhook signature check works and where it could be bypassed",
]


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def rid(prefix):
    return f"{prefix}_{rng.getrandbits(64):016x}"


def session_rows(sid, cwd, start, n_calls, plan, skills, compact_at=None, idle_after=None, end_gap=None):
    """One conversation: a prompt, then a burst of billed calls whose context grows, repeated.

    plan: list of (call_index_from, model) switches. compact_at: call index where an auto compaction happens.
    idle_after: (call_index, minutes) pauses the session long enough for the prompt cache to expire.
    """
    rows, t, ctx = [], start, 18_000
    model = plan[0][1]
    prompt_every = rng.randint(4, 7)
    for i in range(n_calls):
        for frm, m in plan:
            if i >= frm:
                model = m
        if i % prompt_every == 0:
            rows.append({"type": "user", "sessionId": sid, "uuid": str(uuid.UUID(int=rng.getrandbits(128))), "timestamp": iso(t),
                         "cwd": cwd, "isSidechain": False, "message": {"role": "user", "content": rng.choice(PROMPTS)}})
            t += timedelta(seconds=rng.randint(1, 3))
        if idle_after and i == idle_after[0]:
            t += timedelta(minutes=idle_after[1])
        if compact_at is not None and i == compact_at:
            rows.append({"type": "system", "subtype": "compact_boundary", "sessionId": sid, "uuid": str(uuid.UUID(int=rng.getrandbits(128))),
                         "timestamp": iso(t), "cwd": cwd, "compactMetadata": {"trigger": "auto", "preTokens": ctx, "postTokens": 21_500, "durationMs": 38_000}})
            t += timedelta(seconds=40)
            ctx = 21_500
        gap = t - rows_last_assistant_time(rows)
        cold = gap > timedelta(minutes=60)
        new = rng.randint(900, 5200)
        read = 0 if cold else ctx
        write = (ctx + new) if cold else new
        ctx += new
        out = rng.randint(180, 2400)
        thinking = rng.randint(300, 1800) if "opus" in model and rng.random() < 0.5 else 0
        tool = rng.choice(TOOLS)
        skill, plugin = rng.choice(skills) if rng.random() < 0.35 else (None, None)
        row = {
            "type": "assistant", "sessionId": sid, "uuid": str(uuid.UUID(int=rng.getrandbits(128))), "timestamp": iso(t), "cwd": cwd,
            "isSidechain": False,
            "message": {
                "id": rid("msg"), "model": model, "role": "assistant",
                "content": [{"type": "tool_use", "id": rid("toolu"), "name": tool}],
                "usage": {
                    "input_tokens": rng.randint(3, 40), "output_tokens": out + thinking,
                    "cache_creation_input_tokens": write, "cache_read_input_tokens": read,
                    "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": write},
                    "output_tokens_details": {"thinking_tokens": thinking},
                },
            },
        }
        if skill:
            row["attributionSkill"], row["attributionPlugin"] = skill, plugin
        rows.append(row)
        t += timedelta(seconds=rng.randint(8, 70))
    return rows, t


def rows_last_assistant_time(rows):
    for r in reversed(rows):
        if r["type"] == "assistant":
            return datetime.strptime(r["timestamp"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
    return datetime.min.replace(tzinfo=timezone.utc)


def write_session(rows, project_cwd, sid):
    d = os.path.join(HOME, ".claude", "projects", project_cwd.replace("/", "-"))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"{sid}.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")


def own_rng(fn):
    """Runs `fn` with a separate seeded generator in place of the shared one."""
    global rng
    saved, rng = rng, random.Random(901)
    try:
        return fn()
    finally:
        rng = saved


def loop_session():
    """A finished, self-paced /loop over the payments tests: five iterations, one sub-agent, and a test run in each.

    Written as the rows Claude Code writes (wake-up fire rows, ScheduleWakeup calls and results, an Agent launch result,
    sidechain rows with an agentId, pytest summaries), so the feature lanes have something to draw. Returns the session id.
    """
    name, cwd = "payments-api", "/Users/ana/work/payments-api"
    sid = str(uuid.UUID(int=rng.getrandbits(128)))
    model, ctx = "claude-sonnet-5-5", 24_000
    rows = []
    skill = ("superpowers:test-driven-development", "superpowers")

    def uid():
        return str(uuid.UUID(int=rng.getrandbits(128)))

    def user(t, content, **extra):
        r = {"type": "user", "sessionId": sid, "uuid": uid(), "timestamp": iso(t), "cwd": cwd, "isSidechain": False,
             "message": {"role": "user", "content": content}}
        r.update(extra)
        rows.append(r)

    def call(t, blocks, sidechain=False, agent=None, attributed=False):
        nonlocal ctx
        new = rng.randint(1_200, 4_500)
        ctx += 0 if sidechain else new
        read = rng.randint(8_000, 20_000) if sidechain else ctx - new
        r = {"type": "assistant", "sessionId": sid, "uuid": uid(), "timestamp": iso(t), "cwd": cwd, "isSidechain": sidechain,
             "message": {"id": rid("msg"), "model": model, "role": "assistant", "content": blocks,
                         "usage": {"input_tokens": rng.randint(3, 30), "output_tokens": rng.randint(300, 1_600),
                                   "cache_creation_input_tokens": new, "cache_read_input_tokens": read,
                                   "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": new},
                                   "output_tokens_details": {"thinking_tokens": 0}}}}
        if agent:
            r["agentId"] = agent
        if attributed and not sidechain:
            r["attributionSkill"], r["attributionPlugin"] = skill
        rows.append(r)

    def tool(name_, inp):
        return {"type": "tool_use", "id": rid("toolu"), "name": name_, "input": inp}

    def tool_result(t, block, content, **extra):
        r = {"type": "user", "sessionId": sid, "uuid": uid(), "timestamp": iso(t), "cwd": cwd, "isSidechain": False,
             "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": block["id"], "content": content}]}}
        r.update(extra)
        rows.append(r)

    args = "Keep iterating on the retry tests until they are all green, one fix per iteration"
    t0 = NOW - timedelta(minutes=215)
    user(t0, args)
    start_call = tool("Skill", {"skill": "loop", "args": args})
    call(t0 + timedelta(seconds=6), [start_call])

    summaries = ["3 failed, 9 passed", "1 failed, 11 passed", "1 failed, 12 passed", "13 passed", "13 passed"]
    waits = [20, 25, 15, 20]
    t = t0 + timedelta(seconds=30)
    agent_id = f"a{rng.getrandbits(64):016x}"
    for i in range(5):
        if i > 0:  # the harness wakes Claude, then types the /loop prompt
            rows.append({"type": "system", "subtype": "scheduled_task_fire", "sessionId": sid, "uuid": uid(), "timestamp": iso(t),
                         "isSidechain": False, "taskId": f"{rng.getrandbits(32):08x}", "cron": f"{t.minute} {t.hour} * * *",
                         "prompt": "/loop " + args, "taskKind": "loop", "cronKind": "loop", "cwd": cwd})
            t += timedelta(milliseconds=9)
            user(t, f"<command-message>loop</command-message> <command-name>/loop</command-name> <command-args>{args}</command-args>")
        for k in range(rng.randint(4, 6)):
            blocks = [tool(rng.choice(["Read", "Edit", "Grep", "Edit"]), {})]
            call(t, blocks, attributed=rng.random() < 0.4)
            t += timedelta(seconds=rng.randint(15, 45))
            if k == 1 and i == 1:  # a sub-agent reviews edge cases while the loop carries on
                spawn = tool("Agent", {"subagent_type": "general-purpose", "description": "Review backoff edge cases", "prompt": "..."})
                call(t, [spawn])
                tool_result(t + timedelta(seconds=1), spawn, "Async agent launched",
                            toolUseResult={"isAsync": True, "status": "async_launched", "agentId": agent_id, "description": "Review backoff edge cases"})
                at = t + timedelta(seconds=4)
                for _ in range(6):
                    call(at, [tool("Read", {})], sidechain=True, agent=agent_id)
                    at += timedelta(seconds=rng.randint(20, 40))
            if k == 2:  # run the tests
                run = tool("Bash", {"command": f'cd "{cwd}" && pytest -q'})
                call(t, [run])
                tool_result(t + timedelta(seconds=12), run, f"...\n======= {summaries[i]} in 0.52s =======")
                t += timedelta(seconds=rng.randint(20, 40))
        if i < 4:
            delay = waits[i] * 60
            sched = tool("ScheduleWakeup", {"delaySeconds": delay, "noop": False, "prompt": "/loop " + args, "reason": "Re-run the tests after the next fix"})
            call(t, [sched])
            due = t + timedelta(seconds=delay)
            tool_result(t + timedelta(seconds=1), sched, "Next wakeup scheduled",
                        toolUseResult={"scheduledFor": int(due.timestamp() * 1000), "clampedDelaySeconds": delay, "wasClamped": False})
            t = due + timedelta(seconds=rng.randint(4, 20))
        else:
            stop = tool("ScheduleWakeup", {"stop": True})
            call(t, [stop])
            tool_result(t + timedelta(seconds=1), stop, "Loop stopped")
    write_session(rows, cwd, sid)
    with open(os.path.join(HOME, "lanes-session-id"), "w") as f:
        f.write(sid)
    return sid


def main():
    os.makedirs(os.path.join(HOME, ".claude", "sessions"), exist_ok=True)
    names = list(PROJECTS)
    weights = [PROJECTS[n]["w"] for n in names]

    # Thirty days of history. Weekdays are busy; the weekend is quiet. The last day is left to the open sessions.
    for days_ago in range(30, 0, -1):
        day = (NOW - timedelta(days=days_ago)).replace(hour=0, minute=0, second=0)
        weekend = day.weekday() >= 5
        for _ in range(rng.randint(0, 1) if weekend else rng.randint(2, 4)):
            name = rng.choices(names, weights)[0]
            cwd = f"/Users/ana/work/{name}"
            start = day + timedelta(hours=rng.choice([8, 9, 9, 10, 11, 13, 14, 15, 16, 20]), minutes=rng.randint(0, 59))
            heavy = rng.random() < 0.3
            plan = [(0, "claude-opus-5-5")] if heavy else [(0, "claude-sonnet-5-5")]
            if rng.random() < 0.25:
                plan.append((rng.randint(8, 20), "claude-haiku-5-5"))
            n = rng.randint(30, 90) if heavy else rng.randint(12, 45)
            sid = str(uuid.UUID(int=rng.getrandbits(128)))
            rows, _ = session_rows(sid, cwd, start, n, plan, PROJECTS[name]["skills"], compact_at=rng.randint(40, 70) if n > 75 else None)
            write_session(rows, cwd, sid)

    # The loop session draws from its own generator, so adding it neither changes the other sessions' numbers nor repeats
    # their ids (restoring the shared generator's state would hand the next session the same session id and overwrite this one).
    own_rng(loop_session)

    # Three open sessions, each tied to a live pid.
    live = [
        # (project, name, started_min_ago, calls, plan, compact_at, idle, status)
        ("payments-api", "Retry logic for the charge client", 205, 78, [(0, "claude-opus-5-5"), (46, "claude-sonnet-5-5")], 40, (24, 75), "busy"),
        ("web-dashboard", "Paginate the usage table", 52, 30, [(0, "claude-sonnet-5-5")], None, None, "idle"),
        ("infra-terraform", "Split network and compute modules", 21, 14, [(0, "claude-sonnet-5-5"), (9, "claude-haiku-5-5")], None, None, "idle"),
    ]
    for pid, (name, title, ago, n, plan, compact_at, idle, status) in zip(PIDS, live):
        cwd = f"/Users/ana/work/{name}"
        sid = str(uuid.UUID(int=rng.getrandbits(128)))
        start = NOW - timedelta(minutes=ago)
        rows, end = session_rows(sid, cwd, start, n, plan, PROJECTS[name]["skills"], compact_at=compact_at, idle_after=idle)
        # Squeeze the generated activity so the last call lands about a minute ago, whatever the random gaps added up to.
        span_in = (end - start).total_seconds()
        span_out = (NOW - timedelta(seconds=70) - start).total_seconds()
        for r in rows:
            at = datetime.strptime(r["timestamp"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
            r["timestamp"] = iso(start + (at - start) * (span_out / span_in))
        write_session(rows, cwd, sid)
        with open(os.path.join(HOME, ".claude", "sessions", f"{pid}.json"), "w") as f:
            json.dump({"pid": pid, "sessionId": sid, "cwd": cwd, "name": title, "entrypoint": "cli", "status": status,
                       "startedAt": int(start.timestamp() * 1000), "updatedAt": int((NOW - timedelta(seconds=70)).timestamp() * 1000),
                       "version": "2.1.0"}, f)

    acct = str(uuid.UUID(int=rng.getrandbits(128)))
    with open(os.path.join(HOME, ".claude.json"), "w") as f:
        json.dump({
            "oauthAccount": {"accountUuid": acct, "emailAddress": "ana@acme.example", "displayName": "Ana", "organizationName": "Acme Corp",
                             "organizationType": "claude_enterprise", "seatTier": "enterprise_usage_based"},
            "cachedUsageUtilization": {
                "fetchedAtMs": int((NOW - timedelta(minutes=3)).timestamp() * 1000), "accountUuid": acct,
                "utilization": {
                    "five_hour": None,
                    "seven_day": {"utilization": 38.0, "resets_at": iso(NOW + timedelta(days=3))},
                    "extra_usage": {"is_enabled": True, "monthly_limit": 50000, "used_credits": 14260, "utilization": 28.52,
                                    "currency": "USD", "decimal_places": 2},
                },
            },
        }, f)


main()
