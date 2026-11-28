#!/usr/bin/env python3
"""Check the source plists and, when supplied, the compiled iOS app bundle."""

import argparse
import plistlib
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GROUP_KEY = "com.apple.security.application-groups"
GROUP_INFO_KEY = "CarGaugeAppGroup"
GROUP_VARIABLE = "$(CARGAUGE_APP_GROUP)"
WIDGET_POINT = "com.apple.widgetkit-extension"
MIN_IOS = "18.0"
BASE_BUNDLE_ID = "com.cargauge.prototype"
PRODUCTS = {"full": "CarGauge", "basic": "CarGaugeBasic"}


def load(path):
    return plistlib.loads(path.read_bytes())


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def check_app(app):
    require(bool(app.get("NSBluetoothAlwaysUsageDescription")), "App needs a Bluetooth purpose string")
    require(app.get("UIBackgroundModes") == ["bluetooth-central"], "App background modes differ from BLE central")


def check_pair(app, widget):
    require(app.get("NSSupportsLiveActivities") is True, "App must enable Live Activities")
    require(widget.get("NSExtension", {}).get("NSExtensionPointIdentifier") == WIDGET_POINT, "WidgetKit extension point is missing")
    require(not widget.get("UIBackgroundModes"), "Widget must not run BLE tasks")
    require(app.get(GROUP_INFO_KEY) and app[GROUP_INFO_KEY] == widget.get(GROUP_INFO_KEY), "App Group differs between targets")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        require(app.get(key) and app[key] == widget.get(key), f"{key} differs between targets")


def check_basic(app):
    keys = (GROUP_INFO_KEY, GROUP_KEY, "NSSupportsLiveActivities", "NSSupportsLiveActivitiesFrequentUpdates")
    require(not any(key in app for key in keys), "Basic must omit App Groups and Live Activities settings")


def check_executable(executable):
    """Check the app and widget binaries for a thin arm64, unencrypted iPhoneOS build."""
    data = executable.read_bytes()
    name = str(executable)
    require(len(data) >= 32, f"Truncated executable: {name}")
    for fixture in (b"SimulatedTransport", b"--simulation-scenario", b"--adapter-list-fixture", b"--adapter-waiting-fixture", b"--telemetry-history-fixture"):
        require(fixture not in data, f"Test telemetry present in Release executable: {name}")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    require((magic, cpu, kind) == (0xFEEDFACF, 0x100000C, 2), f"Not an arm64 Mach-O executable: {name}")
    offset = 32
    end = offset + size
    require(end <= len(data), f"Invalid Mach-O load commands: {name}")
    versions = []
    for _ in range(count):
        require(offset + 8 <= end, f"Truncated Mach-O load command: {name}")
        command, length = struct.unpack_from("<2I", data, offset)
        require(8 <= length <= end - offset, f"Invalid Mach-O load command size: {name}")
        if command == 0x32:  # LC_BUILD_VERSION
            require(length >= 24, f"Truncated build version: {name}")
            versions.append(struct.unpack_from("<2I", data, offset + 8))
        elif command in {0x21, 0x2C}:  # LC_ENCRYPTION_INFO[_64]
            require(length >= 20 and struct.unpack_from("<I", data, offset + 16)[0] == 0,
                    f"Encrypted executable: {name}")
        require(command != 0x1D, f"Unexpected code signature: {name}")  # LC_CODE_SIGNATURE
        offset += length
    major, minor = map(int, MIN_IOS.split("."))
    require(offset == end and versions == [(2, (major << 16) | (minor << 8))],
            f"Unexpected Mach-O platform or minimum iOS: {name}")


def check_bundle(path, bundle_id, executable, package_type):
    info = load(path / "Info.plist")
    require(info.get("CFBundleIdentifier") == bundle_id, f"Unexpected bundle identifier in {path}")
    require(info.get("CFBundleExecutable") == executable, f"Unexpected executable name in {path}")
    require(info.get("CFBundlePackageType") == package_type, f"Unexpected package type in {path}")
    require(info.get("MinimumOSVersion") == MIN_IOS, f"Unexpected minimum iOS in {path}")
    require(info.get("DTPlatformName") == "iphoneos" and info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
            f"Wrong device platform in {path}")
    require(1 in info.get("UIDeviceFamily", []), f"{path} does not support iPhone")
    binary = path / executable
    require(binary.is_file(), f"Missing {binary}")
    check_executable(binary)
    print(f"{bundle_id}: arm64 iPhoneOS, minimum iOS {MIN_IOS}")
    return info


def check_built_app(path, flavor, base_bundle_id=BASE_BUNDLE_ID):
    product = PRODUCTS[flavor]
    bundle_id = base_bundle_id if flavor == "full" else f"{base_bundle_id}.basic"
    require(path.name == f"{product}.app", f"Unexpected application name for {flavor}")
    app = check_bundle(path, bundle_id, product, "APPL")
    check_app(app)
    require((path / "PrivacyInfo.xcprivacy").is_file(), "The app bundle is missing the privacy manifest")
    plugins = path / "PlugIns"
    if flavor == "full":
        extension = plugins / "CarGaugeWidgets.appex"
        require(plugins.is_dir() and [p.name for p in plugins.iterdir()] == [extension.name],
                "Full IPA must contain exactly the WidgetKit extension")
        widget = check_bundle(extension, f"{bundle_id}.widgets", "CarGaugeWidgets", "XPC!")
        check_pair(app, widget)
        require(app[GROUP_INFO_KEY] == f"group.{bundle_id}", "Unexpected built App Group")
    else:
        check_basic(app)
        require(not plugins.exists(), "Basic must omit PlugIns")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?")
    parser.add_argument("--flavor", choices=PRODUCTS, default="full")
    parser.add_argument("--base-bundle-id", default=BASE_BUNDLE_ID)
    args = parser.parse_args()

    config = ROOT / "Config"
    app = load(config / "App-Info.plist")
    widget = load(config / "Widget-Info.plist")
    basic = load(config / "Basic-Info.plist")
    check_app(app)
    check_pair(app, widget)
    check_app(basic)
    check_basic(basic)
    require(app[GROUP_INFO_KEY] == GROUP_VARIABLE, "App Group must come from the build setting")
    for target in ("App", "Widget"):
        entitlements = load(config / f"{target}.entitlements")
        require(entitlements == {GROUP_KEY: [GROUP_VARIABLE]}, f"Unexpected {target} entitlements")
    privacy = load(ROOT / "App" / "PrivacyInfo.xcprivacy")
    require(
        privacy.get("NSPrivacyAccessedAPITypes") == [{
            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
        }],
        "Declare the required reason for app-local UserDefaults",
    )

    if args.app:
        check_built_app(args.app, args.flavor, args.base_bundle_id)

    print("CarGauge configuration OK")


if __name__ == "__main__":
    main()
