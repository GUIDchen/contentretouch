#!/bin/sh
# 交互工具体检：跑一次 App，把「工具 → 状态 → 渲染」这条链整条量一遍
# （污点修复 / 修补 / 仿制 / 液化 / 收缩 / 裁剪）。
#
# 为什么需要它：coretest 验的是核心函数、体检表（audit_params.sh）验的是**参数**，
# 而这些**交互工具**走的是「simulateTool 改状态 → refresh 重渲」——以前只有人手点一次才知道通不通。
# 它已经立刻抓到过一个真 bug：修补的自检钩子写错了数组（写 clonePoints、管线读 patchPoints），
# 于是 --simulate=patch 打印「修补落了 3 个点」、画面一像素没动（账本第 140 节）。
#
# 判据（两条都要满足，缺一即失败）：
#   ① 落点 ≥ 1  —— 工具状态真的落上了（写错数组/被清空会立刻变 0）
#   ② 峰值 ≥ 4  —— 状态落上之后，渲染确实动了
# 数值是 96 宽缩图上的逐像素差；局部效果的平均值本来就很小，所以看**峰值**不看均值。
#
# 用法：sh tools/dist/audit_tools.sh [照片路径]
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
PHOTO="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"
LOG=/tmp/toolaudit_run.log

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$PHOTO" ] || { echo "缺夹具 $PHOTO —— 没测到不算通过"; exit 1; }

: > "$LOG"
CR_IMPORT="$PHOTO" CR_TOOLAUDIT=1 "$APP" > "$LOG" 2>&1 &
pid=$!
i=0
while [ $i -lt 30 ]; do
    sleep 2; i=$((i+1))
    grep -q 'TOOLAUDIT 完' "$LOG" 2>/dev/null && break
done
kill $pid 2>/dev/null
# ⚠️ 必须 `|| true`：被 kill 的子进程会让 wait 返回 143，set -e 会当场把脚本干掉
#（踩过：脚本一个字的输出都没有就退出 143）
wait $pid 2>/dev/null || true

echo "夹具：$(basename "$PHOTO")"
grep -E '^TOOLAUDIT [a-z]+ ' "$LOG" || true

n=$(grep -cE '^TOOLAUDIT [a-z]+ 均值' "$LOG" || true)
if [ "$n" -ne 6 ]; then
    echo "!! 只量到 $n 个工具（应为 6）—— 没跑到的工具不算通过"; exit 1
fi

awk '/^TOOLAUDIT [a-z]+ 均值/ {
        tool = $2; peak = $7 + 0; pts = $10 + 0
        why = ""
        if (pts < 1) why = "落点 0（工具状态没落上）"
        else if (peak < 4) why = "峰值 " peak " < 4（状态落了但渲染没动）"
        if (why != "") { printf "  X %-8s %s\n", tool, why; bad++ }
        else printf "  V %-8s 落点 %d ｜ 峰值 %d\n", tool, pts, peak
    }
    END { exit (bad > 0) }' "$LOG"
echo "交互工具体检：6 个工具全部有落点、且都改到了画面"
