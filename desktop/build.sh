#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# SwiftUI macros (State etc.) live in the full Xcode toolchain; the bare CLT cannot compile them.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
DESTINATION="${1:-desktop/dist}"
mkdir -p "$DESTINATION"
APP="$DESTINATION/林序下载器.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc desktop/DownloadApp.swift -parse-as-library -swift-version 5 -O \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/LinxuDownloader"
cp desktop/worker.py desktop/douyin.js "$APP/Contents/Resources/"
ICON="$APP/Contents/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
  TMPICON="$(mktemp -d)/icon"
  DEVELOPER_DIR="${DEVELOPER_DIR:-}" swift desktop/make_icon.swift "$TMPICON-1024.png"
  mkdir -p "$TMPICON.iconset"
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$TMPICON-1024.png" --out "$TMPICON.iconset/$2.png" >/dev/null
  done
  iconutil -c icns "$TMPICON.iconset" -o "$ICON"
  rm -rf "$(dirname "$TMPICON")"
fi
python3 - "$APP" <<'PY'
import pathlib, plistlib, shutil, sys
app = pathlib.Path(sys.argv[1])
shutil.copytree('yt_dlp', app / 'Contents/Resources/yt_dlp', dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
shutil.copy('LICENSE', app / 'Contents/Resources/LICENSE-yt-dlp')
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({
        'CFBundleName': '林序下载器',
        'CFBundleDisplayName': '林序下载器',
        'CFBundleIdentifier': 'com.jmzm123.linxu-downloader',
        'CFBundleExecutable': 'LinxuDownloader',
        'CFBundlePackageType': 'APPL',
        'CFBundleIconFile': 'AppIcon',
        'CFBundleShortVersionString': '0.2.0',
        'CFBundleVersion': '2',
        'LSMinimumSystemVersion': '13.0',
        'NSHighResolutionCapable': True,
        'NSHumanReadableCopyright': 'yt-dlp contributors · 林序 macOS interface',
    }, f)
PY
codesign --force --deep --sign - "$APP"
printf '已构建：%s\n' "$APP"
