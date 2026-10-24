#!/usr/bin/env python3
"""Example Shellder plugin in Python.

stdout: one JSON update per line. stdin: one JSON event per line.
"""
import json
import sys

count = 0


def emit():
    color = "urgent" if count < 0 else "accent" if count > 0 else "foreground"
    print(json.dumps({"text": str(count), "color": color}), flush=True)


emit()
for line in sys.stdin:
    ev = json.loads(line)
    if ev["event"] == "click":
        count += {"left": 1, "right": -1}.get(ev["button"], -count)
    elif ev["event"] == "scroll":
        count += 1 if ev["direction"] == "up" else -1
    emit()
