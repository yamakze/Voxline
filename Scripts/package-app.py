import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

if len(sys.argv) != 2 or sys.argv[1] not in {"debug", "release"}:
    raise SystemExit("Usage: package-app.py <debug|release>")
root = Path(__file__).resolve().parents[1]
result = subprocess.run(
    ["swift", "build", "--configuration", sys.argv[1], "--show-bin-path"],
    cwd=root, text=True, capture_output=True, check=True,
)
binary = Path(result.stdout.strip()) / "Voxline"
if not binary.is_file():
    raise SystemExit(f"Missing compiled executable: {binary}")
bundle = root / "build" / "Voxline.app"
contents = bundle / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
shutil.copy2(binary, contents / "MacOS" / "Voxline")
shutil.copy2(binary.parent / "Voxline_VoxlineWhisperKit.bundle" / "BaselineModel.json",
             contents / "Resources" / "BaselineModel.json")
shutil.copytree(root / "Licenses", contents / "Resources" / "Licenses", dirs_exist_ok=True)
icon_source = root / "Resources" / "AppIcon.icns"
if icon_source.is_file():
    shutil.copy2(icon_source, contents / "Resources" / "AppIcon.icns")
icon_png_source = root / "Resources" / "AppIcon.png"
if icon_png_source.is_file():
    shutil.copy2(icon_png_source, contents / "Resources" / "AppIcon.png")
metadata = {
    "CFBundleIdentifier": "dev.voxline.app",
    "CFBundleName": "Voxline",
    "CFBundleDisplayName": "Voxline",
    "CFBundleExecutable": "Voxline",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "CFBundleIconFile": "AppIcon.icns",
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
subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements",
                str(root / "Scripts" / "Voxline.entitlements"), str(bundle)], check=True)
subprocess.run(["touch", str(bundle)], check=False)
lsregister = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
if lsregister.is_file():
    subprocess.run([str(lsregister), "-f", str(bundle)], check=False)
print(bundle)
