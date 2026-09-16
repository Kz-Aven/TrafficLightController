import importlib.util
import pathlib
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("trafficlight_mcp", pathlib.Path(__file__).with_name("trafficlight_mcp.py"))
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


class TrafficLightMCPTests(unittest.TestCase):
    @patch.object(MCP, "call_cli", return_value={"ok": True, "state": "orange"})
    def test_start_task_generates_id(self, call_cli):
        result = MCP.tool_call("start_task", {"name": "测试"})
        self.assertTrue(result["ok"])
        self.assertEqual(call_cli.call_args.args[0][0], "start")

    @patch.object(MCP, "call_cli", return_value={"ok": True, "state": "green"})
    def test_complete_task_forwards_result(self, call_cli):
        MCP.tool_call("complete_task", {"id": "a", "result": "success"})
        self.assertEqual(call_cli.call_args.args[0], ["done", "--id", "a", "--result", "success"])


if __name__ == "__main__":
    unittest.main()
