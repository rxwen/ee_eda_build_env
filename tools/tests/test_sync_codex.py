import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest


TOOLS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("sync_codex", TOOLS / "sync-codex.py")
sync_codex = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync_codex)


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="eda project ")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.config = self.repo / ".codex/config.toml"
        self.config.parent.mkdir()
        self.original = '# custom settings\nmodel = "custom-model"\n[mcp_servers.other]\nurl = "https://example.test/mcp"\n'
        self.config.write_text(self.original)
        self.server = {
            "type": "stdio", "command": 'C:\\EDA tools\\node.exe',
            "args": [str(self.repo / '测试 "quoted"/index.js')],
            "env": {"PYTHONPATH": "path with spaces", "SPECIAL": "line1\nline2\\end"},
        }
        self.write_source({"kicad": self.server})
        self.skill = self.repo / ".claude/skills/example"
        self.skill.mkdir(parents=True)
        (self.skill / "SKILL.md").write_text("shared skill")

    def write_source(self, servers):
        (self.repo / ".mcp.json").write_text(json.dumps({"mcpServers": servers}))

    def test_shared_paths_preservation_idempotence(self):
        sync_codex.sync(self.repo)
        first = self.config.read_bytes()
        self.assertTrue(first.decode().startswith(self.original))
        parsed = tomllib.loads(first.decode())
        self.assertEqual(parsed["model"], "custom-model")
        self.assertEqual(parsed["mcp_servers"]["kicad"], {
            **{k: v for k, v in self.server.items() if k != "type"}, "enabled": True,
        })
        link = self.repo / ".agents/skills/example"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), self.skill.resolve())
        (self.skill / "SKILL.md").write_text("updated")
        self.assertEqual((link / "SKILL.md").read_text(), "updated")
        sync_codex.sync(self.repo)
        self.assertEqual(self.config.read_bytes(), first)
        sync_codex.sync(self.repo, check=True)

    def test_check_does_not_write(self):
        with self.assertRaises(ValueError):
            sync_codex.sync(self.repo, check=True)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertFalse((self.repo / ".agents").exists())

    def test_removal_and_update(self):
        sync_codex.sync(self.repo)
        self.write_source({"konnect": {"command": "/project/konnect", "args": ["--config", "/project/config"]}})
        sync_codex.sync(self.repo)
        servers = tomllib.loads(self.config.read_text())["mcp_servers"]
        self.assertNotIn("kicad", servers)
        self.assertTrue(servers["konnect"]["enabled"])
        self.assertIn("other", servers)

    def test_conflict_preserves_files(self):
        text = self.original + '\n[mcp_servers."kicad"]\ncommand = "custom"\n'
        self.config.write_text(text)
        with self.assertRaises(ValueError):
            sync_codex.sync(self.repo)
        self.assertEqual(self.config.read_text(), text)
        self.assertFalse((self.repo / ".agents").exists())

    def test_invalid_input_preserves_config(self):
        for invalid in ('{"broken":', '{"mcpServers":{"kicad":{"command":42}}}'):
            (self.repo / ".mcp.json").write_text(invalid)
            with self.assertRaises(ValueError):
                sync_codex.sync(self.repo)
            self.assertEqual(self.config.read_text(), self.original)

    def test_skill_conflict_preserved(self):
        target = self.repo / ".agents/skills/example"
        target.mkdir(parents=True)
        (target / "SKILL.md").write_text("user content")
        with self.assertRaises(ValueError):
            sync_codex.sync(self.repo)
        self.assertEqual((target / "SKILL.md").read_text(), "user content")
        self.assertEqual(self.config.read_text(), self.original)

    def test_shell_config_only_and_check(self):
        tools = self.repo / "tools"
        tools.mkdir()
        for name in ("init-eda-env.sh", "sync-codex.py"):
            (tools / name).write_bytes((TOOLS / name).read_bytes())
        command = ["bash", str(tools / "init-eda-env.sh"), "--sync-config-only"]
        self.assertNotEqual(subprocess.run(command + ["--check"], capture_output=True).returncode, 0)
        subprocess.run(command, check=True, capture_output=True)
        subprocess.run(command + ["--check"], check=True, capture_output=True)
        self.assertFalse((self.repo / ".claude/vendor").exists())


if __name__ == "__main__":
    unittest.main()
