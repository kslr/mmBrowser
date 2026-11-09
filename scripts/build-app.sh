#!/bin/zsh
# 构建 mmBrowser.app（release），做本地 ad-hoc 签名，输出到 build/mmBrowser.app
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.2.0}"
swift build -c release --product mmBrowser
swift build -c release --product mmctl

APP=build/mmBrowser.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/mmBrowser "$APP/Contents/MacOS/mmBrowser"
cp .build/release/mmctl "$APP/Contents/MacOS/mmctl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.mmbrowser</string>
    <key>CFBundleName</key><string>mmBrowser</string>
    <key>CFBundleDisplayName</key><string>mmBrowser</string>
    <key>CFBundleExecutable</key><string>mmBrowser</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "已生成 $APP"
