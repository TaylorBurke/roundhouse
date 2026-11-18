#!/usr/bin/python3 -I
"""Install or remove roundhouse's three small pieces of setup, showing every change first.

  setup.py install   [--dry-run] [--yes] [--with-hyprland | --skip-hyprland]
  setup.py uninstall [--dry-run] [--yes]
  setup.py status

What it touches (nothing else):
  1. the Claude Code settings.json: one async command hook per event, all pointing at hooks/emit.py
  2. a symlink ~/.local/bin/roundhouse -> bin/roundhouse
  3. (asked separately, default no) one `dofile(...)  -- roundhouse` line in the Hyprland config

Each change is printed (as a diff) and confirmed, and each file is backed up first. --dry-run
prints everything and writes nothing. --yes answers the questions for you, except the Hyprland
one, which needs --with-hyprland. Without a terminal and without --yes it refuses to change anything.
Uninstall also stops the window service and removes the log folder.
"""
import argparse
import difflib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The events the emitter understands. A test checks this against hooks/emit.py.
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "PostToolBatch", "PermissionRequest", "PermissionDenied", "SubagentStart", "SubagentStop",
          "Stop", "StopFailure", "PreCompact", "PostCompact", "PostModelSwitch", "Notification", "SessionEnd"]
MARK = "-- roundhouse"


class Refuse(Exception):
    """Something is not as expected; nothing is changed."""


# ---- settings.json ---------------------------------------------------------------------


def emitter():
    return os.path.join(ROOT, "hooks", "emit.py")


def is_ours(command, emit):
    if not isinstance(command, str):
        return False
    if command == emit:
        return True
    # the same file reached by another path (a symlinked folder); a command with arguments is never ours
    return " " not in command.strip() and os.path.realpath(command) == os.path.realpath(emit)


def hooks_of(settings):
    hooks = settings.get("hooks", {})
    if not isinstance(hooks, dict):
        raise Refuse('"hooks" in settings.json is not an object; leaving it alone')
    for event, groups in hooks.items():
        if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
            raise Refuse(f'hooks["{event}"] is not a list of groups; leaving settings.json alone')
    return hooks


def has_ours(groups, emit):
    return any(is_ours(h.get("command"), emit) for g in groups for h in g.get("hooks", []) if isinstance(h, dict))


def add_hooks(settings, emit):
    """A copy of `settings` with our hook added to every event that lacks it."""
    new = json.loads(json.dumps(settings))
    hooks = hooks_of(new)
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not has_ours(groups, emit):
            groups.append({"hooks": [{"type": "command", "command": emit, "async": True}]})
    new["hooks"] = hooks
    return new


def remove_hooks(settings, emit):
    """A copy with only our hook entries gone (and any group or event we leave empty)."""
    new = json.loads(json.dumps(settings))
    hooks = hooks_of(new)
    for event in list(hooks):
        kept = []
        for group in hooks[event]:
            inner = group.get("hooks")
            if isinstance(inner, list) and any(isinstance(h, dict) and is_ours(h.get("command"), emit) for h in inner):
                inner = [h for h in inner if not (isinstance(h, dict) and is_ours(h.get("command"), emit))]
                if not inner:
                    continue
                group = {**group, "hooks": inner}
            kept.append(group)
        if kept:
            hooks[event] = kept
        elif hooks[event]:                      # we emptied it
            del hooks[event]
    if "hooks" in new and not hooks:
        del new["hooks"]
    return new


def json_style(text):
    """(indent, trailing newline) of an existing JSON file, so a rewrite changes nothing else."""
    m = re.search(r"\n([ \t]+)\S", text)
    if not m:
        indent = 2
    elif m.group(1)[0] == "\t":
        indent = "\t"
    else:
        indent = len(m.group(1))
    return indent, text.endswith("\n")


def dump(data, style):
    indent, newline = style
    return json.dumps(data, indent=indent, ensure_ascii=False) + ("\n" if newline else "")


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def settings_path():
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(base, "settings.json")


# ---- files -----------------------------------------------------------------------------


def backup(path):
    if not os.path.exists(path):
        return None
    name = f"{path}.roundhouse-backup-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, name)
    return name


def write_atomic(path, text):
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o600
    folder = os.path.dirname(path) or "."
    os.makedirs(folder, exist_ok=True)
    tmp = f"{path}.roundhouse-{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def show_diff(old, new, path):
    diff = list(difflib.unified_diff(old.splitlines(keepends=True), new.splitlines(keepends=True),
                                     f"{path} (now)", f"{path} (after)"))
    print("".join(diff) if diff else "  (no change)")
    return bool(diff)


class Run:
    def __init__(self, dry, yes):
        self.dry, self.yes = dry, yes

    def confirm(self, question, default=False, needs_flag=None):
        if needs_flag is not None:
            return needs_flag
        if self.yes:
            return True
        if not sys.stdin.isatty():
            raise Refuse("no terminal to ask on; run it in a terminal, or pass --yes (after a --dry-run)")
        answer = input(f"  {question} [{'Y/n' if default else 'y/N'}] ").strip().lower()
        return default if not answer else answer in ("y", "yes")


