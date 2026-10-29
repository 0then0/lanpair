#!/usr/bin/env python3
"""Package all runtime files and attach SHA-256 checksums; never publish/sign."""

import hashlib
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path

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
elif target == "windows":
    bundle = root / "build/windows/x64/runner/Release"
    archive = out / "lanpair-windows-x64.zip"
    if not bundle.is_dir():
        raise SystemExit(f"Missing bundle: {bundle}")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as result:
        for path in sorted(bundle.rglob("*")):
            if path.is_file():
                result.write(path, Path("lanpair") / path.relative_to(bundle))
elif target == "macos":
    bundle = root / "build/macos/Build/Products/Release/LANPair.app"
    archive = out / "lanpair-macos-unsigned.tar.gz"
    if not bundle.is_dir():
        raise SystemExit(f"Missing bundle: {bundle}")
    with tarfile.open(archive, "w:gz") as result:
        result.add(bundle, arcname="LANPair.app")
elif target == "android":
    candidates = sorted((root / "build/app/outputs").rglob("*release*.apk"))
    candidates = [p for p in candidates if "unsigned" in p.name] or candidates
    if not candidates:
        raise SystemExit("Missing release APK.")
    archive = out / "lanpair-android-unsigned.apk"
    shutil.copyfile(candidates[0], archive)
else:
    raise SystemExit("Expected linux, windows, macos or android.")
hasher = hashlib.sha256()
with archive.open("rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        hasher.update(chunk)
digest = hasher.hexdigest()
(archive.parent / (archive.name + ".sha256")).write_text(f"{digest}  {archive.name}\n")
print(archive)
