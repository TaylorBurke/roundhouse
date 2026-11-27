"""tools/openable.py: finding the file behind a name on the map, and opening it. Everything runs in a
temporary fake home folder; `omarchy` on PATH is a stand-in that records what it was asked to open."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "openable.py")
_loader = importlib.machinery.SourceFileLoader("openable", TOOL)
_spec = importlib.util.spec_from_loader("openable", _loader)
openable = importlib.util.module_from_spec(_spec)
_loader.exec_module(openable)


def touch(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    return path


class World(unittest.TestCase):
    """A fake home with a project, a .claude folder, plugins and memory."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self.tmp.name)
        self.saved = openable.HOME
        openable.HOME = self.home
        self.proj = os.path.join(self.home, "Work", "dev", "proj")
        os.makedirs(self.proj)
        self.scratch_dir = tempfile.TemporaryDirectory()           # stands in for /tmp/claude-<uid>
        self.scratch = os.path.realpath(self.scratch_dir.name)
        self.saved_scratch = openable.scratch_root
        openable.scratch_root = lambda: self.scratch

    def tearDown(self):
        openable.HOME = self.saved
        openable.scratch_root = self.saved_scratch
        self.scratch_dir.cleanup()
        self.tmp.cleanup()

    def h(self, *p):
        return os.path.join(self.home, *p)

    def resolve(self, kind, label, cwd="default", name=None):
        return openable.resolve(kind, label, self.proj if cwd == "default" else cwd, name)


class Files(World):
    def test_a_two_part_label_is_found_under_the_session_folder(self):
        want = touch(os.path.join(self.proj, "src", "app", "main.ts"))
        touch(os.path.join(self.proj, "src", "other", "main.ts"))
        self.assertEqual(self.resolve("files", "app/main.ts"), [want])

    def test_a_one_part_label_may_match_several_and_the_session_folder_comes_first(self):
        a = touch(os.path.join(self.proj, "README.md"))
        b = touch(self.h(".claude", "rules", "README.md"))
        self.assertEqual(self.resolve("files", "README.md"), [a, b])

    def test_nothing_found_is_an_empty_list(self):
        self.assertEqual(self.resolve("files", "nope/gone.ts"), [])

    def test_hook_scripts_under_dot_claude_are_found(self):
        want = touch(self.h(".claude", "hooks", "cost-tracker.js"))
        self.assertEqual(self.resolve("files", "hooks/cost-tracker.js"), [want])

    def test_transcripts_and_plugins_are_not_searched_for_files(self):
        touch(self.h(".claude", "projects", "-x", "notes", "a.md"))
        touch(self.h(".claude", "plugins", "cache", "notes", "a.md"))
        self.assertEqual(self.resolve("files", "notes/a.md"), [])

    def test_heavy_folders_are_skipped(self):
        touch(os.path.join(self.proj, "node_modules", "lib", "index.js"))
        touch(os.path.join(self.proj, ".git", "lib", "index.js"))
        self.assertEqual(self.resolve("files", "lib/index.js"), [])

    def test_a_file_in_a_folder_the_search_normally_skips_is_found_when_the_label_names_that_folder(self):
        want = touch(os.path.join(self.proj, "dist", "index.js"))
        self.assertEqual(self.resolve("files", "dist/index.js"), [want])
        touch(os.path.join(self.proj, "pkg", "build", "out.js"))
        self.assertEqual(self.resolve("files", "build/out.js"), [os.path.join(self.proj, "pkg", "build", "out.js")])
        self.assertEqual(self.resolve("files", "out.js"), [])           # a bare name gives no reason to look in build/

    def test_labels_that_are_not_plain_names_are_refused(self):
        touch(os.path.join(self.proj, "a", "b.txt"))
        for bad in ("../a/b.txt", "a/../b.txt", "x/a/b.txt", "", "/a/b.txt", "a//b.txt", "a\\b.txt", "a/b\n.txt", "..", ".", "a/.", None, 5):
            self.assertEqual(self.resolve("files", bad), [], bad)

    def test_a_folder_outside_home_is_never_searched(self):
        with tempfile.TemporaryDirectory() as other:
            touch(os.path.join(other, "d", "f.txt"))
            self.assertEqual(openable.resolve("files", "d/f.txt", os.path.realpath(other), None), [])

    def test_without_a_session_folder_a_folder_with_the_sessions_name_is_looked_for(self):
        want = touch(os.path.join(self.proj, "docs", "guide.md"))
        self.assertEqual(openable.project_roots(None, "proj"), [self.proj])
        self.assertEqual(openable.resolve("files", "docs/guide.md", None, "proj"), [want])
        self.assertEqual(openable.project_roots(None, "../proj"), [])            # a name that is not a plain folder name
        self.assertEqual(openable.project_roots(None, None), [])

    def test_a_directory_with_the_name_is_not_a_file(self):
        os.makedirs(os.path.join(self.proj, "a", "b.md"))
        self.assertEqual(self.resolve("files", "a/b.md"), [])


    def test_no_editor_on_path_is_a_refusal_not_a_crash(self):
        f = touch(os.path.join(self.proj, "notes.md"))
        empty = os.path.join(self.tmp.name, "nobin")
        os.makedirs(empty)
        saved = os.environ["PATH"]
        os.environ["PATH"] = empty                      # no omarchy, no xdg-open
        try:
            self.assertFalse(openable.open_file(f))
            self.assertFalse(openable.open_file(touch(os.path.join(self.proj, "shot.png"))))
        finally:
            os.environ["PATH"] = saved


