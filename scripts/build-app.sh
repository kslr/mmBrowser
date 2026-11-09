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
for target in MMCore MMApp mmctl; do
    cp -R ".build/release/mmBrowser_${target}.bundle" "$APP/Contents/Resources/"
done
for lang in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    echo '"CFBundleDisplayName" = "mmBrowser";' > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.mmbrowser</string>
    <key>CFBundleName</key><string>mmBrowser</string>
    <key>CFBundleDisplayName</key><string>mmBrowser</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
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
