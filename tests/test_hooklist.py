"""tools/hooklist.py: the configured hooks, listed from a fake home (settings.json and plugin hooks.json)."""
import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "hooklist.py")
_loader = importlib.machinery.SourceFileLoader("hooklist", TOOL)
_spec = importlib.util.spec_from_loader("hooklist", _loader)
hooklist = importlib.util.module_from_spec(_spec)
_loader.exec_module(hooklist)
EMIT = os.path.join(ROOT, "hooks", "emit.py")


def write(path, text="x", mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)
    return path


def group(command, matcher=None):
    g = {"hooks": [{"type": "command", "command": command}]}
    if matcher is not None:
        g["matcher"] = matcher
    return g


class World(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.outside = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self.tmp.name)
        self.cfg = os.path.join(self.home, ".claude")
        self.env = {k: os.environ.get(k) for k in ("HOME", "CLAUDE_CONFIG_DIR")}
        os.environ["HOME"] = self.home
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        self.saved = (hooklist.openable.HOME, hooklist.openable.scratch_root)
        hooklist.openable.HOME = self.home
        hooklist.openable.scratch_root = lambda: os.path.join(self.home, "no-scratch")

    def tearDown(self):
        hooklist.openable.HOME, hooklist.openable.scratch_root = self.saved
        for k, v in self.env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()
        self.outside.cleanup()

    def settings(self, hooks, name="settings.json"):
        return write(os.path.join(self.cfg, name), json.dumps({"hooks": hooks}))

    def by_event(self, event):
        return [e for e in hooklist.list_hooks() if e["event"] == event]


class Settings(World):
    def test_a_hook_with_a_script_lists_event_matcher_and_script(self):
        script = write(os.path.join(self.cfg, "hooks", "guard.py"))
        src = self.settings({"PreToolUse": [group("python3 %s --token=SECRET" % script, "Bash")]})
        [e] = hooklist.list_hooks()
        self.assertEqual((e["event"], e["matcher"], e["script"], e["source"], e["own"]),
                         ("PreToolUse", "Bash", script, src, False))
        self.assertEqual(e["command"], "python3")

    def test_no_argument_or_secret_ever_appears_in_the_listing(self):
        script = write(os.path.join(self.cfg, "hooks", "g.sh"))
        self.settings({"Stop": [group("API_KEY=hunter2 %s --password=hunter3 'a b'" % script)],
                       "SessionEnd": [group("curl -H 'Authorization: Bearer hunter4' https://x.example/h")]})
        text = json.dumps(hooklist.list_hooks())
        for secret in ("hunter2", "hunter3", "hunter4", "Bearer", "https://", "password"):
            self.assertNotIn(secret, text)
        [stop] = self.by_event("Stop")
        self.assertEqual(stop["command"], "g.sh")                    # the env assignment is skipped, no arguments

    def test_tilde_and_home_are_expanded(self):
        a = write(os.path.join(self.cfg, "hooks", "a.sh"))
        b = write(os.path.join(self.cfg, "hooks", "b.sh"))
        self.settings({"Stop": [group("~/.claude/hooks/a.sh"), group("$HOME/.claude/hooks/b.sh x")]})
        self.assertEqual(sorted(e["script"] for e in hooklist.list_hooks()), [a, b])

    def test_a_command_with_no_file_falls_back_to_the_settings_file(self):
        src = self.settings({"Stop": [group("echo done"), group("/home/nobody/missing.sh")]})
        es = hooklist.list_hooks()
        self.assertEqual([e["script"] for e in es], ["", ""])
        self.assertEqual([e["source"] for e in es], [src, src])

    def test_a_shell_variable_is_not_expanded(self):
        write(os.path.join(self.cfg, "hooks", "a.sh"))
        self.settings({"Stop": [group("$SOMETHING/hooks/a.sh"), group("$CLAUDE_PLUGIN_ROOT/hooks/a.sh")]})
        self.assertEqual([e["script"] for e in hooklist.list_hooks()], ["", ""])

    def test_the_config_dir_variable_is_honoured(self):
        other = os.path.join(self.home, "elsewhere")
        write(os.path.join(other, "settings.json"), json.dumps({"hooks": {"Stop": [group("echo x")]}}))
        self.settings({"Start": [group("echo y")]})
        os.environ["CLAUDE_CONFIG_DIR"] = other
        self.assertEqual([e["event"] for e in hooklist.list_hooks()], ["Stop"])

    def test_events_come_out_sorted_and_several_hooks_per_group_are_kept(self):
        self.settings({"Stop": [{"hooks": [{"command": "a"}, {"command": "b"}]}],
                       "PreToolUse": [group("c", "Edit|Write")]})
        es = hooklist.list_hooks()
        self.assertEqual([(e["event"], e["command"]) for e in es], [("PreToolUse", "c"), ("Stop", "a"), ("Stop", "b")])


