#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "iOS builds require Xcode on macOS." >&2
  exit 1
fi

mkdir -p .artifacts
output="$(mktemp -d "$PWD/.artifacts/ios.XXXXXX")"
derived="$output/DerivedData"

{
  xcodebuild -version
  python3 scripts/validate_project.py
  xcodegen generate --spec project.yml
} 2>&1 | tee "$output/CarGauge-Setup.log"

status=0
if simulator="$(xcrun simctl list devices available --json | python3 scripts/select_simulator.py)"; then
  if ! xcodebuild -project CarGauge.xcodeproj -scheme CarGauge \
    -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath "$derived" -parallel-testing-enabled NO \
    -resultBundlePath "$output/CarGauge-UI.xcresult" test \
    2>&1 | tee "$output/CarGauge-Simulator.log"; then
    status=1
  fi
else
  status=1
fi

if xcodebuild -project CarGauge.xcodeproj -scheme CarGauge -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  -resultBundlePath "$output/CarGauge-Device.xcresult" CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee "$output/CarGauge-Device.log"; then
  app="$derived/Build/Products/Release-iphoneos/CarGauge.app"
  python3 scripts/validate_project.py "$app" 2>&1 | tee -a "$output/CarGauge-Device.log"
  ditto -c -k --keepParent "$app" "$output/CarGauge-unsigned.zip"
else
  status=1
fi
echo "iOS results: $output"
exit "$status"
