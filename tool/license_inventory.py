#!/usr/bin/env python3
"""Collect the exact resolved Dart dependency license texts, including SDKs."""

import hashlib
import json
from collections import defaultdict
from pathlib import Path
from urllib.parse import unquote, urlparse

root = Path(__file__).resolve().parents[1]
config_path = root / ".dart_tool/package_config.json"
config = json.loads(config_path.read_text())
groups = defaultdict(list)
texts = {}
for package in config["packages"]:
    if package["name"] == "lanpair":
        continue
    uri = package["rootUri"]
    base = (
        Path(unquote(urlparse(uri).path))
        if uri.startswith("file:")
        else (config_path.parent / uri).resolve()
    )
    candidates = [
        base / name for name in ["LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE"]
    ]
    path = next((p for p in candidates if p.is_file()), None)
    # Flutter SDK packages inherit the SDK license at its root.
    if path is None and "flutter" in base.parts:
        path = next(
            (p / "LICENSE" for p in base.parents if (p / "LICENSE").is_file()), None
        )
    if path is None:
        raise SystemExit(f"Missing license for {package['name']}: {base}")
    text = path.read_text().strip()
    digest = hashlib.sha256(text.encode()).hexdigest()
    groups[digest].append(package["name"])
    texts[digest] = text
lines = [
    "# Third-party notices",
    "",
    "Generated from the resolved `pubspec.lock` and Flutter 3.47.8 package sources.",
    "Includes development dependencies as well as runtime packages. Rerun after dependency updates:",
    "`python3 tool/license_inventory.py` following `flutter pub get --enforce-lockfile`.",
    "",
    "LANPair is Apache-2.0. Retain these upstream notices when distributing applicable code.",
    "No custom font files are added; platform fonts and Flutter SDK icons follow their own licenses.",
    "",
]
for digest, packages in sorted(groups.items(), key=lambda item: min(item[1])):
    lines += [
        "## " + ", ".join(sorted(packages)),
        "",
        "```text",
        texts[digest],
        "```",
        "",
    ]
(root / "THIRD_PARTY_NOTICES.md").write_text("\n".join(lines))
print(
    f"{sum(map(len, groups.values()))} packages, {len(groups)} distinct license texts."
)