class Own(World):
    def test_roundhouses_own_entries_are_marked(self):
        self.settings({"Stop": [group(EMIT)], "SessionEnd": [group(EMIT + " --x")], "PreToolUse": [group("/usr/bin/true")]})
        own = {e["event"]: e["own"] for e in hooklist.list_hooks()}
        self.assertEqual(own, {"Stop": True, "SessionEnd": False, "PreToolUse": False})   # arguments: not the plain entry

    def test_another_folders_emit_py_is_not_ours(self):
        other = write(os.path.join(self.home, "other", "hooks", "emit.py"))
        self.settings({"Stop": [group(other)]})
        self.assertFalse(hooklist.list_hooks()[0]["own"])

    def test_a_symlink_to_our_emit_py_counts(self):
        link = os.path.join(self.home, "link", "hooks")
        os.makedirs(os.path.dirname(link))
        os.symlink(os.path.dirname(EMIT), link)
        self.settings({"Stop": [group(os.path.join(link, "emit.py"))]})
        self.assertTrue(hooklist.list_hooks()[0]["own"])


class Plugins(World):
    def plugin(self, name, hooks, wrapped=True):
        path = os.path.join(self.cfg, "plugins", "cache", "mk", name, "1.0", "hooks", "hooks.json")
        write(path, json.dumps({"hooks": hooks} if wrapped else hooks))
        return path

    def test_a_plugin_hook_with_plugin_root_resolves_to_its_script(self):
        path = self.plugin("p", {"PostToolUse": [group("${CLAUDE_PLUGIN_ROOT}/scripts/run.sh", "Write")]})
        script = write(os.path.join(os.path.dirname(os.path.dirname(path)), "scripts", "run.sh"))
        [e] = hooklist.list_hooks()
        self.assertEqual((e["event"], e["matcher"], e["script"], e["source"]), ("PostToolUse", "Write", script, path))

    def test_a_hooks_json_without_the_wrapper_is_read_too(self):
        self.plugin("p", {"Stop": [group("echo x")]}, wrapped=False)
        self.assertEqual([e["event"] for e in hooklist.list_hooks()], ["Stop"])

    def test_malformed_and_odd_files_are_skipped_without_an_error(self):
        write(os.path.join(self.cfg, "settings.json"), "{ not json")
        write(os.path.join(self.cfg, "plugins", "cache", "mk", "a", "1.0", "hooks", "hooks.json"), "[1, 2]")
        write(os.path.join(self.cfg, "plugins", "cache", "mk", "b", "1.0", "hooks", "hooks.json"), '{"hooks": {"Stop": "no"}}')
        write(os.path.join(self.cfg, "plugins", "cache", "mk", "c", "1.0", "hooks", "hooks.json"), '{"hooks": {"Stop": [{"hooks": [{"command": 5}, 7]}, 3]}}')
        write(os.path.join(self.cfg, "plugins", "cache", "mk", "d", "1.0", "hooks", "hooks.json"), "\xff\xfe", None)
        self.plugin("ok", {"Stop": [group("echo fine")]})
        self.assertEqual([e["command"] for e in hooklist.list_hooks()], ["echo"])

    def test_missing_files_give_an_empty_list(self):
        self.assertEqual(hooklist.list_hooks(), [])
        os.makedirs(self.cfg)
        self.assertEqual(hooklist.list_hooks(), [])

    def test_a_hooks_json_that_is_a_symlink_out_gets_no_source(self):
        target = write(os.path.join(self.outside.name, "hooks.json"), json.dumps({"hooks": {"Stop": [group("echo a")]}}))
        link = os.path.join(self.cfg, "plugins", "cache", "mk", "lnk", "1.0", "hooks", "hooks.json")
        os.makedirs(os.path.dirname(link))
        os.symlink(target, link)                       # links under plugins are normal: it is listed and may open
        [e] = hooklist.list_hooks()
        self.assertEqual(e["source"], link)

    def test_a_folder_link_is_not_followed(self):
        write(os.path.join(self.outside.name, "hooks.json"), json.dumps({"hooks": {"Stop": [group("echo a")]}}))
        os.makedirs(os.path.join(self.cfg, "plugins", "cache"))
        os.symlink(self.outside.name, os.path.join(self.cfg, "plugins", "cache", "dirlink"))
        self.assertEqual(hooklist.list_hooks(), [])


