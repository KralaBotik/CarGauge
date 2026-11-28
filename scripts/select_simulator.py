#!/usr/bin/env python3
"""Pick an available iPhone UUID from xcrun simctl list devices --json."""

import json
import os
import re
import sys

runtime_prefix = "com.apple.CoreSimulator.SimRuntime."
requested = os.environ.get("CARGAUGE_IOS_RUNTIME")
devices_by_runtime = json.load(sys.stdin)["devices"]
candidates = []

for runtime, devices in devices_by_runtime.items():
    name = runtime.removeprefix(runtime_prefix)
    if not runtime.startswith(runtime_prefix) or not re.fullmatch(r"iOS-[0-9]+(?:-[0-9]+)+", name):
        continue
    if requested and requested != name:
        continue
    version = tuple(map(int, name.removeprefix("iOS-").split("-")))
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((version, device["state"] == "Booted", device["name"], runtime, device["udid"]))

if not candidates:
    sys.exit(f"No available iPhone simulator for {requested or 'any iOS runtime'}")
print(max(candidates)[-2 if "--runtime-id" in sys.argv else -1])
