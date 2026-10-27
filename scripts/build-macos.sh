#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Build on macOS with Xcode Command Line Tools installed." >&2
  exit 1
fi
architecture="${1:-arm64}"
case "$architecture" in
  arm64) machine_arch="arm64" ;;
  x64) machine_arch="x86_64" ;;
  *) echo "Usage: bash scripts/build-macos.sh [arm64|x64]" >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "Build one architecture at a time: arm64 or x64." >&2
  exit 1
fi
runtime="osx-$architecture"
signing_identity="${SOFATAP_SIGN_IDENTITY:--}"
if [ "$signing_identity" != "-" ] && [ "$signing_identity" != "Developer ID Application: CHEKUSU INC. (FKSR2JD63B)" ]; then
  echo "Use the CHEKUSU Developer ID Application identity for signed distribution." >&2
  exit 1
fi
dotnet_cmd="${SOFATAP_DOTNET:-$repo_dir/.tools/dotnet/dotnet}"
if [ ! -x "$dotnet_cmd" ]; then
  dotnet_cmd="$(command -v dotnet || true)"
fi
if [ -z "$dotnet_cmd" ]; then
  echo "Install the .NET 10 SDK, or set SOFATAP_DOTNET to its executable." >&2
  exit 1
fi
for utility in python3 codesign ditto iconutil sips lipo xcrun; do
  if ! command -v "$utility" >/dev/null; then
    echo "Required build utility is missing: $utility" >&2
    exit 1
  fi
done

# Dependency is pinned by archive SHA-256 and reverified before cached tools run.
sparkle_dir="$(python3 scripts/macos/sparkle.py fetch "$repo_dir/.tools/Sparkle-2.10.0")"
build_dir="$repo_dir/artifacts/macos-build/$runtime"
release_name="SofaTap-macOS-$architecture"
# File Provider/iCloud folders can attach FinderInfo to a newly created .app,
# invalidating codesign. Assemble and sign outside that folder; publish the ZIP.
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-macos.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
release_dir="$stage_dir/$release_name"
app_dir="$release_dir/Sofatap Receiver.app"
publish_dir="$build_dir/self-contained"
mkdir -p "$build_dir"
# Recreate only this architecture's generated publish directory.
rm -rf "$publish_dir"
mkdir -p "$publish_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources"

"$dotnet_cmd" publish host/SofaTap.Host.csproj -c Release -r "$runtime" \
  --artifacts-path "$build_dir/intermediate" --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -o "$publish_dir"
if [ ! -x "$publish_dir/SofaTap" ]; then
  echo "Publish did not produce the expected native SofaTap executable." >&2
  exit 1
fi
if [ "$(lipo -archs "$publish_dir/SofaTap")" != "$machine_arch" ]; then
  echo "Published executable does not match the requested architecture." >&2
  exit 1
