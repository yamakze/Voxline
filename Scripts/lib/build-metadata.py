"""Stable local signing selection and monotonically increasing development versions."""
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
settings = root / ".local"
settings.mkdir(exist_ok=True)

if sys.argv[1:] == ["version"]:
    requested = os.environ.get("VOXLINE_BUILD_VERSION")
    if requested:
        if not re.fullmatch(r"[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}", requested):
            raise SystemExit("VOXLINE_BUILD_VERSION must be a valid CFBundleVersion")
        print(requested)
        sys.exit(0)
    now = datetime.datetime.now(datetime.timezone.utc)
    version = ((now.date() - datetime.date(2020, 1, 1)).days, now.hour, now.minute)
    record = settings / "build-version"
    if record.exists():
        previous = tuple(int(part) for part in record.read_text().strip().split("."))
        if len(previous) != 3 or not (0 < previous[0] <= 9999 and all(0 <= n <= 99 for n in previous[1:])):
            raise SystemExit(f"Invalid build version: {record}")
        if version <= previous:
            major, minor, patch = previous
            patch += 1
            if patch > 99:
                minor, patch = minor + 1, 0
            if minor > 99:
                major, minor = major + 1, 0
            version = major, minor, patch
    if version[0] > 9999:
        raise SystemExit("Build version exceeds CFBundleVersion range")
    value = ".".join(map(str, version))
    record.write_text(value + "\n")
    print(value)
elif sys.argv[1:] == ["mac-signing"]:
    record = settings / "mac-signing.json"
    requested = os.environ.get("VOXLINE_MAC_SIGN_IDENTITY")
    if requested == "-":
        print(requested)
        sys.exit(0)
    if not requested and record.exists():
        requested = json.loads(record.read_text())["identity"]
    result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                            check=True, capture_output=True, text=True)
    identities = re.findall(r'\d+\) ([0-9A-F]{40}) "([^"]+)"', result.stdout)
    if requested:
        matches = [(digest, name) for digest, name in identities if requested in (digest, name)]
    else:
        matches = [(digest, name) for digest, name in identities
                   if name.startswith(("Apple Development:", "Developer ID Application:"))]
    if len(matches) != 1:
        raise SystemExit("需要一个有效的固定代码签名证书。请在 Xcode 配置 Apple Development；"
                         "多个证书时设置 VOXLINE_MAC_SIGN_IDENTITY 为名称或 SHA-1。"
                         "已保存证书失效时须显式重新选择。")
    digest, _ = matches[0]
    if os.environ.get("CI") != "true" and os.environ.get("VOXLINE_MAC_DISTRIBUTION") != "1":
        record.write_text(json.dumps({"identity": digest}) + "\n")
    print(digest)
else:
    raise SystemExit("Usage: build-metadata.py version|mac-signing")
