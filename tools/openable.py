#!/usr/bin/python3 -I
"""Find the file behind a name on the map, and open it in the editor.

  openable.py resolve KIND LABEL [--cwd DIR] [--sid ID] [--dir NAME]   prints {"paths": [...]} (best first)
  openable.py list memory [--cwd DIR] [--sid ID] [--dir NAME]           prints the project's own memory files
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
(or the session's folder), and a symlink that leads out of the home folder is refused, except under
~/.claude/skills and the plugin folders, where such links are normal. `open` checks the same again, and
then only hands the path to `omarchy launch editor` (or `xdg-open` for pictures, video, audio and PDFs, by extension; never SVG):
nothing is ever executed. The search stops after a
couple of seconds.

Exit status: 0 done, 2 bad arguments or a path that is not an openable file.
"""
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time

HOME = os.path.realpath(os.path.expanduser("~"))
BUDGET = 4.0                 # seconds a lookup may take
MAX_PATHS = 20                # what a lookup returns
COLLECT = 400                # what the walk gathers before ranking picks the best MAX_PATHS
MAX_DEPTH = 9
CLAUDE_SKIP = frozenset("plugins projects session-data shell-snapshots todos statsig file-history ide backups cache".split())
SKIP_DIRS = frozenset(
    "node_modules .git .hg .svn __pycache__ .venv venv .tox target build dist .next .nuxt .gradle .cache .npm "
    ".cargo .rustup .mozilla .local .var .steam .wine Trash .Trash".split())
SKILL_NAME = re.compile(r"[A-Za-z0-9_.:-]{1,80}")
KINDS = ("files", "memory", "skills")


def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def link_roots():
    """Folders whose entries may be symlinks to another tool's files (a skill linked from /usr/share ...)."""
    return [os.path.join(HOME, ".claude", "skills"), os.path.join(HOME, ".claude", "plugins")]


def scratch_root():
    """Claude Code's scratch folder for this user (screenshots, notes and the like are written there)."""
    return os.path.join("/tmp", f"claude-{os.getuid()}")


def scratch_ok():
    """The scratch folder only counts if it is a real folder owned by this user that nobody else can write
    to: /tmp is shared, and someone else could have created the name first."""
    try:
        st = os.lstat(scratch_root())
        return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and not (st.st_mode & 0o022)
    except OSError:
        return False


def usable(path, extra_root=None):
    """An existing regular file inside the home folder, Claude's scratch folder or the session's folder.

    The path as given must be inside one of them. If a symlink on the way leads out, the file is only
    accepted when the path lies in a place meant for such links (~/.claude/skills and the plugin
    folders); anywhere else, a project folder above all, a link out is refused, so a cloned repo
    cannot point the editor at /etc. Returns the normalised path, or False."""
    try:
        norm = os.path.normpath(path)
        if not os.path.isabs(norm) or not os.path.isfile(norm):
            return False
        roots = [HOME] + ([scratch_root()] if scratch_ok() else []) + ([extra_root] if extra_root else [])
        if not any(under(norm, r) for r in roots):
            return False
        real = os.path.realpath(norm)
        if any(under(real, os.path.realpath(r)) for r in roots):
            return norm
        return norm if any(under(norm, r) for r in link_roots()) else False
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


def find_files(root, parts, deadline, depth=MAX_DEPTH, skip=frozenset(), exempt=frozenset()):
    """Files under root whose path ends with the label's parts; stops at the deadline."""
    out = []
    root = os.path.realpath(root)
    base = root.count("/")
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if time.monotonic() > deadline or len(out) >= COLLECT:
            break
        if dirpath.count("/") - base >= depth:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if (d not in SKIP_DIRS or d in exempt) and d not in skip]
        if parts[-1] in filenames and (len(parts) == 1 or os.path.basename(dirpath) == parts[0]):
            out.append(os.path.join(dirpath, parts[-1]))
    return out


def project_key(cwd):
    return cwd.replace("/", "-").replace(".", "-")


