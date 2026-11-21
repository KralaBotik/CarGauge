#!/usr/bin/env bash
set -euo pipefail

simulator="$1"
output="$2"
derived="$3"
old="$output/Legacy"
bundle=com.cargauge.prototype
base=841c88911cf28f9becbe945f8539ef104bdaa3e0

mkdir -p "$old"
git archive "$base" | tar -xf - -C "$old"
(cd "$old" && xcodegen generate --spec project.yml)
xcodebuild -project "$old/CarGauge.xcodeproj" -scheme CarGauge -configuration Release \
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$old/DerivedData" build

# Reuse only the disposable simulator created by CI. Install the old product first.
xcrun simctl uninstall "$simulator" "$bundle"
old_app="$old/DerivedData/Build/Products/Release-iphonesimulator/CarGauge.app"
new_app="$derived/Build/Products/Release-iphonesimulator/CarGauge.app"
xcrun simctl install "$simulator" "$old_app"
before="$(xcrun simctl get_app_container "$simulator" "$bundle" data)"
python3 - "$before" "$bundle" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

destination = Path(sys.argv[1]) / "Library" / "Preferences" / (sys.argv[2] + ".plist")
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(plistlib.dumps({
    "appearance": "light",
    "autoConnect": False,
    "autoLiveActivity": True,
    "selectedBLEPeripheral": "00000000-0000-0000-0000-000000000001",
    "thermalThresholds": json.dumps({"operating": 80, "warning": 108, "critical": 115}).encode(),
}))
PY
xcrun simctl launch "$simulator" "$bundle"
xcrun simctl terminate "$simulator" "$bundle"

# Update in place under the same bundle ID and confirm the seeded defaults survive.
xcrun simctl install "$simulator" "$new_app"
after="$(xcrun simctl get_app_container "$simulator" "$bundle" data)"
python3 - "$old_app" "$new_app" "$after" "$bundle" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

for app, version in zip(sys.argv[1:3], ["0.3.0", "0.4.0"], strict=True):
    info = plistlib.loads((Path(app) / "Info.plist").read_bytes())
    assert info["CFBundleShortVersionString"] == version and info["CFBundleIdentifier"] == sys.argv[4]
p = plistlib.loads((Path(sys.argv[3]) / "Library" / "Preferences" / (sys.argv[4] + ".plist")).read_bytes())
assert p["appearance"] == "light" and p["autoConnect"] is False and p["autoLiveActivity"] is True
assert p["selectedBLEPeripheral"] == "00000000-0000-0000-0000-000000000001"
assert json.loads(p["thermalThresholds"])["warning"] == 108
assert "verifiedOBDAdapter" not in p
print("VERIFIED: Full 0.3.0 -> 0.4.0 update preserved preferences and tentative adapter")
PY
xcodebuild -project CarGauge.xcodeproj -scheme CarGauge -configuration Release \
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$derived" -parallel-testing-enabled NO \
  -resultBundlePath "$output/CarGauge-ReleaseUpgrade.xcresult" \
  -only-testing:CarGaugeUITests/DashboardUITests/testReleaseUpgradeRetainsLegacyPreferences test
