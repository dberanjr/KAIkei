import importlib.util, json, os, shlex, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("install_advisor", os.path.join(HERE, "install_advisor.py"))
ia = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ia)

def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f)


def read_json(path):
    with open(path) as f:
        return json.load(f)


BIN = "/home/u/.kaikei/bin/kaikei-advise"
OTHER_HOOK = {"hooks": [{"type": "command", "command": "echo other"}]}
STATUS = {"type": "command", "command": "bash '/x/it'\\''s.sh'", "padding": 1}


class InstallTests(unittest.TestCase):
    def test_adds_the_hook_and_keeps_the_others(self):
        s = {"hooks": {"UserPromptSubmit": [OTHER_HOOK], "Stop": [OTHER_HOOK]}, "model": "sonnet"}
        new, _ = ia.install(s, BIN)
        groups = new["hooks"]["UserPromptSubmit"]
        self.assertEqual(groups[0], OTHER_HOOK)
        self.assertEqual(groups[1]["hooks"][0]["command"], f"{BIN} prompt")
        self.assertEqual(groups[1]["hooks"][0]["timeout"], 5)
        self.assertEqual(new["hooks"]["Stop"], [OTHER_HOOK])
        self.assertEqual(new["model"], "sonnet")

    def test_creates_hooks_in_an_empty_file(self):
        new, _ = ia.install({}, BIN)
        self.assertEqual(len(new["hooks"]["UserPromptSubmit"]), 1)
        self.assertEqual(new["statusLine"], {"type": "command", "command": f"{BIN} statusline"})

    def test_wraps_the_existing_status_line_command_exactly(self):
        new, _ = ia.install({"statusLine": STATUS}, BIN)
        words = shlex.split(new["statusLine"]["command"])
        self.assertEqual(words[:2], [BIN, "statusline"])
        self.assertEqual(words[words.index("--then") + 1], STATUS["command"])   # quotes and all
        self.assertEqual(new["statusLine"]["padding"], 1)

    def test_installing_twice_changes_nothing(self):
        once, _ = ia.install({"statusLine": STATUS}, BIN)
        twice, notes = ia.install(once, BIN)
        self.assertEqual(once, twice)
        self.assertTrue(all("already" in n for n in notes))

    def test_uninstall_restores_the_original_file(self):
        s = {"hooks": {"UserPromptSubmit": [OTHER_HOOK]}, "statusLine": STATUS}
        new, _ = ia.install(s, BIN)
        back, _ = ia.uninstall(new)
        self.assertEqual(back, s)

    def test_uninstall_drops_what_it_added_to_an_empty_file(self):
        new, _ = ia.install({}, BIN)
        back, _ = ia.uninstall(new)
        self.assertEqual(back, {})

    def test_uninstall_without_us_changes_nothing(self):
        s = {"hooks": {"UserPromptSubmit": [OTHER_HOOK]}, "statusLine": STATUS}
        self.assertEqual(ia.uninstall(s)[0], s)


class FileTests(unittest.TestCase):
    def run_script(self, *args):
        return subprocess.run([sys.executable, "-I", os.path.join(HERE, "install_advisor.py"), *args], capture_output=True, text=True)

    def test_writes_a_backup_and_the_new_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "settings.json")
            write_json(path, {"model": "sonnet"})
            r = self.run_script("--settings", path, "--bin", BIN)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(len([f for f in os.listdir(d) if "kaikei-backup" in f]), 1)
            self.assertIn("UserPromptSubmit", read_json(path)["hooks"])

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "settings.json")
            write_json(path, {"model": "sonnet"})
            self.run_script("--settings", path, "--bin", BIN, "--dry-run")
            self.assertEqual(read_json(path), {"model": "sonnet"})
            self.assertEqual(os.listdir(d), ["settings.json"])


if __name__ == "__main__":
    unittest.main()
