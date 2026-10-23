#!/bin/sh
# 画布坐标体检：指针落在画布上时，"屏幕坐标 → 图像坐标"必须对。
#
# 为什么需要它：账本里为坐标映射栽过两次（并排模式指针落错栏、滑杆双击复位算错矩形），
# 而这条链以前只有一个人眼看探针的输出。判据全部是**不变量**，与实现无关：
#   ① 每一栏的中心点 → 图像中心 (0.500, 0.500)（±0.02）
#   ② 每一栏"3/4 宽、1/2 高"处 → 0.5 + 0.25/Z（Z = 缩放倍率；适配模式 Z=1 时为 0.750）
#   ③ 适配模式下，栏外一点必须映射为 nil（否则工具会对画面外的位置动手）
# 历史对照：修好之前用的是"把整块画布当一张图"的老口径，两栏会算成 0.07 / 0.93 —— 偏离中心 0.43，
# 是容差的 20 倍，所以这条判据真的能抓住那类 bug。
#
# ⚠️ 必须带 --module 精修：默认进的是图库页，那里**没有画布**，paneFrames 永远为空
#    （实测：不带 --module 时探针 30 秒后报 CANVASPT-FAIL）。
# ⚠️ 参数一律用 --flag=value 单 token 形式；"裸参数"会让窗口根本不出现（AppKit 把它当成要打开的文件）。
#
# 用法：sh tools/dist/audit_canvas.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
PHOTO="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$PHOTO" ] || { echo "缺夹具 $PHOTO —— 没测到不算通过"; exit 1; }

run_one() {   # $1=标签 $2=日志 $3..=额外参数
    label=$1; log=$2; shift 2
    : > "$log"
    CR_IMPORT="$PHOTO" CR_CANVASPT=1 "$APP" --module 精修 --panel 1 "$@" > "$log" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 30 ]; do
        sleep 1; i=$((i+1))
        grep -qE 'CANVASPT-SUM|CANVASPT-FAIL' "$log" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
}

echo "夹具：$(basename "$PHOTO")"
bad=0
check_case() {   # $1=标签 $2=日志
    if grep -q 'CANVASPT-FAIL' "$2" 2>/dev/null; then
        echo "  X ${1}：探针没拿到画布（$(grep -o 'CANVASPT-FAIL.*' "$2" | head -1)）"; bad=1; return
    fi
    sum=$(grep -o 'CANVASPT-SUM.*' "$2" | head -1)
    [ -n "$sum" ] || { echo "  X ${1}：没有汇总行"; bad=1; return; }
    echo "  · ${1}：$sum"
    echo "$sum" | awk '
        function ck(desc, ok) {
            if (ok) printf "  V %s\n", desc
            else { printf "  X %s\n", desc; bad++ }
        }
        function abs(x) { return x < 0 ? -x : x }
        function num(s,   m) { if (match(s, /-?[0-9.]+/)) return substr(s, RSTART, RLENGTH) + 0; return -999 }
        {
            panes = 0; z = 0
            for (i = 1; i <= NF; i++) {
                if (index($i, "panes=") == 1) { split($i, kv, "="); panes = kv[2] + 0 }
                if (index($i, "z=") == 1)     { split($i, kv, "="); z = kv[2] + 0 }
                # ⚠️ 必须从 "(" 之后取数：token 形如 c0(0.500,0.514)，
                # 直接 num(token) 会取到索引里的 0/1（踩过：把 0.500 读成 0，判据全红）
                # ⚠️ 映射失败时 token 是 c0nil（没有括号）—— 必须**保留成判据**并判失败。
                # 第一版把这种 token 直接跳过了，于是"某栏根本映射不出来"反而变成假通过（负向验证时踩到）。
                # ⚠️ 必须用**严格的 token 形状**匹配：原来用 index($i,"c")==1 这种松匹配，
                # 后来汇总行里多了一个 cap=2800 字段，它也被当成"栏 a" → 多出一条 x=-999 的假判据（踩过）。
                if ($i ~ /^c[0-9]+\(/) { k = substr($i, 2, 1); j = index($i, "("); c[k] = num(substr($i, j)) }
                else if ($i ~ /^c[0-9]+nil$/) { k = substr($i, 2, 1); c[k] = -999 }
                if ($i ~ /^q[0-9]+\(/) { k = substr($i, 2, 1); j = index($i, "("); q[k] = num(substr($i, j)) }
                else if ($i ~ /^q[0-9]+nil$/) { k = substr($i, 2, 1); q[k] = -999 }
                if ($i ~ /^out[01][0-9]+$/) {
                    o[substr($i, 5)] = substr($i, 4, 1) + 0    # out%d%d = 标记 + 栏号
                }
            }
            # 期望：适配(z<1) 时 3/4 点 = 0.750；缩放 Z 时 = 0.5 + 0.25/(Z/100)
            want = (z < 1) ? 0.750 : 0.5 + 0.25 / (z / 100.0)
            ck("画布有两栏（src + out，实际 " panes "）", panes == 2)
            for (k in c) {
                ck("栏" k " 中心 → 图像中心（x=" c[k] "）", abs(c[k] - 0.500) <= 0.02)
            }
            for (k in q) {
                ck("栏" k " 3/4 点 → " want "（实际 " q[k] "）", abs(q[k] - want) <= 0.02)
            }
            if (z < 1) {
                for (k in o) {
                    ck("栏" k " 栏外一点 → nil（适配模式下越界必须返回空）", o[k] == 1)
                }
            }
            exit (bad > 0)
        }' || bad=1
}

run_one 默认 /tmp/cv_default.log
check_case "适配模式(z=0)" /tmp/cv_default.log
run_one zoom200 /tmp/cv_zoom200.log --zoom=200
check_case "缩放 200%" /tmp/cv_zoom200.log

echo "画布坐标体检：$([ "$bad" = "0" ] && echo "全部通过" || echo "有失败")"
exit $bad
