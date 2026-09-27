#!/bin/zsh
# 打包 biubiu 小猫桌宠：./build.sh（素材已在 assets/ 里）
set -e
cd "$(dirname "$0")"
APP="build/biubiu小猫.app"
rm -rf "$APP" build/icon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

# 同时编译 Apple 芯片和 Intel 两个版本，合成一个通用程序
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13.0 app/main.swift -o build/BiubiuCat-$arch
done
lipo -create build/BiubiuCat-arm64 build/BiubiuCat-x86_64 -output "$APP/Contents/MacOS/BiubiuCat"
rm build/BiubiuCat-arm64 build/BiubiuCat-x86_64
cp -R assets "$APP/Contents/Resources/assets"

# 图标
swift tools/icon.swift assets/main/frames/000.png build/icon_1024.png 2>/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>biubiu小猫</string>
  <key>CFBundleDisplayName</key><string>biubiu小猫</string>
  <key>CFBundleIdentifier</key><string>studio.antibes.biubiucat</string>
  <key>CFBundleExecutable</key><string>BiubiuCat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "打包完成：$APP"

# 发布用的压缩包（放到 GitHub Releases 给别人下载）
rm -f build/biubiu-cat-mac.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" build/biubiu-cat-mac.zip
echo "下载包：build/biubiu-cat-mac.zip"