fi
cp "$publish_dir/SofaTap" "$app_dir/Contents/Helpers/SofaTapHost"
xcrun swiftc -parse-as-library -swift-version 5 -O -target "$machine_arch-apple-macosx15.0" \
  -D SOFATAP_SPARKLE -F "$sparkle_dir" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  ios/SofaTap/Core/BluetoothTransport.swift desktop/macos/*.swift -o "$app_dir/Contents/MacOS/SofaTap"
mkdir -p "$app_dir/Contents/Frameworks"
ditto "$sparkle_dir/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
python3 - "$publish_dir" "$app_dir/Contents/Resources" <<'PY'
import json
from pathlib import Path
import shutil
import sys

publish, resources = map(Path, sys.argv[1:])
for item in publish.iterdir():
    if item.name == "SofaTap":
        continue
    # The receiver exposes WSS only, with no static asset routes.
    # Non-code files cannot live in Contents/MacOS under strict bundle signing.
    if item.name != "SofaTap.staticwebassets.endpoints.json" or json.loads(item.read_text())["Endpoints"]:
        raise SystemExit("Review the macOS bundle location of new publish content: " + item.name)
    shutil.copyfile(item, resources / item.name)
PY

python3 - "$repo_dir" "$app_dir" "$runtime" <<'PY'
from pathlib import Path
import plistlib
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root, app = map(Path, sys.argv[1:3])
version = (root / "updates/desktop-version.txt").read_text().strip()
if not version or not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+].+)?", version):
    raise SystemExit("Expected a semantic version in the receiver project")
short_version = re.split(r"[-+]", version)[0]
build = os.environ.get("SOFATAP_MAC_BUILD_NUMBER") or subprocess.check_output(["git", "rev-list", "--count", "HEAD"], cwd=root, text=True).strip()
if not re.fullmatch(r"[1-9][0-9]*", build):
    raise SystemExit("SOFATAP_MAC_BUILD_NUMBER must be a positive, monotonically increasing integer")
updates = json.loads((root / "scripts/macos/update-config.json").read_text())
info = {
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleIdentifier": "com.chekusu.sofatap.receiver",
    "CFBundleExecutable": "SofaTap",
    "CFBundleName": "Sofatap Receiver",
    "CFBundleDisplayName": "Sofatap Receiver",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": short_version,
    "SofatapReleaseVersion": version,
    "CFBundleVersion": build,
    "CFBundleIconFile": "SofaTap.icns",
    "SUFeedURL": updates["feedBaseURL"] + "/" + sys.argv[3].removeprefix("osx-") + "/appcast.xml",
    "SUPublicEDKey": updates["publicEdKey"],
    "SUEnableAutomaticChecks": True,
    "SUAutomaticallyUpdate": True,
    "SUEnableSystemProfiling": False,
    "SUScheduledCheckInterval": 86400,
    "SUVerifyUpdateBeforeExtraction": True,
    "SURequireSignedFeed": True,
    "SUSignedFeedFailureExpirationInterval": 0,
    "LSApplicationCategoryType": "public.app-category.utilities",
    "LSMinimumSystemVersion": "15.0",
    "LSUIElement": False,
    "NSHighResolutionCapable": True,
    "NSBonjourServices": ["_sofatap-peer._tcp"],
    "NSBluetoothAlwaysUsageDescription": "Sofatap uses Bluetooth to receive input from your paired iPhone when you enable experimental Bluetooth mode.",
    "NSLocalNetworkUsageDescription": "Sofatap 通过家庭局域网接收你已配对的 iPhone 发来的鼠标和文字操作。",
    "NSHumanReadableCopyright": "Copyright © CHEKUSU INC. Sofatap is available under the MIT license.",
}
with (app / "Contents/Info.plist").open("wb") as output:
    plistlib.dump(info, output)
(app / "Contents/PkgInfo").write_bytes(b"APPL????")
PY

# Format conversion only: use the repository's existing iPhone app artwork.
iconset="$build_dir/SofaTap.iconset"
mkdir -p "$iconset"
icon_source="$repo_dir/ios/SofaTap/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
for points in 16 32 128 256 512; do
  sips -z "$points" "$points" "$icon_source" --out "$iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  sips -z "$pixels" "$pixels" "$icon_source" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/SofaTap.icns"

"$dotnet_cmd" msbuild host/SofaTap.Host.csproj -t:ResolveFrameworkReferences \
  -p:RuntimeIdentifier="$runtime" -p:SelfContained=true -p:PublishSingleFile=true \
  -p:UseArtifactsOutput=true -p:ArtifactsPath="$build_dir/intermediate" \
  -getItem:ResolvedSingleFileHostPack > "$build_dir/host-pack.json"
python3 scripts/package-licenses.py \
  --assets "$build_dir/intermediate/obj/SofaTap.Host/project.assets.json" \
  --host-pack "$build_dir/host-pack.json" \
  --runtime "$runtime" --destination "$app_dir/Contents/Resources/licenses"
cp "$sparkle_dir/LICENSE" "$app_dir/Contents/Resources/licenses/Sparkle-LICENSE.txt"
cp LICENSE THIRD-PARTY-NOTICES.md "$app_dir/Contents/Resources/"
cp LICENSE THIRD-PARTY-NOTICES.md "$release_dir/"
cp docs/MAC-START.md "$release_dir/开始使用.md"
cp docs/MAC-START.md "$app_dir/Contents/Resources/开始使用.md"

# Sign nested code first; never rely on --deep to repair unknown contents.
sign_flags=(--force --sign "$signing_identity" --options runtime)
if [ "$signing_identity" != "-" ]; then sign_flags+=(--timestamp); fi
python3 scripts/macos/sparkle.py sign "$app_dir" "$signing_identity"
codesign "${sign_flags[@]}" --identifier com.chekusu.sofatap.receiver.host \
  --entitlements scripts/macos/Receiver.entitlements.plist "$app_dir/Contents/Helpers/SofaTapHost"
codesign "${sign_flags[@]}" --identifier com.chekusu.sofatap.receiver "$app_dir/Contents/MacOS/SofaTap"
codesign "${sign_flags[@]}" --identifier com.chekusu.sofatap.receiver "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

python3 - "$repo_dir" "$release_dir" "$runtime" "$dotnet_cmd" "$signing_identity" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root, release = map(Path, sys.argv[1:3])
sys.path.insert(0, str(root / "scripts/macos"))
from sparkle import inventory, FRAMEWORK
updates = json.loads((root / "scripts/macos/update-config.json").read_text())
exe = release / "Sofatap Receiver.app/Contents/MacOS/SofaTap"
manifest = {
    "runtime": sys.argv[3],
    "bundleIdentifier": "com.chekusu.sofatap.receiver",
    "architectureCount": 1,
    "signature": "ad-hoc" if sys.argv[5] == "-" else "Developer ID Application: CHEKUSU INC. (FKSR2JD63B)",
    "hardenedRuntime": True,
    "notarized": False,
    "minimumMacOS": "15.0",
    "sourceRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "sourceDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip()),
    "sdkVersion": subprocess.check_output([sys.argv[4], "--version"], cwd=root, text=True).strip(),
    "builtAt": datetime.now(timezone.utc).isoformat(),
    "executableSHA256": hashlib.sha256(exe.read_bytes()).hexdigest(),
    "backendSHA256": hashlib.sha256((release / "Sofatap Receiver.app/Contents/Helpers/SofaTapHost").read_bytes()).hexdigest(),
    "pairingUI": "native AppKit and SwiftUI",
    "iconSource": "ios/SofaTap/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "physicalInputVerified": False,
    "updateFramework": {"name": "Sparkle", "version": updates["sparkleVersion"],
        "archiveSHA256": updates["sparkleArchiveSHA256"],
        "files": inventory(release / "Sofatap Receiver.app" / FRAMEWORK)},
}
(release / "BUILD-MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
cp "$release_dir/BUILD-MANIFEST.json" "$build_dir/BUILD-MANIFEST.json"
# An optional caller-owned directory preserves the exact signed bundle for notarization.
if [ -n "${SOFATAP_MAC_STAGING:-}" ]; then
  if [ -e "$SOFATAP_MAC_STAGING/$release_name" ]; then
    echo "Not overwriting an existing preserved staging bundle." >&2; exit 1
  fi
  mkdir -p "$SOFATAP_MAC_STAGING"
  ditto "$release_dir" "$SOFATAP_MAC_STAGING/$release_name"
fi

archive="$repo_dir/artifacts/SofaTap-macOS-$architecture.zip"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$release_dir" "$archive"
cd "$repo_dir/artifacts"
shasum -a 256 "SofaTap-macOS-$architecture.zip" > "SofaTap-macOS-$architecture.zip.sha256"
echo "Built artifacts/SofaTap-macOS-$architecture.zip (signed: $signing_identity; notarization is a separate verified step)"
