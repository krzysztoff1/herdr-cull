#!/usr/bin/env python3
"""herdr-cull — review and close idle agent panes.

herdr tracks an agent's *status* (idle/working) but not *when* it last did
anything, so staleness is measured from the mtime of the agent's session
transcript — Claude and Codex append to it on every turn. Panes whose agent is
still working are never offered. The review step is an fzf multi-select: you mark
what to close and confirm; nothing is closed otherwise.

Config (first match wins):
  * env HERDR_CULL_IDLE_HOURS
  * `idle_hours` in <plugin-config-dir>/config.toml
  * default: 4

Debug envs: CULL_LIST_ONLY=1 (print candidates, don't prompt),
CULL_DRY_RUN=1 (go through selection but don't actually close).
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import time

HERDR = (os.environ.get("HERDR_BIN_PATH") or os.environ.get("HERDR_BIN")
         or shutil.which("herdr") or "/opt/homebrew/bin/herdr")
DEFAULT_HOURS = 4.0
LIST_ONLY = os.environ.get("CULL_LIST_ONLY") == "1"
DRY_RUN = os.environ.get("CULL_DRY_RUN") == "1"


def idle_hours():
    env = os.environ.get("HERDR_CULL_IDLE_HOURS")
    if env:
        try:
            return float(env)
        except ValueError:
            pass
    cfg_dir = os.environ.get("HERDR_PLUGIN_CONFIG_DIR")
    if cfg_dir:
        path = os.path.join(cfg_dir, "config.toml")
        if os.path.isfile(path):
            try:
                import tomllib
                with open(path, "rb") as fh:
                    val = tomllib.load(fh).get("idle_hours")
                if isinstance(val, (int, float)):
                    return float(val)
            except Exception:
                pass
    return DEFAULT_HOURS


def herdr_json(*args):
    try:
        r = subprocess.run([HERDR, *args], capture_output=True, text=True, timeout=8)
        return json.loads(r.stdout)
    except Exception:
        return None


def session_mtime(agent, value):
    """Newest mtime of the agent session transcript, or None if not found."""
    if not value:
        return None
    home = os.path.expanduser("~")
    patterns = []
    if agent != "codex":
        patterns.append(f"{home}/.claude/projects/*/{value}.jsonl")
    if agent != "claude":
        patterns.append(f"{home}/.codex/sessions/**/*{value}*.jsonl")
    best = None
    for pat in patterns:
        for match in glob.glob(pat, recursive=True):
            try:
                mt = os.path.getmtime(match)
            except OSError:
                continue
            best = mt if best is None else max(best, mt)
    return best


def shorten(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path and path.startswith(home) else (path or "")


def gather(threshold, now):
    agents = (herdr_json("agent", "list") or {}).get("result", {}).get("agents", [])
    panes = (herdr_json("pane", "list") or {}).get("result", {}).get("panes", [])
    tab_counts = {}
    for p in panes:
        tid = p.get("tab_id")
        if tid:
            tab_counts[tid] = tab_counts.get(tid, 0) + 1

    candidates, unknown = [], 0
    for a in agents:
        if not a.get("agent") or a.get("agent_status") == "working":
            continue
        value = (a.get("agent_session") or {}).get("value")
        mt = session_mtime(a.get("agent"), value)
        if mt is None:
            unknown += 1
            continue
        age = (now - mt) / 3600.0
        if age < threshold:
            continue
        candidates.append({
            "pane_id": a.get("pane_id"),
            "tab_id": a.get("tab_id"),
            "agent": a.get("agent"),
            "status": a.get("agent_status") or "?",
            "title": (a.get("terminal_title_stripped") or "(no title)").strip(),
            "cwd": shorten(a.get("foreground_cwd") or a.get("cwd")),
            "age": age,
        })
    candidates.sort(key=lambda c: c["age"], reverse=True)
    return candidates, tab_counts, unknown


def plan(selected, tab_counts):
    """Close the whole tab when the agent is its only pane, else just the pane."""
    seen, actions = set(), []
    for c in selected:
        tid, pid = c["tab_id"], c["pane_id"]
        if tab_counts.get(tid, 99) <= 1:
            if tid not in seen:
                seen.add(tid)
                actions.append(("tab", tid, c))
        else:
            actions.append(("pane", pid, c))
    return actions


def pause(msg="\nPress any key to close…"):
    sys.stdout.write(msg)
    sys.stdout.flush()
    try:
        with open("/dev/tty") as tty:
            subprocess.run(["stty", "-icanon", "-echo"], stdin=tty, check=False)
            tty.read(1)
            subprocess.run(["stty", "icanon", "echo"], stdin=tty, check=False)
    except Exception:
        time.sleep(2)


def color_age(age, threshold):
    if age >= 2 * threshold:
        code = "\033[91m"   # red — very stale
    elif age >= threshold:
        code = "\033[93m"   # yellow — stale
    else:
        code = ""
    return f"{code}{age:5.1f}h idle\033[0m"


def select(candidates, threshold):
    """Return the chosen candidates, or None to cancel."""
    fzf = shutil.which("fzf")
    if fzf:
        rows = []
        for c in candidates:
            disp = (f"{color_age(c['age'], threshold)}  │  {c['title'][:44]:<44}"
                    f"  │  {c['agent']:<6}  │  {c['cwd']}")
            rows.append(f"{c['pane_id']}\t{c['tab_id']}\t{disp}")
        header = (f"Agent panes idle ≥ {threshold:g}h — review before closing\n"
                  "Tab mark · Ctrl-A all · Enter close marked · Esc cancel")
        proc = subprocess.run(
            [fzf, "--multi", "--ansi", "--delimiter", "\t", "--with-nth", "3..",
             "--layout=reverse", "--height=100%", "--border", "--marker=✗ ",
             "--pointer=▶", "--prompt", "close ▸ ", "--header", header,
             "--header-first", "--bind", "ctrl-a:toggle-all"],
            input="\n".join(rows), capture_output=True, text=True)
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        chosen = {ln.split("\t", 1)[0] for ln in proc.stdout.splitlines() if ln.strip()}
        return [c for c in candidates if c["pane_id"] in chosen]

    # Fallback: per-item y/N prompt (fzf not installed).
    try:
        tty = open("/dev/tty")
    except Exception:
        return None
    print(f"fzf not found — per-pane prompt (agent panes idle ≥ {threshold:g}h):\n")
    chosen = []
    for c in candidates:
        sys.stdout.write(f"Close [{c['age']:.1f}h] {c['title']} "
                         f"({c['agent']}, {c['cwd']})? [y/N] ")
        sys.stdout.flush()
        if tty.readline().strip().lower() == "y":
            chosen.append(c)
    return chosen or None


def main():
    threshold = idle_hours()
    now = time.time()
    candidates, tab_counts, unknown = gather(threshold, now)

    if LIST_ONLY:
        print(f"threshold={threshold:g}h  candidates={len(candidates)}  unknown_age={unknown}")
        for c in candidates:
            kind, ident, _ = plan([c], tab_counts)[0]
            print(f"  {c['age']:6.2f}h  {c['status']:<7} {c['agent']:<6} {c['pane_id']} "
                  f"tab={c['tab_id']} → close {kind} {ident}  | {c['title']}")
        return

    if not candidates:
        extra = f" ({unknown} had no readable session file)" if unknown else ""
        print(f"✓ No agent panes idle ≥ {threshold:g}h.{extra}")
        pause()
        return

    selected = select(candidates, threshold)
    if not selected:
        print("Cancelled — nothing closed.")
        pause()
        return

    actions = plan(selected, tab_counts)
    closed = 0
    for kind, ident, c in actions:
        if DRY_RUN:
            print(f"[dry-run] would close {kind} {ident}  ({c['age']:.1f}h  {c['title']})")
            continue
        r = subprocess.run([HERDR, kind, "close", ident], capture_output=True, text=True)
        ok = r.returncode == 0
        closed += 1 if ok else 0
        print(f"{'✓' if ok else '✗'} closed {kind} {ident}  ({c['age']:.1f}h  {c['title']})")
    if not DRY_RUN:
        print(f"\nClosed {closed}/{len(actions)}.")
    pause()


if __name__ == "__main__":
    main()
