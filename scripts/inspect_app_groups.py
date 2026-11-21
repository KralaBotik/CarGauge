#!/usr/bin/env python3
"""Report only the App Groups evidence in a signed CarGauge IPA."""
import argparse
import json
import plistlib
import struct
import subprocess
from zipfile import ZipFile

from validate_project import GROUP_INFO_KEY, GROUP_KEY


def signed_entitlements(binary):
    if binary[:4] != b"\xcf\xfa\xed\xfe":
        return {}, "unsupported-binary"
    count, length = struct.unpack_from("<II", binary, 16)
    position, end = 32, 32 + length
    for _ in range(count):
        if position + 8 > min(len(binary), end):
            raise ValueError("truncated load command")
        kind, size = struct.unpack_from("<II", binary, position)
        if not 8 <= size <= end - position:
            raise ValueError("invalid load command length")
        if kind == 0x1D and size >= 16:
            offset, length = struct.unpack_from("<II", binary, position + 8)
            return read_entitlement_blob(binary[offset:offset + length])
        position += size
    return {}, "unsigned"


def read_entitlement_blob(signature):
    magic, total, count = struct.unpack_from(">III", signature)
    if magic != 0xFADE0CC0 or total > len(signature) or 12 + count * 8 > total:
        raise ValueError("invalid signature SuperBlob")
    includes_der = False
    for index in range(count):
        slot, offset = struct.unpack_from(">II", signature, 12 + index * 8)
        if slot == 7:
            includes_der = True
        if slot != 5:
            continue
        blob_type, size = struct.unpack_from(">II", signature, offset)
        if blob_type != 0xFADE7171 or size < 8 or offset + size > total:
            raise ValueError("invalid XML entitlement blob")
        return plistlib.loads(signature[offset + 8:offset + size]), "xml"
    return {}, "der-only" if includes_der else "missing"


def inspect_bundle(archive, info_path, openssl):
    prefix = info_path.rsplit("/", 1)[0] + "/"
    info = plistlib.loads(archive.read(info_path))
    group = info.get(GROUP_INFO_KEY)
    binary = archive.read(prefix + info["CFBundleExecutable"])
    signature, signature_status = signed_entitlements(binary)
    try:
        profile = archive.read(prefix + "embedded.mobileprovision")
    except KeyError:
        provisioning, profile_status = {}, "missing"
    else:
        try:
            decoded = subprocess.run(
                [openssl, "cms", "-verify", "-noverify", "-inform", "DER"],
                input=profile, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, timeout=15,
            )
            provisioning, profile_status = plistlib.loads(decoded.stdout)["Entitlements"], "decoded"
        except (OSError, subprocess.SubprocessError, ValueError, KeyError):
            provisioning, profile_status = {}, "unreadable"
    return {
        "group_matches_signature": bool(group and group in signature.get(GROUP_KEY, [])),
        "group_matches_profile": bool(group and group in provisioning.get(GROUP_KEY, [])),
        "signature": signature_status,
        "profile": profile_status,
    }, group


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--openssl", default="openssl")
    args = parser.parse_args()
    try:
        with ZipFile(args.ipa) as archive:
            (app_path,) = [name for name in archive.namelist()
                           if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2]
            (widget_path,) = [name for name in archive.namelist()
                              if name.startswith(app_path.removesuffix("Info.plist") + "PlugIns/")
                              and name.endswith(".appex/Info.plist")]
            app, app_group = inspect_bundle(archive, app_path, args.openssl)
            widget, widget_group = inspect_bundle(archive, widget_path, args.openssl)
    except (OSError, ValueError, KeyError, struct.error) as error:
        parser.exit(2, f"Cannot inspect Full IPA ({type(error).__name__}).\n")
    matches = bool(app_group and app_group == widget_group)
    verified = matches and all(details[key] for details in (app, widget)
                               for key in ("group_matches_signature", "group_matches_profile"))
    print(json.dumps({"plist_groups_match": matches, "app": app, "widget": widget,
                      "status": "VERIFIED" if verified else "UNVERIFIED"}, indent=2))
    return 0 if verified else 1


if __name__ == "__main__":
    raise SystemExit(main())