class Outside(World):
    def test_a_script_outside_the_home_folder_is_not_a_target(self):
        out = write(os.path.join(self.outside.name, "evil.sh"))
        self.settings({"Stop": [group(out)]})
        self.assertEqual(hooklist.list_hooks()[0]["script"], "")

    def test_a_script_that_is_a_symlink_out_of_home_is_not_a_target(self):
        out = write(os.path.join(self.outside.name, "evil.sh"))
        link = os.path.join(self.home, "bin", "evil.sh")
        os.makedirs(os.path.dirname(link))
        os.symlink(out, link)
        self.settings({"Stop": [group(link)]})
        self.assertEqual(hooklist.list_hooks()[0]["script"], "")

    def test_a_script_that_is_a_directory_is_not_a_target(self):
        os.makedirs(os.path.join(self.cfg, "hooks", "dir"))
        self.settings({"Stop": [group(os.path.join(self.cfg, "hooks", "dir"))]})
        self.assertEqual(hooklist.list_hooks()[0]["script"], "")

    def test_a_symlinked_settings_file_pointing_out_is_listed_with_no_source(self):
        out = write(os.path.join(self.outside.name, "s.json"), json.dumps({"hooks": {"Stop": [group("echo a")]}}))
        os.makedirs(self.cfg)
        os.symlink(out, os.path.join(self.cfg, "settings.json"))
        [e] = hooklist.list_hooks()
        self.assertEqual(e["source"], "")


class Interpreters(World):
    def test_the_script_after_an_interpreter_is_the_target_not_the_interpreter(self):
        uv = write(os.path.join(self.home, ".local", "bin", "uv"), "#!/bin/sh\n", 0o755)
        py = write(os.path.join(self.home, "proj", ".venv", "bin", "python"), "#!/bin/sh\n", 0o755)
        script = write(os.path.join(self.home, "x", "script.py"), "print(1)\n")
        self.settings({"Stop": [group("%s run %s --flag" % (uv, script))],
                       "PreToolUse": [group("%s -u %s arg" % (py, script))],
                       "SessionEnd": [group("/usr/bin/env python3 %s" % script)]})
        self.assertEqual([e["script"] for e in hooklist.list_hooks()], [script] * 3)

    def test_inline_code_is_no_script_and_falls_back_to_the_source(self):
        py = write(os.path.join(self.home, "bin", "python3"), "#!/bin/sh\n", 0o755)
        other = write(os.path.join(self.home, "x", "data.txt"))
        src = self.settings({"Stop": [group("%s -c 'print(1)' %s" % (py, other))]})
        [e] = hooklist.list_hooks()
        self.assertEqual((e["script"], e["source"]), ("", src))

    def test_a_compiled_program_is_not_a_script(self):
        prog = write(os.path.join(self.home, "bin", "tool"), "\x7fELF\0\0\0binary")
        src = self.settings({"Stop": [group(prog + " go")]})
        [e] = hooklist.list_hooks()
        self.assertEqual((e["script"], e["source"]), ("", src))


