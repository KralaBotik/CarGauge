#!/usr/bin/env python3
"""Package or validate an unsigned CarGauge IPA without installing Apple tools."""

import argparse
import hashlib
import stat
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory
from zipfile import ZIP_DEFLATED, Path as ZipPath, ZipFile

from validate_project import BASE_BUNDLE_ID, PRODUCTS, check_built_app, require


def validate(ipa, flavor, base_bundle_id):
    app_name = PRODUCTS[flavor] + ".app"
    prefix = f"Payload/{app_name}"
    with ZipFile(ipa) as archive:
        entries = archive.infolist()
        require(entries, "IPA is empty")
        seen = set()
        for entry in entries:
            name = entry.filename.rstrip("/")
            path = PurePosixPath(name)
            require(path.as_posix() == name and "\\" not in name and ".." not in path.parts,
                    f"Invalid IPA entry: {name}")
            require(name == "Payload" or name == prefix or name.startswith(prefix + "/"),
                    f"Unexpected IPA entry: {name}")
            require(name.casefold() not in seen, f"Duplicate IPA entry: {name}")
            seen.add(name.casefold())
            require(not stat.S_ISLNK(entry.external_attr >> 16), f"Unexpected symbolic link: {name}")
            require("_CodeSignature" not in path.parts and "CodeResources" not in path.parts
                    and path.suffix.lower() not in {".mobileprovision", ".provisionprofile", ".p12", ".p8",
                                                    ".pfx", ".pem", ".key", ".cer", ".der"},
                    f"Unexpected signature or signing material: {name}")
            if path.suffix == ".appex":
                require(flavor == "full" and name == f"{prefix}/PlugIns/CarGaugeWidgets.appex",
                        f"Unexpected extension: {name}")
        invalid = archive.testzip()
        require(invalid is None, f"Unreadable IPA entry: {invalid}")
        app = ZipPath(archive) / "Payload" / app_name
        check_built_app(app, flavor, base_bundle_id)
        executables = [f"{prefix}/{PRODUCTS[flavor]}"]
        if flavor == "full":
            executables.append(f"{prefix}/PlugIns/CarGaugeWidgets.appex/CarGaugeWidgets")
        for executable in executables:
            require(archive.getinfo(executable).external_attr & (0o111 << 16), f"Missing execute mode: {executable}")


def package(app, output, flavor, base_bundle_id):
    require(app.is_dir() and not app.is_symlink(), "Expected a built .app directory")
    require(output.suffix == ".ipa", "Output must end in .ipa")
    output.parent.mkdir(parents=True, exist_ok=True)
    prefix = f"Payload/{app.name}"
    with TemporaryDirectory(dir=output.parent) as scratch:
        staged = Path(scratch) / output.name
        with ZipFile(staged, "w", compression=ZIP_DEFLATED) as archive:
            archive.write(app, prefix)
            for path in sorted(app.rglob("*")):
                require(not path.is_symlink() and (path.is_file() or path.is_dir()),
                        f"Unexpected file type in built app: {path}")
                archive.write(path, f"{prefix}/{path.relative_to(app).as_posix()}")
        validate(staged, flavor, base_bundle_id)
        staged.replace(output)
    checksum = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".ipa.sha256").write_text(f"{checksum}  {output.name}\n", encoding="ascii")
    print(f"Packaged {output.name}: {checksum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--app", type=Path, help="Build this IPA from a Release .app directory")
    parser.add_argument("--flavor", choices=PRODUCTS, required=True)
    parser.add_argument("--base-bundle-id", default=BASE_BUNDLE_ID)
    args = parser.parse_args()
    if args.app is None:
        validate(args.ipa, args.flavor, args.base_bundle_id)
    else:
        package(args.app, args.ipa, args.flavor, args.base_bundle_id)


if __name__ == "__main__":
    main()
