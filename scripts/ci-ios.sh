#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "iOS builds require Xcode on macOS." >&2
  exit 1
fi

flavor="${1:-full}"
case "$flavor" in
  full) scheme=CarGauge; test_target=CarGaugeUITests; ipa=CarGauge-Full-unsigned.ipa ;;
  basic) scheme=CarGaugeBasic; test_target=CarGaugeBasicUITests; ipa=CarGauge-Basic-unsigned.ipa ;;
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
devices="$(xcrun simctl list devices available --json)"
if simulator="$(printf '%s\n' "$devices" | python3 scripts/select_simulator.py)"; then
  runtime="$(printf '%s\n' "$devices" | python3 scripts/select_simulator.py --runtime-id)"
  if compact="$(xcrun simctl create 'CarGauge iPhone 11' com.apple.CoreSimulator.SimDeviceType.iPhone-11 "$runtime")"; then
    simulator="$compact"
    echo "Using iPhone 11 simulator on $runtime"
  else
    echo "iPhone 11 unavailable on $runtime; using the installed iPhone simulator"
  fi
  xcrun simctl bootstatus "$simulator" -b
  run_debug_ui() {
    local result="$1" log="$2"
    xcodebuild -project CarGauge.xcodeproj -scheme "$scheme" \
      -destination "platform=iOS Simulator,arch=arm64,id=$simulator" \
      -derivedDataPath "$derived" -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES \
      -resultBundlePath "$output/$result.xcresult" test 2>&1 | tee "$output/$log"
  }
  if ! run_debug_ui CarGauge-UI CarGauge-Simulator.log; then
    status=1
    if python3 scripts/xctest_simulator_failure.py "$output/CarGauge-Simulator.log"; then
      echo "Retrying once after an XCTest automation failure. Initial logs and results are retained."
      xcrun simctl bootstatus "$simulator" -b
      if run_debug_ui CarGauge-UIRetry CarGauge-Simulator-Retry.log; then status=0; fi
    fi
  fi
  if [[ "$status" -eq 0 ]]; then
    if ! xcodebuild -project CarGauge.xcodeproj -scheme "$scheme" -configuration Release \
      -destination "platform=iOS Simulator,arch=arm64,id=$simulator" \
      -derivedDataPath "$derived" -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES \
      -resultBundlePath "$output/CarGauge-ReleaseUI.xcresult" \
      "-only-testing:$test_target/DashboardUITests/testReleaseIgnoresTestLaunchFlags" test \
      2>&1 | tee "$output/CarGauge-ReleaseUI.log"; then
      status=1
    elif [[ "$flavor" == full ]]; then
      if ! scripts/ci-upgrade.sh "$simulator" "$output" "$derived" 2>&1 | tee "$output/CarGauge-Upgrade.log"; then
        status=1
      fi
    fi
  fi
  for result in CarGauge-UI CarGauge-UIRetry CarGauge-ReleaseUI CarGauge-ReleaseUpgrade; do
    if [[ -d "$output/$result.xcresult" ]]; then
      attachments="$output/screenshots/$result"
      mkdir -p "$attachments"
      xcrun xcresulttool export attachments --path "$output/$result.xcresult" \
        --output-path "$attachments" || echo "Screenshots are available in the xcresult bundle."
      python3 scripts/name_screenshots.py "$attachments" "$output/gallery"
    fi
  done
else
  status=1
fi

if xcodebuild -project CarGauge.xcodeproj -scheme "$scheme" -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  -resultBundlePath "$output/CarGauge-Device.xcresult" CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee "$output/CarGauge-Device.log"; then
  if [[ "$status" -eq 0 ]]; then
    app="$derived/Build/Products/Release-iphoneos/$scheme.app"
    test -f "$app/Assets.car"
    if [[ ! -s "$app/Metadata.appintents/extract.actionsdata" ]]; then
      echo "Release build is missing the Open Instruments shortcut metadata." | tee -a "$output/CarGauge-Device.log"
      exit 1
    fi
    python3 scripts/package_ipa.py --flavor "$flavor" --app "$app" "$output/$ipa" \
      2>&1 | tee -a "$output/CarGauge-Device.log"
  fi
else
  status=1
fi
echo "iOS results: $output"
exit "$status"
