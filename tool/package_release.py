#!/usr/bin/env python3
"""Package all runtime files and attach SHA-256 checksums; never publish/sign."""

import hashlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path


def apk_is_signed(path):
    """True when the APK has a v1 (JAR) signature or an APK Signing Block (v2+).

    This detects presence only. It does not verify the signature or identify
    the key; use `apksigner verify --print-certs` for that.
    """
    with zipfile.ZipFile(path) as apk:
        names = set(apk.namelist())
    if any(
        n.startswith("META-INF/") and n.endswith((".RSA", ".DSA", ".EC")) for n in names
    ) and any(n.startswith("META-INF/") and n.endswith(".SF") for n in names):
        return True
    data = path.read_bytes()
    eocd = data.rfind(b"PK\x05\x06")
    if eocd < 0:
        return False
    central_directory = int.from_bytes(data[eocd + 16 : eocd + 20], "little")
    return data[central_directory - 16 : central_directory] == b"APK Sig Block 42"


def make_dmg(bundle, destination):
    """Create a compressed disk image holding the app and an Applications link.

    The image is unsigned and not notarized, like the archive. `ditto` keeps
    symbolic links, extended attributes and any code signature intact.
    """
    if sys.platform != "darwin" or shutil.which("hdiutil") is None:
        raise SystemExit("A DMG can only be created on macOS (hdiutil).")
    with tempfile.TemporaryDirectory() as staging:
        stage = Path(staging)
        subprocess.run(["ditto", str(bundle), str(stage / bundle.name)], check=True)
        (stage / "Applications").symlink_to("/Applications")
        destination.unlink(missing_ok=True)
        subprocess.run(
            [
                "hdiutil",
                "create",
                "-volname",
                "LANPair",
                "-srcfolder",
                str(stage),
                "-fs",
                "HFS+",
                "-format",
                "UDZO",
                "-ov",
                str(destination),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )


def write_checksum(archive):
    hasher = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    (archive.parent / (archive.name + ".sha256")).write_text(
        f"{hasher.hexdigest()}  {archive.name}\n"
    )


root = Path(__file__).resolve().parents[1]
target = sys.argv[1]
out = root / "dist"
out.mkdir(exist_ok=True)
if target == "linux":
    bundle = root / "build/linux/x64/release/bundle"
    archive = out / "lanpair-linux-x64.tar.gz"
    if not bundle.is_dir():
        raise SystemExit(f"Missing bundle: {bundle}")
    with tarfile.open(archive, "w:gz") as result:
        result.add(bundle, arcname="lanpair")
    packages = [archive]
elif target == "windows":
    bundle = root / "build/windows/x64/runner/Release"
    archive = out / "lanpair-windows-x64.zip"
    if not bundle.is_dir():
        raise SystemExit(f"Missing bundle: {bundle}")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as result:
        for path in sorted(bundle.rglob("*")):
            if path.is_file():
                result.write(path, Path("lanpair") / path.relative_to(bundle))
    packages = [archive]
elif target == "macos":
    bundle = root / "build/macos/Build/Products/Release/LANPair.app"
    archive = out / "lanpair-macos-unsigned.tar.gz"
    if not bundle.is_dir():
        raise SystemExit(f"Missing bundle: {bundle}")
    with tarfile.open(archive, "w:gz") as result:
        result.add(bundle, arcname="LANPair.app")
    image = out / "lanpair-macos-unsigned.dmg"
    make_dmg(bundle, image)
    packages = [archive, image]
elif target == "android":
    # `flutter build apk --release` reports this file. Searching the whole
    # output tree could pick up an older unsigned build next to a signed one.
    outputs = root / "build/app/outputs/flutter-apk"
    source = outputs / "app-release.apk"
    if not source.is_file():
        # Split or flavored builds: accept exactly one release APK.
        found = sorted(outputs.glob("*release*.apk"))
        if len(found) != 1:
            raise SystemExit(
                f"Expected app-release.apk or exactly one release APK in {outputs}, "
                f"found {len(found)}."
            )
        source = found[0]
    signed = apk_is_signed(source)
    archive = out / (
        "lanpair-android.apk" if signed else "lanpair-android-unsigned.apk"
    )
    shutil.copyfile(source, archive)
    packages = [archive]
    if not signed:
        print(
            "WARNING: this APK carries no signature. Android refuses to install an "
            "unsigned APK. Sign it with your own key (see docs/distribution.md) "
            "before giving it to anyone.",
            file=sys.stderr,
        )
else:
    raise SystemExit("Expected linux, windows, macos or android.")
for package in packages:
    write_checksum(package)
    print(package)
