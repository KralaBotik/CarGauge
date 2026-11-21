#!/usr/bin/env python3
"""Allow one CI retry for specific hosted Simulator/XCTest automation failures."""
import re
import sys
from pathlib import Path

infra_errors = (
    r"Failed to terminate com\.cargauge\.prototype",
    r"Application 'com\.cargauge\.prototype(?:\.basic)?' does not have a process ID",
    r"Failed to get matching snapshots: Timed out while evaluating UI query\.",
)
failure_line = re.compile(r"\.swift:\d+(?::\d+)?: error: (.+)$")
failures = [match[1] for line in Path(sys.argv[1]).read_text(errors="replace").splitlines()
            if (match := failure_line.search(line))]
raise SystemExit(0 if failures and all(any(re.search(reason, failure) for reason in infra_errors)
                                       for failure in failures) else 1)
