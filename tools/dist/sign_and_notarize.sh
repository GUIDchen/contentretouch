#!/bin/sh
# T8：签名 + 公证 + 装订票据（需要 Apple Developer 凭据，本机目前没有）
#
# 用法：
#   DEVELOPER_ID_APP="Developer ID Application: 你的名字 (TEAMID)" \
#   APPLE_ID="you@example.com" TEAM_ID="TEAMID" APP_PASSWORD="app-specific-password" \
#     sh tools/dist/sign_and_notarize.sh app/src-tauri/target/release/bundle/macos/ContentHarvester.app \
#        app/src-tauri/target/release/bundle/dmg/ContentHarvester_0.1.0_aarch64.dmg
#
# 也支持 App Store Connect API Key（CI 里更合适）：
#   AC_KEY_ID=xxx AC_ISSUER_ID=xxx AC_KEY_PATH=/path/AuthKey_xxx.p8
#
# 参数：$1 = .app 路径（必需），$2 = .dmg 路径（可选，有就一起装订票据）
set -eu


# --check：只体检，不签名。列出缺什么、下一步做什么。
if [ "${1:-}" = "--check" ]; then
  echo "== 签名与公证体检 =="
  ok=0; bad=0
  chk() { if eval "$2" >/dev/null 2>&1; then echo "  ✅ $1"; ok=$((ok+1)); else echo "  ❌ $1"; bad=$((bad+1)); fi }
  chk "codesign 可用" "command -v codesign"
  chk "xcrun 可用" "command -v xcrun"
  chk "hdiutil 可用" "command -v hdiutil"
  ids=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Developer ID Application" || true)
  if [ "$ids" -gt 0 ]; then echo "  ✅ 找到 $ids 个 Developer ID Application 证书"; ok=$((ok+1)); else echo "  ❌ 没有 Developer ID Application 证书（签名与公证无法进行）"; bad=$((bad+1)); fi
  if [ -n "${AC_KEY_ID:-}" ] || [ -n "${APPLE_ID:-}" ]; then echo "  ✅ 检测到公证凭据环境变量"; ok=$((ok+1)); else echo "  ❌ 没有公证凭据（APPLE_ID+TEAM_ID+APP_PASSWORD 或 AC_KEY_ID+AC_ISSUER_ID+AC_KEY_PATH）"; bad=$((bad+1)); fi
  echo
  echo "通过 $ok 项，缺 $bad 项"
  if [ "$bad" -gt 0 ]; then
    echo
    echo "拿到证书后的完整步骤见 docs/分发与签名指南.md；装好证书后可用："
    echo "  DEVELOPER_ID_APP=\"Developer ID Application: 你的名字 (TEAMID)\" APPLE_ID=... TEAM_ID=... APP_PASSWORD=... sh tools/dist/sign_and_notarize.sh <app> <dmg>"
  fi
  exit $([ "$bad" -gt 0 ] && echo 1 || echo 0)
fi

APP="${1:-}"
DMG="${2:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "需要 .app 路径作为第一个参数，例如 app/src-tauri/target/release/bundle/macos/ContentHarvester.app"
  exit 2
fi

IDENTITY="${DEVELOPER_ID_APP:-}"
if [ -z "$IDENTITY" ]; then
  echo "[中止] 缺少 DEVELOPER_ID_APP（Developer ID Application 证书名）"
  echo "本机现有身份："
  security find-identity -v -p codesigning || true
  echo
  echo "获取方式：Apple Developer 账号 -> Certificates -> 创建 Developer ID Application -> 下载并双击导入钥匙串"
  exit 3
fi

# entitlements：Tauri 那个 app 有，我们的 Swift app 没有；文件不存在就自动不传，
# 这样同一个脚本对两个 app 都能用（不必为 ContentRetouch 复制一份）
ENTITLEMENTS="${ENTITLEMENTS:-app/src-tauri/entitlements.plist}"
if [ ! -f "$ENTITLEMENTS" ]; then ENTITLEMENTS=""; fi

echo "== 1/4 签名 .app（硬化运行时 + 时间戳） =="
codesign --force --deep --options runtime --timestamp \
  ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} \
  --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"

echo "== 2/4 提交公证（等待结果） =="
if [ -n "${AC_KEY_ID:-}" ] && [ -n "${AC_ISSUER_ID:-}" ] && [ -n "${AC_KEY_PATH:-}" ]; then
  xcrun notarytool submit "$APP" --key "$AC_KEY_PATH" --key-id "$AC_KEY_ID" --issuer "$AC_ISSUER_ID" --wait
else
  : "${APPLE_ID:?需要 APPLE_ID 或用 AC_KEY_* 三件套}"
  : "${TEAM_ID:?需要 TEAM_ID}"
  : "${APP_PASSWORD:?需要 APP_PASSWORD（App 专用密码，不是账号密码）}"
  xcrun notarytool submit "$APP" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
fi

echo "== 3/4 装订票据 =="
xcrun stapler staple "$APP"
if [ -n "$DMG" ] && [ -f "$DMG" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun stapler staple "$DMG"
fi

echo "== 4/4 校验 =="
spctl -a -vvv -t install "$APP" || echo "（spctl 未通过：通常是证书链或公证未完成）"
xcrun stapler validate "$APP"
echo "完成：可分发了"
