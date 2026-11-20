#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "iOS builds require Xcode on macOS." >&2
  exit 1
fi

xcodebuild -version
xcodegen generate --spec project.yml
simulator="$(xcrun simctl list devices available --json | python3 scripts/select_simulator.py)"
mkdir -p .artifacts
output="$(mktemp -d "$PWD/.artifacts/ios.XXXXXX")"
derived="$output/DerivedData"

xcodebuild -project CarGauge.xcodeproj -scheme CarGauge \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$derived" -parallel-testing-enabled NO \
  -resultBundlePath "$output/CarGauge-UI.xcresult" test

xcodebuild -project CarGauge.xcodeproj -scheme CarGauge -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO build

app="$derived/Build/Products/Release-iphoneos/CarGauge.app"
test -d "$app/PlugIns/CarGaugeWidgets.appex"
python3 scripts/validate_project.py "$app"
ditto -c -k --keepParent "$app" "$output/CarGauge-unsigned.zip"
echo "iOS results: $output"
