"""Package the device build without carrying macOS extended attributes."""
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("Use Scripts/build-ios-ipa.sh [debug|release]")
app = Path(sys.argv[1])
info = plistlib.loads((app / "Info.plist").read_bytes())
if info["CFBundleIdentifier"] != "dev.voxline.ios":
    raise SystemExit("IPA Bundle ID changed; refusing to replace the existing package")
root = Path(__file__).resolve().parents[2]
output = root / "dist" / "ios"
output.mkdir(parents=True, exist_ok=True)
workspace = root / ".build" / "packaging" / "ios"
workspace.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="ipa.", dir=workspace) as directory:
    stage = Path(directory)
    payload = stage / "Payload"
    payload.mkdir()
    subprocess.run(["ditto", "--norsrc", "--noextattr", str(app), str(payload / "Voxline.app")], check=True)
    ipa = stage / "Voxline-unsigned.ipa"
    subprocess.run(["ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(payload), str(ipa)], check=True)
    digest = hashlib.sha256()
    with ipa.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    metadata = {"bundleIdentifier": info["CFBundleIdentifier"],
                "version": info["CFBundleShortVersionString"], "buildVersion": info["CFBundleVersion"],
                "signing": "unsigned", "sha256": digest.hexdigest()}
    manifest = stage / "Voxline-unsigned.identity.json"
    manifest.write_text(json.dumps(metadata, indent=2) + "\n")
    ipa.replace(output / ipa.name)
    manifest.replace(output / manifest.name)
print(f"Unsigned IPA: {output / ipa.name}")
print(f"Bundle ID: {metadata['bundleIdentifier']} · Version: {metadata['version']} · Build: {metadata['buildVersion']}")
