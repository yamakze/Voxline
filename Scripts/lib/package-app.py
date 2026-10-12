import plistlib
import base64
import os
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

if len(sys.argv) < 3 or sys.argv[1] not in {"debug", "release"}:
    raise SystemExit("Use Scripts/build-app.sh [debug|release]")
root = Path(__file__).resolve().parents[2]
identity = os.environ.get("VOXLINE_MAC_SIGN_IDENTITY")
version = os.environ.get("VOXLINE_BUILD_VERSION")
if not identity or not version:
    raise SystemExit("Use Scripts/build-app.sh to select a fixed signing identity and build version")
binary_directories = [Path(directory) for directory in sys.argv[2:]]
output = Path(os.environ.get("VOXLINE_MAC_OUTPUT_DIRECTORY", root / "build"))
output.mkdir(parents=True, exist_ok=True)
staging = tempfile.TemporaryDirectory(prefix="mac-package.", dir=output)
bundle = Path(staging.name) / "Voxline.app"
contents = bundle / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
executables = [str(directory / "Voxline") for directory in binary_directories]
if len(executables) == 1:
    shutil.copy2(executables[0], contents / "MacOS" / "Voxline")
else:
    subprocess.run(["lipo", "-create", *executables, "-output", str(contents / "MacOS" / "Voxline")], check=True)
for resource_bundle in binary_directories[0].glob("Voxline_*.bundle"):
    shutil.copytree(resource_bundle, contents / "Resources" / resource_bundle.name)
sparkle_distribution = root / ".build/artifacts/sparkle/Sparkle"
framework = contents / "Frameworks" / "Sparkle.framework"
shutil.copytree(sparkle_distribution / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework", framework, symlinks=True)
shutil.copytree(root / "Licenses", contents / "Resources" / "Licenses", dirs_exist_ok=True)
shutil.copy2(root / "LICENSE", contents / "Resources" / "LICENSE")
for language in ("zh-Hans", "en"):
    source = root / "Sources" / "Voxline" / "App" / "Resources" / f"{language}.lproj" / "InfoPlist.strings"
    destination = contents / "Resources" / f"{language}.lproj"
    destination.mkdir()
    shutil.copy2(source, destination / source.name)
icon_source = root / "Resources" / "AppIcon.icns"
shutil.copy2(icon_source, contents / "Resources" / "AppIcon.icns")
marketing_version = (root / "Version.xcconfig").read_text().split("=", 1)[1].strip()
metadata = {
    "CFBundleIdentifier": "dev.voxline.app",
    "CFBundleName": "Voxline",
    "CFBundleDevelopmentRegion": "zh-Hans",
    "CFBundleLocalizations": ["zh-Hans", "en"],
    "CFBundleDisplayName": "Voxline",
    "CFBundleExecutable": "Voxline",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": marketing_version,
    "CFBundleVersion": version,
    "CFBundleIconFile": "AppIcon",
    "CFBundleIconName": "AppIcon",
    "LSMinimumSystemVersion": "15.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "SUFeedURL": "https://github.com/yamakze/Voxline/releases/latest/download/appcast.xml",
    "SUEnableInstallerLauncherService": True,
    "SUAutomaticallyUpdate": False,
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
public_key = os.environ.get("VOXLINE_SPARKLE_PUBLIC_KEY", "").strip()
metadata["SUEnableAutomaticChecks"] = bool(public_key)
if public_key:
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise SystemExit("VOXLINE_SPARKLE_PUBLIC_KEY must be a base64 Ed25519 public key")
    metadata["SUPublicEDKey"] = public_key
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump(metadata, file)
distribution = os.environ.get("VOXLINE_MAC_DISTRIBUTION") == "1"
timestamp_options = ["--timestamp"] if distribution else ["--timestamp=none"]
signing_options = ["--options", "runtime", *timestamp_options] if distribution else timestamp_options
framework_version = framework / "Versions/B"
for component in (framework_version / "XPCServices/Installer.xpc", framework_version / "XPCServices/Downloader.xpc",
                  framework_version / "Autoupdate", framework_version / "Updater.app", framework):
    subprocess.run(["codesign", "--force", "--sign", identity, "--options", "runtime", *timestamp_options,
                    "--preserve-metadata=entitlements", str(component)], check=True)
subprocess.run(["codesign", "--force", "--sign", identity, *signing_options, "--entitlements",
                str(root / "Scripts" / "Voxline.entitlements"), str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
requirement = subprocess.run(["codesign", "-d", "-r-", str(bundle)],
                             check=True, capture_output=True, text=True).stdout.strip()
# codesign prefixes the generated cdhash requirement of an ad-hoc signature with '# '.
if identity == "-":
    requirement = requirement.removeprefix("# ")
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
if output == root / "build" and lsregister.is_file():
    subprocess.run([str(lsregister), "-f", "-R", "-trusted", str(bundle)], check=True)
print(bundle)
print(f"Bundle ID: {metadata['CFBundleIdentifier']} · Build: {version} · Signer: {identity}")