def project_keys(cwd):
    """The names Claude Code may have given a project's folder: every character that is not a letter
    or digit turned into a dash (a dot, a space, maybe an underscore), or the narrower forms."""
    return {project_key(cwd), re.sub(r"[^A-Za-z0-9]", "-", cwd), re.sub(r"[^A-Za-z0-9_]", "-", cwd)}


def folder_of_session(sid):
    """The folder a session runs in, from claude-strip's state file for it (it holds the session id and
    the folder), or None. Lets the all-sessions window, which has no strip of its own, find files too."""
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{8}", sid):
        return None
    folder = os.environ.get("CLAUDE_STRIP_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "claude-strip")
    best = None
    try:
        for name in os.listdir(folder):
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(folder, name), encoding="utf-8") as f:
                    state = json.load(f)
            except (OSError, ValueError):
                continue
            cwd, session = state.get("cwd"), state.get("sessionId")
            if isinstance(session, str) and session[:8] == sid and isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 400:
                stamp = state.get("updatedAt") if isinstance(state.get("updatedAt"), (int, float)) else 0
                if best is None or stamp >= best[0]:
                    best = (stamp, cwd)
    except OSError:
        return None
    return best[1] if best else None


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


def home_wide(parts, deadline):
    """Files named like the label anywhere in the home folder, newest first: for a name that is not under
    the session's folder (or a session whose folder is not known). Uses fd when there is one."""
    regex = "(^|/)" + "/".join(re.escape(p) for p in parts) + "$"
    found = []
    left = max(0.5, deadline - time.monotonic())
    fd = shutil.which("fd")
    if fd:
        cmd = [fd, "--type", "f", "--hidden", "--no-ignore", "--absolute-path", "--full-path", "--max-results", str(COLLECT)]
        for d in sorted(SKIP_DIRS):
            cmd += ["--exclude", d]
        for d in sorted(CLAUDE_SKIP):
            cmd += ["--exclude", ".claude/" + d]                # only Claude's own folders, not a user's "projects"
        try:
            out = subprocess.run(cmd + [regex, HOME], capture_output=True, text=True, timeout=left).stdout
            found = [line for line in out.splitlines() if line]
        except (OSError, subprocess.SubprocessError):
            found = []
    else:
        found = find_files(HOME, parts, deadline, depth=7, skip=frozenset())
        found = [p for p in found if not any(under(p, os.path.join(HOME, ".claude", d)) for d in CLAUDE_SKIP)]
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
        # this project's own memory folder first, then every project's; the label's folder part is respected
        for root in roots:
            for key in sorted(project_keys(root)):
                own.append(os.path.join(claude, "projects", key, "memory"))
        projects = os.path.join(claude, "projects")
        every = [os.path.join(projects, e, "memory") for e in sorted(os.listdir(projects))] if os.path.isdir(projects) else []
        for folder in own + every:
            if os.path.isdir(folder):
                found += find_files(folder, parts, deadline, depth=4)
    scratch = scratch_root()
    for root in roots + ([scratch] if kind == "files" and scratch_ok() else []):
        found += find_files(root, parts, deadline, exempt=frozenset(parts[:-1]))      # `dist/index.js` may live in dist/
    if os.path.isdir(claude):
        found += find_files(claude, parts, deadline, depth=6, skip=CLAUDE_SKIP) if kind != "memory" else []
    ranked = rank(found, roots, own)
    if kind == "files":                              # nothing under the session's folder or the scratch folder: look through home
        near = roots + ([scratch] if scratch_ok() else [])
        if not any(under(p, r) for p in ranked for r in near):
            ranked = rank(ranked + home_wide(parts, deadline), roots, own)
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
    """Other tools' copies (.kiro, .cursor, .agents ...) and translated docs, tests, examples: judged only
    inside the plugin folders, and only by the part of the path below them, so where the user's own
    folders happen to live never counts."""
    plugins = os.path.join(HOME, ".claude", "plugins") + "/"
    if not path.startswith(plugins):
        return False
    below = "/" + path[len(plugins):]
    hidden = re.search(r"/(\.[A-Za-z0-9_-]+)/skills/", below)
    return bool(hidden or re.search(r"/(docs|tests?|examples?|fixtures?)/", below))


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


