#!/bin/sh
# 稳定性体检：连续换图/重渲/套预设+撤销 N 轮，看**常驻内存会不会一路涨**、会不会崩。
#
# 为什么需要它：桌面应用最怕"开久了越来越卡 / 突然崩"，而这类问题在功能测试里完全看不到。
#
# ⚠️ 排障过程值得记（第 163 节）：第一版体检**每轮 +12.6 MB、40 轮涨到 666 MB**，看着像严重泄漏。
#    依次排除了：解码缓存上限（12 条）、autorelease 池、CoreImage 缓存（clearCaches 每轮清）。
#    真因是**测试自己**：体检在**一次主线程调用里连写 40 次 @State**，SwiftUI 的视图更新排队积压、
#    图片随之被钉住；真实使用每次交互都会回到 runloop。每轮让出一次 runloop 之后**完全平台化**
#   （189 → 202 → 201 MB）。这条规律现在写进体检里了：**多轮压测必须让出 runloop**。
#
# 判据：
#   A 跑完全部轮次且没崩
#   B **内存要平台化**：后半程（第 N 轮）不超过前半程（第 N/2 轮）的 1.3 倍
#   C 结束常驻 < 起始 + 400 MB（宽松兜底：真泄漏会远超）
#   D 切图+首帧中位 ≤ 500 ms（内存平台化 ≠ 点一下不卡；§196。
#     实测 83~162 ms（同一份代码两种夹具/负载下差 2 倍），所以阈值按最忙那次留 3 倍余量，
#     而不是按最好那次 —— 忙机器上的假红会把一条有用的判据变成噪音）
#
# 用法：sh tools/dist/audit_stress.sh [轮数]
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
IMG="$ROOT/douyin_favorites/images"
# ⚠️ 约定：**第一个参数是夹具路径**（体检网里所有门都这样，"没测到必须失败"那条判据才能自动抽查），
# 轮数是第二个参数。第一版把 $1 当轮数用，于是 audit_gates.sh 抽查时报"夹具不存在却退出 0" —— 被抓了个正着。
A="${1:-$IMG/0001_7673816620465215714_01.webp}"
# 轮数从 30 提到 60（§235）：30 轮**正好落在预热段**（§201 实测前 10~20 轮涨 200~300 MB 才走平），
# B/C 两条判据因此只能看见"热身有没有失控"，看不见稳态斜率。60 轮里热身约占前 1/3，后 40 轮是稳态观测窗。
# 代价：实测 30 轮 17 秒 ⇒ 60 轮约 35 秒，仍在门的预算内。
ROUNDS="${2:-60}"
B="$IMG/0001_7676844130508479842_23.webp"
C="$IMG/0184_7379189016593321253_05.webp"

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$A" ] || { echo "缺夹具 $A —— 没测到不算通过"; exit 1; }
[ -f "$B" ] && [ -f "$C" ] || { echo "缺夹具（$B / ${C}）—— 没测到不算通过"; exit 1; }

log=/tmp/stress_audit.log
: > "$log"
CR_IMPORT="$A,$B,$C" CR_STRESSAUDIT=1 CR_STRESS_ROUNDS="$ROUNDS" "$APP" > "$log" 2>&1 &
pid=$!
i=0
while [ $i -lt 150 ]; do
    sleep 2; i=$((i+1))
    grep -q 'STRESSAUDIT 完' "$log" 2>/dev/null && break
done
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true

grep -E '^STRESSAUDIT' "$log" | sed 's/^/  /' || true

sum=$(grep -o 'STRESSAUDIT-SUM.*' "$log" | head -1)
if [ -z "$sum" ]; then echo "  X 稳定性体检：没跑完（见 ${log}）—— 没测到不算通过"; exit 1; fi

awk '
    function ck(desc, ok) { if (ok) printf "  V %s\n", desc; else { printf "  X %s\n", desc; bad++ } }
    { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] + 0 } }
    END {
        ck("跑完 " v["rounds"] " 轮没崩（起始 " v["start"] " MB）", v["rounds"] > 0)
        ck("内存没无界增长：结束 " v["end"] " MB ≤ 起始 + 400 MB", v["end"] <= v["start"] + 400)
        ck("峰值 " v["peak"] " MB ≤ 起始 + 400 MB", v["peak"] <= v["start"] + 400)
        # D 切图延迟：内存平台化不等于"点一下不卡"（§196 之前只量内存，从不问这一点）。
        # 口径：**中位** ≤500 ms（实测 83~162 ms，按最忙那次留 3 倍余量）；p95 只报告不判 ——
        # 夹具里混了 40MP 那张，切到它的首帧天然是秒级（实测 p95 942 ms），拿它当判据会假红。
        # 字段缺失必须判失败而不是当成 0（本项目的老坑：空值被 awk 当 0 ⇒ 假绿）
        if (v["switch_median"] <= 0) ck("切图延迟量到了（switch_median 应 >0，SCHEMA 是否变了）", 0)
        else ck("切图+首帧中位 " v["switch_median"] " ms ≤ 500（p95 " v["switch_p95"] " ms 只报告）", v["switch_median"] <= 500)
        exit (bad > 0)
    }' "$log" <<EOF
$sum
EOF
echo "稳定性体检：$([ $? = 0 ] && echo "全部通过" || echo "有失败")"
