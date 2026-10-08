import plistlib
import os
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

if len(sys.argv) != 2 or sys.argv[1] not in {"debug", "release"}:
    raise SystemExit("Usage: package-app.py <debug|release>")
root = Path(__file__).resolve().parents[1]
identity = os.environ.get("VOXLINE_MAC_SIGN_IDENTITY")
version = os.environ.get("VOXLINE_BUILD_VERSION")
if not identity or not version:
    raise SystemExit("Use Scripts/build-app.sh to select a fixed signing identity and build version")
result = subprocess.run(
    ["swift", "build", "--configuration", sys.argv[1], "--show-bin-path"],
    cwd=root, text=True, capture_output=True, check=True,
)
binary = Path(result.stdout.strip()) / "Voxline"
if not binary.is_file():
    raise SystemExit(f"Missing compiled executable: {binary}")
output = root / "build"
output.mkdir(exist_ok=True)
staging = tempfile.TemporaryDirectory(prefix="mac-package.", dir=output)
bundle = Path(staging.name) / "Voxline.app"
contents = bundle / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
shutil.copy2(binary, contents / "MacOS" / "Voxline")
for resource_bundle in binary.parent.glob("Voxline_*.bundle"):
    shutil.copytree(resource_bundle, contents / "Resources" / resource_bundle.name)
shutil.copytree(root / "Licenses", contents / "Resources" / "Licenses", dirs_exist_ok=True)
for language in ("zh-Hans", "en"):
    source = root / "Sources" / "Voxline" / "App" / "Resources" / f"{language}.lproj" / "InfoPlist.strings"
    destination = contents / "Resources" / f"{language}.lproj"
    destination.mkdir()
    shutil.copy2(source, destination / source.name)
icon_source = root / "Resources" / "AppIcon.icns"
if icon_source.is_file():
    shutil.copy2(icon_source, contents / "Resources" / "AppIcon.icns")
icon_png_source = root / "Resources" / "AppIcon.png"
if icon_png_source.is_file():
    shutil.copy2(icon_png_source, contents / "Resources" / "AppIcon.png")
metadata = {
    "CFBundleIdentifier": "dev.voxline.app",
    "CFBundleName": "Voxline",
    "CFBundleDevelopmentRegion": "zh-Hans",
    "CFBundleLocalizations": ["zh-Hans", "en"],
    "CFBundleDisplayName": "Voxline",
    "CFBundleExecutable": "Voxline",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": version,
    "CFBundleIconFile": "AppIcon",
    "CFBundleIconName": "AppIcon",
    "LSMinimumSystemVersion": "15.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "CFBundleDocumentTypes": [{
        "CFBundleTypeName": "Voxline Task", "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "Owner", "LSItemContentTypes": ["dev.voxline.project"],
    }],
    "UTExportedTypeDeclarations": [{
        "UTTypeIdentifier": "dev.voxline.project", "UTTypeDescription": "Voxline 字幕任务",
        "UTTypeConformsTo": ["public.json"],
        "UTTypeTagSpecification": {"public.filename-extension": ["voxline"],
                                   "public.mime-type": "application/vnd.voxline.project+json"},
    }],
}
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump(metadata, file)
subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", "--entitlements",
                str(root / "Scripts" / "Voxline.entitlements"), str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
requirement = subprocess.run(["codesign", "-d", "-r-", str(bundle)],
                             check=True, capture_output=True, text=True).stdout.strip()
if not requirement.startswith("designated => "):
    raise SystemExit("codesign did not return a designated requirement")
identity_manifest = Path(staging.name) / "Voxline.identity.json"
identity_manifest.write_text(json.dumps({
    "bundleIdentifier": metadata["CFBundleIdentifier"], "buildVersion": version,
    "signingIdentity": identity, "designatedRequirement": requirement.removeprefix("designated => ")
}, indent=2) + "\n")
target = output / "Voxline.app"
previous = Path(staging.name) / "previous.app"
if target.exists():
    target.rename(previous)
try:
    bundle.rename(target)
except OSError:
    if previous.exists():
        previous.rename(target)
    raise
bundle = target
identity_manifest.replace(output / "Voxline.identity.json")
staging.cleanup()
subprocess.run(["touch", str(bundle)], check=True)
lsregister = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
if lsregister.is_file():
    subprocess.run([str(lsregister), "-f", "-R", "-trusted", str(bundle)], check=True)
print(bundle)
print(f"Bundle ID: {metadata['CFBundleIdentifier']} · Build: {version} · Signer: {identity}")