# ---- the three steps -------------------------------------------------------------------


def step_hooks(run, install, path):
    print(f"\n1. Claude Code hooks in {path}")
    emit = emitter()
    if os.path.exists(path):
        old = read_text(path)
        try:
            settings = json.loads(old)
        except ValueError as err:
            raise Refuse(f"{path} is not valid JSON ({err}); leaving it alone")
        if not isinstance(settings, dict):
            raise Refuse(f"{path} is not a JSON object; leaving it alone")
        style = json_style(old)
    else:
        old, settings, style = "", {}, (2, True)
    new_settings = add_hooks(settings, emit) if install else remove_hooks(settings, emit)
    new = dump(new_settings, style)
    if not show_diff(old, new, path):
        print("  nothing to do." if install else "  none of our hooks are there.")
        return
    if install and not os.path.exists(path):
        print("  (the file does not exist yet; it will be created)")
    if run.dry:
        print("  [dry run] it would ask before writing this, after backing the file up.")
        return
    if run.confirm(("Add" if install else "Remove") + " these hooks?", default=True):
        saved = backup(path)
        write_atomic(path, new)
        print(f"  done. backup: {saved or 'none (new file)'}")
        if install:
            print("  Open Claude Code sessions need a restart to pick the hooks up.")
    else:
        print("  skipped.")


def link_path(bin_dir):
    return os.path.join(bin_dir, "roundhouse")


def step_link(run, install, bin_dir):
    link, target = link_path(bin_dir), os.path.join(ROOT, "bin", "roundhouse")
    print(f"\n2. The command {link}")
    exists = os.path.lexists(link)
    ours = exists and os.path.islink(link) and os.path.realpath(link) == os.path.realpath(target)
    if install:
        if ours:
            print("  already links here; nothing to do.")
            return
        if exists:
            print(f"  {link} exists and is not ours; leaving it alone. Link it yourself if you want it.")
            return
        print(f"  + {link} -> {target}")
        if run.dry:
            print("  [dry run] it would ask before creating this.")
            return
        if run.confirm("Create this link?", default=True):
            os.makedirs(bin_dir, exist_ok=True)
            os.symlink(target, link)
            print("  done.")
        else:
            print("  skipped.")
    else:
        if not ours:
            print("  no link of ours there; nothing to do.")
            return
        print(f"  - {link}")
        if run.dry:
            print("  [dry run] it would ask before removing this.")
            return
        if run.confirm("Remove this link?", default=True):
            os.unlink(link)
            print("  done.")
        else:
            print("  skipped.")


def hypr_line():
    return f'dofile("{os.path.join(ROOT, "hypr", "roundhouse.lua")}")  {MARK}'


def has_hypr_line(text):
    return any(l.strip().endswith(MARK) and "dofile(" in l for l in text.splitlines())


