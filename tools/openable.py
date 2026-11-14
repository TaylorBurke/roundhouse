#!/usr/bin/python3 -I
"""Find the file behind a name on the map, and open it in the editor.

  openable.py resolve KIND LABEL [--cwd DIR] [--dir NAME]    prints {"paths": [...]} (best first)
  openable.py open PATH                                       opens one file in the editor

KIND is files, memory or skills. LABEL is what the map shows: the last two parts of a file's path
(`hooks/cost-tracker.js`), or a skill's name (`tdd-workflow`, `ecc:tdd-workflow`). The log keeps no
full paths, so a click looks the name up on disk now:

  files, memory  under the session's folder (--cwd, from claude-strip's state; else a folder named
                 --dir is looked for under the home folder), then under ~/.claude; a memory file is
                 first looked for in that project's own memory folder.
  skills         ~/.claude/skills, the session's .claude/skills, then plugin folders (the installed
                 copy first; translated docs and other tools' copies last).

Only names are read, never file contents. A result is an existing regular file under the home folder
(or the session's folder). `open` checks the same again, and then only hands the path to
`omarchy launch editor`: nothing is ever executed. The search stops after a couple of seconds.

Exit status: 0 done, 2 bad arguments or a path that is not an openable file.
"""
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.realpath(os.path.expanduser("~"))
BUDGET = 2.5                 # seconds a lookup may take
MAX_PATHS = 20
MAX_DEPTH = 9
CLAUDE_SKIP = frozenset("plugins projects session-data shell-snapshots todos statsig file-history ide backups cache".split())
SKIP_DIRS = frozenset(
    "node_modules .git .hg .svn __pycache__ .venv venv .tox target build dist .next .nuxt .gradle .cache .npm "
    ".cargo .rustup .mozilla .local .var .steam .wine Trash .Trash".split())
SKILL_NAME = re.compile(r"[A-Za-z0-9_.:-]{1,80}")
KINDS = ("files", "memory", "skills")


def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def usable(path, extra_root=None):
    """An existing regular file whose own path is inside the home folder (or the session's folder).

    The path is judged as given, not after following links: a skill that is a symlink into some
    other tool's folder is still the user's own, and the editor is only shown the file. Returns the
    normalised path, or False."""
    try:
        norm = os.path.normpath(path)
        if not os.path.isabs(norm) or not os.path.isfile(norm):
            return False
        inside = under(norm, HOME) or bool(extra_root and under(norm, extra_root))
        return norm if inside else False
    except (OSError, ValueError):
        return False


def parts_of(label):
    """The path parts of a label, or None if it is not a plain name (no .., no empty part, at most two)."""
    if not isinstance(label, str) or not label or len(label) > 200 or re.search(r"[\x00-\x1f\\]", label):
        return None
    parts = label.split("/")
    if len(parts) > 2 or any(p in ("", ".", "..") for p in parts):
        return None
    return parts


def find_files(root, parts, deadline, depth=MAX_DEPTH, skip=frozenset()):
    """Files under root whose path ends with the label's parts; stops at the deadline."""
    out = []
    root = os.path.realpath(root)
    base = root.count("/")
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if time.monotonic() > deadline or len(out) >= MAX_PATHS:
            break
        if dirpath.count("/") - base >= depth:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and d not in skip]
        if parts[-1] in filenames and (len(parts) == 1 or os.path.basename(dirpath) == parts[0]):
            out.append(os.path.join(dirpath, parts[-1]))
    return out


def project_key(cwd):
    return cwd.replace("/", "-").replace(".", "-")


def project_roots(cwd, name):
    """The session's folder: the one given, else folders named `name` a few levels below home."""
    if cwd:
        real = os.path.realpath(cwd)
        return [real] if os.path.isdir(real) and under(real, HOME) else []
    if not name or not re.fullmatch(r"[A-Za-z0-9_. -]{1,80}", name):
        return []
    found, deadline = [], time.monotonic() + 1.2
    for dirpath, dirnames, _ in os.walk(HOME, followlinks=False):
        if time.monotonic() > deadline or len(found) >= 3:
            break
        if dirpath.count("/") - HOME.count("/") >= 4:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        if name in dirnames:
            found.append(os.path.join(dirpath, name))
    return found


