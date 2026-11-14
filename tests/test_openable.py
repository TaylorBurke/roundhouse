"""tools/openable.py: finding the file behind a name on the map, and opening it. Everything runs in a
temporary fake home folder; `omarchy` on PATH is a stand-in that records what it was asked to open."""
import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import tempfile
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

    def tearDown(self):
        openable.HOME = self.saved
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
        self.assertEqual(openable.resolve("files", "docs/guide.md", None, "proj"), [want])
        self.assertEqual(openable.resolve("files", "docs/guide.md", None, "../proj"), [])
        self.assertEqual(openable.resolve("files", "docs/guide.md", None, None), [])

    def test_a_directory_with_the_name_is_not_a_file(self):
        os.makedirs(os.path.join(self.proj, "a", "b.md"))
        self.assertEqual(self.resolve("files", "a/b.md"), [])


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
        bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(bindir, exist_ok=True)
        fake = os.path.join(bindir, "omarchy")
        with open(fake, "w") as f:
            f.write(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{record}'\n")
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
        env = {**os.environ, "HOME": self.home, "PATH": bindir + os.pathsep + os.environ["PATH"]}
        run = subprocess.run([TOOL, "open", path], env=env, capture_output=True, text=True, timeout=20)
        asked = []
        for _ in range(50):                      # the editor is started detached: give it a moment
            if os.path.exists(record):
                with open(record) as f:
                    asked = f.read().splitlines()
                break
            if run.returncode != 0:
                break
            subprocess.run(["sleep", "0.05"])
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

    def test_a_path_with_dots_that_stays_inside_home_is_tidied_not_refused(self):
        path = touch(self.h("notes", "a.md"))
        run, asked = self.run_open(self.h("notes", "sub", "..", "a.md"))
        self.assertEqual((run.returncode, asked), (0, [f"launch editor {path}"]))


class Command(unittest.TestCase):
    def run_tool(self, *args):
        return subprocess.run([TOOL, *args], capture_output=True, text=True, timeout=30)

    def test_resolve_prints_one_json_object(self):
        run = self.run_tool("resolve", "skills", "no-such-skill-anywhere")
        self.assertEqual((run.returncode, json.loads(run.stdout)), (0, {"paths": []}))

    def test_bad_arguments_exit_2(self):
        for args in ((), ("resolve",), ("resolve", "files"), ("resolve", "agents", "x"), ("resolve", "files", "a/b", "--cwd"),
                     ("resolve", "files", "a/b", "--bogus", "x"), ("open",), ("open", "a", "b"), ("launch", "x")):
            self.assertEqual(self.run_tool(*args).returncode, 2, args)

    def test_a_relative_cwd_is_ignored(self):
        run = self.run_tool("resolve", "files", "x/y.txt", "--cwd", "relative/dir")
        self.assertEqual(json.loads(run.stdout), {"paths": []})


if __name__ == "__main__":
    unittest.main()
