#!/usr/bin/python3 -I
"""The hooks Claude Code has configured, for a click on the Hooks station; and opening the file behind one.

  hooklist.py list            prints [{"event", "matcher", "command", "script", "source", "own"}], sorted by event;
                              on a failure prints {"error": "..."} and exits 1 (an empty list is a real "none")
  hooklist.py open PATH       opens PATH in the editor, if it is the script or source file of a listed hook

Read at click time, never written: the `hooks` section of settings.json and settings.local.json (in
$CLAUDE_CONFIG_DIR, else ~/.claude) and the hooks.json of each installed and enabled plugin (the installed
version only: installed_plugins.json and `enabledPlugins` are read for that; without a usable
installed_plugins.json, the newest version folder of each plugin in plugins/cache). Project-level
.claude/settings*.json are not read (the log does not know the project folder reliably). The log does not
say which hook fired, so this is the configuration, not history.

Nothing sensitive is printed. A hook's command line can hold tokens and passwords, so `command` is only the
program's basename (no arguments; "prompt hook" and the like for a hook that is not a command), `script`
is the first word of the command that is an existing text file and not an interpreter (python, uv, node,
sh ...; ~, $HOME, and $CLAUDE_PLUGIN_ROOT for a plugin's own hooks.json are expanded; nothing else is), or
"" when none is found, and `source` is the file that defines the hook. `own` marks this folder's
hooks/emit.py (roundhouse's own entries; setup.py's is_ours). `open` only opens a path the listing itself
gave, and then only through openable.py's rules (an existing regular file in the home folder or Claude's
scratch folder).

Exit status: 0 done, 1 `list` could not read, 2 bad arguments or a path that is not one of the listed files.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import shlex
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUDGET = 2.0                 # seconds the plugin walk may take
MAX_FILE = 1 << 20           # a settings or hooks file larger than this is not read
MAX_ENTRIES = 500
MAX_OWN = 200                # roundhouse's own entries are counted apart, so they never push real ones out
MAX_DEPTH = 6


def _load(name):
    loader = importlib.machinery.SourceFileLoader(name, os.path.join(HERE, name + ".py"))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


openable = _load("openable")
setup = _load("setup")          # is_ours: the one definition of "this is roundhouse's own hook"
INTERPRETERS = re.compile(r"(python[0-9.]*|uv|uvx|node|nodejs|bash|sh|zsh|dash|fish|env|npx|bun|bunx|deno|ruby|perl|php|pnpm|npm|pipx)$")
CODE_FLAGS = frozenset(("-c", "-e", "-m", "-p", "--eval", "--print", "--command"))   # what follows is code, not a file


def config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


class Unreadable(Exception):
    pass


def read_json(path):
    """A JSON object from a regular file; None if there is no such file; Unreadable if it is there but not usable."""
    try:
        if not os.path.isfile(path):
            return None
        if os.path.getsize(path) > MAX_FILE:
            raise Unreadable(os.path.basename(path))
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError, UnicodeDecodeError, RecursionError):
        raise Unreadable(os.path.basename(path))
    if not isinstance(data, dict):
        raise Unreadable(os.path.basename(path))
    return data


def read_quiet(path):
    try:
        return read_json(path)
    except Unreadable:
        return None


def hooks_files(folder, deadline):
    """hooks.json files under one folder: found by walking, without following folder links."""
    found = []
    stack = [(folder, 0)]
    while stack and time.monotonic() < deadline and len(found) < 100:
        here, depth = stack.pop()
        try:
            entries = sorted(os.scandir(here), key=lambda e: e.name)
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_dir(follow_symlinks=False) and depth < MAX_DEPTH and e.name not in ("node_modules", ".git"):
                    stack.append((e.path, depth + 1))
                elif e.name == "hooks.json" and e.is_file(follow_symlinks=True):
                    found.append(e.path)
            except OSError:
                pass
    return found


def enabled_plugins(cfg):
    """{name: bool} from `enabledPlugins` in settings.json, settings.local.json overriding."""
    out = {}
    for name in ("settings.json", "settings.local.json"):
        ep = (read_quiet(os.path.join(cfg, name)) or {}).get("enabledPlugins")
        if isinstance(ep, dict):
            out.update({k: v for k, v in ep.items() if isinstance(k, str) and isinstance(v, bool)})
    return out


def plugin_hook_files(cfg, deadline):
    """[(hooks.json, plugin root)] of installed and enabled plugins, the installed version only."""
    enabled = enabled_plugins(cfg)
    plugins = os.path.join(cfg, "plugins")
    installed = (read_quiet(os.path.join(plugins, "installed_plugins.json")) or {}).get("plugins")
    out = []
    if isinstance(installed, dict):
        for name, versions in installed.items():
            if enabled.get(name) is not True or not isinstance(versions, list):
                continue
            for v in versions:
                root = v.get("installPath") if isinstance(v, dict) else None
                if not isinstance(root, str) or not os.path.isabs(root) or not openable.under(os.path.normpath(root), plugins):
                    continue
                for rel in ("hooks/hooks.json", "hooks.json"):
                    f = os.path.join(root, rel)
                    if os.path.isfile(f):
                        out.append((f, root))
                        break
        return out
    # no usable installed_plugins.json: the newest version folder of each plugin in the cache, minus the disabled
    best = {}
    cache = os.path.join(plugins, "cache")
    for f in hooks_files(cache, deadline):
        parts = os.path.relpath(f, cache).split(os.sep)
        if len(parts) < 4:
            continue
        key = (parts[0], parts[1])
        if enabled.get(parts[1] + "@" + parts[0]) is False:
            continue
        ver = os.path.join(cache, parts[0], parts[1], parts[2])
        try:
            age = os.stat(ver).st_mtime
        except OSError:
            continue
        if key not in best or age > best[key][0]:
            best[key] = (age, ver, [])
        if best[key][1] == ver:
            best[key][2].append(f)
    for _, ver, files in best.values():
        out += [(f, ver) for f in files]
    return out


def expand(token, plugin):
    """~, $HOME and (for a plugin's own hooks) $CLAUDE_PLUGIN_ROOT at the start of one word."""
    home = os.path.expanduser("~")
    if token == "~" or token.startswith("~/"):
        token = home + token[1:]
    token = re.sub(r"^\$\{?HOME\}?(?=/|$)", lambda m: home, token)
    if plugin:
        token = re.sub(r"^\$\{?CLAUDE_PLUGIN_ROOT\}?(?=/|$)", lambda m: plugin, token)
    return token


def words(command):
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def is_text(path):
    """Not a compiled program (no NUL byte in the first KB); the content is never kept or shown."""
    try:
        with open(path, "rb") as f:
            return b"\0" not in f.read(1024)
    except OSError:
        return False


def script_of(w, plugin=None):
    """The first word that is an existing text file and not an interpreter; "" if none. A flag that takes code
    (python -c, node -e) ends the search; other flags are skipped."""
    for t in w[:12]:
        if t in CODE_FLAGS:
            return ""
        if t.startswith("-"):
            continue
        p = expand(t, plugin)
        if "$" in p or not p.startswith("/") or INTERPRETERS.match(os.path.basename(p)):
            continue
        ok = openable.usable(p)
        if ok and is_text(ok):
            return ok
    return ""


def program_of(w):
    for t in w:
        if not re.match(r"[A-Za-z_][A-Za-z0-9_]*=", t):
            return os.path.basename(t.rstrip("/"))[:80]
    return ""


def entries_of(hooks, source, plugin=None):
    """(own, others): lists of (entry, identity); the identity is only used to drop duplicates and never leaves."""
    own, out = [], []
    if not isinstance(hooks, dict):
        return own, out
    emit = setup.emitter()
    for event, groups in hooks.items():
        if not isinstance(event, str) or not isinstance(groups, list):
            continue
        for g in groups:
            if not isinstance(g, dict) or not isinstance(g.get("hooks"), list):
                continue
            matcher = g.get("matcher")
            matcher = matcher[:120] if isinstance(matcher, str) else ""
            for h in g["hooks"]:
                if not isinstance(h, dict):
                    continue
                cmd = h.get("command")
                if isinstance(cmd, str) and cmd.strip():
                    w = words(cmd)
                    entry = {"event": event[:60], "matcher": matcher, "command": program_of(w),
                             "script": script_of(w, plugin), "source": source, "own": setup.is_ours(cmd.strip(), emit)}
                    (own if entry["own"] else out).append((entry, cmd))
                elif h.get("type") in ("prompt", "agent", "http", "mcp_tool"):
                    out.append(({"event": event[:60], "matcher": matcher, "command": h["type"] + " hook",
                                 "script": "", "source": source, "own": False},
                                "\0" + h["type"] + json.dumps(h, sort_keys=True, default=str)))
    return own, out


def list_hooks():
    cfg = config_dir()
    sources = []
    failed = 0
    for name in ("settings.json", "settings.local.json"):
        path = os.path.join(cfg, name)
        try:
            data = read_json(path)
        except Unreadable:
            failed += 1
            continue
        if data:
            sources.append((data.get("hooks"), openable.usable(path) or "", None))
    for path, root in plugin_hook_files(cfg, time.monotonic() + BUDGET):
        try:
            data = read_json(path)
        except Unreadable:
            failed += 1
            continue
        if data:
            sources.append((data.get("hooks") if isinstance(data.get("hooks"), dict) else data, openable.usable(path) or "", root))
    own, out, seen = [], [], set()
    for hooks, source, plugin in sources:
        o, x = entries_of(hooks, source, plugin)
        for lst, dest in ((o, own), (x, out)):
            for entry, ident in lst:
                key = (entry["event"], entry["matcher"], ident)          # the same hook twice is listed once
                if key not in seen:
                    seen.add(key)
                    dest.append(entry)
    out.sort(key=lambda e: e["event"])
    result = out[:MAX_ENTRIES] + own[:MAX_OWN]
    if failed and not result:
        raise Unreadable("a hooks file could not be read")
    return result


def open_listed(path):
    if not isinstance(path, str) or not path.startswith("/"):
        return False
    norm = os.path.normpath(path)
    if not any(norm in (e["script"], e["source"]) for e in list_hooks()):
        return False
    return openable.open_file(norm)


def main(argv):
    if argv == ["list"]:
        try:
            print(json.dumps(list_hooks()))
            return 0
        except Exception as e:            # a failed read is not an empty list: say so
            print(json.dumps({"error": type(e).__name__}))
            return 1
    if argv[:1] == ["open"] and len(argv) == 2:
        try:
            ok = open_listed(argv[1])
        except Exception:
            ok = False
        if ok:
            return 0
        print("not a listed hook file, or the editor could not be started", file=sys.stderr)
        return 2
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