class Kinds(World):
    def test_a_prompt_agent_or_http_hook_is_a_row_that_opens_the_source(self):
        src = self.settings({"Stop": [{"matcher": "x", "hooks": [{"type": "prompt", "prompt": "SECRET text"},
                                                                  {"type": "agent", "prompt": "p"},
                                                                  {"type": "http", "url": "https://u.example/?k=SECRET"}]}]})
        es = hooklist.list_hooks()
        self.assertEqual(sorted(e["command"] for e in es), ["agent hook", "http hook", "prompt hook"])
        self.assertTrue(all(e["source"] == src and e["script"] == "" and e["matcher"] == "x" for e in es))
        self.assertNotIn("SECRET", json.dumps(es))

    def test_an_unknown_handler_type_is_dropped(self):
        self.settings({"Stop": [{"hooks": [{"type": "weird"}]}]})
        self.assertEqual(hooklist.list_hooks(), [])


class Sources(World):
    def test_settings_local_json_is_read_too(self):
        a = self.settings({"Stop": [group("echo a")]})
        b = self.settings({"PreToolUse": [group("echo b")]}, "settings.local.json")
        self.assertEqual({e["event"]: e["source"] for e in hooklist.list_hooks()}, {"Stop": a, "PreToolUse": b})

    def test_the_same_hook_in_two_files_is_listed_once(self):
        self.settings({"Stop": [group("echo a")]})
        self.settings({"Stop": [group("echo a")]}, "settings.local.json")
        self.assertEqual(len(hooklist.list_hooks()), 1)

    def test_a_project_settings_file_is_not_read(self):
        write(os.path.join(self.home, "proj", ".claude", "settings.json"), json.dumps({"hooks": {"Stop": [group("echo p")]}}))
        self.assertEqual(hooklist.list_hooks(), [])

    def test_every_file_unreadable_is_an_error_not_an_empty_list(self):
        write(os.path.join(self.cfg, "settings.json"), "{ nope")
        with self.assertRaises(hooklist.Unreadable):
            hooklist.list_hooks()


class Installed(World):
    def install(self, name, version, hooks, enabled=True):
        mk, plug = name.split("@")[1], name.split("@")[0]
        root = os.path.join(self.cfg, "plugins", "cache", mk, plug, version)
        write(os.path.join(root, "hooks", "hooks.json"), json.dumps({"hooks": hooks}))
        return root

    def register(self, entries, enabled):
        write(os.path.join(self.cfg, "plugins", "installed_plugins.json"),
              json.dumps({"version": 2, "plugins": {n: [{"scope": "user", "installPath": p, "version": "x"}] for n, p in entries.items()}}))
        write(os.path.join(self.cfg, "settings.json"), json.dumps({"enabledPlugins": enabled}))

    def test_only_installed_and_enabled_plugins_and_only_the_installed_version(self):
        new = self.install("a@mk", "2.0", {"Stop": [group("echo new")]})
        self.install("a@mk", "1.0", {"Stop": [group("echo old")]})                     # a stale version
        off = self.install("b@mk", "1.0", {"Stop": [group("echo off")]})
        self.install("c@mk", "1.0", {"Stop": [group("echo unregistered")]})
        write(os.path.join(self.cfg, "plugins", "marketplaces", "mk", "x", "hooks", "hooks.json"),
              json.dumps({"hooks": {"Stop": [group("echo market")]}}))
        self.register({"a@mk": new, "b@mk": off}, {"a@mk": True, "b@mk": False})
        self.assertEqual([e["command"] for e in hooklist.list_hooks()], ["echo"])
        self.assertEqual(len(hooklist.list_hooks()), 1)
        self.assertIn("/2.0/", hooklist.list_hooks()[0]["source"])

    def test_without_the_registry_the_newest_version_of_each_plugin_wins(self):
        old = self.install("a@mk", "1.0", {"Stop": [group("echo old")]})
        new = self.install("a@mk", "2.0", {"PreToolUse": [group("echo new")]})
        os.utime(old, (1000, 1000))
        os.utime(new, (2000, 2000))
        self.assertEqual([e["event"] for e in hooklist.list_hooks()], ["PreToolUse"])

    def test_an_install_path_outside_the_plugins_folder_is_ignored(self):
        write(os.path.join(self.outside.name, "hooks", "hooks.json"), json.dumps({"hooks": {"Stop": [group("echo x")]}}))
        self.register({"a@mk": self.outside.name}, {"a@mk": True})
        self.assertEqual(hooklist.list_hooks(), [])


