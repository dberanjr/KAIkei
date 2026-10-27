#!/usr/bin/env python3 -I
"""Wires kaikei-advise into Claude Code's settings.json: a UserPromptSubmit hook and a status line.

    install_advisor.py [--settings PATH] [--bin PATH] [--uninstall] [--dry-run]

Safe to run twice. Keeps every other hook and setting; backs the file up before the first change; wraps the status line
command that was already there (so it keeps working) and restores it on --uninstall.
"""
import argparse, json, os, shlex, shutil, sys, time

MARK = "kaikei-advise"
HOOK_TIMEOUT = 5


def is_ours(command):
    return isinstance(command, str) and MARK in command


def our_hook(binary):
    return {"hooks": [{"type": "command", "command": f"{shlex.quote(binary)} prompt", "timeout": HOOK_TIMEOUT}]}


def install(settings, binary):
    """Returns (new_settings, notes)."""
    out = json.loads(json.dumps(settings))
    notes = []
    groups = out.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
    if any(is_ours(h.get("command")) for g in groups for h in g.get("hooks", [])):
        notes.append("prompt hook: already installed")
    else:
        groups.append(our_hook(binary))
        notes.append("prompt hook: added (UserPromptSubmit)")

    status = out.get("statusLine")
    if isinstance(status, dict) and is_ours(status.get("command")):
        notes.append("status line: already installed")
    else:
        command = f"{shlex.quote(binary)} statusline"
        if isinstance(status, dict) and status.get("type") == "command" and status.get("command"):
            command += f" --then {shlex.quote(status['command'])}"
            notes.append("status line: wrapped your existing command (it still runs, and shows first)")
        else:
            notes.append("status line: added")
        new = dict(status) if isinstance(status, dict) else {}
        new.update({"type": "command", "command": command})
        out["statusLine"] = new
    return out, notes


def uninstall(settings):
    out = json.loads(json.dumps(settings))
    notes = []
    hooks = out.get("hooks", {})
    groups = hooks.get("UserPromptSubmit", [])
    kept = []
    for g in groups:
        g = dict(g)
        g["hooks"] = [h for h in g.get("hooks", []) if not is_ours(h.get("command"))]
        if g["hooks"]:
            kept.append(g)
    if len(kept) != len(groups) or any(is_ours(h.get("command")) for g in groups for h in g.get("hooks", [])):
        notes.append("prompt hook: removed")
    if kept:
        hooks["UserPromptSubmit"] = kept
    else:
        hooks.pop("UserPromptSubmit", None)
    if not hooks:
        out.pop("hooks", None)

    status = out.get("statusLine")
    if isinstance(status, dict) and is_ours(status.get("command")):
        words = shlex.split(status["command"])
        if "--then" in words and words.index("--then") + 1 < len(words):
            status["command"] = words[words.index("--then") + 1]
            notes.append("status line: restored your original command")
        else:
            out.pop("statusLine")
            notes.append("status line: removed")
    return out, notes


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    ap.add_argument("--bin", default=os.path.expanduser("~/.kaikei/bin/kaikei-advise"))
    ap.add_argument("--uninstall", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    try:
        with open(args.settings) as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    new, notes = uninstall(settings) if args.uninstall else install(settings, args.bin)
    for n in notes:
        print(n)
    if new == settings:
        print("settings.json unchanged")
        return 0
    if args.dry_run:
        print("(dry run: nothing written)")
        return 0
    if os.path.exists(args.settings):
        backup = f"{args.settings}.kaikei-backup-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(args.settings, backup)
        print(f"backup: {backup}")
    tmp = args.settings + ".kaikei-tmp"
    with open(tmp, "w") as f:
        json.dump(new, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.path.exists(args.settings):
        shutil.copymode(args.settings, tmp)
    os.replace(tmp, args.settings)
    print(f"updated: {args.settings}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
