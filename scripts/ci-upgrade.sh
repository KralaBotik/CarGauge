#!/usr/bin/env bash
set -euo pipefail

simulator="$1"
output="$2"
derived="$3"
old="$output/Legacy"
bundle=com.cargauge.prototype
base=7d6e89cd0a67dfc91c328fa146101d45a10aa7d6

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
python3 - "$before" "$bundle" "$old/Sources/CarGaugeCore/TelemetryArchive.swift" <<'PY'
import json
import plistlib
import re
import sqlite3
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
source = Path(sys.argv[3]).read_text()
schema = re.search(r'private static let schema = """(.*?)"""', source, re.S).group(1)
history = Path(sys.argv[1]) / "Library" / "Application Support" / "CarGauge" / "History.sqlite3"
history.parent.mkdir(parents=True, exist_ok=True)
with sqlite3.connect(history) as db:
    db.executescript(schema)
    db.executescript("""
    PRAGMA user_version = 1;
    INSERT INTO trip(id,owner,started_utc,last_utc,finish) VALUES(908,'upgrade-ci',100,105,'engine_stopped');
    INSERT INTO frame(id,trip_id,utc,elapsed,observed,km,base_litres,litres,idle,discontinuous)
      VALUES(909,908,104,4,4,.04,.001,.002,0,0);
    INSERT INTO reading(frame_id,signal,utc,offset,value,quality,bytes)
      VALUES(909,5,103.75,-.25,90,'received','82');
    INSERT INTO fill(id,start_utc,end_utc,km,litres,base_litres,engine_seconds,fuel_seconds,paired_km)
      VALUES(1,20,99,300,24,20,500,500,298);
    """)
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

for app, version in zip(sys.argv[1:3], ["0.8.0", "0.9.0"], strict=True):
    info = plistlib.loads((Path(app) / "Info.plist").read_bytes())
    assert info["CFBundleShortVersionString"] == version and info["CFBundleIdentifier"] == sys.argv[4]
p = plistlib.loads((Path(sys.argv[3]) / "Library" / "Preferences" / (sys.argv[4] + ".plist")).read_bytes())
assert p["appearance"] == "light" and p["autoConnect"] is False and p["autoLiveActivity"] is True
assert json.loads(p["verifiedOBDAdapter"])["id"] == "00000000-0000-0000-0000-000000000001"
assert json.loads(p["thermalThresholds"])["warning"] == 108
assert json.loads(p["verifiedOBDAdapter"])["name"] == "Vgate iCar Pro BLE (CI)"
print("VERIFIED: CarGauge 0.8.0 -> 0.9.0 update preserved preferences and verified adapter")
PY
xcodebuild -project CarGauge.xcodeproj -scheme CarGauge -configuration Release \
  -destination "platform=iOS Simulator,arch=arm64,id=$simulator" \
  -derivedDataPath "$derived" -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES \
  -resultBundlePath "$output/CarGauge-ReleaseUpgrade.xcresult" \
  -only-testing:CarGaugeUITests/DashboardUITests/testReleaseUpgradeRetainsPreferences test


python3 - "$after" <<'PY'
import sqlite3
import sys
from pathlib import Path

history = Path(sys.argv[1]) / "Library" / "Application Support" / "CarGauge" / "History.sqlite3"
with sqlite3.connect(history.as_uri() + "?mode=ro", uri=True) as db:
    assert db.execute("PRAGMA user_version").fetchone() == (2,)
    assert db.execute("PRAGMA quick_check").fetchone() == ("ok",)
    assert db.execute("SELECT owner, finish FROM trip WHERE id=908").fetchone() == ("upgrade-ci", "engine_stopped")
    assert db.execute("SELECT value, bytes FROM reading WHERE frame_id=909").fetchone() == (90.0, "82")
    assert db.execute("SELECT km,litres,base_litres FROM fill").fetchone() == (300.0, 24.0, 20.0)
print("VERIFIED: 0.8 SQLite trip, raw PID and fuel calibration survived app upgrade")
PY