def resolve_files(kind, label, cwd, name):
    parts = parts_of(label)
    if not parts:
        return []
    deadline = time.monotonic() + BUDGET
    roots = project_roots(cwd, name)
    found = []
    claude = os.path.join(HOME, ".claude")
    own = []
    if kind == "memory":
        # this project's own memory folder first, then any project's
        for root in roots:
            key = project_key(root)
            own.append(os.path.join(claude, "projects", key, "memory"))
            found.append(os.path.join(own[-1], parts[-1]))
        projects = os.path.join(claude, "projects")
        if os.path.isdir(projects):
            for entry in sorted(os.listdir(projects)):
                found.append(os.path.join(projects, entry, "memory", parts[-1]))
    for root in roots:
        found += find_files(root, parts, deadline)
    if os.path.isdir(claude):
        found += find_files(claude, parts, deadline, depth=6, skip=CLAUDE_SKIP) if kind != "memory" else []
    ranked = rank(found, roots, own)
    if kind == "memory":                         # this project's own memory file, if it has one: the others are noise
        mine = [p for p in ranked if any(under(p, o) for o in own)]
        return mine or ranked
    return ranked


def skill_tier(path):
    """0 the user's own skill, 1 an installed plugin's, 2 a marketplace checkout's, 3 anything else."""
    if "/.claude/skills/" in path:
        return 0
    if "/plugins/cache/" in path:
        return 1
    if "/plugins/marketplaces/" in path:
        return 2
    return 3


def noisy(path):
    """Other tools' copies (.kiro, .cursor, .agents ...) and translated docs, tests, examples."""
    hidden = re.search(r"/(\.[A-Za-z0-9_-]+)/skills/", path)
    return bool((hidden and hidden.group(1) != ".claude") or re.search(r"/(docs|tests?|examples?|fixtures?)/", path))


def resolve_skills(label, cwd, name):
    if not isinstance(label, str) or not SKILL_NAME.fullmatch(label):
        return []
    ns, _, base = label.rpartition(":")
    if not base or base in (".", ".."):
        return []
    deadline = time.monotonic() + BUDGET
    found = []
    for root in project_roots(cwd, name):
        found.append(os.path.join(root, ".claude", "skills", base, "SKILL.md"))
    claude = os.path.join(HOME, ".claude")
    found.append(os.path.join(claude, "skills", base, "SKILL.md"))
    plugins = os.path.join(claude, "plugins")
    if os.path.isdir(plugins):
        for dirpath, dirnames, filenames in os.walk(plugins, followlinks=False):
            if time.monotonic() > deadline or len(found) > 400:
                break
            if dirpath.count("/") - plugins.count("/") >= 9:
                dirnames[:] = []
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            if "SKILL.md" in filenames and os.path.basename(dirpath) == base and os.path.basename(os.path.dirname(dirpath)) == "skills":
                found.append(os.path.join(dirpath, "SKILL.md"))
    good = sorted({usable(p) for p in found if usable(p)})
    if ns:                                       # `ecc:tdd-workflow`: the plugin is `ecc`
        good = [p for p in good if f"/{ns}/" in p] or good
    clean = [p for p in good if not noisy(p)]
    good = clean or good
    best = min((skill_tier(p) for p in good), default=0)
    return sorted([p for p in good if skill_tier(p) == best])[:MAX_PATHS]


def rank(paths, roots, own=()):
    """Existing files, best first: this project's own memory folder, then the session's folder, then the rest."""
    seen, out = set(), []
    for p in paths:
        real = usable(p, roots[0] if roots else None)
        if real and real not in seen:
            seen.add(real)
            out.append(real)

    def key(p):
        tier = 0 if any(under(p, o) for o in own) else 1 if any(under(p, r) for r in roots) else 2
        try:
            return (tier, -os.path.getmtime(p))
        except OSError:
            return (tier, 0)
    return sorted(out, key=key)[:MAX_PATHS]


def resolve(kind, label, cwd=None, name=None):
    if kind == "skills":
        return resolve_skills(label, cwd, name)
    if kind in ("files", "memory"):
        return resolve_files(kind, label, cwd, name)
    return []


def open_file(path):
    real = usable(path) if isinstance(path, str) and path.startswith("/") else False
    if not real:
        return False
    subprocess.Popen(["omarchy", "launch", "editor", real], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


def main(argv):
    try:
        if argv[:1] == ["resolve"] and len(argv) >= 3 and argv[1] in KINDS:
            kind, label, rest = argv[1], argv[2], argv[3:]
            opts = {}
            while rest:
                if rest[0] not in ("--cwd", "--dir") or len(rest) < 2:
                    raise ValueError("usage")
                opts[rest[0][2:]] = rest[1]
                rest = rest[2:]
            cwd = opts.get("cwd") if opts.get("cwd", "").startswith("/") else None
            print(json.dumps({"paths": resolve(kind, label, cwd, opts.get("dir"))}))
            return 0
        if argv[:1] == ["open"] and len(argv) == 2:
            if open_file(argv[1]):
                return 0
            print("not an openable file", file=sys.stderr)
            return 2
    except ValueError:
        pass
    print(__doc__.split("\n\n")[0] + "\n  (see the file header for KIND, LABEL and the options)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
