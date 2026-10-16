"""Create versioned release assets from the actual application metadata."""
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[2]
output = root / "dist" / "release"
workspace = root / ".build" / "packaging" / "release"
workspace.mkdir(parents=True, exist_ok=True)
output.mkdir(parents=True, exist_ok=True)
version = (root / "Version.xcconfig").read_text().split("=", 1)[1].strip()
command = sys.argv[1] if len(sys.argv) > 1 else ""
if command == "macos" and len(sys.argv) == 3:
    mode = sys.argv[2]
    app = workspace / "macos" / "Voxline.app"
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version:
        raise SystemExit("Mac application version does not match Version.xcconfig")
    with tempfile.TemporaryDirectory(prefix="archive.", dir=workspace) as directory:
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
    app = root / ".build" / "ios" / "device" / "DerivedData" / "Build" / "Products" / "Release-iphoneos" / "Voxline.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version:
        raise SystemExit("iOS application version does not match Version.xcconfig")
    destination = output / f"Voxline-iOS-{version}.ipa"
    temporary = destination.with_suffix(".ipa.tmp")
    shutil.copy2(root / "dist" / "ios" / "Voxline-unsigned.ipa", temporary)
    temporary.replace(destination)
elif command == "appcast" and len(sys.argv) == 4:
    tag, notes = sys.argv[2], Path(sys.argv[3])
    private_key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not private_key:
        raise SystemExit("SPARKLE_PRIVATE_KEY is required to sign the update archive")
    if tag != f"v{version}" and not tag.startswith(f"v{version}-"):
        raise SystemExit("Appcast tag must match Version.xcconfig")
    archive = output / f"Voxline-{version}.zip"
    app = workspace / "macos" / "Voxline.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not info.get("SUPublicEDKey"):
        raise SystemExit("The application has no Sparkle public key")
    feed = output / "appcast.xml"
    with tempfile.TemporaryDirectory(prefix="appcast.", dir=workspace) as directory:
        directory = Path(directory)
        shutil.copy2(archive, directory / archive.name)
        shutil.copy2(notes, directory / archive.with_suffix(".md").name)
        subprocess.run([str(root / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"),
                        "--ed-key-file", "-", "--embed-release-notes", "--maximum-deltas", "0",
                        "--download-url-prefix", f"https://github.com/yamakze/Voxline/releases/download/{tag}/",
                        "--link", f"https://github.com/yamakze/Voxline/releases/tag/{tag}",
                        "--full-release-notes-url", "https://github.com/yamakze/Voxline/releases",
                        "-o", str(directory / "appcast.xml"), str(directory)],
                       input=private_key, text=True, check=True)
        sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
        item = ET.parse(directory / "appcast.xml").find("./channel/item")
        enclosure = item.find("enclosure") if item is not None else None
        if enclosure is None or not enclosure.get(sparkle + "edSignature"):
            raise SystemExit("Sparkle did not sign the archive; check the application's public key and signing key")
        if (item.findtext(sparkle + "version") != info["CFBundleVersion"] or
                item.findtext(sparkle + "shortVersionString") != info["CFBundleShortVersionString"] or
                enclosure.get("url") != f"https://github.com/yamakze/Voxline/releases/download/{tag}/{archive.name}" or
                int(enclosure.get("length", "0")) != archive.stat().st_size):
            raise SystemExit("Appcast does not match the release archive's metadata")
        (directory / "appcast.xml").replace(feed)
    print(f"Generated signed update feed: {feed}")
elif command == "checksums" and len(sys.argv) == 2:
    assets = [path for path in (output / f"Voxline-{version}.zip", output / f"Voxline-iOS-{version}.ipa", output / "appcast.xml") if path.is_file()]
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
    raise SystemExit("Usage: release-assets.py macos <adhoc|notarized> | ios | appcast <tag> <notes.md> | checksums")