class WiderSearch(World):
    """A file the session's folder does not hold: Claude's scratch folder, or anywhere under home."""

    def test_a_file_in_claudes_scratch_folder_is_found_and_may_be_opened(self):
        want = touch(os.path.join(self.scratch, "-home-x", "abc", "scratchpad", "notes.md"))
        self.assertEqual(self.resolve("files", "scratchpad/notes.md"), [want])
        self.assertEqual(openable.usable(want), want)

    def test_other_places_outside_home_are_still_refused(self):
        with tempfile.TemporaryDirectory() as other:
            outside = touch(os.path.join(os.path.realpath(other), "n.md"))
            self.assertFalse(openable.usable(outside))

    def test_a_name_that_is_not_under_the_session_folder_is_found_elsewhere_in_home(self):
        want = touch(self.h("Pictures", "Screenshots", "shot.png"))
        self.assertEqual(self.resolve("files", "Screenshots/shot.png"), [want])
        self.assertEqual(self.resolve("files", "shot.png"), [want])

    def test_a_session_whose_folder_is_unknown_still_finds_its_files(self):
        want = touch(self.h("Work", "dev", "other", "hooks", "emit.py"))
        self.assertEqual(openable.resolve("files", "hooks/emit.py", None, None), [want])

    def test_a_weaker_match_elsewhere_does_not_hide_the_search_through_home(self):
        weak = touch(self.h(".claude", "rules", "README.md"))
        other = touch(self.h("Pictures", "x", "README.md"))
        got = self.resolve("files", "README.md")
        self.assertEqual(sorted(got), sorted([weak, other]))

    def test_the_session_folder_wins_and_adds_no_noise_from_the_rest_of_home(self):
        mine = touch(os.path.join(self.proj, "hooks", "emit.py"))
        touch(self.h("Work", "dev", "other", "hooks", "emit.py"))
        self.assertEqual(self.resolve("files", "hooks/emit.py"), [mine])

    def test_the_home_wide_search_stays_out_of_claudes_plugin_and_transcript_folders(self):
        touch(self.h(".claude", "plugins", "cache", "p", "notes", "a.md"))
        touch(self.h(".claude", "projects", "-x", "notes", "a.md"))
        mine = touch(self.h("projects", "notes", "a.md"))                     # a user's own "projects" folder is fine
        self.assertEqual(self.resolve("files", "notes/a.md"), [mine])

    def test_without_fd_a_bounded_walk_does_the_same(self):
        want = touch(self.h("Pictures", "Screenshots", "shot.png"))
        saved = openable.shutil.which
        openable.shutil.which = lambda name: None
        try:
            self.assertEqual(self.resolve("files", "Screenshots/shot.png"), [want])
        finally:
            openable.shutil.which = saved

    def test_hidden_places_under_home_are_searched_too(self):
        want = touch(self.h(".config", "omarchy", "plugins", "x.widget", "Bar.qml"))
        self.assertEqual(self.resolve("files", "x.widget/Bar.qml"), [want])

    def test_nothing_found_anywhere_is_an_empty_list(self):
        self.assertEqual(self.resolve("files", "no/such-file.xyz"), [])


class Scratch(World):
    """/tmp is shared: Claude's scratch folder only counts if it is the user's own and private."""

    def test_a_scratch_folder_owned_by_the_user_and_private_counts(self):
        self.assertTrue(openable.scratch_ok())
        want = touch(os.path.join(self.scratch, "s", "a.md"))
        self.assertEqual(openable.usable(want), want)

    def test_one_anyone_can_write_to_does_not_count(self):
        want = touch(os.path.join(self.scratch, "s", "a.md"))
        os.chmod(self.scratch, 0o777)
        self.assertFalse(openable.scratch_ok())
        self.assertFalse(openable.usable(want))
        self.assertEqual(self.resolve("files", "s/a.md"), [])

    def test_one_group_writable_does_not_count(self):
        os.chmod(self.scratch, 0o770)
        self.assertFalse(openable.scratch_ok())

    def test_one_owned_by_someone_else_does_not_count(self):
        saved = os.getuid
        os.getuid = lambda: saved() + 1
        try:
            self.assertFalse(openable.scratch_ok())
        finally:
            os.getuid = saved

    def test_a_symlink_in_its_place_does_not_count(self):
        real = tempfile.mkdtemp()
        link = os.path.join(self.tmp.name, "scratch-link")
        os.symlink(real, link)
        openable.scratch_root = lambda: link
        try:
            self.assertFalse(openable.scratch_ok())
        finally:
            os.rmdir(real)

    def test_a_missing_one_does_not_count(self):
        openable.scratch_root = lambda: os.path.join(self.tmp.name, "nope")
        self.assertFalse(openable.scratch_ok())


