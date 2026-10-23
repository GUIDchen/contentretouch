#!/bin/sh
# 多图冒烟：拿一批**不同来源**的照片，逐个走"导入 → 渲染 → 截图"，
# 确认没有一个会崩、也没有"导入后画布空白"。
#
# 为什么单独有这个脚本：这个项目里踩过的坑几乎都来自"只用一张图测"——
#   · 腿的分支串了 bug，而测试用的半身照里没有腿，测试直接跳过；
#   · 皮肤掩膜、天空、衣物这些闸门的通过率，每张照片都不一样；
#   · 还有人像/宠物/天空都测不到的构图。
# 所以每次改完核心链路，除了 coretest，也应该跑一遍这个。
#
# 用法：sh tools/dist/smoke_multi.sh [张数，默认 8]
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
N=${1:-8}
BIN="$ROOT/app-retouch/.build/release/ContentRetouch"

[ -x "$BIN" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }

# 取样：抖音收藏里均匀取 + 婚礼 RAW 全取，混着来
FILES=""
for f in $(ls "$ROOT/douyin_favorites/images" 2>/dev/null | grep -E '\.(jpg|webp|png)$' | sort | awk -v n="$N" 'NR % 97 == 1' | head -$((N-2))); do
    FILES="$FILES $ROOT/douyin_favorites/images/$f"
done
for f in $(ls "$ROOT/2604_wedding/00_RAW_readonly" 2>/dev/null | grep -iE '\.(jpg|jpeg)$' | sort | head -2); do
    FILES="$FILES $ROOT/2604_wedding/00_RAW_readonly/$f"
done

ok=0; fail=0; got=0
for f in $FILES; do
    got=$((got+1))
    if [ ! -f "$f" ]; then
        # ⚠️ 这里以前是 `|| continue`：夹具丢了就少测一张，还照样报"通过"（第 128 节那个毛病）。
        echo "  [FAIL] $(basename "$f")  夹具不存在（取样列表里有、磁盘上没有）"
        fail=$((fail+1))
        continue
    fi
    out=/tmp/smoke_$$.png
    rm -f "$out"
    CR_IMPORT="$f" "$BIN" --module 精修 --panel 1 --screenshot "$out" >/dev/null 2>&1 || true
    if [ -s "$out" ]; then
        sz=$(/opt/homebrew/bin/magick identify -format "%wx%h" "$out" 2>/dev/null || echo "?")
        echo "  [OK]   $(basename "$f")  截图 $sz"
        ok=$((ok+1))
    else
        echo "  [FAIL] $(basename "$f")  没有产出截图"
        fail=$((fail+1))
    fi
    rm -f "$out"
done

echo "多图冒烟：取样 $got 张（要求 $N 张），通过 $ok 张，失败 $fail 张"
# 三条都要满足：确实取到足够的图、每张都出图、且没有失败。
# 「一张都没测到」曾经会返回 0（ok=0 fail=0 → 真），等于空跑也算通过。
[ "$got" -ge "$N" ] && [ "$ok" -gt 0 ] && [ "$fail" -eq 0 ]
