#!/usr/bin/env python3
"""Merge TrafficLight lifecycle hooks into a WorkBuddy settings file."""

import json
import os
import sys
from pathlib import Path


EVENTS = ("UserPromptSubmit", "PostToolUse", "Stop", "Interrupt", "SessionEnd")


def contains_command(groups, command):
    return any(
        hook.get("command") == command
        for group in groups
        for hook in group.get("hooks", [])
        if hook.get("type") == "command"
    )


def main():
    settings_path = Path(sys.argv[1])
    command = sys.argv[2]
    settings = {}
    if settings_path.exists():
        with settings_path.open() as file:
            settings = json.load(file)

    hooks = settings.setdefault("hooks", {})
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not contains_command(groups, command):
            groups.append({"hooks": [{"type": "command", "command": command}]})

    settings_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = settings_path.with_suffix(".json.trafficlight-tmp")
    with temporary_path.open("w") as file:
        json.dump(settings, file, ensure_ascii=False, indent=2)
        file.write("\n")
    os.replace(temporary_path, settings_path)


if __name__ == "__main__":
    main()
