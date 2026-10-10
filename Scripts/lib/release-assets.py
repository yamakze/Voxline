"""Create versioned release assets from the actual application metadata."""
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
output = root / "build" / "release"
output.mkdir(parents=True, exist_ok=True)
version = (root / "Version.xcconfig").read_text().split("=", 1)[1].strip()
command = sys.argv[1] if len(sys.argv) > 1 else ""
if command == "macos" and len(sys.argv) == 3:
    mode = sys.argv[2]
    app = output / "work" / "mac" / "Voxline.app"
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version:
        raise SystemExit("Mac application version does not match Version.xcconfig")
    with tempfile.TemporaryDirectory(prefix="archive.", dir=output / "work") as directory:
        archive = Path(directory) / f"Voxline-{version}.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
        archive.replace(output / archive.name)
    architectures = subprocess.check_output(["lipo", "-archs", str(app / "Contents" / "MacOS" / "Voxline")], text=True).strip()
    signing = "Developer ID signed and notarized" if mode == "notarized" else "ad-hoc signed; not notarized"
    (output / "PACKAGE_NOTES.md").write_text(
        f"## Downloads\n\n- macOS 15+: `Voxline-{version}.zip` ({architectures}; {signing}).\n"
        f"- iOS / iPadOS 18+: `Voxline-iOS-{version}.ipa` (unsigned; sign with AltStore, SideStore or Xcode).\n"
        "- `SHA256SUMS.txt`: download integrity checksums.\n\n"
        "Keep the same signing account and Bundle ID when reinstalling the IPA to preserve app data.\n"
    )
elif command == "ios" and len(sys.argv) == 2:
    app = root / "build" / "ios" / "device" / "DerivedData" / "Build" / "Products" / "Release-iphoneos" / "Voxline.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version:
        raise SystemExit("iOS application version does not match Version.xcconfig")
    destination = output / f"Voxline-iOS-{version}.ipa"
    temporary = destination.with_suffix(".ipa.tmp")
    shutil.copy2(root / "build" / "ios" / "Voxline-unsigned.ipa", temporary)
    temporary.replace(destination)
elif command == "checksums" and len(sys.argv) == 2:
    assets = [path for path in (output / f"Voxline-{version}.zip", output / f"Voxline-iOS-{version}.ipa") if path.is_file()]
    if not assets:
        raise SystemExit("No release assets to checksum")
    lines = []
    for path in assets:
        digest = hashlib.sha256()
        with path.open("rb") as file:
            for block in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(block)
        lines.append(f"{digest.hexdigest()}  {path.name}\n")
    (output / "SHA256SUMS.txt").write_text("".join(lines))
else:
    raise SystemExit("Usage: release-assets.py macos <adhoc|notarized> | ios | checksums")
