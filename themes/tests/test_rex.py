"""Проверки публичного CLI на изолированных пользовательских конфигах."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / "rex.py"


class RexTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {**os.environ, "XDG_CONFIG_HOME": str(self.root)}
        self.source = self.root / "source.json"
        self.themes = [{"id": "dark", "name": "Dark", "source": {
            "background": "#010203", "foreground": "#fefdfc", "cursor": "#112233",
            "cursorText": "#445566", "selectionBackground": "#778899",
            "selectionForeground": "#aabbcc", "ansi": [f"#{i:06x}" for i in range(16)]}}]
        self.source.write_text(json.dumps(self.themes))
        (self.root / "agterm").mkdir()

    def run_cli(self, *args, success=True):
        result = subprocess.run([sys.executable, str(CLI), *args, "--no-reload"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        return result

    def test_install_apply_reset_preserves_user_config_and_symlink(self):
        original = 'font-size = 16\n# Моя настройка\n'
        target = self.root / "my-config"
        target.write_text(original)
        target.chmod(0o640)
        config = self.root / "agterm/ghostty.conf"
        config.symlink_to(target)
        keymap = self.root / "agterm/keymap.conf"
        keymap.write_text('command "Mine" echo mine\n')
        self.run_cli("install", "--source", str(self.source))
        first = keymap.read_text()
        self.run_cli("install", "--source", str(self.source))
        self.assertEqual(first, keymap.read_text())
        self.assertTrue(first.startswith('command "Mine" echo mine\n'))
        self.run_cli("apply", "dark")
        self.assertIn("background = #010203\n", target.read_text())
        self.assertIn("palette = 15=#00000f\n", target.read_text())
        self.assertTrue(config.is_symlink())
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)
        self.run_cli("reset")
        self.assertEqual(target.read_text(), original)
        self.assertEqual(self.run_cli("list").stdout, "dark\tDark\n")

    def test_bad_colors_and_traversal_do_not_write(self):
        for key, value in [("id", "../escape"), ("name", 'Bad"\ncommand "X" touch /tmp/x')]:
            bad = json.loads(json.dumps(self.themes))
            bad[0][key] = value
            self.source.write_text(json.dumps(bad))
            self.run_cli("install", "--source", str(self.source), success=False)
        self.themes[0]["source"]["ansi"][3] = "#fff\nshell-command = evil"
        self.source.write_text(json.dumps(self.themes))
        self.run_cli("install", "--source", str(self.source), success=False)
        self.assertFalse((self.root / "agterm/keymap.conf").exists())
        self.assertFalse((self.root / "agterm-kit").exists())

    def test_broken_markers_and_unknown_theme_preserve_files(self):
        keymap = self.root / "agterm/keymap.conf"
        keymap.write_text("# agterm-kit:rex begin\nMine\n")
        self.run_cli("install", "--source", str(self.source), success=False)
        self.assertEqual(keymap.read_text(), "# agterm-kit:rex begin\nMine\n")
        keymap.write_text("")
        self.run_cli("install", "--source", str(self.source))
        self.run_cli("apply", "../source.json", success=False)
        self.assertFalse((self.root / "agterm/ghostty.conf").exists())


if __name__ == "__main__":
    unittest.main()
