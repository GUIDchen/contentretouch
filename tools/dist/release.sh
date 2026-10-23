#!/bin/sh
# 发布清单：一条命令走完"预检 → 参数体检（对基线 + 留历史）→ 打包 dmg"。
# 为什么要有它：以前这三步是散在几次手工调用里的，而参数体检那一步（能抓"控件没接上"）
# 常常被漏掉 —— 它偏偏是最能防住本项目那类反复出现的问题的一步。
#
# 用法：sh tools/dist/release.sh 9.11.0
set -e
ROOT=/Users/you/Documents/DeepSeek-Harness-Projects/dsh-xiutu
VER=${1:?用法: sh tools/dist/release.sh <版本号，如 9.11.0>}
cd $ROOT

echo "==== 1/4 版本号 → $VER ===="
sed -i '' "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$VER</string>|" app-retouch/build_app.sh
grep -o '<key>CFBundleShortVersionString</key><string>[^<]*' app-retouch/build_app.sh

# ⚠️ 这里以前写的是 `sh preflight.sh 2>&1 | tail -6`：管道的退出码取自 **tail**，
# 预检失败也不会中止（set -e 只看到管道的最后一个命令）—— 发布门形同"建议"。
# 改成先落盘、判退出码、失败就中止，再打印尾部。
echo "==== 2/4 预检（编译 / coretest / 审计 / 界面回归 / 多图冒烟 / 模型 / 打包）===="
if ! sh tools/dist/preflight.sh > /tmp/release_preflight.log 2>&1; then
    tail -20 /tmp/release_preflight.log
    echo "预检未通过 —— 发布中止（别把没体检过的包发出去）"
    exit 1
fi
tail -6 /tmp/release_preflight.log

echo "==== 3/4 参数体检（对基线，结果写入体检历史）===="
if ! sh tools/dist/audit_params.sh check 60 > /tmp/release_audit.log 2>&1; then
    grep -vE 'Terminated' /tmp/release_audit.log | tail -20
    echo "参数体检未通过（回归 / 缺照片）—— 发布中止"
    exit 1
fi
grep -vE 'Terminated' /tmp/release_audit.log | tail -6

echo "==== 4/4 打包 dmg ===="
sh app-retouch/build_app.sh > /tmp/release_pkg.log 2>&1
rm -rf /tmp/dmgstage && mkdir -p /tmp/dmgstage && cp -R dist/ContentRetouch.app /tmp/dmgstage/
OUT=dist/ContentRetouch_${VER}_aarch64.dmg
hdiutil create -volname "智能修图" -srcfolder /tmp/dmgstage -ov -format UDZO "$OUT" > /dev/null
APPVER=$(defaults read "$ROOT/dist/ContentRetouch.app/Contents/Info.plist" CFBundleShortVersionString)
SIZE=$(du -h "$OUT" | cut -f1); echo "产物: $OUT  size=$SIZE  app_version=$APPVER"
git add -A && git -c user.email=dev@local -c user.name=dev commit -q -m "release: $VER" || true
echo "发布完成：$VER"