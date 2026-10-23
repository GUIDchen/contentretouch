#!/bin/sh
# 撤销 / 重做体检：用户的安全网，此前没有任何自动验证。
#
# 它在第一轮就抓出四个真 bug（账本第 142 节）：
#   ① 导入/切图时的"打开状态"没入历史 → 撤销到底也回不到最初的原图
#   ② undo() apply 的是**当前步**而不是上一步 → 第一次撤销画面纹丝不动，每步滞后一格
#   ③ 切换照片不重建历史栈（EditState 里没有历史）→ 在 A 图编辑后切到 B 图按撤销，
#      会把 **A 图的编辑**套到 B 图上
#   ④ 笔触历史记的是"笔前"状态、滑杆记的是"笔后"状态 → 两套语义混在一个数组里，
#      撤销一步会跳掉一整步；同时"预览（增量修复）"与"导出/撤销（批量修复）"结果不同
#
# 判据（数值是 96 宽缩图上的峰值差）：
#   编辑1 vs 初始 ≥ 3、编辑2 vs 编辑1 ≥ 3   —— 编辑真的生效（否则下面全是假通过）
#   撤销1 vs 编辑1 ≤ 1 且 vs 编辑2 ≥ 3      —— 撤销回到上一步，而不是"没动"
#   撤销2 vs 初始 ≤ 1                        —— 能回到最初的原图
#   撤销3 vs 初始 ≤ 1                        —— 到底之后必须不动
#   重做1 vs 编辑1 ≤ 1、重做2 vs 编辑2 ≤ 1   —— 重做精确回到那一版（也验"同一状态两次渲染一致"）
#
# 用法：sh tools/dist/audit_undo.sh [照片路径]
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
PHOTO="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"
LOG=/tmp/undoaudit_run.log

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$PHOTO" ] || { echo "缺夹具 $PHOTO —— 没测到不算通过"; exit 1; }

: > "$LOG"
CR_IMPORT="$PHOTO" CR_UNDOAUDIT=1 "$APP" > "$LOG" 2>&1 &
pid=$!
i=0
while [ $i -lt 30 ]; do
    sleep 2; i=$((i+1))
    grep -q 'UNDOAUDIT 完' "$LOG" 2>/dev/null && break
done
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true

echo "夹具：$(basename "$PHOTO")"
grep -E '^UNDOAUDIT ' "$LOG" | grep -v '完' | sed 's/^/  /' || true

n=$(grep -cE '^UNDOAUDIT 编辑2 后' "$LOG" || true)
if [ "$n" -ne 1 ]; then echo "!! 体检没跑完（缺编辑2 那行）—— 没测到不算通过"; exit 1; fi

awk '
    /^UNDOAUDIT / {
        step = $2
        for (i = 1; i <= NF; i++)
            if ($i == "vs" && $(i+2) == "峰值") { v[step "|" $(i+1)] = $(i+3) + 0 }
    }
    function ck(desc, ok) {
        if (ok) printf "  V %s\n", desc
        else { printf "  X %s\n", desc; bad++ }
    }
    END {
        ck("编辑1 生效（vs 初始 " v["编辑1|初始"] " ≥ 3）",            v["编辑1|初始"] >= 3)
        ck("编辑2 生效（vs 编辑1 " v["编辑2|编辑1"] " ≥ 3）",          v["编辑2|编辑1"] >= 3)
        ck("撤销1 回到上一步（vs 编辑1 " v["撤销1|编辑1"] " ≤ 1）",     v["撤销1|编辑1"] <= 1)
        ck("撤销1 确实动了（vs 编辑2 " v["撤销1|编辑2"] " ≥ 3）",       v["撤销1|编辑2"] >= 3)
        ck("撤销2 回到最初原图（vs 初始 " v["撤销2|初始"] " ≤ 1）",     v["撤销2|初始"] <= 1)
        ck("撤销3 到底后不再动（vs 初始 " v["撤销3|初始"] " ≤ 1）",     v["撤销3|初始"] <= 1)
        ck("重做1 精确回到编辑1（vs 编辑1 " v["重做1|编辑1"] " ≤ 1）",  v["重做1|编辑1"] <= 1)
        ck("重做2 精确回到编辑2（vs 编辑2 " v["重做2|编辑2"] " ≤ 1）",  v["重做2|编辑2"] <= 1)
        exit (bad > 0)
    }' "$LOG"
echo "撤销/重做体检：8 条判据"