def list_memory(cwd=None, name=None):
    """The memory files of the session's project, from its own memory folder: MEMORY.md (the index)
    first, then the others, newest first. Nothing here depends on what the session has touched:
    memory is loaded at the start without any tool call, so there may be no event to go by."""
    claude = os.path.join(HOME, ".claude")
    roots = project_roots(cwd, name)
    folders, found = [], []
    for root in roots:
        for key in sorted(project_keys(root)):
            folder = os.path.join(claude, "projects", key, "memory")
            if folder not in folders and os.path.isdir(folder):
                folders.append(folder)
    for folder in folders:
        base = folder.count("/")
        for dirpath, dirnames, filenames in os.walk(folder, followlinks=False):
            if dirpath.count("/") - base >= 3:
                dirnames[:] = []
            for f in filenames:
                if f.lower().endswith((".md", ".markdown")):
                    found.append((folder, os.path.join(dirpath, f)))
    out = []
    for folder, path in found:
        real = usable(path)
        if real:
            out.append((folder, real))

    def key(item):
        folder, path = item
        try:
            newest = -os.path.getmtime(path)
        except OSError:
            newest = 0
        return (0 if path == os.path.join(folder, "MEMORY.md") else 1, newest, path)
    seen, paths = set(), []
    for _, path in sorted(out, key=key):
        if path not in seen:
            seen.add(path)
            paths.append(path)
    return paths[:MAX_PATHS]


def resolve(kind, label, cwd=None, name=None):
    if kind == "skills":
        return resolve_skills(label, cwd, name)
    if kind in ("files", "memory"):
        return resolve_files(kind, label, cwd, name)
    return []


# Shown in the default viewer rather than as text in an editor: pictures, video, audio and PDFs, by
# extension (a guessed MIME type varies between systems: .ts can come out as a video). SVG is left to the
# editor on purpose: opened as a picture it can run script in a browser.
VIEWED = frozenset(".png .jpg .jpeg .gif .webp .bmp .tif .tiff .ico .avif .heic .mp4 .mkv .webm .mov .avi "
                   ".mp3 .wav .flac .ogg .oga .opus .m4a .pdf".split())


def opener(path):
    """The command that shows a file: the default viewer for a picture, video, audio or PDF (a text editor
    would show noise), the editor for everything else. Neither runs the file."""
    if os.path.splitext(path)[1].lower() in VIEWED:
        return ["xdg-open", path]
    return ["omarchy", "launch", "editor", path]


def open_file(path):
    real = usable(path) if isinstance(path, str) and path.startswith("/") else False
    if not real:
        return False
    try:
        subprocess.Popen(opener(real), start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:                              # the opener is not on PATH, or cannot start
        return False
    return True


def parse_options(rest):
    """--cwd (the session's folder), --sid (its session id: the folder is looked up from claude-strip's
    state) and --dir (the folder's name, a last resort). Returns (cwd, dir name)."""
    opts = {}
    while rest:
        if rest[0] not in ("--cwd", "--dir", "--sid") or len(rest) < 2:
            raise ValueError("usage")
        opts[rest[0][2:]] = rest[1]
        rest = rest[2:]
    cwd = opts.get("cwd") if opts.get("cwd", "").startswith("/") else None
    return cwd or folder_of_session(opts.get("sid")), opts.get("dir")


def main(argv):
    try:
        if argv[:1] == ["resolve"] and len(argv) >= 3 and argv[1] in KINDS:
            cwd, name = parse_options(argv[3:])
            print(json.dumps({"paths": resolve(argv[1], argv[2], cwd, name)}))
            return 0
        if argv[:2] == ["list", "memory"]:
            cwd, name = parse_options(argv[2:])
            print(json.dumps({"paths": list_memory(cwd, name)}))
            return 0
        if argv[:1] == ["open"] and len(argv) == 2:
            if open_file(argv[1]):
                return 0
            print("not an openable file, or the editor could not be started", file=sys.stderr)
            return 2
    except ValueError:
        pass
    print(__doc__.split("\n\n")[0] + "\n  (see the file header for KIND, LABEL and the options)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
