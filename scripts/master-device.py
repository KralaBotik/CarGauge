#!/usr/bin/env python3
"""Build and validate an unsigned Release IPA and record the measured stages."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


PRODUCTS = {"basic": "CarGaugeBasic", "full": "CarGauge"}
MAX_LOG_BYTES = 8 * 1024 * 1024


def checked(arguments, source):
    return subprocess.check_output(arguments, cwd=source, text=True, timeout=12).strip()


def capture(arguments, source, log):
    with subprocess.Popen(arguments, cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as command:
        remaining = MAX_LOG_BYTES
        while chunk := command.stdout.read(65536):
            log.write(chunk[:remaining])
            remaining -= min(len(chunk), remaining)
        if remaining == 0:
            log.write(b"\n[build log truncated]\n")
        if status := command.wait():
            raise SystemExit(status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("flavor", choices=PRODUCTS)
    parser.add_argument("phase", choices=("cold", "warm"))
    args = parser.parse_args()
    source = args.source.resolve()
    workspace = source / ".artifacts/master-device" / args.flavor
    derived = workspace / "DerivedData"
    cold = args.phase == "cold"
    if derived.exists() == cold:
        parser.error("cold needs fresh DerivedData and warm needs the same existing DerivedData")
    output = workspace / args.phase
    output.mkdir(parents=True, exist_ok=False)
    export = output / "export"
    export.mkdir()
    scheme = PRODUCTS[args.flavor]
    ipa = export / "CarGauge.ipa"
    log_path = export / "build.log"
    tools = {
        "xcode": checked(["xcodebuild", "-version"], source),
        "sdk": checked(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], source),
        "xcodegen": checked(["xcodegen", "--version"], source),
        "host_arch": os.uname().machine,
    }
    commit = checked(["git", "rev-parse", "HEAD"], source)
    with log_path.open("wb") as log:
        started = time.monotonic()
        capture(["python3", "scripts/validate_project.py"], source, log)
        capture(["xcodegen", "generate", "--spec", "project.yml"], source, log)
        setup = time.monotonic()
        capture(["xcodebuild", "-project", "CarGauge.xcodeproj", "-scheme", scheme,
                 "-configuration", "Release", "-destination", "generic/platform=iOS",
                 "-derivedDataPath", str(derived), "-resultBundlePath", str(export / "build.xcresult"),
                 "CODE_SIGNING_ALLOWED=NO", "build"], source, log)
        compiled = time.monotonic()
        app = derived / "Build/Products/Release-iphoneos" / (scheme + ".app")
        if not (app / "Assets.car").is_file() or not (app / "Metadata.appintents/extract.actionsdata").stat().st_size:
            raise SystemExit("Release resources or Open Instruments shortcut metadata are missing")
        capture(["python3", "scripts/package_ipa.py", "--flavor", args.flavor, "--app", str(app), str(ipa)], source, log)
    timing = {
        "commit": commit, "flavor": args.flavor, "phase": args.phase, "tools": tools,
        "setup_seconds": round(setup - started, 3),
        "compile_seconds": round(compiled - setup, 3),
        "package_seconds": round(time.monotonic() - compiled, 3),
        "ipa_sha256": hashlib.file_digest(ipa.open("rb"), "sha256").hexdigest(),
        "ipa_bytes": ipa.stat().st_size,
    }
    (export / "receipt.json").write_text(json.dumps(timing, indent=2) + "\n")
    print(json.dumps(timing), flush=True)


if __name__ == "__main__":
    main()
