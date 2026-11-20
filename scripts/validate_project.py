#!/usr/bin/env python3
"""Check the source plists and, when supplied, the compiled iOS app bundle."""

import argparse
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GROUP_KEY = "com.apple.security.application-groups"
GROUP_INFO_KEY = "CarGaugeAppGroup"
GROUP_VARIABLE = "$(CARGAUGE_APP_GROUP)"
WIDGET_POINT = "com.apple.widgetkit-extension"


def load(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def check_pair(app, widget):
    require(bool(app.get("NSBluetoothAlwaysUsageDescription")), "App needs a Bluetooth purpose string")
    require(app.get("UIBackgroundModes") == ["bluetooth-central"], "App background modes differ from BLE central")
    require(app.get("NSSupportsLiveActivities") is True, "App must enable Live Activities")
    require(widget.get("NSExtension", {}).get("NSExtensionPointIdentifier") == WIDGET_POINT, "WidgetKit extension point is missing")
    require(not widget.get("UIBackgroundModes"), "Widget must not run BLE tasks")
    require(app.get(GROUP_INFO_KEY) and app[GROUP_INFO_KEY] == widget.get(GROUP_INFO_KEY), "App Group differs between targets")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        require(app.get(key) and app[key] == widget.get(key), f"{key} differs between targets")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?")
    args = parser.parse_args()

    config = ROOT / "Config"
    app = load(config / "App-Info.plist")
    widget = load(config / "Widget-Info.plist")
    check_pair(app, widget)
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
        app = load(args.app / "Info.plist")
        extension = args.app / "PlugIns" / "CarGaugeWidgets.appex"
        widget = load(extension / "Info.plist")
        check_pair(app, widget)
        bundle_id = app["CFBundleIdentifier"]
        require("$" not in bundle_id and widget["CFBundleIdentifier"] == f"{bundle_id}.widgets", "Unexpected built bundle identifiers")
        require(app[GROUP_INFO_KEY] == f"group.{bundle_id}", "Unexpected built App Group")
        for path, info in ((args.app, app), (extension, widget)):
            require((path / info["CFBundleExecutable"]).is_file(), f"Missing executable in {path}")
            require(info.get("DTPlatformName") == "iphoneos", f"{path} was not built for iPhone")
        require((args.app / "PrivacyInfo.xcprivacy").is_file(), "The app bundle is missing the privacy manifest")

    print("CarGauge configuration OK")


if __name__ == "__main__":
    main()
