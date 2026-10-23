#!/bin/sh
# 把 SPM 产物打成可双击的 .app（M3）
# 用法: sh app-retouch/build_app.sh [debug|release]
set -e
MODE="${1:-release}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/app-retouch"

echo "== 1/3 swift build -c $MODE =="
swift build -c "$MODE"
BIN_DIR=$(swift build -c "$MODE" --show-bin-path)

APP="$ROOT/dist/ContentRetouch.app"
echo "== 2/3 组装 $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ContentRetouch" "$APP/Contents/MacOS/ContentRetouch"
cp "$BIN_DIR/retouch-cli" "$APP/Contents/MacOS/retouch-cli"
# 人脸解析模型（50 MB）：放进 Resources/Models，核心会按 Bundle 路径去找
if [ -d "$ROOT/app-retouch/Models" ]; then
  mkdir -p "$APP/Contents/Resources/Models"
  cp -R "$ROOT/app-retouch/Models/" "$APP/Contents/Resources/Models/"
  # SAM（23 MB，Apache-2.0）**不打进包**：改成可选下载（App 里点「下载精细分割模型」）
  #  打包时把 Models/SAM 移出去，避免误带；核心在缺它时会自动退回系统前景掩膜
  rm -rf "$APP/Contents/Resources/Models/SAM"
  echo "  已内置模型：$(ls "$APP/Contents/Resources/Models" | tr '\n' ' ')"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ContentRetouch</string>
  <key>CFBundleDisplayName</key><string>智能修图</string>
  <key>CFBundleExecutable</key><string>ContentRetouch</string>
  <key>CFBundleIdentifier</key><string>com.dsh.content-retouch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>9.10.90</string>
  <key>CFBundleVersion</key><string>98</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "== 3/3 ad-hoc 签名（自用；对外分发仍需 Developer ID） =="
codesign --force --deep --sign - "$APP" 2>&1 | tail -1 || true
echo "完成：$APP"
echo "  GUI: $APP/Contents/MacOS/ContentRetouch"
echo "  CLI: $APP/Contents/MacOS/retouch-cli"
