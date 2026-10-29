#!/usr/bin/env python3
"""Check message and placeholder coverage across all supported locales."""

import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
files = sorted((root / "lib/l10n").glob("app_*.arb"))
base = json.loads((root / "lib/l10n/app_en.arb").read_text())
keys = {k for k in base if not k.startswith("@")}
errors = []
for path in files:
    data = json.loads(path.read_text())
    actual = {k for k in data if not k.startswith("@")}
    if actual != keys:
        errors.append(f"{path.name}: missing={keys - actual}, extra={actual - keys}")
    for key in keys & actual:
        # ICU branch names are not placeholders; require declared template args.
        args = base.get("@" + key, {}).get("placeholders", {})
        for arg in args:
            if not re.search(r"\{\s*" + re.escape(arg) + r"\s*[,}]", data[key]):
                errors.append(f"{path.name}: missing placeholder {arg} in {key}")
        if not isinstance(data[key], str) or not data[key].strip():
            errors.append(f"{path.name}: empty {key}")
if errors:
    raise SystemExit("\n".join(errors))
print(
    f"{len(files)} ARB files, {len(keys)} messages: complete."
)
