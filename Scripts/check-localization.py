#!/usr/bin/env python3
"""Check compiler-extracted Chinese messages against each module's resources."""

import argparse
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("extracted", nargs="+", type=Path, help="Current build's .stringsdata directories")
    args = parser.parse_args()
    sources = Path(__file__).resolve().parent.parent / "Sources/Voxline"
    resources = {}
    for module in ("App", "Core", "Media", "Translation", "WhisperKit", "Workflow"):
        for language in ("en", "zh-Hans"):
            path = sources / module / "Resources" / f"{language}.lproj/Localizable.strings"
            resources[module, language] = json.loads(subprocess.check_output(
                ["plutil", "-convert", "json", "-o", "-", str(path)], text=True))

    messages = set()
    missing = set()
    source_files = set()
    for directory in args.extracted:
        if not directory.is_dir():
            parser.error(f"Extraction directory does not exist: {directory}")
        for path in directory.rglob("*.stringsdata"):
            extracted = json.loads(path.read_text())
            source = Path(extracted.get("source", ""))
            if not source.is_relative_to(sources) or not source.is_file():
                continue  # Dependencies and removed source files are outside this build contract.
            relative = source.relative_to(sources)
            module = relative.parts[0]
            if (module, "en") not in resources:
                continue
            source_files.add(source)
            for entry in extracted.get("tables", {}).get("Localizable", []):
                key = entry["key"]
                # Numeric format strings, model IDs, URLs and speed labels need no translation.
                if not re.search(r"[\u3400-\u9fff]", key):
                    continue
                messages.add((module, key))
                for language in ("en", "zh-Hans"):
                    if key not in resources[module, language] or not resources[module, language][key]:
                        missing.add((str(relative), entry["location"]["startingLine"], language, key))

    if not messages:
        parser.error("No Voxline messages extracted; build with localized string emission first")
    for source, line, language, key in sorted(missing):
        print(f"{source}:{line}: missing {language} translation: {key}")
    print(f"Checked {len(messages)} messages from {len(source_files)} source files; {len(missing)} missing")
    return bool(missing)


if __name__ == "__main__":
    raise SystemExit(main())
