#!/bin/sh
# 多图切换体检：切来切去时每张图自己的编辑还在不在（editStates 的记忆）。
#
# 为什么需要它：用户在 A 图修了半天 → 切到 B 看一眼 → 切回 A，编辑必须还在；
# 而切图这条路上还踩过一个更严重的坑：**历史栈不跟着图重建**，
# 于是在 A 图编辑后切到 B 图按撤销，会把 A 图的编辑套到 B 图上（第 142 节 bug ③）。
#
# 判据：
#   A 图编辑后 vs A 原样 ≥ 3       —— 编辑真的生效
#   切到 B 后与 A 编辑后 ≥ 3        —— 确实换图了（不是没切动）
#   切到 B 后历史只剩 1 条          —— 历史栈跟着图重建
#   在 B 上按撤销：画面不动（=0）    —— 不许把 A 的编辑套过来，状态栏应说"已经是最初的状态"
#   切回 A：vs A 编辑后 ≤ 1 且 vs A 原样 ≥ 3 —— 编辑还在
#
# 用法：sh tools/dist/audit_strip.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
IMG="$ROOT/douyin_favorites/images"
A="${1:-$IMG/0001_7673816620465215714_01.webp}"
B="${2:-$IMG/0001_7685569954204725839_07.webp}"
LOG=/tmp/stripaudit_run.log

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$A" ] || { echo "缺夹具 $A —— 没测到不算通过"; exit 1; }
[ -f "$B" ] || { echo "缺夹具 $B —— 没测到不算通过"; exit 1; }

: > "$LOG"
CR_IMPORT="$A,$B" CR_STRIPAUDIT=1 "$APP" > "$LOG" 2>&1 &
pid=$!
i=0
while [ $i -lt 30 ]; do
    sleep 2; i=$((i+1))
    grep -q 'STRIPAUDIT 完' "$LOG" 2>/dev/null && break
done
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true

echo "夹具：$(basename "$A") + $(basename "$B")"
grep -E '^STRIPAUDIT ' "$LOG" | grep -v '完' | sed 's/^/  /' || true

n=$(grep -cE '^STRIPAUDIT 切回 A' "$LOG" || true)
if [ "$n" -ne 1 ]; then echo "!! 体检没跑完（缺"切回 A"那行）—— 没测到不算通过"; exit 1; fi

# 只解析**机器可读汇总行**：中文行里的"峰值/条数"在多字节下按字节算偏移，会读错（踩过）
awk '
    function ck(desc, ok) {
        if (ok) printf "  V %s\n", desc
        else { printf "  X %s\n", desc; bad++ }
    }
    /^STRIPAUDIT-SUM / {
        for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] + 0 }
    }
    END {
        histN = v["hist"]; histBefore = v["histBefore"]
        editPeak = v["edit"]; crossPeak = v["cross"]
        undoPeak = v["undo"]; backPeak = v["back"]; rawPeak = v["raw"]
        ck("A 图编辑生效（vs 原样 " editPeak " ≥ 3）",        editPeak >= 3)
        ck("确实换了图（与 A 编辑后 " crossPeak " ≥ 3）",      crossPeak >= 3)
        ck("编辑前历史里已有基准状态（" histBefore " 条 = 打开 + 一笔）", histBefore == 2)
        ck("历史栈跟着图重建（切图后只剩 " histN " 条）",       histN == 1)
        ck("B 图上撤销不会套用 A 的编辑（" undoPeak " = 0）",   undoPeak == 0)
        ck("切回 A 编辑还在（vs A 编辑后 " backPeak " ≤ 1）",   backPeak <= 1)
        ck("切回 A 确实带着编辑（vs A 原样 " rawPeak " ≥ 3）",  rawPeak >= 3)
        exit (bad > 0)
    }' "$LOG"
# ── 第 7 条：**笔触**的按图隔离 ────────────────────────────────
# 为什么单列：上面那几条比的是"两张不同的照片"，而两张不同的照片本来就该不一样 ——
# 所以它们**抓不到"笔触串图"**（§185.3）。而 currentEditState() 只存参数类状态、不含笔触，
# 于是"手动笔触算哪张图的"必须单独量：A 上下一笔 → 切到 B（不许串）→ 切回 A（不许丢）。
SLOG=/tmp/strokebaudit_run.log
: > "$SLOG"
CR_IMPORT="$A,$B" CR_STROKEAUDIT=1 "$APP" > "$SLOG" 2>&1 &
pid=$!
i=0
while [ $i -lt 40 ]; do
    sleep 2; i=$((i+1))
    grep -q 'STROKEAUDIT 完' "$SLOG" 2>/dev/null && break
done
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true
sk=$(grep -oE 'STROKEAUDIT-SUM.*' "$SLOG" | head -1)
if [ -z "$sk" ]; then
    echo "  X 7 笔触按图隔离：没拿到汇总行（见 $SLOG）—— 没测到不算通过"; fail=1
else
    echo "  · $sk"
    se=$(echo "$sk" | grep -oE 'edit=[0-9]+' | head -1 | sed 's/.*=//')
    sl=$(echo "$sk" | grep -oE 'leak=[0-9]+' | head -1 | sed 's/.*=//')
    sb=$(echo "$sk" | grep -oE 'back=[0-9]+' | head -1 | sed 's/.*=//')
    [ -n "$se" ] || se=0
    [ -n "$sl" ] || sl=99
    [ -n "$sb" ] || sb=99
    if [ "$se" -ge 3 ] && [ "$sl" -le 1 ] && [ "$sb" -le 1 ]; then
        echo "  V 7 笔触按图隔离：A 上那一笔改了画面（${se}），切到 B 不串（${sl}），切回 A 还在（${sb}）"
    else
        echo "  X 7 笔触按图隔离：edit=$se leak=$sl back=$sb（应当 edit>=3、leak<=1、back<=1）"; fail=1
    fi
fi

echo "多图切换体检：7 条判据"
