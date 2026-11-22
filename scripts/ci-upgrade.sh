#!/usr/bin/env bash
set -euo pipefail

simulator="$1"
output="$2"
derived="$3"
old="$output/Legacy"
bundle=com.cargauge.prototype
base=7b1c9fe46121a3efc77ea8e3761c03c5c39e0dd0

mkdir -p "$old"
git archive "$base" | tar -xf - -C "$old"
(cd "$old" && xcodegen generate --spec project.yml)
xcodebuild -project "$old/CarGauge.xcodeproj" -scheme CarGauge -configuration Release \
  -destination "platform=iOS Simulator,arch=arm64,id=$simulator" \
  -derivedDataPath "$old/DerivedData" ONLY_ACTIVE_ARCH=YES build

# Reuse only the disposable simulator created by CI. Install the old product first.
xcrun simctl bootstatus "$simulator" -b
if xcrun simctl get_app_container "$simulator" "$bundle" data >/dev/null 2>&1; then
  xcrun simctl uninstall "$simulator" "$bundle"
fi
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
    "verifiedOBDAdapter": json.dumps({"id": "00000000-0000-0000-0000-000000000001", "name": "Vgate iCar Pro BLE (CI)"}).encode(),
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

for app, version in zip(sys.argv[1:3], ["0.5.0", "0.6.0"], strict=True):
    info = plistlib.loads((Path(app) / "Info.plist").read_bytes())
    assert info["CFBundleShortVersionString"] == version and info["CFBundleIdentifier"] == sys.argv[4]
p = plistlib.loads((Path(sys.argv[3]) / "Library" / "Preferences" / (sys.argv[4] + ".plist")).read_bytes())
assert p["appearance"] == "light" and p["autoConnect"] is False and p["autoLiveActivity"] is True
assert json.loads(p["verifiedOBDAdapter"])["id"] == "00000000-0000-0000-0000-000000000001"
assert json.loads(p["thermalThresholds"])["warning"] == 108
assert json.loads(p["verifiedOBDAdapter"])["name"] == "Vgate iCar Pro BLE (CI)"
print("VERIFIED: Full 0.5.0 -> 0.6.0 update preserved preferences and verified adapter")
PY
xcodebuild -project CarGauge.xcodeproj -scheme CarGauge -configuration Release \
  -destination "platform=iOS Simulator,arch=arm64,id=$simulator" \
  -derivedDataPath "$derived" -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES \
  -resultBundlePath "$output/CarGauge-ReleaseUpgrade.xcresult" \
  -only-testing:CarGaugeUITests/DashboardUITests/testReleaseUpgradeRetainsPreferences test