def hypr_reload_ok():
    """Reload Hyprland and report whether its config has errors."""
    try:
        subprocess.run(["hyprctl", "reload"], check=True, capture_output=True, timeout=10)
        time.sleep(0.5)
        out = subprocess.run(["hyprctl", "configerrors"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError) as err:
        return False, str(err)
    return out.strip() == "", out.strip()


def step_hypr(run, install, path, with_hypr, reload_check):
    print(f"\n3. Window rules in {path}")
    if not os.path.exists(path):
        print("  no Hyprland config there; skipping. The rules are in hypr/roundhouse.lua.")
        return
    old = read_text(path)
    if install:
        if has_hypr_line(old):
            print("  already has the roundhouse line; nothing to do.")
            return
        new = old + ("" if old.endswith("\n") or not old else "\n") + hypr_line() + "\n"
        # Its own question (a bad Hyprland config is worse than a bad hook), asked even with --yes.
        show_diff(old, new, path)
        if run.dry:
            print("  [dry run] it would ask first (default no), then back the file up, reload Hyprland and check for errors.")
            return
        if not run.confirm("Add this line to your Hyprland config?", default=False,
                           needs_flag=with_hypr if run.yes else None):
            print("  skipped. Without it Hyprland tiles the windows instead of floating them.\n"
                  "  To do it yourself, add this line:\n    " + hypr_line())
            return
    else:
        if not has_hypr_line(old):
            print("  no roundhouse line there; nothing to do.")
            return
        new = "".join(l for l in old.splitlines(keepends=True) if not (l.strip().endswith(MARK) and "dofile(" in l))
        show_diff(old, new, path)
        if run.dry:
            print("  [dry run] it would ask before removing this line.")
            return
        if not run.confirm("Remove the roundhouse line?", default=True):
            print("  skipped.")
            return
    saved = backup(path)
    write_atomic(path, new)
    print(f"  written. backup: {saved}")
    if reload_check:
        ok, errors = hypr_reload_ok()
        if not ok:
            shutil.copy2(saved, path)
            hypr_reload_ok()
            print(f"  Hyprland reported errors, so the backup was put back:\n{errors}")
            return
        print("  Hyprland reloaded with no config errors.")


# ---- uninstall extras ------------------------------------------------------------------


def stop_service():
    """End the window service: the process `quickshell -n -p <this folder>/ui`, found by exact argv."""
    ui = os.path.join(ROOT, "ui")
    stopped = 0
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")[:-1]
        except OSError:
            continue
        if len(argv) == 4 and os.path.basename(argv[0].decode(errors="replace")) == "quickshell" \
                and argv[1:3] == [b"-n", b"-p"] and os.path.realpath(argv[3].decode(errors="replace")) == os.path.realpath(ui) \
                and int(pid) != os.getpid():
            os.kill(int(pid), signal.SIGTERM)
            stopped += 1
    return stopped


def runtime_dir(base):
    return os.path.join(base, "lot-map")


def step_cleanup(run, base):
    folder = runtime_dir(base)
    print(f"\n4. The window service and the log folder {folder}")
    running = any(True for _ in _service_pids())
    exists = os.path.isdir(folder)
    print(f"  window service running: {'yes' if running else 'no'}; log folder: {'present' if exists else 'absent'}")
    if not running and not exists:
        print("  nothing to do.")
        return
    if run.dry:
        print("  [dry run] it would ask before stopping the service and deleting the folder.")
        return
    if run.confirm("Stop the window service and delete the log folder?", default=True):
        n = stop_service()
        if exists and os.path.basename(folder) == "lot-map":
            shutil.rmtree(folder)
        print(f"  done ({n} service stopped).")
    else:
        print("  skipped.")


def _service_pids():
    ui = os.path.join(ROOT, "ui")
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")[:-1]
        except OSError:
            continue
        if len(argv) == 4 and os.path.basename(argv[0].decode(errors="replace")) == "quickshell" \
                and argv[1:3] == [b"-n", b"-p"] and os.path.realpath(argv[3].decode(errors="replace")) == os.path.realpath(ui):
            yield int(pid)


# ---- status and main -------------------------------------------------------------------


def status(args):
    emit = emitter()
    path = args.settings
    try:
        settings = json.loads(read_text(path))
        hooks = hooks_of(settings)
        have = [e for e in EVENTS if has_ours(hooks.get(e, []), emit)]
    except (OSError, ValueError, Refuse):
        have = []
    link = link_path(args.bin_dir)
    ours = os.path.islink(link) and os.path.realpath(link) == os.path.realpath(os.path.join(ROOT, "bin", "roundhouse"))
    try:
        rules = has_hypr_line(read_text(args.hypr_config))
    except OSError:
        rules = False
    print(f"hooks in {path}: {len(have)} of {len(EVENTS)} events")
    print(f"command {link}: {'ours' if ours else ('present, not ours' if os.path.lexists(link) else 'absent')}")
    print(f"window rules line in {args.hypr_config}: {'yes' if rules else 'no'}")
    print(f"window service: {'running' if any(True for _ in _service_pids()) else 'not running'}")


def parser():
    p = argparse.ArgumentParser(prog="setup.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["install", "uninstall", "status"])
    p.add_argument("--dry-run", action="store_true", help="show everything, change nothing")
    p.add_argument("--yes", action="store_true", help="answer the questions yes (not the Hyprland one)")
    p.add_argument("--with-hyprland", action="store_true", help="with --yes: also add the Hyprland line")
    p.add_argument("--skip-hyprland", action="store_true", help="do not touch the Hyprland config at all")
    p.add_argument("--settings", default=settings_path())
    p.add_argument("--bin-dir", default=os.path.expanduser("~/.local/bin"))
    p.add_argument("--hypr-config", default=os.path.expanduser("~/.config/hypr/hyprland.lua"))
    p.add_argument("--runtime-dir", default=os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/lot-map-{os.getuid()}")
    p.add_argument("--no-reload", action="store_true", help="do not reload Hyprland after editing its config (tests)")
    return p


def main(argv):
    args = parser().parse_args(argv)
    if args.action == "status":
        status(args)
        return 0
    run = Run(args.dry_run, args.yes)
    install = args.action == "install"
    print(f"roundhouse {args.action}" + (" (dry run: nothing will be changed)" if run.dry else ""))
    try:
        step_hooks(run, install, args.settings)
        step_link(run, install, args.bin_dir)
        if not args.skip_hyprland:
            step_hypr(run, install, args.hypr_config, args.with_hyprland, not args.no_reload)
        if not install:
            step_cleanup(run, args.runtime_dir)
    except Refuse as err:
        print(f"\nstopped: {err}", file=sys.stderr)
        return 1
    print("\nDry run: nothing was changed." if run.dry else "\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
