#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
HOOK = ROOT / "trafficlight-codex-hook"


class CodexHookTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.log = root / "trafficlight.log"
        self.state = root / "state"
        self.fake_cli = root / "trafficlight"
        self.fake_cli.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$TRAFFICLIGHT_TEST_LOG\"\n")
        self.fake_cli.chmod(0o755)
        self.environment = {
            **os.environ,
            "TRAFFICLIGHT_BIN": str(self.fake_cli),
            "TRAFFICLIGHT_TEST_LOG": str(self.log),
            "TRAFFICLIGHT_HOOK_STATE_DIR": str(self.state),
            "TRAFFICLIGHT_KEEPALIVE_INTERVAL_SECONDS": "0.05",
            "TRAFFICLIGHT_KEEPALIVE_MAX_SECONDS": "5",
        }

    def tearDown(self):
        self.emit({"hook_event_name": "SessionEnd", "session_id": "session-1"})
        self.temporary.cleanup()

    def emit(self, event):
        subprocess.run([sys.executable, str(HOOK)], input=json.dumps(event), text=True,
                       env=self.environment, check=True, capture_output=True)

    def commands(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def wait_for(self, predicate):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail(f"timed out; commands: {self.commands()}")

    def test_keeps_heartbeat_until_stop(self):
        event = {"hook_event_name": "UserPromptSubmit", "session_id": "session-1", "turn_id": "turn-1"}
        self.emit(event)
        identifier = "codex:session-1:turn-1"
        self.wait_for(lambda: sum(command == f"heartbeat --id {identifier}" for command in self.commands()) >= 2)

        self.emit({**event, "hook_event_name": "Stop"})
        self.wait_for(lambda: f"done --id {identifier} --result success" in self.commands())
        self.assertFalse(list(self.state.glob("*.json")))

    def test_interrupt_finishes_only_current_turn(self):
        first = {"hook_event_name": "UserPromptSubmit", "session_id": "session-1", "turn_id": "turn-1"}
        second = {"hook_event_name": "UserPromptSubmit", "session_id": "session-1", "turn_id": "turn-2"}
        self.emit(first)
        self.emit(second)
        self.emit({**first, "hook_event_name": "Interrupt"})

        first_id = "codex:session-1:turn-1"
        second_id = "codex:session-1:turn-2"
        self.wait_for(lambda: f"done --id {first_id} --result fail" in self.commands())
        records = [json.loads(path.read_text()) for path in self.state.glob("*.json")]
        self.assertEqual([second_id], [record["task_id"] for record in records])
        self.emit({**second, "hook_event_name": "Stop"})


if __name__ == "__main__":
    unittest.main()
