#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "iOS builds require Xcode on macOS." >&2
  exit 1
fi

flavor="${1:-full}"
case "$flavor" in
  full) scheme=CarGauge; ipa=CarGauge-Full-unsigned.ipa ;;
  basic) scheme=CarGaugeBasic; ipa=CarGauge-Basic-unsigned.ipa ;;
  *) echo "Usage: scripts/ci-ios.sh [full|basic]" >&2; exit 2 ;;
esac

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
  if ! xcodebuild -project CarGauge.xcodeproj -scheme "$scheme" \
    -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath "$derived" -parallel-testing-enabled NO \
    -resultBundlePath "$output/CarGauge-UI.xcresult" test \
    2>&1 | tee "$output/CarGauge-Simulator.log"; then
    status=1
  fi
else
  status=1
fi

if xcodebuild -project CarGauge.xcodeproj -scheme "$scheme" -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  -resultBundlePath "$output/CarGauge-Device.xcresult" CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee "$output/CarGauge-Device.log"; then
  if [[ "$status" -eq 0 ]]; then
    app="$derived/Build/Products/Release-iphoneos/$scheme.app"
    python3 scripts/package_ipa.py --flavor "$flavor" --app "$app" "$output/$ipa" \
      2>&1 | tee -a "$output/CarGauge-Device.log"
  fi
else
  status=1
fi
echo "iOS results: $output"
exit "$status"
