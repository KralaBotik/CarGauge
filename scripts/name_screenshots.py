#!/usr/bin/env python3
"""Copy named XCTest screenshots from xcresulttool's attachment export."""
import json
import re
import shutil
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
manifest = source / "manifest.json"
if manifest.is_file():
    destination.mkdir(parents=True, exist_ok=True)
    for test in json.loads(manifest.read_text()):
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "")
            match = re.match(r"((?:\d{2}-|Release-)[A-Za-z-]+)_\d+_.*\.png$", name)
            if match and not attachment.get("isAssociatedWithFailure"):
                original = source / Path(attachment["exportedFileName"]).name
                shutil.copyfile(original, destination / f"{match[1]}.png")