class SessionFolder(World):
    def state(self, name, **fields):
        folder = os.path.join(self.tmp.name, "strip")
        os.makedirs(folder, exist_ok=True)
        touch(os.path.join(folder, name), json.dumps(fields))
        return folder

    def with_state(self, folder, fn):
        saved = os.environ.get("CLAUDE_STRIP_DIR")
        os.environ["CLAUDE_STRIP_DIR"] = folder
        try:
            return fn()
        finally:
            if saved is None:
                os.environ.pop("CLAUDE_STRIP_DIR", None)
            else:
                os.environ["CLAUDE_STRIP_DIR"] = saved

    def test_the_folder_is_read_from_the_strips_state_by_session_id(self):
        folder = self.state("1.json", sessionId="abcd1234-0000-1111-2222-333344445555", cwd=self.proj, updatedAt=5)
        self.assertEqual(self.with_state(folder, lambda: openable.folder_of_session("abcd1234")), self.proj)

    def test_the_newest_state_for_a_session_wins(self):
        self.state("old.json", sessionId="abcd1234-x", cwd="/old/place", updatedAt=1)
        folder = self.state("new.json", sessionId="abcd1234-x", cwd=self.proj, updatedAt=9)
        self.assertEqual(self.with_state(folder, lambda: openable.folder_of_session("abcd1234")), self.proj)

    def test_anything_odd_gives_none(self):
        folder = self.state("1.json", sessionId="abcd1234-x", cwd="relative/dir", updatedAt=1)
        self.state("2.json", sessionId="zzzzzzzz-x", cwd=self.proj)
        touch(os.path.join(folder, "3.json"), "{ not json")
        for sid in ("abcd1234", "nomatch1", "short", "../../x", None, 5, ""):
            self.assertIsNone(self.with_state(folder, lambda: openable.folder_of_session(sid)), sid)
        self.assertIsNone(self.with_state("/nonexistent", lambda: openable.folder_of_session("abcd1234")))

    def test_the_command_finds_files_for_a_session_by_its_id(self):
        want = touch(os.path.join(self.proj, "pkg", "unique-name.ts"))
        folder = self.state("1.json", sessionId="abcd1234-x", cwd=self.proj)
        env = {**os.environ, "HOME": self.home, "CLAUDE_STRIP_DIR": folder}
        run = subprocess.run([TOOL, "resolve", "files", "pkg/unique-name.ts", "--sid", "abcd1234"], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual((run.returncode, json.loads(run.stdout)), (0, {"paths": [want]}))

    def test_memory_is_listed_for_a_session_by_its_id(self):
        key = openable.project_key(self.proj)
        mine = touch(self.h(".claude", "projects", key, "memory", "MEMORY.md"))
        folder = self.state("1.json", sessionId="abcd1234-x", cwd=self.proj)
        env = {**os.environ, "HOME": self.home, "CLAUDE_STRIP_DIR": folder}
        run = subprocess.run([TOOL, "list", "memory", "--sid", "abcd1234"], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual((run.returncode, json.loads(run.stdout)), (0, {"paths": [mine]}))


class HomeWideFd(World):
    """The fd branch: what is asked of fd, and what is done with its answer."""

    def fake_fd(self, answer):
        bindir = os.path.join(self.tmp.name, "fdbin")
        os.makedirs(bindir, exist_ok=True)
        record = os.path.join(self.tmp.name, "fd-args")
        fake = os.path.join(bindir, "fd")
        with open(fake, "w") as f:
            f.write("#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + record + "'\ncat <<'FD_END'\n" + answer + "\nFD_END\n")
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
        return bindir, record

    def test_it_asks_fd_for_hidden_and_ignored_files_minus_the_heavy_and_clauds_own_folders(self):
        want = touch(self.h("Pictures", "shot.png"))
        bindir, record = self.fake_fd(want)
        saved = os.environ["PATH"]
        os.environ["PATH"] = bindir + os.pathsep + saved
        try:
            got = openable.home_wide(["shot.png"], time.monotonic() + 5)
        finally:
            os.environ["PATH"] = saved
        self.assertEqual(got, [want])
        with open(record) as f:
            args = f.read().splitlines()
        for flag in ("--type", "f", "--hidden", "--no-ignore", "--absolute-path", "--full-path", "--max-results", str(openable.COLLECT)):
            self.assertIn(flag, args)
        excluded = {args[i + 1] for i, a in enumerate(args) if a == "--exclude"}
        for must in ("node_modules", ".git", ".cache", ".local", ".claude/plugins", ".claude/projects"):
            self.assertIn(must, excluded)
        self.assertEqual(args[-2:], ["(^|/)shot\\.png$", self.home])     # the label is escaped and anchored; the search is under home

    def test_what_fd_returns_is_still_checked_before_it_is_offered(self):
        inside = touch(self.h("Pictures", "shot.png"))
        bindir, _ = self.fake_fd("\n".join([inside, "/etc/passwd", self.h("missing.png")]))
        saved = os.environ["PATH"]
        os.environ["PATH"] = bindir + os.pathsep + saved
        try:
            self.assertEqual(self.resolve("files", "shot.png"), [inside])
        finally:
            os.environ["PATH"] = saved

    def test_a_failing_fd_gives_nothing_not_a_crash(self):
        bindir = os.path.join(self.tmp.name, "badfd")
        os.makedirs(bindir)
        with open(os.path.join(bindir, "fd"), "w") as f:
            f.write("#!/bin/sh\nexit 3\n")
        os.chmod(os.path.join(bindir, "fd"), 0o755)
        saved = os.environ["PATH"]
        os.environ["PATH"] = bindir + os.pathsep + saved
        try:
            self.assertEqual(openable.home_wide(["x.png"], time.monotonic() + 5), [])
        finally:
            os.environ["PATH"] = saved

    @unittest.skipUnless(shutil.which("fd"), "fd is not installed")
    def test_with_the_real_fd_the_same_answer_comes_back(self):
        want = touch(self.h("Pictures", "Screenshots", "shot.png"))
        touch(self.h(".claude", "plugins", "cache", "Screenshots", "shot.png"))
        touch(self.h("node_modules", "Screenshots", "shot.png"))
        self.assertEqual(self.resolve("files", "Screenshots/shot.png"), [want])


class Memory(World):
    def test_this_projects_own_memory_file_is_the_only_one_offered_when_it_has_one(self):
        key = openable.project_key(self.proj)
        own = touch(self.h(".claude", "projects", key, "memory", "MEMORY.md"))
        touch(self.h(".claude", "projects", "-someone-else", "memory", "MEMORY.md"))
        self.assertEqual(self.resolve("memory", "memory/MEMORY.md"), [own])

    def test_memory_files_of_other_projects_are_still_offered(self):
        other = touch(self.h(".claude", "projects", "-someone-else", "memory", "note.md"))
        self.assertEqual(self.resolve("memory", "memory/note.md"), [other])

    def test_with_no_file_of_its_own_every_projects_matches_are_offered(self):
        a = touch(self.h(".claude", "projects", "-aaa", "memory", "MEMORY.md"))
        b = touch(self.h(".claude", "projects", "-bbb", "memory", "MEMORY.md"))
        self.assertEqual(sorted(self.resolve("memory", "memory/MEMORY.md")), sorted([a, b]))

    def test_the_project_key_matches_how_claude_names_its_folders(self):
        self.assertEqual(openable.project_key("/home/ww/Work/dev/round.house"), "-home-ww-Work-dev-round-house")


class ProjectKeys(World):
    def test_every_plausible_spelling_of_the_project_folder_name_is_tried(self):
        keys = openable.project_keys("/home/ww/Work/my_app v2.0")
        self.assertIn("-home-ww-Work-my_app v2-0", keys)          # the old rule: / and . only
        self.assertIn("-home-ww-Work-my-app-v2-0", keys)          # every non-alphanumeric character
        self.assertIn("-home-ww-Work-my_app-v2-0", keys)          # underscores kept

    def test_memory_of_a_folder_with_an_underscore_is_still_recognised_as_its_own(self):
        proj = os.path.join(self.home, "Work", "my_app")
        os.makedirs(proj)
        own = touch(self.h(".claude", "projects", "-" + proj.strip("/").replace("/", "-").replace("_", "-"), "memory", "MEMORY.md"))
        touch(self.h(".claude", "projects", "-someone-else", "memory", "MEMORY.md"))
        self.assertEqual(openable.resolve("memory", "memory/MEMORY.md", proj, None), [own])


class Skills(World):
    def skill(self, *parts):
        return touch(self.h(*parts, "SKILL.md"))

    def test_a_users_own_skill(self):
        want = self.skill(".claude", "skills", "omarchy")
        self.assertEqual(self.resolve("skills", "omarchy"), [want])

    def test_a_skill_in_the_session_folder(self):
        want = self.skill("Work", "dev", "proj", ".claude", "skills", "local-one")
        self.assertEqual(self.resolve("skills", "local-one"), [want])

    def test_the_users_skill_beats_a_plugins_copy(self):
        mine = self.skill(".claude", "skills", "dup")
        self.skill(".claude", "plugins", "cache", "mk", "pl", "1.0", "skills", "dup")
        self.assertEqual(self.resolve("skills", "dup"), [mine])

    def test_the_installed_copy_beats_the_marketplace_checkout(self):
        installed = self.skill(".claude", "plugins", "cache", "ecc", "ecc", "2.0", "skills", "tdd")
        self.skill(".claude", "plugins", "marketplaces", "ecc", "skills", "tdd")
        self.assertEqual(self.resolve("skills", "ecc:tdd"), [installed])

    def test_other_tools_copies_and_translated_docs_are_left_out_when_a_clean_one_exists(self):
        clean = self.skill(".claude", "plugins", "cache", "ecc", "ecc", "2.0", "skills", "tdd")
        for noisy in ((".kiro", "skills"), (".cursor", "skills"), ("docs", "ja-JP", "skills"), ("tests", "skills")):
            self.skill(".claude", "plugins", "cache", "ecc", "ecc", "2.0", *noisy, "tdd")
        self.assertEqual(self.resolve("skills", "tdd"), [clean])

    def test_noisy_copies_are_used_when_they_are_all_there_is(self):
        only = self.skill(".claude", "plugins", "cache", "ecc", "ecc", "2.0", ".agents", "skills", "tdd")
        self.assertEqual(self.resolve("skills", "tdd"), [only])

    def test_the_plugin_part_of_a_name_picks_that_plugin(self):
        a = self.skill(".claude", "plugins", "cache", "alpha", "alpha", "1", "skills", "same")
        self.skill(".claude", "plugins", "cache", "beta", "beta", "1", "skills", "same")
        self.assertEqual(self.resolve("skills", "alpha:same"), [a])
        self.assertEqual(len(self.resolve("skills", "same")), 2)       # no plugin named: both are offered

    def test_a_skill_that_is_a_symlink_to_another_tools_folder_is_still_found(self):
        with tempfile.TemporaryDirectory() as other:
            touch(os.path.join(other, "omarchy", "SKILL.md"))
            os.makedirs(self.h(".claude", "skills"))
            os.symlink(os.path.join(other, "omarchy"), self.h(".claude", "skills", "omarchy"))
            self.assertEqual(self.resolve("skills", "omarchy"), [self.h(".claude", "skills", "omarchy", "SKILL.md")])

    def test_where_the_users_own_folders_live_never_makes_a_skill_noisy(self):
        proj = os.path.join(self.home, "tests", "app")
        os.makedirs(proj)
        mine = touch(os.path.join(proj, ".claude", "skills", "foo", "SKILL.md"))
        self.skill(".claude", "plugins", "cache", "mk", "pl", "1.0", "skills", "foo")
        self.assertEqual(openable.resolve("skills", "foo", proj, None), [mine])
        self.assertFalse(openable.noisy(mine))

    def test_noisy_is_judged_below_the_plugins_folder_only(self):
        base = self.h(".claude", "plugins", "cache", "ecc", "ecc", "2.0")
        self.assertTrue(openable.noisy(os.path.join(base, ".kiro", "skills", "x", "SKILL.md")))
        self.assertTrue(openable.noisy(os.path.join(base, "docs", "ja", "skills", "x", "SKILL.md")))
        self.assertFalse(openable.noisy(os.path.join(base, "skills", "x", "SKILL.md")))

    def test_names_that_are_not_skill_names_are_refused(self):
        self.skill(".claude", "skills", "good")
        for bad in ("", "a b", "../good", "a/b", "good/", "x" * 81, ":", "ns:", None, 5):
            self.assertEqual(self.resolve("skills", bad), [], bad)

    def test_a_missing_skill_is_an_empty_list(self):
        self.assertEqual(self.resolve("skills", "absent"), [])


class Opening(World):
    def run_open(self, path):
        """Run the real tool with HOME pointing at the fake home and `omarchy` recording its arguments."""
        record = os.path.join(self.tmp.name, "asked")
        if os.path.exists(record):
            os.remove(record)                    # each call sees only its own line
        bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(bindir, exist_ok=True)
        for name, line in (("omarchy", '"$*"'), ("xdg-open", '"xdg-open $*"')):
            fake = os.path.join(bindir, name)
            with open(fake, "w") as f:
                f.write(f"#!/bin/sh\nprintf '%s\\n' {line} >> '{record}'\n")
            os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
        env = {**os.environ, "HOME": self.home, "PATH": bindir + os.pathsep + os.environ["PATH"]}
        run = subprocess.run([TOOL, "open", path], env=env, capture_output=True, text=True, timeout=20)
        asked = []
        if run.returncode == 0:                  # the editor is started detached: wait (up to 10 s) for its record
            deadline = time.monotonic() + 10
            while not os.path.exists(record) and time.monotonic() < deadline:
                time.sleep(0.05)
        if os.path.exists(record):
            with open(record) as f:
                asked = f.read().splitlines()
        return run, asked

    def test_a_file_in_home_is_handed_to_the_editor_and_nothing_else(self):
        path = touch(self.h("notes", "a.md"))
        run, asked = self.run_open(path)
        self.assertEqual((run.returncode, asked), (0, [f"launch editor {path}"]))

    def test_anything_that_is_not_an_existing_file_in_home_is_refused(self):
        touch(self.h("notes", "a.md"))
        os.makedirs(self.h("adir"))
        with tempfile.TemporaryDirectory() as out:
            outside = touch(os.path.join(out, "o.txt"))
            for bad in ("notes/a.md", self.h("missing.txt"), self.h("adir"), outside, "", "-x", self.h("notes", "..", "..", "etc", "passwd")):
                run, asked = self.run_open(bad)
                self.assertEqual((run.returncode, asked), (2, []), bad)

    def test_pictures_video_audio_and_pdfs_go_to_the_default_viewer(self):
        for name in ("shot.png", "a.JPG", "clip.mp4", "song.mp3", "doc.pdf", "photo.heic", "clip.webm"):
            path = touch(self.h("media", name))
            run, asked = self.run_open(path)
            self.assertEqual((run.returncode, asked), (0, [f"xdg-open {path}"]), name)

    def test_everything_else_goes_to_the_editor_and_is_never_run(self):
        for name in ("a.md", "run.sh", "app.desktop", "tool.py", "noext", "data.json", "Makefile", "app.ts", "mod.mts", "x.tsx", "clip.m2ts", "logo.svg"):
            path = touch(self.h("things", name))
            run, asked = self.run_open(path)
            self.assertEqual((run.returncode, asked), (0, [f"launch editor {path}"]), name)

    def test_the_viewer_is_chosen_by_extension_never_by_a_guessed_type(self):
        for name in ("app.ts", "mod.mts", "x.tsx", "logo.svg", "notes.txt", "a.html"):
            self.assertEqual(openable.opener("/h/" + name)[0], "omarchy", name)      # .ts is a video on some systems; svg can run script
        for name in ("a.PNG", "b.jpeg", "c.pdf", "d.mp4"):
            self.assertEqual(openable.opener("/h/" + name)[0], "xdg-open", name)

    def test_a_missing_launcher_is_a_refusal_not_a_traceback(self):
        path = touch(self.h("notes", "a.md"))
        env = {**os.environ, "HOME": self.home, "PATH": "/nonexistent"}
        run = subprocess.run(["/usr/bin/python3", "-I", TOOL, "open", path], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(run.returncode, 2)
        self.assertNotIn("Traceback", run.stderr)

    def test_a_path_with_dots_that_stays_inside_home_is_tidied_not_refused(self):
        path = touch(self.h("notes", "a.md"))
        run, asked = self.run_open(self.h("notes", "sub", "..", "a.md"))
        self.assertEqual((run.returncode, asked), (0, [f"launch editor {path}"]))


class Links(World):
    """A symlink that leads out of the home folder is refused, except where such links are normal."""

    def setUp(self):
        super().setUp()
        self.out = tempfile.TemporaryDirectory()
        self.secret = touch(os.path.join(os.path.realpath(self.out.name), "secret.txt"))

    def tearDown(self):
        self.out.cleanup()
        super().tearDown()

    def test_a_link_in_a_project_to_a_file_outside_home_is_neither_found_nor_opened(self):
        os.makedirs(os.path.join(self.proj, "docs"))
        os.symlink(self.secret, os.path.join(self.proj, "docs", "notes.md"))
        self.assertEqual(self.resolve("files", "docs/notes.md"), [])
        self.assertFalse(openable.usable(os.path.join(self.proj, "docs", "notes.md")))
        self.assertFalse(openable.open_file(os.path.join(self.proj, "docs", "notes.md")))

    def test_a_link_to_a_folder_outside_home_does_not_smuggle_its_files_in(self):
        touch(os.path.join(os.path.realpath(self.out.name), "d", "inner.txt"))
        os.symlink(os.path.join(os.path.realpath(self.out.name), "d"), os.path.join(self.proj, "linked"))
        self.assertFalse(openable.usable(os.path.join(self.proj, "linked", "inner.txt")))

    def test_a_link_to_a_file_inside_home_is_fine(self):
        target = touch(self.h("notes", "real.md"))
        os.symlink(target, os.path.join(self.proj, "alias.md"))
        self.assertEqual(openable.usable(os.path.join(self.proj, "alias.md")), os.path.join(self.proj, "alias.md"))

    def test_skills_and_plugin_folders_may_link_to_another_tools_files(self):
        os.makedirs(self.h(".claude", "skills"))
        os.makedirs(self.h(".claude", "plugins"))
        skill = os.path.join(self.h(".claude", "skills", "linked"), "SKILL.md")
        os.symlink(os.path.dirname(touch(os.path.join(os.path.realpath(self.out.name), "skill", "SKILL.md"))), self.h(".claude", "skills", "linked"))
        os.symlink(self.secret, self.h(".claude", "plugins", "p.md"))
        self.assertEqual(openable.usable(skill), skill)
        self.assertEqual(openable.usable(self.h(".claude", "plugins", "p.md")), self.h(".claude", "plugins", "p.md"))

    def test_elsewhere_under_dot_claude_links_out_of_home_are_refused(self):
        os.makedirs(self.h(".claude", "hooks"))
        os.symlink(self.secret, self.h(".claude", "hooks", "h.js"))
        self.assertFalse(openable.usable(self.h(".claude", "hooks", "h.js")))

    def test_open_refuses_such_a_link_through_the_real_command(self):
        os.makedirs(os.path.join(self.proj, "docs"))
        os.symlink(self.secret, os.path.join(self.proj, "docs", "notes.md"))
        env = {**os.environ, "HOME": self.home}
        run = subprocess.run([TOOL, "open", os.path.join(self.proj, "docs", "notes.md")], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(run.returncode, 2)


class Limits(World):
    def test_the_best_matches_are_found_even_when_a_common_name_occurs_everywhere(self):
        paths = []
        for i in range(45):
            p = touch(os.path.join(self.proj, f"pkg{i:02d}", "index.ts"))
            stamp = time.time() - 10000 + (i * 17) % 45 * 10           # scrambled, so no walk order can match it
            os.utime(p, (stamp, stamp))
            paths.append((stamp, p))
        newest20 = [p for _, p in sorted(paths, reverse=True)[:openable.MAX_PATHS]]
        self.assertEqual(self.resolve("files", "index.ts"), newest20)   # the cap applies after ranking, not during the walk

    def test_the_walk_goes_no_deeper_than_the_limit(self):
        shallow = touch(os.path.join(self.proj, *["d"] * (openable.MAX_DEPTH - 2), "f.txt"))
        touch(os.path.join(self.proj, *["d"] * (openable.MAX_DEPTH + 3), "g.txt"))
        deadline = time.monotonic() + 5
        self.assertEqual(openable.find_files(self.proj, ["f.txt"], deadline), [shallow])
        self.assertEqual(openable.find_files(self.proj, ["g.txt"], deadline), [])

    def test_hidden_folders_are_not_searched_for_the_session_folder(self):
        os.makedirs(self.h(".hidden", "proj"))
        os.makedirs(self.h("a", "b", "proj"))
        self.assertEqual(openable.project_roots(None, "proj")[0].count(".hidden"), 0)
        self.assertEqual(len(openable.project_roots(None, "proj")), 2)       # a/b/proj and Work/dev/proj

    def test_at_most_three_folders_with_the_sessions_name_are_considered(self):
        for i in range(6):
            os.makedirs(self.h(f"dir{i}", "proj"))
        self.assertLessEqual(len(openable.project_roots(None, "proj")), 3)


class ListMemory(World):
    """Clicking Memory lists the project's own memory files, whatever the session has touched."""

    def folder(self, *p):
        return self.h(".claude", "projects", openable.project_key(self.proj), "memory", *p)

    def test_the_index_comes_first_then_the_others_newest_first(self):
        index = touch(self.folder("MEMORY.md"))
        old = touch(self.folder("old_note.md"))
        new = touch(self.folder("new_note.md"))
        os.utime(index, (1000, 1000)); os.utime(old, (2000, 2000)); os.utime(new, (3000, 3000))
        self.assertEqual(openable.list_memory(self.proj, None), [index, new, old])

    def test_notes_in_a_subfolder_are_listed_and_other_file_types_are_not(self):
        sub = touch(self.folder("topics", "deep.md"))
        touch(self.folder("image.png"))
        touch(self.folder("data.json"))
        self.assertEqual(openable.list_memory(self.proj, None), [sub])

    def test_only_this_projects_folder_is_listed(self):
        mine = touch(self.folder("MEMORY.md"))
        touch(self.h(".claude", "projects", "-someone-else", "memory", "MEMORY.md"))
        self.assertEqual(openable.list_memory(self.proj, None), [mine])

    def test_no_memory_folder_or_no_session_folder_is_an_empty_list(self):
        self.assertEqual(openable.list_memory(self.proj, None), [])
        self.assertEqual(openable.list_memory(None, None), [])
        self.assertEqual(openable.list_memory(None, "../proj"), [])

    def test_the_session_folder_may_be_found_by_its_name(self):
        mine = touch(self.folder("MEMORY.md"))
        self.assertEqual(openable.list_memory(None, "proj"), [mine])

    def test_the_list_is_capped_and_a_link_out_of_home_is_left_out(self):
        for i in range(30):
            touch(self.folder(f"note{i:02d}.md"))
        self.assertEqual(len(openable.list_memory(self.proj, None)), openable.MAX_PATHS)
        with tempfile.TemporaryDirectory() as other:
            outside = touch(os.path.join(os.path.realpath(other), "secret.md"))
            os.symlink(outside, self.folder("linked.md"))
            self.assertNotIn(self.folder("linked.md"), openable.list_memory(self.proj, None))

    def test_the_command_prints_the_same_list(self):
        mine = touch(self.folder("MEMORY.md"))
        env = {**os.environ, "HOME": self.home}
        run = subprocess.run([TOOL, "list", "memory", "--cwd", self.proj], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual((run.returncode, json.loads(run.stdout)), (0, {"paths": [mine]}))
        bad = subprocess.run([TOOL, "list", "files"], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(bad.returncode, 2)


class NestedMemory(World):
    def test_a_nested_memory_label_respects_its_folder_part(self):
        key = openable.project_key(self.proj)
        nested = touch(self.h(".claude", "projects", key, "memory", "notes", "x.md"))
        touch(self.h(".claude", "projects", "-other", "memory", "x.md"))
        self.assertEqual(self.resolve("memory", "notes/x.md"), [nested])

    def test_the_memory_folder_itself_matches_the_label_memory_slash_file(self):
        key = openable.project_key(self.proj)
        top = touch(self.h(".claude", "projects", key, "memory", "x.md"))
        touch(self.h(".claude", "projects", key, "memory", "notes", "x.md"))
        self.assertEqual(self.resolve("memory", "memory/x.md"), [top])


class Tasks(World):
    """A background task's output: <scratch>/<project>/<session id>/tasks/<id>.output."""
    SID = "0123abcd-1111-2222-3333-444455556666"

    def out(self, task="bq1", project="-home-x-proj", session=None):
        return os.path.join(self.scratch, project, session or self.SID, "tasks", task + ".output")

    def test_the_output_file_is_found_by_task_id_and_the_first_8_of_the_session_id(self):
        want = touch(self.out())
        touch(self.out("other"))
        self.assertEqual(openable.resolve_task("bq1", "0123abcd"), [want])

    def test_another_session_or_task_or_nothing_finds_nothing(self):
        touch(self.out())
        self.assertEqual(openable.resolve_task("bq1", "ffffffff"), [])
        self.assertEqual(openable.resolve_task("nope", "0123abcd"), [])
        self.assertEqual(openable.resolve_task("bq1", ""), [])

    def test_ids_that_are_not_plain_names_find_nothing(self):
        touch(self.out())
        for task, sid in (("../x", "0123abcd"), ("bq1/../bq1", "0123abcd"), ("", "0123abcd"), ("b" * 65, "0123abcd"),
                          ("bq1", "0123abc"), ("bq1", "../../ab"), (None, "0123abcd"), ("bq1", None)):
            self.assertEqual(openable.resolve_task(task, sid), [], (task, sid))

    def test_a_link_out_of_home_and_scratch_is_refused_but_a_subagent_transcript_in_home_is_fine(self):
        outside = tempfile.TemporaryDirectory()
        target = touch(os.path.join(os.path.realpath(outside.name), "secret.txt"))
        os.makedirs(os.path.dirname(self.out("evil")), exist_ok=True)
        os.symlink(target, self.out("evil"))
        self.assertEqual(openable.resolve_task("evil", "0123abcd"), [])
        outside.cleanup()
        jsonl = touch(self.h(".claude", "projects", "p", self.SID, "subagents", "agent-a1.jsonl"))
        os.makedirs(os.path.dirname(self.out("a1")), exist_ok=True)
        os.symlink(jsonl, self.out("a1"))
        self.assertEqual(openable.resolve_task("a1", "0123abcd"), [self.out("a1")])

    def test_a_scratch_folder_that_is_not_private_is_not_used(self):
        touch(self.out())
        os.chmod(self.scratch, 0o777)
        self.assertEqual(openable.resolve_task("bq1", "0123abcd"), [])

    def test_a_directory_is_not_a_file(self):
        os.makedirs(self.out())
        self.assertEqual(openable.resolve_task("bq1", "0123abcd"), [])

    def test_the_command_prints_the_same_and_a_bad_id_prints_an_empty_list(self):
        want = touch(self.out())
        saved = (openable.HOME, openable.scratch_root)
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = openable.main(["task", "bq1", "--sid", "0123abcd"])
        self.assertEqual((code, json.loads(buf.getvalue())), (0, {"paths": [want]}))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            openable.main(["task", "../x", "--sid", "0123abcd"])
        self.assertEqual(json.loads(buf.getvalue()), {"paths": []})


class Command(unittest.TestCase):
    def run_tool(self, *args):
        return subprocess.run([TOOL, *args], capture_output=True, text=True, timeout=30)

    def test_resolve_prints_one_json_object(self):
        with tempfile.TemporaryDirectory() as home:                     # a fake home: nothing of the machine's own
            skill = touch(os.path.join(home, ".claude", "skills", "mine", "SKILL.md"))
            env = {**os.environ, "HOME": home}
            run = subprocess.run([TOOL, "resolve", "skills", "mine"], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual((run.returncode, json.loads(run.stdout)), (0, {"paths": [os.path.join(os.path.realpath(home), ".claude", "skills", "mine", "SKILL.md")]}))
            none = subprocess.run([TOOL, "resolve", "skills", "no-such-skill-anywhere"], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual((none.returncode, json.loads(none.stdout)), (0, {"paths": []}))

    def test_bad_arguments_exit_2(self):
        for args in ((), ("resolve",), ("resolve", "files"), ("resolve", "agents", "x"), ("resolve", "files", "a/b", "--cwd"),
                     ("resolve", "files", "a/b", "--bogus", "x"), ("open",), ("open", "a", "b"), ("task",), ("task", "x", "--bogus", "y"), ("launch", "x")):
            self.assertEqual(self.run_tool(*args).returncode, 2, args)

    def test_a_relative_cwd_is_ignored(self):
        run = self.run_tool("resolve", "files", "x/y.txt", "--cwd", "relative/dir")
        self.assertEqual(json.loads(run.stdout), {"paths": []})


if __name__ == "__main__":
    unittest.main()