class Caps(World):
    def test_own_entries_never_push_real_ones_out_and_the_cap_holds(self):
        saved = hooklist.MAX_ENTRIES
        hooklist.MAX_ENTRIES = 5
        try:
            hooks = {"E%02d" % i: [group("echo %d" % i)] for i in range(12)}
            hooks["Stop"] = [group(EMIT)]
            self.settings(hooks)
            es = hooklist.list_hooks()
            self.assertEqual(len([e for e in es if not e["own"]]), 5)
            self.assertEqual(len([e for e in es if e["own"]]), 1)
            self.assertEqual([e["event"] for e in es if not e["own"]], ["E00", "E01", "E02", "E03", "E04"])   # after sorting
        finally:
            hooklist.MAX_ENTRIES = saved


class Errors(World):
    def test_a_failure_prints_an_error_object_and_exits_1(self):
        write(os.path.join(self.cfg, "settings.json"), "{ nope")
        env = {**os.environ, "HOME": self.home}
        r = subprocess.run(["python3", "-I", TOOL, "list"], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(list(json.loads(r.stdout)), ["error"])

    def test_nothing_configured_is_an_empty_list_and_exit_0(self):
        env = {**os.environ, "HOME": self.home}
        r = subprocess.run(["python3", "-I", TOOL, "list"], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual((r.returncode, json.loads(r.stdout)), (0, []))


class Open(World):
    def setUp(self):
        super().setUp()
        self.bin = os.path.join(self.home, "fakebin")
        self.log = os.path.join(self.home, "opened.txt")
        write(os.path.join(self.bin, "omarchy"), '#!/bin/sh\nprintf "%%s\\n" "$3" >> "%s"\n' % self.log, 0o755)
        self.script = write(os.path.join(self.cfg, "hooks", "guard.py"))
        self.src = self.settings({"Stop": [group("python3 " + self.script)]})

    def run_tool(self, *args):
        env = {**os.environ, "HOME": self.home, "PATH": self.bin + ":" + os.environ["PATH"], "XDG_RUNTIME_DIR": self.home}
        return subprocess.run(["python3", "-I", TOOL, *args], env=env, capture_output=True, text=True, timeout=20)

    def opened(self):
        import time
        for _ in range(40):
            if os.path.exists(self.log):
                break
            time.sleep(0.05)
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().split()

    def test_list_prints_json_and_exits_0(self):
        r = self.run_tool("list")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)[0]["script"], self.script)

    def test_a_listed_script_and_the_settings_file_open(self):
        self.assertEqual(self.run_tool("open", self.script).returncode, 0)
        self.assertEqual(self.run_tool("open", self.src).returncode, 0)
        self.assertEqual(sorted(self.opened()), sorted([self.script, self.src]))

    def test_a_path_that_is_not_listed_is_refused_even_inside_home(self):
        other = write(os.path.join(self.home, "notes.txt"))
        r = self.run_tool("open", other)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.opened(), [])

    def test_a_listed_path_that_now_points_outside_is_refused(self):
        out = write(os.path.join(self.outside.name, "x.sh"))
        os.remove(self.script)
        os.symlink(out, self.script)                    # swapped for a link out after listing
        r = self.run_tool("open", self.script)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.opened(), [])

    def test_bad_arguments_exit_2(self):
        for args in ([], ["open"], ["open", "relative"], ["list", "x"], ["nope"]):
            self.assertEqual(self.run_tool(*args).returncode, 2, args)

    def test_nothing_is_written_to_the_config(self):
        before = {p: os.stat(p).st_mtime_ns for p in (self.src, self.script)}
        self.run_tool("list")
        self.run_tool("open", self.src)
        self.assertEqual(before, {p: os.stat(p).st_mtime_ns for p in (self.src, self.script)})


if __name__ == "__main__":
    unittest.main()
