#!/usr/bin/env python3
"""Pick an available iPhone UUID from xcrun simctl list devices --json."""

import json
import os
import sys

runtime_prefix = "com.apple.CoreSimulator.SimRuntime."
requested = os.environ.get("CARGAUGE_IOS_RUNTIME")
devices_by_runtime = json.load(sys.stdin)["devices"]
candidates = []

for runtime, devices in devices_by_runtime.items():
    name = runtime.removeprefix(runtime_prefix)
    if not name.startswith("iOS-") or (requested and requested != name):
        continue
    version = tuple(map(int, name.removeprefix("iOS-").split("-")))
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((version, device["state"] == "Booted", device["name"], device["udid"]))

if not candidates:
    sys.exit(f"No available iPhone simulator for {requested or 'any iOS runtime'}")
print(max(candidates)[-1])
